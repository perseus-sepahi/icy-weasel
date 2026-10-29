import XCTest
@testable import Icy_Weasel

final class URLSanitizerTests: XCTestCase {

    func testStripsGlobalTrackersAndKeepsRealParameters() {
        let url = URL(string: "https://shop.com/item?id=42&utm_source=news&fbclid=abc&color=red")!
        let result = URLSanitizer.sanitize(url)
        XCTAssertEqual(result.url.absoluteString, "https://shop.com/item?id=42&color=red")
        XCTAssertEqual(Set(result.removed), ["utm_source", "fbclid"])
    }

    func testRemovesQuestionMarkWhenQueryBecomesEmpty() {
        let result = URLSanitizer.sanitize(URL(string: "https://a.com/p?gclid=1")!)
        XCTAssertEqual(result.url.absoluteString, "https://a.com/p")
    }

    func testHostScopedParametersOnlyApplyOnTheirHost() {
        let yt = URLSanitizer.sanitize(URL(string: "https://www.youtube.com/watch?v=abc&si=track")!)
        XCTAssertEqual(yt.url.absoluteString, "https://www.youtube.com/watch?v=abc")
        // `si` is a real parameter on unrelated sites and must survive there.
        let other = URLSanitizer.sanitize(URL(string: "https://example.com/?si=keep")!)
        XCTAssertFalse(other.didChange)
    }

    func testSanitizingIsIdempotent() {
        let once = URLSanitizer.sanitize(URL(string: "https://a.com/?utm_medium=x&q=1&_ga=2")!).url
        XCTAssertTrue(URLSanitizer.isClean(once), "second pass must be a no-op or navigation loops")
    }

    func testFragmentAndPathPreserved() {
        let result = URLSanitizer.sanitize(URL(string: "https://a.com/x/y?utm_source=1#section")!)
        XCTAssertEqual(result.url.absoluteString, "https://a.com/x/y#section")
    }
}

final class OmniboxTests: XCTestCase {
    private func resolve(_ s: String) -> String? {
        BrowserViewModel.resolve(input: s, searchEngine: .duckDuckGo)?.absoluteString
    }

    func testBareHostGoesToHTTPS() {
        XCTAssertEqual(resolve("example.com"), "https://example.com")
        XCTAssertEqual(resolve("news.ycombinator.com/item?id=1"), "https://news.ycombinator.com/item?id=1")
    }

    func testSpacesMeanSearchEvenWithDots() {
        // Otherwise "node.js tutorial" would be sent to DNS as a hostname.
        XCTAssertTrue(resolve("node.js tutorial")?.hasPrefix("https://duckduckgo.com/?q=") == true)
    }

    func testLocalhostStaysPlaintext() {
        XCTAssertEqual(resolve("localhost:3000"), "http://localhost:3000")
    }

    func testExplicitSchemeIsRespected() {
        XCTAssertEqual(resolve("http://neverssl.com"), "http://neverssl.com")
    }

    func testSingleWordIsSearch() {
        XCTAssertTrue(resolve("weasels")?.contains("duckduckgo") == true)
    }
}

final class PublicSuffixTests: XCTestCase {
    func testRegistrableDomains() {
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "a.b.example.com"), "example.com")
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "user.github.io"), "user.github.io")
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "192.168.1.1"), "192.168.1.1")
    }

    func testThirdPartyDetection() {
        let page = URL(string: "https://www.nytimes.com/")!
        XCTAssertFalse(PublicSuffix.isThirdParty(URL(string: "https://static.nytimes.com/a.js"), relativeTo: page))
        XCTAssertTrue(PublicSuffix.isThirdParty(URL(string: "https://doubleclick.net/a.js"), relativeTo: page))
    }
}

@MainActor
final class FailureClassificationTests: XCTestCase {
    private let plain = URL(string: "http://neverssl.com/")!

    private func error(_ code: Int) -> NSError { NSError(domain: NSURLErrorDomain, code: code) }

    func testUpgradeTimeoutMeansNoHTTPS() {
        // Observed for neverssl.com in HTTPSPolicyProbe.
        XCTAssertEqual(Tab.classify(error(NSURLErrorTimedOut), upgradeTarget: plain, failingURL: nil),
                       .insecureTransport(plain))
    }

    func testUnknownHostIsNotBlamedOnHTTPS() {
        let issue = Tab.classify(error(NSURLErrorCannotFindHost), upgradeTarget: plain, failingURL: nil)
        guard case .loadFailed = issue else { return XCTFail("DNS failure blamed on HTTPS: \(issue)") }
    }

    func testOfflineIsNotBlamedOnHTTPS() {
        let issue = Tab.classify(error(NSURLErrorNotConnectedToInternet), upgradeTarget: plain, failingURL: nil)
        guard case .loadFailed = issue else { return XCTFail("offline blamed on HTTPS: \(issue)") }
    }

    func testBadCertificateOnRequestedHTTPSIsACertificateIssue() {
        let issue = Tab.classify(error(NSURLErrorServerCertificateUntrusted), upgradeTarget: nil,
                                 failingURL: URL(string: "https://self-signed.example/"))
        guard case .certificateInvalid = issue else { return XCTFail("\(issue)") }
    }

    func testBadCertificateOnAnUpgradeOffersTheHTTPEscapeHatch() {
        XCTAssertEqual(Tab.classify(error(NSURLErrorServerCertificateHasUnknownRoot), upgradeTarget: plain, failingURL: nil),
                       .insecureTransport(plain))
    }
}

@MainActor
final class DownloadNamingTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testServerSuppliedPathCannotEscapeDownloads() {
        let target = DownloadManager.uniqueDestination(for: "../../Library/LaunchAgents/evil.plist", in: dir)
        XCTAssertEqual(target.deletingLastPathComponent().standardizedFileURL, dir.standardizedFileURL)
        XCTAssertEqual(target.lastPathComponent, "evil.plist")
    }

    func testExistingFilesAreNeverOverwritten() throws {
        try Data().write(to: dir.appendingPathComponent("report.pdf"))
        try Data().write(to: dir.appendingPathComponent("report 2.pdf"))
        XCTAssertEqual(DownloadManager.uniqueDestination(for: "report.pdf", in: dir).lastPathComponent, "report 3.pdf")
    }
}

final class ExternalSchemePolicyTests: XCTestCase {
    private func decide(_ url: String, main: Bool = true, click: Bool = true) -> ExternalSchemePolicy.Decision {
        ExternalSchemePolicy.decide(url: URL(string: url)!, isMainFrame: main, isUserClick: click)
    }

    func testWebSchemesRenderNormally() {
        XCTAssertEqual(decide("https://example.com"), .web)
        XCTAssertEqual(decide("blob:https://example.com/uuid", main: false, click: false), .web)
    }

    func testNetworkSharesAndFilesAreNeverOpened() {
        for url in ["smb://attacker.example/share", "file:///etc/passwd", "afp://host/x", "ssh://host", "ftp://host/f"] {
            guard case .block = decide(url) else { return XCTFail("\(url) must be refused even on a click") }
        }
    }

    func testAppSchemesNeedAClickInTheTopFrame() {
        guard case .block = decide("zoommtg://join?id=1", click: false) else { return XCTFail("script-driven launch") }
        guard case .block = decide("zoommtg://join?id=1", main: false) else { return XCTFail("subframe launch") }
        XCTAssertEqual(decide("mailto:a@b.example"), .confirm(scheme: "mailto"))
    }
}

@MainActor
final class SitePolicyStoreTests: XCTestCase {
    private func makeStores() -> (SitePolicyStore, BrowserSettings) {
        let suite = "iw-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return (SitePolicyStore(defaults: defaults), BrowserSettings(defaults: defaults))
    }

    func testTogglingBackToTheDefaultClearsTheOverride() {
        let (store, settings) = makeStores()
        let url = URL(string: "https://news.example.com/a")!
        store.update(url: url, settings: settings) { $0.blockAds = false }
        XCTAssertNotNil(store.override(for: url))
        store.update(url: url, settings: settings) { $0.blockAds = true }
        XCTAssertNil(store.override(for: url), "restating the default must not pin it")
    }

    func testOverridesApplyAcrossTheWholeSite() {
        let (store, settings) = makeStores()
        store.update(url: URL(string: "https://www.example.co.uk/")!, settings: settings) { $0.javaScriptHardening = .standard }
        let policy = store.resolve(url: URL(string: "https://live.example.co.uk/x")!, settings: settings)
        XCTAssertEqual(policy.javaScriptHardening, .standard)
        XCTAssertTrue(policy.isCustomised)
    }
}

final class PopupPolicyTests: XCTestCase {
    private let page = URL(string: "https://www.streaming.example/watch")!
    private func decide(_ target: String, click: Bool = false, allowed: Bool = false) -> PopupPolicy.Decision {
        PopupPolicy.decide(target: URL(string: target)!, opener: page, isLinkClick: click, siteAllowsPopups: allowed)
    }

    func testScriptOpenedCrossSiteWindowsAreBlocked() {
        XCTAssertEqual(decide("https://casino-ads.example/land"), .block)
        XCTAssertEqual(decide("about:blank"), .block)
    }

    func testRealLinksAndSameSiteWindowsOpen() {
        XCTAssertEqual(decide("https://other.example/article", click: true), .open)
        XCTAssertEqual(decide("https://accounts.streaming.example/login"), .open)
    }

    func testPerSiteAllowanceOpensEverythingWebby() {
        XCTAssertEqual(decide("https://accounts.google.com/o/oauth2", allowed: true), .open)
        XCTAssertEqual(decide("javascript:alert(1)", allowed: true), .block)
    }
}

/// What App Review checks in the signed app (guideline 2.4.5): sandboxed, and
/// no hardened-runtime exception keys, not even ones set to false.
final class EntitlementTests: XCTestCase {
    private func signedEntitlements() throws -> [String: Any] {
        var code: SecCode?
        XCTAssertEqual(SecCodeCopySelf([], &code), errSecSuccess)
        var staticCode: SecStaticCode?
        XCTAssertEqual(SecCodeCopyStaticCode(try XCTUnwrap(code), [], &staticCode), errSecSuccess)
        var info: CFDictionary?
        XCTAssertEqual(SecCodeCopySigningInformation(try XCTUnwrap(staticCode),
                                                     SecCSFlags(rawValue: kSecCSSigningInformation), &info), errSecSuccess)
        let dict = try XCTUnwrap(info as? [String: Any])
        return try XCTUnwrap(dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any], "the app is signed with entitlements")
    }

    func testTheSignedAppHasOnlyEntitlementsTheMacAppStoreAccepts() throws {
        let entitlements = try signedEntitlements()
        XCTAssertEqual(entitlements["com.apple.security.app-sandbox"] as? Bool, true)
        let runtimeExceptions = entitlements.keys.filter { $0.hasPrefix("com.apple.security.cs.") }
        XCTAssertEqual(runtimeExceptions, [], "App Review rejects these keys, even with the value false")
    }
}
