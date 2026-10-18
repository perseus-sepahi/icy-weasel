import XCTest
import WebKit
@testable import Icy_Weasel

/// Runs the production pipeline — fetch, parse, compile, WebKit compile with
/// bisect — against the real default filter lists.
///
/// Network-dependent, so gated: `TEST_RUNNER_IW_NETWORK_TESTS=1 xcodebuild test`.
@MainActor
final class RealFilterListTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IW_NETWORK_TESTS"] == "1",
                          "set IW_NETWORK_TESTS=1 to run against live filter lists")
    }

    /// Tests run inside the app's container. Compiled lists are tens of MB each,
    /// so anything a test builds must not outlive it.
    override func tearDown() async throws {
        let store = WKContentRuleListStore.default()!
        let ids: [String] = await withCheckedContinuation { c in
            store.getAvailableContentRuleListIdentifiers { c.resume(returning: $0 ?? []) }
        }
        for id in ids where id.hasPrefix("iw-realtest-") || id.hasPrefix("test-") {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                store.removeContentRuleList(forIdentifier: id) { _ in c.resume() }
            }
        }
    }

    func testDefaultListsCompileEndToEnd() async throws {
        let fetcher = FilterListFetcher()
        let sources = FilterListCatalog.all.filter(\.defaultEnabled)

        var texts: [String] = []
        var report = "\n=== Real filter list pipeline ===\n"
        let fetchStart = Date()
        for source in sources {
            let text = await fetcher.text(for: source, maxAge: 3600)
            let lines = text.map { ContentBlockerStore.lines(of: [$0]).count } ?? 0
            report += "  fetched \(source.id.padding(toLength: 18, withPad: " ", startingAt: 0)) \(lines.formatted()) lines\n"
            if let text { texts.append(text) }
        }
        report += "  fetch: \(String(format: "%.1f", Date().timeIntervalSince(fetchStart)))s\n"
        XCTAssertEqual(texts.count, sources.count, "every default list should download")

        // Parse + translate only, to separate our cost from WebKit's.
        let store = ContentBlockerStore()
        var compiler = ContentRuleCompiler()
        compiler.separatorStyle = await store.probeSeparatorStyle()
        let parseStart = Date()
        let lines = ContentBlockerStore.lines(of: texts)
        let dry = compiler.compile(lines: lines)
        let parseTime = Date().timeIntervalSince(parseStart)
        let emitted = dry.chunks.reduce(0) { $0 + $1.count }

        report += "  parse+translate: \(String(format: "%.2f", parseTime))s for \(dry.stats.totalLines.formatted()) lines\n"
        report += "  network rules \(dry.stats.networkRules.formatted()), cosmetic \(dry.stats.cosmeticRules.formatted()), exceptions \(dry.stats.exceptionRules.formatted())\n"
        report += "  comments/blank \(dry.stats.comments.formatted()), unsupported \(dry.stats.rejected.formatted())\n"
        report += "  duplicates removed \(dry.stats.duplicatesRemoved.formatted()), subsumed by host rules \(dry.stats.subsumedRemoved.formatted()), page exceptions \(dry.stats.pageExceptions.formatted())\n"
        report += "  emitted \(emitted.formatted()) WebKit rules across \(dry.chunks.count) chunk(s)\n"
        let top = dry.stats.rejectionsByReason.sorted { $0.value > $1.value }.prefix(12)
        report += "  top rejection reasons:\n"
        for (reason, count) in top { report += "    \(count.formatted().padding(toLength: 7, withPad: " ", startingAt: 0)) \(reason)\n" }

        // Full production path, cold (cache purged by a unique name).
        let compileStart = Date()
        let ruleset = try await store.buildRuleset(named: "realtest-\(Int(Date().timeIntervalSince1970))", from: texts)
        let compileTime = Date().timeIntervalSince(compileStart)
        report += "  WebKit compile (cold): \(String(format: "%.1f", compileTime))s -> \(ruleset.lists.count) list(s), \(ruleset.droppedByCompiler) rule(s) rejected by WebKit\n"

        // Warm path: the same name + content must skip parsing entirely.
        let warmName = "realtest-\(Int(Date().timeIntervalSince1970))"
        let warmStart = Date()
        let warm = try await store.buildRuleset(named: warmName, from: texts)
        _ = warmStart
        let hitStart = Date()
        let hit = try await store.buildRuleset(named: warmName, from: texts)
        let hitTime = Date().timeIntervalSince(hitStart)
        report += "  relaunch (cache hit, no parse): \(String(format: "%.3f", hitTime))s -> \(hit.lists.count) list(s)\n"
        print(report)

        XCTAssertGreaterThanOrEqual(ruleset.lists.count, dry.chunks.count, "every chunk yields at least one list (more if split)")
        XCTAssertGreaterThan(dry.stats.networkRules, 20_000, "sanity: real lists are large")
        let dropRate = Double(ruleset.droppedByCompiler) / Double(max(1, emitted))
        XCTAssertLessThan(dropRate, 0.01, "validator should pre-empt nearly all WebKit rejections")
        XCTAssertFalse(warm.lists.isEmpty)
        XCTAssertEqual(hit.lists.count, warm.lists.count)
        XCTAssertLessThan(hitTime, 1.0, "a cache hit must not re-parse 160k lines")
    }
}
