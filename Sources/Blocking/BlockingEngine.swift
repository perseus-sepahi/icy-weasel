import Foundation
import WebKit
import Observation
import os

/// Coordinates filter lists, compilation and the rule lists attached to tabs.
///
/// Rule lists are attached to a `WKUserContentController` at runtime, which is
/// what makes the per-site escape hatch possible: allowlisting a site is just
/// removing the lists from that one tab's controller, with no reconfiguration
/// and no new web view.
@MainActor
@Observable
final class BlockingEngine {

    enum State: Equatable {
        case idle
        case loading(String)
        case ready(rules: Int, lists: Int)
        case failed(String)
    }

    static let listsDidChange = Notification.Name("IcyWeaselRuleListsDidChange")

    private(set) var state: State = .idle
    /// Setting either list set notifies open tabs. Tabs capture their lists when
    /// they wake, so without this a tab opened before compilation finished —
    /// including the very first tab at launch — would never be protected.
    private(set) var contentLists: [WKContentRuleList] = [] {
        didSet { NotificationCenter.default.post(name: Self.listsDidChange, object: self) }
    }
    private(set) var securityLists: [WKContentRuleList] = [] {
        didSet { NotificationCenter.default.post(name: Self.listsDidChange, object: self) }
    }
    private(set) var stats = CompileStats()
    /// Estimated blocks this session. See `BlockCounter` for why it is an estimate.
    var sessionBlockEstimate = 0

    private let store = ContentBlockerStore()
    private let fetcher = FilterListFetcher()
    private let log = Logger(subsystem: "com.icyweasel.browser", category: "engine")
    private var settings: BrowserSettings

    init(settings: BrowserSettings) {
        self.settings = settings
    }

    /// All rule lists a tab should carry, given the policy in force for its site.
    func lists(for policy: ResolvedSitePolicy) -> [WKContentRuleList] {
        var result: [WKContentRuleList] = []
        if policy.blockAds { result += contentLists }
        if policy.httpsOnly || policy.blockThirdPartyCookies { result += securityLists }
        return result
    }

    // MARK: Loading

    /// Seeds from the bundled list first so blocking is live within milliseconds
    /// of launch, then upgrades to the full network lists in the background.
    func start() async {
        await buildSecurityLists()
        await loadSeed()
        await refresh()
    }

    private func loadSeed() async {
        guard contentLists.isEmpty else { return }
        guard let url = Bundle.main.url(forResource: "seed-filters", withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            log.error("Bundled seed list missing")
            return
        }
        state = .loading("Loading built-in rules")
        do {
            let ruleset = try await store.buildRuleset(named: "seed", from: [text])
            contentLists = ruleset.lists
            stats = ruleset.stats
            state = .ready(rules: ruleset.stats.converted, lists: ruleset.lists.count)
        } catch {
            log.error("Seed compile failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    /// Fetches every enabled list and recompiles. Safe to call repeatedly; a
    /// content hash short-circuits the expensive path when nothing changed.
    func refresh(force: Bool = false) async {
        let sources = FilterListCatalog.all.filter { settings.enabledFilterLists.contains($0.id) }
        guard !sources.isEmpty else {
            await loadSeed()
            return
        }

        state = .loading("Updating filter lists")
        var texts: [String] = []
        if let seedURL = Bundle.main.url(forResource: "seed-filters", withExtension: "txt"),
           let seed = try? String(contentsOf: seedURL, encoding: .utf8) {
            texts.append(seed)
        }
        for source in sources {
            if let text = await fetcher.text(for: source, maxAge: force ? 0 : 86_400 * 3) {
                texts.append(text)
            }
        }
        texts.append(settings.customFilters)

        do {
            state = .loading("Compiling \(texts.count) lists")
            let ruleset = try await store.buildRuleset(named: "content", from: texts)
            guard !ruleset.lists.isEmpty else {
                state = .failed("No rules compiled"); return
            }
            contentLists = ruleset.lists
            stats = ruleset.stats
            state = .ready(rules: ruleset.stats.converted, lists: ruleset.lists.count)
            settings.lastFilterUpdate = Date()
        } catch {
            log.error("Content compile failed: \(error.localizedDescription)")
            state = .failed(error.localizedDescription)
        }
    }

    // MARK: Security rules

    /// Rules that enforce transport and cookie policy. Separate from the content
    /// lists so toggling ad blocking for one site never weakens its transport
    /// security — the two escape hatches are genuinely independent.
    private func buildSecurityLists() async {
        var rules: [ContentRule] = []

        // Upgrade every plaintext load to HTTPS.
        rules.append(ContentRule(
            trigger: .init(
                urlFilter: "^http://",
                urlFilterIsCaseSensitive: nil,
                resourceType: nil, loadType: nil, ifDomain: nil, unlessDomain: nil
            ),
            action: .init(type: "make-https", selector: nil)
        ))

        // Deny cookies to third parties outright.
        rules.append(ContentRule(
            trigger: .init(
                urlFilter: ".*",
                urlFilterIsCaseSensitive: nil,
                resourceType: nil,
                loadType: [WebKitLoadType.thirdParty.rawValue],
                ifDomain: nil, unlessDomain: nil
            ),
            action: .init(type: "block-cookies", selector: nil)
        ))

        // Loopback has no usable certificate. Exempt it last so
        // `ignore-previous-rules` cancels the upgrade above. `[:/]` needs no `$`
        // alternative: a canonical http URL always has a path, so the host is
        // always followed by `:` or `/` (and WebKit rejects `$` in a group anyway).
        for host in ["localhost", "127\\.0\\.0\\.1", "\\[::1\\]", "0\\.0\\.0\\.0"] {
            rules.append(ContentRule(
                trigger: .init(
                    urlFilter: "^http://\(host)[:/]",
                    urlFilterIsCaseSensitive: nil,
                    resourceType: nil, loadType: nil, ifDomain: nil, unlessDomain: nil
                ),
                action: .init(type: "ignore-previous-rules", selector: nil)
            ))
        }

        // Generated, not parsed, so these bypass the filter compiler entirely
        // and are compiled under a fixed identifier that survives list refreshes.
        do {
            let json = try CompiledRuleset.encode(rules)
            securityLists = try await compileDirect(identifier: "iw-security-v1", json: json)
        } catch {
            log.error("Security rules failed to compile: \(error.localizedDescription)")
        }
    }

    private func compileDirect(identifier: String, json: String) async throws -> [WKContentRuleList] {
        try await withCheckedThrowingContinuation { continuation in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: identifier, encodedContentRuleList: json
            ) { list, error in
                if let list { continuation.resume(returning: [list]) }
                else { continuation.resume(throwing: error ?? BlockerError.compileFailed) }
            }
        }
    }
}
