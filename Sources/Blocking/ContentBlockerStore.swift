import Foundation
import WebKit
import CryptoKit
import os

/// Owns compilation and caching of `WKContentRuleList`s.
///
/// Compiling ~100k rules takes seconds and allocates heavily, so it must happen
/// once per filter-list *version*, never once per launch. `WKContentRuleListStore`
/// persists compiled DFA bytecode on disk; we key entries by a content hash so a
/// changed list recompiles and an unchanged one loads in milliseconds.
@MainActor
final class ContentBlockerStore {

    struct Ruleset {
        var identifier: String
        var lists: [WKContentRuleList]
        var stats: CompileStats
        var droppedByCompiler: Int
    }

    private let store: WKContentRuleListStore
    private let log = Logger(subsystem: "com.icyweasel.browser", category: "blocking")
    private var separatorStyle: ContentRuleCompiler.SeparatorStyle?

    init(store: WKContentRuleListStore? = nil) {
        self.store = store ?? .default()
    }

    // MARK: Capability probe

    /// WebKit's rule compiler has varied in whether it accepts `($|[^…])` for the
    /// `^` separator token. Guessing wrong fails *every* rule that uses `^`,
    /// which is most of them — so ask WebKit directly, once, with a 1-rule list.
    func probeSeparatorStyle() async -> ContentRuleCompiler.SeparatorStyle {
        if let cached = separatorStyle { return cached }

        // The answer can only change with WebKit, i.e. with the OS. Probing
        // compiles a list WebKit is expected to reject, and every rejected
        // compile leaves a small temp file in the store, so ask once per OS build
        // instead of once per launch.
        let key = "iw.separatorStyle.\(ProcessInfo.processInfo.operatingSystemVersionString)"
        if let stored = UserDefaults.standard.string(forKey: key) {
            let style: ContentRuleCompiler.SeparatorStyle = stored == "strict" ? .strict : .compatible
            separatorStyle = style
            return style
        }

        let probe = ContentRule(
            trigger: .init(
                urlFilter: "^[a-z][a-z0-9+.-]*://([^/?#]+\\.)?probe\\.invalid($|[^a-zA-Z0-9_.%-])",
                urlFilterIsCaseSensitive: nil, resourceType: nil,
                loadType: nil, ifDomain: nil, unlessDomain: nil
            ),
            action: .init(type: "block", selector: nil)
        )

        let style: ContentRuleCompiler.SeparatorStyle
        if let json = try? CompiledRuleset.encode([probe]),
           (try? await compileList(identifier: "iw-probe", json: json)) != nil {
            style = .strict
        } else {
            log.notice("Separator probe rejected strict form; using compatible form")
            style = .compatible
        }
        try? await removeList(identifier: "iw-probe")
        separatorStyle = style
        UserDefaults.standard.set(style == .strict ? "strict" : "compatible", forKey: key)
        return style
    }

    // MARK: Building

    /// What was compiled last time, so a relaunch can skip parsing entirely.
    private struct Manifest: Codable {
        var fingerprint: String
        var identifiers: [String]
        var stats: CompileStats
    }

    private func manifestKey(_ name: String) -> String { "iw.manifest.\(name)" }

    /// Compiles `sources` into rule lists, reusing cached bytecode when the
    /// content hash is unchanged.
    ///
    /// The cache hit is the hot path — it runs on every launch — so it must not
    /// parse. Hashing the raw text is milliseconds; parsing 160k lines is
    /// seconds. We hash, compare against the manifest, and look up the compiled
    /// lists directly. Parsing only happens on a genuine content change, and
    /// then off the main actor so the window stays responsive.
    func buildRuleset(
        named name: String,
        from sources: [String],
        maxRulesPerChunk: Int = ContentRuleCompiler.defaultMaxRulesPerChunk
    ) async throws -> Ruleset {
        let style = await probeSeparatorStyle()
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let compilerKey = "\(ContentRuleCompiler.outputVersion)|\(build)|\(style.pattern)|\(maxRulesPerChunk)"
        let fingerprint = await Task.detached(priority: .userInitiated) {
            Self.hash(sources.joined(separator: "\n") + "|" + compilerKey)
        }.value
        let baseIdentifier = "iw-\(name)-\(fingerprint)"

        if let cached = await cachedRuleset(name: name, fingerprint: fingerprint, baseIdentifier: baseIdentifier) {
            log.notice("Ruleset \(name, privacy: .public): cache hit, \(cached.lists.count) list(s), no parse")
            return cached
        }

        let ruleset = await Task.detached(priority: .userInitiated) {
            var compiler = ContentRuleCompiler()
            compiler.separatorStyle = style
            compiler.maxRulesPerChunk = maxRulesPerChunk
            return compiler.compile(lines: Self.lines(of: sources))
        }.value

        // WebKit compiles each list on its own background queue, so chunks can
        // build concurrently. The bound keeps peak memory sane: a 30k-rule
        // compile briefly holds a large NFA→DFA working set.
        let compiled = try await compileChunks(ruleset.chunks, baseIdentifier: baseIdentifier, maxConcurrent: 4)
        let lists = compiled.flatMap(\.lists)
        let dropped = compiled.reduce(0) { $0 + $1.lost }

        // Only record a manifest for a complete build, or a later launch would
        // "hit" a cache that is missing chunks.
        if !lists.isEmpty,
           let data = try? JSONEncoder().encode(Manifest(
               fingerprint: fingerprint, identifiers: lists.map(\.identifier), stats: ruleset.stats)) {
            UserDefaults.standard.set(data, forKey: manifestKey(name))
        }
        await purgeStale(name: name, keeping: baseIdentifier)

        log.notice("""
            Ruleset \(name, privacy: .public): \(ruleset.stats.converted) rules in \
            \(lists.count) list(s), \(ruleset.stats.rejected) unsupported, \(dropped) rejected by WebKit
            """)
        return Ruleset(identifier: baseIdentifier, lists: lists, stats: ruleset.stats, droppedByCompiler: dropped)
    }

    /// Compiles chunks with bounded concurrency, returning results in chunk order
    /// (order across lists does not affect matching, but stable order keeps
    /// identifiers and logs deterministic).
    private func compileChunks(
        _ chunks: [[ContentRule]],
        baseIdentifier: String,
        maxConcurrent: Int
    ) async throws -> [(lists: [WKContentRuleList], lost: Int)] {
        var results = [(lists: [WKContentRuleList], lost: Int)](repeating: ([], 0), count: chunks.count)
        try await withThrowingTaskGroup(of: (Int, [WKContentRuleList], Int).self) { group in
            var next = 0
            func launch(_ index: Int) {
                group.addTask { @MainActor in
                    let (lists, lost) = try await self.compileWithBisect(
                        identifier: "\(baseIdentifier)-\(index)", rules: chunks[index]
                    )
                    return (index, lists, lost)
                }
            }
            while next < min(maxConcurrent, chunks.count) { launch(next); next += 1 }
            while let (index, lists, lost) = try await group.next() {
                results[index] = (lists, lost)
                if next < chunks.count { launch(next); next += 1 }
            }
        }
        return results
    }

    private func cachedRuleset(name: String, fingerprint: String, baseIdentifier: String) async -> Ruleset? {
        guard let data = UserDefaults.standard.data(forKey: manifestKey(name)),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.fingerprint == fingerprint, !manifest.identifiers.isEmpty
        else { return nil }

        var lists: [WKContentRuleList] = []
        for identifier in manifest.identifiers {
            // Any missing list means the store was cleared behind our back;
            // fall through to a full rebuild rather than block with a partial set.
            guard let list = try? await lookUpList(identifier: identifier) else { return nil }
            lists.append(list)
        }
        return Ruleset(identifier: baseIdentifier, lists: lists, stats: manifest.stats, droppedByCompiler: 0)
    }

    /// Splits filter text into lines, handling LF, CR and CRLF.
    ///
    /// `split(separator: "\n")` is wrong here: Swift treats `"\r\n"` as a single
    /// `Character`, which never equals `"\n"`. A CRLF list (AdGuard serves them)
    /// would arrive as one enormous line, parse as a comment, and vanish.
    nonisolated static func lines(of sources: [String]) -> [String] {
        sources.flatMap { $0.split(whereSeparator: \.isNewline).map(String.init) }
    }

    /// WebKit rejects a whole list if a single rule is malformed, and its error
    /// does not say which one. It also rejects lists that are simply too large.
    /// Those two failures need opposite responses — drop the bad rule, or split
    /// the list — and treating a size failure as a bad rule silently discards
    /// the entire chunk.
    ///
    /// Returns one list normally, several if the chunk had to be split, and the
    /// number of rules genuinely rejected.
    func compileWithBisect(
        identifier: String,
        rules: [ContentRule]
    ) async throws -> ([WKContentRuleList], Int) {
        guard !rules.isEmpty else { return ([], 0) }

        if let json = try? CompiledRuleset.encode(rules),
           let list = try? await compileList(identifier: identifier, json: json) {
            return ([list], 0)
        }

        let survivors = await survivingRules(rules, probeIdentifier: identifier + "-probe")
        try? await removeList(identifier: identifier + "-probe")
        let lost = rules.count - survivors.count
        if lost > 0 { log.notice("WebKit rejected \(lost) rule(s) in \(identifier, privacy: .public)") }
        guard !survivors.isEmpty else { return ([], rules.count) }

        if let json = try? CompiledRuleset.encode(survivors),
           let list = try? await compileList(identifier: identifier, json: json) {
            return ([list], lost)
        }

        // Every piece compiles but the whole does not: a size limit, not a bad
        // rule. Split in two (each half stays a valid, independent list) and
        // recurse. Exceptions must stay with their blocks, so split by position
        // only within the content part and give both halves every exception.
        log.notice("Splitting \(identifier, privacy: .public) (\(survivors.count) rules): too large for one list")
        let (left, right) = Self.splitPreservingExceptions(survivors)
        guard !left.isEmpty, !right.isEmpty, left.count < survivors.count else { return ([], rules.count) }
        let (a, lostA) = try await compileWithBisect(identifier: identifier + "a", rules: left)
        let (b, lostB) = try await compileWithBisect(identifier: identifier + "b", rules: right)
        return (a + b, lost + lostA + lostB)
    }

    /// Splits a chunk into two chunks that are each correct on their own: the
    /// non-exception rules are divided, and every `ignore-previous-rules` rule
    /// goes into both, in its original relative position.
    nonisolated static func splitPreservingExceptions(_ rules: [ContentRule]) -> ([ContentRule], [ContentRule]) {
        let contentIndices = rules.indices.filter { rules[$0].action.type != "ignore-previous-rules" }
        guard contentIndices.count >= 2 else { return (rules, []) }
        let firstHalf = Set(contentIndices.prefix(contentIndices.count / 2))
        var left: [ContentRule] = [], right: [ContentRule] = []
        for index in rules.indices {
            let rule = rules[index]
            if rule.action.type == "ignore-previous-rules" {
                left.append(rule); right.append(rule)
            } else if firstHalf.contains(index) {
                left.append(rule)
            } else {
                right.append(rule)
            }
        }
        return (left, right)
    }

    /// Returns the subset of `rules` WebKit accepts, preserving order.
    ///
    /// Recursion returns *rules*, not compiled lists: a half that compiles only
    /// after its bad rule was removed must not be re-merged whole, or the bad
    /// rule comes straight back and poisons the parent.
    private func survivingRules(_ rules: [ContentRule], probeIdentifier: String) async -> [ContentRule] {
        guard !rules.isEmpty else { return [] }
        if await compiles(rules, identifier: probeIdentifier) { return rules }
        guard rules.count > 1 else {
            log.debug("Dropping rule rejected by WebKit: \(rules[0].trigger.urlFilter, privacy: .public)")
            return []
        }
        let mid = rules.count / 2
        let left = await survivingRules(Array(rules[..<mid]), probeIdentifier: probeIdentifier)
        let right = await survivingRules(Array(rules[mid...]), probeIdentifier: probeIdentifier)
        return left + right
    }

    private func compiles(_ rules: [ContentRule], identifier: String) async -> Bool {
        guard let json = try? CompiledRuleset.encode(rules) else { return false }
        return (try? await compileList(identifier: identifier, json: json)) != nil
    }

    // MARK: Store plumbing

    private func compileList(identifier: String, json: String) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { list, error in
                if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: error ?? BlockerError.compileFailed) }
            }
        }
    }

    private func lookUpList(identifier: String) async throws -> WKContentRuleList {
        try await withCheckedThrowingContinuation { continuation in
            store.lookUpContentRuleList(forIdentifier: identifier) { list, error in
                if let list { continuation.resume(returning: list) }
                else { continuation.resume(throwing: error ?? BlockerError.notCached) }
            }
        }
    }

    private func removeList(identifier: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.removeContentRuleList(forIdentifier: identifier) { error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume() }
            }
        }
    }

    /// Removes superseded builds of *one* ruleset.
    ///
    /// Scoping by name is essential. The seed and content rulesets coexist, and
    /// an unscoped purge run while building the seed would delete the cached
    /// content lists — forcing a multi-second cold recompile on every launch.
    private func purgeStale(name: String, keeping current: String) async {
        let identifiers: [String] = await withCheckedContinuation { continuation in
            store.getAvailableContentRuleListIdentifiers { continuation.resume(returning: $0 ?? []) }
        }
        let prefix = "iw-\(name)-"
        for identifier in identifiers
        where identifier.hasPrefix(prefix) && !identifier.hasPrefix(current + "-") {
            try? await removeList(identifier: identifier)
        }
    }

    nonisolated private static func hash(_ string: String) -> String {
        SHA256.hash(data: Data(string.utf8))
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

enum BlockerError: Error {
    case compileFailed
    case notCached
}
