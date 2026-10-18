import XCTest
import AppKit
@testable import Icy_Weasel

/// Fixes from the 2026-10 security review of the published source.
@MainActor
final class SecurityReviewFixTests: XCTestCase {

    // MARK: Public Suffix List (cases from publicsuffix.org's test_psl.txt)

    func testRegistrableDomainsFollowTheFullPublicSuffixList() {
        let cases: [(String, String)] = [
            ("example.com", "example.com"),
            ("www.example.com", "example.com"),
            ("a.b.example.uk.com", "example.uk.com"),      // private suffix uk.com
            ("www.example.co.uk", "example.co.uk"),
            ("b.c.mm", "b.c.mm"),                          // wildcard *.mm
            ("a.b.c.mm", "b.c.mm"),
            ("www.ck", "www.ck"),                          // exception !www.ck
            ("www.www.ck", "www.ck"),
            ("b.test.ck", "b.test.ck"),                    // wildcard *.ck
            ("a.b.test.ck", "b.test.ck"),
            ("b.c.kobe.jp", "b.c.kobe.jp"),                // wildcard *.kobe.jp
            ("city.kobe.jp", "city.kobe.jp"),              // exception !city.kobe.jp
            ("www.city.kobe.jp", "city.kobe.jp"),
            ("test.kyoto.jp", "test.kyoto.jp"),
            ("b.ide.kyoto.jp", "b.ide.kyoto.jp"),
            ("alice.github.io", "alice.github.io"),        // private section
            ("www.alice.github.io", "alice.github.io"),
            ("bucket.s3.amazonaws.com", "bucket.s3.amazonaws.com"),
            ("WWW.Example.COM.", "example.com"),           // case and trailing dot
            ("www.xn--85x722f.xn--55qx5d.cn", "xn--85x722f.xn--55qx5d.cn"), // 食狮.公司.cn
            ("192.168.1.10", "192.168.1.10"),
        ]
        for (host, expected) in cases {
            XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: host), expected, host)
        }
        // A host that is itself a public suffix stands alone, never merged.
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "github.io"), "github.io")
        XCTAssertEqual(PublicSuffix.registrableDomain(ofHost: "c.mm"), "c.mm")
    }

    func testCustomersOfAHostingSuffixAreSeparateSites() {
        let alice = URL(string: "https://alice.github.io/")
        let mallory = URL(string: "https://mallory.github.io/")
        XCTAssertTrue(PublicSuffix.isThirdParty(mallory, relativeTo: alice))
    }

    func testPunycodeMatchesRFC3492() {
        XCTAssertEqual(Punycode.encode("bücher"), "bcher-kva")
        XCTAssertEqual(Punycode.encode("公司"), "55qx5d")
        XCTAssertEqual(Punycode.encode("食狮"), "85x722f")
        XCTAssertEqual(Punycode.asciiDomain("食狮.公司.cn"), "xn--85x722f.xn--55qx5d.cn")
    }

    func testBundledListIsLoaded() {
        XCTAssertGreaterThan(PublicSuffix.rules.exact.count, 5_000, "the full list ships in the app")
    }

    // MARK: Private windows

    func testPrivateWindowSiteSettingsAreNeverPersisted() {
        let suite = "iw-ephemeral-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = BrowserSettings(defaults: defaults)
        let store = SitePolicyStore(defaults: defaults)
        store.update(url: URL(string: "https://saved.example/"), settings: settings) { $0.blockAds = false }

        let model = BrowserViewModel(settings: settings, policyStore: store,
                                     blocking: BlockingEngine(settings: settings), downloads: DownloadManager(),
                                     isPrivate: true)
        XCTAssertTrue(model.policyStore.isEphemeral)
        XCTAssertFalse(model.policyStore.resolve(url: URL(string: "https://saved.example/"), settings: settings).blockAds,
                       "saved per-site settings still apply in private windows")

        model.policyStore.update(url: URL(string: "https://secret.example/"), settings: settings) { $0.blockAds = false }
        XCTAssertEqual(store.customisedSites, ["saved.example"], "the shared store never learns the private site")
        XCTAssertEqual(SitePolicyStore(defaults: defaults).customisedSites, ["saved.example"], "nothing reached disk")
    }

    // MARK: Real gestures

    private func click(window: Int, at time: TimeInterval, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseUp, location: .zero, modifierFlags: modifiers, timestamp: time,
                           windowNumber: window, context: nil, eventNumber: 0, clickCount: 1, pressure: 0)!
    }

    func testOnlyARecentRealClickInTheSameWindowCounts() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.orderFront(nil)

        UserInput.record(click(window: window.windowNumber, at: 100, modifiers: .command))
        XCTAssertEqual(UserInput.recentActivation(in: window, now: 100.5)?.modifiers.contains(.command), true)
        XCTAssertNil(UserInput.recentActivation(in: window, now: 102), "a stale click doesn't count")

        UserInput.record(click(window: window.windowNumber + 999, at: 200))
        XCTAssertNil(UserInput.recentActivation(in: window, now: 200.1), "a click in another window doesn't count")
        XCTAssertNil(UserInput.recentActivation(in: nil, now: 200.1))
    }

    // MARK: data: URLs

    func testDataURLsCannotOpenAsAPage() {
        let data = URL(string: "data:text/html,<h1>Bank login</h1>")!
        XCTAssertEqual(ExternalSchemePolicy.decide(url: data, isMainFrame: true, isUserClick: true),
                       .block(reason: "data: URLs can't open as a page"))
        XCTAssertEqual(ExternalSchemePolicy.decide(url: data, isMainFrame: false, isUserClick: false), .web,
                       "inside a frame, data: is ordinary web content")
    }
}
