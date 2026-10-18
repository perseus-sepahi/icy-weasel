import XCTest
import WebKit
@testable import Icy_Weasel

/// These tests hand our output to the real WebKit rule compiler and a real
/// `WKWebView`. Unit tests on the JSON only prove we produce what we *think*
/// WebKit wants; these prove WebKit accepts it and actually applies it.
@MainActor
final class WebKitIntegrationTests: XCTestCase {

    private let store = WKContentRuleListStore.default()!

    private func compile(_ rules: [ContentRule], id: String = UUID().uuidString) async throws -> WKContentRuleList {
        let json = try CompiledRuleset.encode(rules)
        return try await withCheckedThrowingContinuation { c in
            store.compileContentRuleList(forIdentifier: "test-\(id)", encodedContentRuleList: json) { list, error in
                if let list { c.resume(returning: list) } else { c.resume(throwing: error!) }
            }
        }
    }

    func testSeparatorProbeResolves() async {
        let style = await ContentBlockerStore().probeSeparatorStyle()
        // Either answer is valid; the point is WebKit gave one and we recorded it.
        print("WebKit separator style: \(style)")
    }

    func testBundledSeedListCompilesCleanlyInWebKit() async throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: "seed-filters", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)

        var compiler = ContentRuleCompiler()
        compiler.separatorStyle = await ContentBlockerStore().probeSeparatorStyle()
        let set = compiler.compile(lines: ContentBlockerStore.lines(of: [text]))

        XCTAssertEqual(set.stats.rejected, 0, "seed list should be 100% supported syntax: \(set.stats.rejectionsByReason)")
        for (i, chunk) in set.chunks.enumerated() {
            // Compiling chunks whole, without bisect, proves no rule was silently dropped.
            _ = try await compile(chunk, id: "seed-\(i)")
        }
    }

    func testSecurityRuleActionsCompile() async throws {
        let rules = [
            ContentRule(trigger: .init(urlFilter: "^http://", urlFilterIsCaseSensitive: nil, resourceType: nil,
                                       loadType: nil, ifDomain: nil, unlessDomain: nil),
                        action: .init(type: "make-https", selector: nil)),
            ContentRule(trigger: .init(urlFilter: ".*", urlFilterIsCaseSensitive: nil, resourceType: nil,
                                       loadType: ["third-party"], ifDomain: nil, unlessDomain: nil),
                        action: .init(type: "block-cookies", selector: nil)),
            ContentRule(trigger: .init(urlFilter: "^http://localhost[:/]", urlFilterIsCaseSensitive: nil,
                                       resourceType: nil, loadType: nil, ifDomain: nil, unlessDomain: nil),
                        action: .init(type: "ignore-previous-rules", selector: nil))
        ]
        _ = try await compile(rules, id: "security")
    }

    func testBisectRecoversFromOneBadRule() async throws {
        let good = (0..<40).map { i in
            ContentRule(trigger: .init(urlFilter: "^https://good\(i)\\.com", urlFilterIsCaseSensitive: nil,
                                       resourceType: nil, loadType: nil, ifDomain: nil, unlessDomain: nil),
                        action: .init(type: "block", selector: nil))
        }
        // One rule WebKit rejects, buried in the middle. Unbisected, it would
        // take all forty good rules down with it.
        var bad = good[0]
        bad.trigger.urlFilter = "(ads|track)"
        let poisoned = Array(good[..<20]) + [bad] + Array(good[20...])

        let json = try CompiledRuleset.encode(poisoned)
        let wholeListRejected: Bool = await withCheckedContinuation { c in
            store.compileContentRuleList(forIdentifier: "test-poison", encodedContentRuleList: json) { list, _ in
                c.resume(returning: list == nil)
            }
        }
        XCTAssertTrue(wholeListRejected, "precondition: one bad rule fails the entire list")

        let (lists, lost) = try await ContentBlockerStore().compileWithBisect(identifier: "test-bisect", rules: poisoned)
        XCTAssertEqual(lists.count, 1, "bisect must salvage the good rules into one list")
        XCTAssertEqual(lost, 1, "exactly the one bad rule should be dropped")
    }

    /// The static validator exists to avoid paying for bisect. It must never
    /// approve something the real compiler refuses.
    func testStaticValidatorNeverApprovesWhatWebKitRejects() async {
        let samples = ["^https://a\\.com/", "a.*b", "[^a-zA-Z0-9_.%-]", "(ab)+", "a\\.js$",
                       "(ab|cd)", "a([:/]|$)", "a$b", "a^b", "a{2}", "(?:ab)", "a(?=b)",
                       "a\\d", "a\\w", "\\ba", "(a)\\1", "caf\u{e9}",
                       "^[a-z][a-z0-9+.-]*://([^/?#]+\\.)?x\\.com"]
        var approved = 0
        for pattern in samples where ContentRuleCompiler.isWebKitCompatible(regex: pattern) {
            approved += 1
            let rule = ContentRule(trigger: .init(urlFilter: pattern, urlFilterIsCaseSensitive: nil,
                                                  resourceType: nil, loadType: nil, ifDomain: nil, unlessDomain: nil),
                                   action: .init(type: "block", selector: nil))
            let accepted = (try? await compile([rule])) != nil
            XCTAssertTrue(accepted, "validator approved \(pattern) but WebKit rejected it")
        }
        XCTAssertGreaterThan(approved, 3, "sanity: the validator should approve the plain cases")
    }

    /// End to end: parse → compile → attach to a real web view → WebKit hides
    /// the element. Needs no network, so it is deterministic in CI.
    func testCosmeticRuleIsAppliedByRealWebView() async throws {
        let set = ContentRuleCompiler().compile(lines: [
            "##.adsbygoogle",
            "example.test##.site-specific-ad",
            "other.test##.control"
        ])
        let list = try await compile(try XCTUnwrap(set.chunks.first), id: "cosmetic")

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(list)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)

        let navigation = NavigationWaiter()
        webView.navigationDelegate = navigation
        webView.loadHTMLString("""
            <html><body>
              <ins class="adsbygoogle" id="generic">ad</ins>
              <div class="site-specific-ad" id="specific">ad</div>
              <div class="control" id="control">content</div>
              <div class="article" id="article">content</div>
            </body></html>
            """, baseURL: URL(string: "https://example.test/")!)
        try await navigation.wait()
        // Cosmetic rules are applied via a stylesheet WebKit injects; give layout a beat.
        try await Task.sleep(for: .milliseconds(300))

        func display(_ id: String) async throws -> String {
            try await webView.evaluateJavaScript(
                "getComputedStyle(document.getElementById('\(id)')).display"
            ) as? String ?? "?"
        }

        let generic = try await display("generic")
        let specific = try await display("specific")
        let control = try await display("control")
        let article = try await display("article")
        XCTAssertEqual(generic, "none", "generic ##rule should hide on every site")
        XCTAssertEqual(specific, "none", "domain rule should hide on its own domain")
        XCTAssertNotEqual(control, "none", "rule scoped to other.test must not fire on example.test")
        XCTAssertNotEqual(article, "none", "unrelated content must be untouched")
    }
}

final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    func wait() async throws {
        if finished { return }
        try await withCheckedThrowingContinuation { self.continuation = $0 }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finished = true
        continuation?.resume(); continuation = nil
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}
