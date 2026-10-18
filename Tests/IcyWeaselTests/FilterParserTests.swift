import XCTest
@testable import Icy_Weasel

final class FilterParserTests: XCTestCase {

    private func network(_ line: String, file: StaticString = #filePath, line l: UInt = #line) -> NetworkFilter? {
        guard case .success(.network(let f)) = AdblockParser.parse(line: line) else {
            XCTFail("Expected network filter for \(line)", file: file, line: l); return nil
        }
        return f
    }

    func testCommentsAndHeadersAreSkipped() {
        for line in ["! comment", "[Adblock Plus 2.0]", "", "   ", "# hosts-style comment"] {
            guard case .failure(let reason) = AdblockParser.parse(line: line) else {
                return XCTFail("\(line) should be rejected")
            }
            XCTAssertTrue(reason == .comment || reason == .empty, "\(line) -> \(reason)")
        }
    }

    func testDomainAnchorAndSeparator() throws {
        let f = try XCTUnwrap(network("||doubleclick.net^"))
        XCTAssertTrue(f.domainAnchored)
        XCTAssertFalse(f.isException)
        XCTAssertEqual(f.pattern, "doubleclick.net^")
        XCTAssertTrue(f.resourceTypes.isEmpty, "no options means every type")
    }

    func testExceptionWithOptions() throws {
        let f = try XCTUnwrap(network("@@||example.com/ads.js$script,domain=news.com|~sports.news.com"))
        XCTAssertTrue(f.isException)
        XCTAssertEqual(f.resourceTypes, [.script])
        XCTAssertEqual(f.includeDomains, ["news.com"])
        XCTAssertEqual(f.excludeDomains, ["sports.news.com"])
    }

    func testThirdPartyAndNegation() throws {
        XCTAssertEqual(network("||cdn.com^$third-party")?.loadType, .thirdParty)
        XCTAssertEqual(network("||cdn.com^$~third-party")?.loadType, .firstParty)
        XCTAssertEqual(network("||cdn.com^$1p")?.loadType, .firstParty)
    }

    func testNegatedTypesExpandToComplement() throws {
        let f = try XCTUnwrap(network("||x.com^$~script,~image"))
        XCTAssertFalse(f.resourceTypes.contains(.script))
        XCTAssertFalse(f.resourceTypes.contains(.image))
        XCTAssertTrue(f.resourceTypes.contains(.styleSheet))
        XCTAssertFalse(f.resourceTypes.contains(.popup), "popup must never be implied by negation")
    }

    func testRegexLiteralKeepsInnerDollar() throws {
        let f = try XCTUnwrap(network("/ads[0-9]+$/$image"))
        XCTAssertTrue(f.isRawRegex)
        XCTAssertEqual(f.pattern, "ads[0-9]+$")
        XCTAssertEqual(f.resourceTypes, [.image])
    }

    func testUnsupportedOptionsAreRejectedNotApproximated() {
        for line in ["||x.com^$redirect=noop.js", "||x.com^$csp=script-src 'none'",
                     "||x.com^$removeparam=utm_source", "||x.com^$badfilter"] {
            guard case .failure(.unsupportedOption) = AdblockParser.parse(line: line) else {
                return XCTFail("\(line) must be rejected, not approximated")
            }
        }
    }

    func testCosmeticParsing() throws {
        guard case .success(.cosmetic(let c)) = AdblockParser.parse(line: "example.com,~shop.example.com##.banner") else {
            return XCTFail("expected cosmetic")
        }
        XCTAssertEqual(c.selector, ".banner")
        XCTAssertEqual(c.includeDomains, ["example.com"])
        XCTAssertEqual(c.excludeDomains, ["shop.example.com"])
        XCTAssertFalse(c.isException)
    }

    func testProceduralCosmeticsRejectedButHasAllowed() {
        guard case .failure(.unsupportedSelector) = AdblockParser.parse(line: "x.com##div:has-text(Sponsored)") else {
            return XCTFail(":has-text is procedural and must be rejected")
        }
        guard case .failure(.unsupportedSelector) = AdblockParser.parse(line: "x.com##+js(set-constant, a, 1)") else {
            return XCTFail("scriptlets must be rejected")
        }
        guard case .success(.cosmetic) = AdblockParser.parse(line: "x.com##div:has(> .sponsored)") else {
            return XCTFail(":has() is real CSS in modern WebKit and should pass")
        }
    }

    func testPageScopedExceptionOptions() throws {
        XCTAssertEqual(network("@@||example.com^$generichide")?.pageScope, .genericHide)
        XCTAssertEqual(network("@@||example.com^$ghide")?.pageScope, .genericHide)
        XCTAssertEqual(network("@@||example.com^$elemhide")?.pageScope, .elementHide)
        XCTAssertEqual(network("@@||example.com^$shide")?.pageScope, .elementHide)
        XCTAssertEqual(network("@@||example.com^$document")?.pageScope, .document)
        XCTAssertEqual(network("@@||example.com^$ghide,document")?.pageScope, .document, "widest scope wins")
        XCTAssertNil(network("@@||example.com^$script")?.pageScope, "request-level exception")
        XCTAssertNil(network("||example.com^$document")?.pageScope, "$document on a block rule blocks navigation")
    }

    func testPreciseResourceTypes() throws {
        XCTAssertEqual(network("||x.com^$xmlhttprequest")?.resourceTypes, [.fetch])
        XCTAssertEqual(network("||x.com^$websocket")?.resourceTypes, [.websocket])
        XCTAssertEqual(network("||x.com^$ping")?.resourceTypes, [.ping])
        XCTAssertEqual(network("||x.com^$object")?.resourceTypes, [.other])
    }

    /// Regression: AdGuard serves CRLF. Swift treats "\r\n" as one Character,
    /// so a naive split(separator: "\n") returned the whole list as one line.
    func testCRLFListsSplitIntoLines() {
        let crlf = "! Title\r\n||ads.example^\r\n||track.example^\r\n##.banner"
        let lines = ContentBlockerStore.lines(of: [crlf])
        XCTAssertEqual(lines, ["! Title", "||ads.example^", "||track.example^", "##.banner"])

        let stats = ContentRuleCompiler().compile(lines: lines).stats
        XCTAssertEqual(stats.networkRules, 2, "CRLF rules must not be swallowed as a comment")
        XCTAssertEqual(stats.cosmeticRules, 1)
    }

    func testMixedAndBareCRLineEndings() {
        XCTAssertEqual(ContentBlockerStore.lines(of: ["a\nb\rc\r\nd"]), ["a", "b", "c", "d"])
    }

    func testAdGuardExtendedSyntaxIsNotMistakenForNetworkRules() {
        for line in ["example.com#%#//scriptlet('abort-on-property-read', 'ads')",
                     "example.com#?#div:-abp-has(.sponsored)",
                     "example.com#$#body { overflow: auto !important; }",
                     "example.com$$script[tag-content=\"ads\"]",
                     "example.com#@%#window.x = 1"] {
            guard case .failure(.unsupportedSyntax) = AdblockParser.parse(line: line) else {
                return XCTFail("\(line) must be rejected as extended syntax")
            }
        }
    }
}
