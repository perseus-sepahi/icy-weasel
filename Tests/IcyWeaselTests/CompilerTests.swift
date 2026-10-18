import XCTest
@testable import Icy_Weasel

final class CompilerTests: XCTestCase {

    /// WebKit's url-filter dialect is a strict subset of ICU regex, so if ICU
    /// gives the wrong answer the generated pattern is definitely wrong.
    private func matches(_ regex: String, _ url: String) -> Bool {
        let re = try! NSRegularExpression(pattern: regex, options: [.caseInsensitive])
        return re.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)) != nil
    }

    /// The separator style WebKit actually accepts today (see RegexDialectProbe).
    private var compiler: ContentRuleCompiler {
        var c = ContentRuleCompiler()
        c.separatorStyle = .compatible
        return c
    }

    private func rules(_ line: String) -> [String] {
        guard case .success(.network(let f)) = AdblockParser.parse(line: line) else {
            XCTFail("not a network filter: \(line)"); return []
        }
        return compiler.makeRules(from: f).map(\.trigger.urlFilter)
    }

    /// A URL is blocked if *any* rule emitted for the filter matches it.
    private func blocked(_ line: String, _ url: String) -> Bool {
        rules(line).contains { matches($0, url) }
    }

    private func filterRegex(_ line: String) -> String { rules(line).first ?? "" }

    func testDomainAnchorMatchesHostAndSubdomainsOnly() {
        let f = "||doubleclick.net^"
        XCTAssertTrue(blocked(f, "https://doubleclick.net/"))
        XCTAssertTrue(blocked(f, "https://ad.doubleclick.net/pixel?x=1"))
        XCTAssertTrue(blocked(f, "http://stats.g.doubleclick.net:8080/"))
        // The negatives are the ones that matter: over-blocking breaks sites.
        XCTAssertFalse(blocked(f, "https://notdoubleclick.net/"))
        XCTAssertFalse(blocked(f, "https://doubleclick.net.example.com/"))
        XCTAssertFalse(blocked(f, "https://example.com/?ref=doubleclick.net"))
    }

    func testPureHostRuleEmitsExactlyOneRule() {
        // Canonical http(s) URLs always have a path, so no `$` companion needed.
        XCTAssertEqual(rules("||doubleclick.net^").count, 1)
    }

    func testTrailingSeparatorOnPathAlsoMatchesEndOfURL() {
        let f = "||example.com/ads^"
        XCTAssertEqual(rules(f).count, 2, "path rule needs the end-of-URL companion")
        XCTAssertTrue(blocked(f, "https://example.com/ads"), "URL ending right at the separator")
        XCTAssertTrue(blocked(f, "https://example.com/ads?id=1"))
        XCTAssertTrue(blocked(f, "https://example.com/ads/banner.png"))
        XCTAssertFalse(blocked(f, "https://example.com/adsense.js"), "`^` must not match a letter")
    }

    func testWildcardAndStartAndEndAnchors() {
        let f = "|https://cdn.*/ad.js|"
        XCTAssertTrue(blocked(f, "https://cdn.example.com/ad.js"))
        XCTAssertFalse(blocked(f, "https://cdn.example.com/ad.js?v=2"))
        XCTAssertFalse(blocked(f, "xhttps://cdn.example.com/ad.js"))
    }

    func testEveryGeneratedRegexPassesTheWebKitValidator() {
        let lines = ["||a.com^", "||a.com/x^", "|https://b.com/*.js|", "/banner(1).gif^",
                     "-ad-unit^", "||c.com^$script,third-party", "@@||d.com/ok^"]
        for line in lines {
            for regex in rules(line) {
                XCTAssertTrue(ContentRuleCompiler.isWebKitCompatible(regex: regex),
                              "\(line) generated \(regex), which WebKit would reject")
            }
        }
    }

    func testRegexMetacharactersInPatternAreEscaped() {
        let r = filterRegex("/banner(1).gif")
        XCTAssertTrue(matches(r, "https://x.com/banner(1).gif"))
        XCTAssertFalse(matches(r, "https://x.com/banner1Xgif"), "literal dot must not match any char")
    }

    func testRawRegexFeaturesWebKitCannotHonourAreRejected() {
        for line in ["/ad\\d+\\.js/", "/(?=ads)/", "/a{2,3}/", "/(ads|track)/",
                     "/(a)\\1/", "/a$b/", "/a^b/"] {
            guard case .success(.network(let f)) = AdblockParser.parse(line: line) else { continue }
            XCTAssertNil(compiler.urlFilterRegex(for: f), "\(line) would fail or misbehave in WebKit")
        }
        guard case .success(.network(let ok)) = AdblockParser.parse(line: "/^https:\\/\\/[a-z]+\\.ads\\.[a-z]+\\//") else {
            return XCTFail("parse")
        }
        XCTAssertNotNil(compiler.urlFilterRegex(for: ok), "a plain anchored regex must survive")
    }

    func testDomainOptionsGetWildcardPrefix() {
        let set = ContentRuleCompiler().compile(lines: ["||t.com^$domain=news.com"])
        XCTAssertEqual(set.chunks.first?.first?.trigger.ifDomain, ["*news.com"])
    }

    func testIfAndUnlessDomainTogetherIsDropped() {
        let set = ContentRuleCompiler().compile(lines: ["||t.com^$domain=a.com|~b.a.com"])
        XCTAssertTrue(set.chunks.flatMap { $0 }.isEmpty, "WebKit rejects both keys in one trigger")
    }

    // MARK: Chunk invariants

    func testExceptionsFollowBlocksInEveryChunk() {
        var lines = (0..<250).map { "||tracker\($0).com^" }
        lines += ["@@||tracker7.com^$script", "@@||tracker200.com^"]
        var compiler = ContentRuleCompiler()
        compiler.maxRulesPerChunk = 60

        let set = compiler.compile(lines: lines)
        XCTAssertGreaterThan(set.chunks.count, 1)

        for (i, chunk) in set.chunks.enumerated() {
            let exceptionCount = chunk.filter { $0.action.type == "ignore-previous-rules" }.count
            XCTAssertEqual(exceptionCount, 2, "chunk \(i) must carry every exception")

            // No network block may appear after a network exception, or the
            // exception would silently fail to cancel it.
            if let firstException = chunk.firstIndex(where: { $0.action.type == "ignore-previous-rules" }) {
                XCTAssertTrue(chunk[firstException...].allSatisfy { $0.action.type == "ignore-previous-rules" },
                              "chunk \(i) has a block rule after an exception")
            }
            XCTAssertLessThanOrEqual(chunk.count, 60)
        }
        let totalBlocks = set.chunks.flatMap { $0 }.filter { $0.action.type == "block" }.count
        XCTAssertEqual(totalBlocks, 250, "chunking must not lose or duplicate block rules")
    }

    func testGenericCosmeticPicksUpUnhideExceptions() {
        let set = ContentRuleCompiler().compile(lines: ["##.promo", "shop.com#@#.promo"])
        let rule = set.chunks.flatMap { $0 }.first { $0.action.type == "css-display-none" }
        XCTAssertEqual(rule?.action.selector, ".promo")
        XCTAssertEqual(rule?.trigger.unlessDomain, ["*shop.com"])
    }

    func testStatsAccountForEveryLine() {
        let lines = ["! c", "", "||a.com^", "@@||b.com^", "##.x", "||c.com^$redirect=noop"]
        let stats = ContentRuleCompiler().compile(lines: lines).stats
        XCTAssertEqual(stats.totalLines, 6)
        XCTAssertEqual(stats.comments, 2)
        XCTAssertEqual(stats.networkRules, 1)
        XCTAssertEqual(stats.exceptionRules, 1)
        XCTAssertEqual(stats.cosmeticRules, 1)
        XCTAssertEqual(stats.rejected, 1)
    }

    func testDuplicateRulesAcrossListsAreRemoved() {
        let set = compiler.compile(lines: ["||ads.com^", "||tracker.com^", "||ads.com^", "@@||ok.com^", "@@||ok.com^"])
        let all = set.chunks.flatMap { $0 }
        XCTAssertEqual(all.filter { $0.action.type == "block" }.count, 2)
        XCTAssertEqual(all.filter { $0.action.type == "ignore-previous-rules" }.count, 1)
        XCTAssertEqual(set.stats.duplicatesRemoved, 2)
    }

    // MARK: Page-scoped exceptions (regression: bat.bing.com / analytics.tiktok.com)

    private func layerOf(_ rule: ContentRule, in chunk: [ContentRule]) -> Int { chunk.firstIndex(of: rule)! }

    func testGenericHideExceptionCannotReachNetworkRules() throws {
        let set = compiler.compile(lines: [
            "##.ad", "bing.com##.sponsored", "||bat.bing.com^", "@@||bing.com^$generichide"
        ])
        let cosmeticChunk = try XCTUnwrap(set.chunks.first { $0.contains { $0.action.type == "css-display-none" } })
        let networkChunks = set.chunks.filter { $0.contains { $0.action.type == "block" } }
        XCTAssertFalse(networkChunks.isEmpty)

        // The exception lives only where cosmetics live.
        for chunk in networkChunks {
            XCTAssertFalse(chunk.contains { $0.trigger.ifDomain == ["*bing.com"] },
                           "a $generichide exception must never sit in a list with network blocks")
        }
        let exception = try XCTUnwrap(cosmeticChunk.first { $0.action.type == "ignore-previous-rules" })
        XCTAssertEqual(exception.trigger.urlFilter, ".*", "page-scoped, not request-scoped")
        XCTAssertEqual(exception.trigger.ifDomain, ["*bing.com"])

        let generic = try XCTUnwrap(cosmeticChunk.firstIndex { $0.action.selector == ".ad" })
        let specific = try XCTUnwrap(cosmeticChunk.firstIndex { $0.action.selector == ".sponsored" })
        let exceptionIndex = try XCTUnwrap(cosmeticChunk.firstIndex(of: exception))
        XCTAssertLessThan(generic, exceptionIndex, "generichide cancels generic cosmetics…")
        XCTAssertLessThan(exceptionIndex, specific, "…but not site-specific ones")
        XCTAssertEqual(set.stats.pageExceptions, 1)
    }

    func testSiteCosmeticsAreDocumentScopedOneRulePerSite() throws {
        let set = compiler.compile(lines: [
            "news.example##.promo", "news.example,shop.example##.chat",
            "shop.example,~beta.shop.example##.upsell", "##.generic-ad", "~news.example##.popup"
        ])
        let rules = set.chunks.flatMap { $0 }.filter { $0.action.type == "css-display-none" }
        let promo = try XCTUnwrap(rules.first { $0.action.selector == ".promo" })
        XCTAssertEqual(promo.trigger.resourceType, ["document"])
        XCTAssertNil(promo.trigger.ifDomain, "site is in the url-filter, not a .* + if-domain condition")
        XCTAssertTrue(matches(promo.trigger.urlFilter, "https://www.news.example/story"))
        XCTAssertFalse(matches(promo.trigger.urlFilter, "https://news.example.evil.test/"))
        XCTAssertEqual(rules.filter { $0.action.selector == ".chat" }.count, 2, "one rule per listed site, never merged")

        let upsell = try XCTUnwrap(rules.first { $0.action.selector == ".upsell" })
        XCTAssertEqual(upsell.trigger.unlessDomain, ["*beta.shop.example"], "exclusions survive as a document-time condition")

        let universal = try XCTUnwrap(rules.first { $0.action.selector == ".generic-ad" })
        XCTAssertEqual(universal.trigger.urlFilter, ".*")
        XCTAssertNil(universal.trigger.resourceType, "unconditional rules keep WebKit's universal fast path")

        let conditioned = try XCTUnwrap(rules.first { $0.action.selector == ".popup" })
        XCTAssertEqual(conditioned.trigger.resourceType, ["document"])
        XCTAssertEqual(conditioned.trigger.unlessDomain, ["*news.example"])
    }

    func testDocumentExceptionIsPageWideAndLast() throws {
        let set = compiler.compile(lines: ["||tracker.example^", "@@||bank.example^$document", "@@||cdn.example^"])
        let chunk = try XCTUnwrap(set.chunks.first)
        let last = try XCTUnwrap(chunk.last)
        XCTAssertEqual(last.trigger.urlFilter, ".*")
        XCTAssertEqual(last.trigger.ifDomain, ["*bank.example"], "$document allowlists the page, not requests to it")
    }

    func testPathScopedPageExceptionUsesTopURL() throws {
        let set = compiler.compile(lines: ["##.ad", "@@||bing.com/search?$generichide"])
        let rule = try XCTUnwrap(set.chunks.first?.first { $0.action.type == "ignore-previous-rules" })
        XCTAssertNil(rule.trigger.ifDomain)
        let top = try XCTUnwrap(rule.trigger.ifTopURL?.first)
        XCTAssertTrue(matches(top, "https://www.bing.com/search?q=weasel"))
        XCTAssertFalse(matches(top, "https://www.bing.com/maps"))
    }

    func testEntityDomainsNeverWidenARule() {
        // Include list: the entity entry is removed, the real one kept.
        let narrowed = compiler.compile(lines: ["##.ad", "@@*$ghide,domain=web.de|gmx.*"]).chunks.flatMap { $0 }
        XCTAssertEqual(narrowed.first { $0.action.type == "ignore-previous-rules" }?.trigger.ifDomain, ["*web.de"])
        // Include list of only entities: dropped, never left unscoped.
        XCTAssertTrue(compiler.compile(lines: ["||ads.example^$domain=gmx.*"]).chunks.flatMap { $0 }.isEmpty)
        // Exclude list with an entity: dropped, never widened onto the exempted site.
        XCTAssertTrue(compiler.compile(lines: ["||ads.example^$domain=~gmx.*"]).chunks.flatMap { $0 }.isEmpty)
    }

    func testLayerOrderHoldsInEveryChunk() {
        var c = compiler
        c.maxRulesPerChunk = 40
        var lines = (0..<60).map { "||t\($0).example^" }
        lines += (0..<30).map { "##.ad\($0)" } + (0..<30).map { "s\($0).example##.x" }
        lines += ["@@||a.example^$generichide", "@@||b.example^$elemhide", "@@||c.example^", "@@||d.example^$document"]
        let set = c.compile(lines: lines)
        XCTAssertGreaterThan(set.chunks.count, 2)
        for (i, chunk) in set.chunks.enumerated() {
            func rank(_ r: ContentRule) -> Int {
                if r.action.type == "css-display-none" { return r.trigger.urlFilter == ".*" ? 0 : 2 }
                if r.action.type == "block" { return 4 }
                switch r.trigger.ifDomain?.first {
                case "*a.example": return 1
                case "*b.example": return 3
                case "*d.example": return 6
                default: return 5
                }
            }
            let ranks = chunk.map(rank)
            XCTAssertEqual(ranks, ranks.sorted(), "chunk \(i) is out of layer order: \(ranks)")
            let isCosmetic = chunk.contains { $0.action.type == "css-display-none" }
            let isNetwork = chunk.contains { $0.action.type == "block" }
            XCTAssertFalse(isCosmetic && isNetwork, "chunk \(i) mixes families")
            let exceptions = chunk.filter { $0.action.type == "ignore-previous-rules" }.count
            XCTAssertEqual(exceptions, isCosmetic ? 3 : 2,
                           "chunk \(i): cosmetic lists carry generichide+elemhide+document, network lists network+document")
        }
    }

    /// Regression for the Swift `case a, b where c` pitfall: a `$document` block
    /// rule must block navigation, never allowlist the page.
    func testDocumentBlockRuleBlocksInsteadOfAllowlisting() throws {
        let set = compiler.compile(lines: ["||malware.example^$document"])
        let rule = try XCTUnwrap(set.chunks.first?.first)
        XCTAssertEqual(rule.action.type, "block")
        XCTAssertEqual(rule.trigger.resourceType, ["document"])
        XCTAssertEqual(set.stats.pageExceptions, 0)
    }

    // MARK: Subsumption

    func testRulesCoveredByAHostRuleAreRemoved() {
        let set = compiler.compile(lines: [
            "||tracker.example^",
            "||tracker.example/pixel.gif",          // covered: same host
            "||ads.tracker.example^$script",        // covered: subdomain
            "||tracker.example:8443/beacon",        // covered: port is a separator
            "||tracker.example.evil.test^",         // NOT covered: different host
            "||tracker.examples.test^",             // NOT covered
            "||tracker.example*.js",                // NOT covered: wildcard reaches other hosts
            "||tracker.example",                    // NOT covered: no separator, matches tracker.example.au
            "@@||tracker.example/ok.js"             // exceptions are never pruned
        ])
        let filters = set.chunks.flatMap { $0 }.map(\.trigger.urlFilter)
        XCTAssertEqual(set.stats.subsumedRemoved, 3, "\(filters)")
        XCTAssertTrue(filters.contains { $0.contains("evil") })
        XCTAssertTrue(filters.contains { $0.contains("examples") })
        XCTAssertEqual(set.chunks.flatMap { $0 }.filter { $0.action.type == "ignore-previous-rules" }.count, 1)
    }

    func testAConditionalHostRuleCoversNothing() {
        // `$third-party` means first-party requests are NOT blocked by it, so it
        // cannot stand in for a more specific unconditional rule.
        let set = compiler.compile(lines: ["||cdn.example^$third-party", "||cdn.example/ads.js"])
        XCTAssertEqual(set.stats.subsumedRemoved, 0)
    }

    func testSplittingAChunkKeepsEveryExceptionWithEveryHalf() {
        var c = compiler
        c.maxRulesPerChunk = 10_000
        let set = c.compile(lines: (0..<40).map { "||t\($0).example^" } + ["@@||t3.example/ok", "@@||t30.example^$document"])
        let chunk = set.chunks[0]
        let (left, right) = ContentBlockerStore.splitPreservingExceptions(chunk)
        let blocks = { (r: [ContentRule]) in r.filter { $0.action.type == "block" }.count }
        let exceptions = { (r: [ContentRule]) in r.filter { $0.action.type == "ignore-previous-rules" }.count }
        XCTAssertEqual(blocks(left) + blocks(right), blocks(chunk), "no block lost or duplicated")
        XCTAssertEqual(exceptions(left), exceptions(chunk))
        XCTAssertEqual(exceptions(right), exceptions(chunk))
        // Order within each half still puts exceptions after the blocks they cancel.
        for half in [left, right] {
            let lastBlock = half.lastIndex { $0.action.type == "block" }!
            XCTAssertTrue(half[..<lastBlock].allSatisfy { $0.action.type == "block" })
        }
    }
}
