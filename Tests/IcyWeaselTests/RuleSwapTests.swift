import XCTest
@testable import Icy_Weasel

/// Regression: a tab attached rule lists once, for the first site it opened.
/// Following a link from a site with ad blocking switched off left every later
/// site in that tab unprotected (and the reverse kept blocking an allowlisted site).
@MainActor
final class RuleSwapTests: XCTestCase {

    /// What `decidePolicyFor` does for every allowed main-frame navigation.
    /// (WKNavigationAction can't be faked: WebKit crashes freeing a stand-in.)
    private func navigate(_ tab: Tab, to url: String, store: SitePolicyStore, settings: BrowserSettings) {
        let target = URL(string: url)!
        tab.prepareMainFrameNavigation(to: target, policy: store.resolve(url: target, settings: settings))
    }

    func testRulesFollowTheSiteBeingNavigatedTo() {
        let suite = "iw-rules-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = BrowserSettings(defaults: defaults)
        let store = SitePolicyStore(defaults: defaults)
        store.update(url: URL(string: "https://allowed.example/"), settings: settings) { $0.blockAds = false }
        let model = BrowserViewModel(settings: settings, policyStore: store,
                                     blocking: BlockingEngine(settings: settings), downloads: DownloadManager())
        let tab = model.tabs[0]
        tab.wake()

        let blocked = Tab.listsKey(store.resolve(url: URL(string: "https://news.example/"), settings: settings))
        let allowed = Tab.listsKey(store.resolve(url: URL(string: "https://allowed.example/"), settings: settings))
        XCTAssertNotEqual(blocked, allowed, "precondition: the override changes which rules apply")

        navigate(tab, to: "https://allowed.example/page", store: store, settings: settings)
        XCTAssertEqual(tab.installedListsKey, allowed, "the allowlisted site gets no ad rules")
        navigate(tab, to: "https://news.example/story", store: store, settings: settings)
        XCTAssertEqual(tab.installedListsKey, blocked, "leaving it restores ad blocking")
        navigate(tab, to: "https://www.allowed.example/other", store: store, settings: settings)
        XCTAssertEqual(tab.installedListsKey, allowed, "subdomains share the site's override")
    }

    /// End to end through the tab's real navigation delegate and real rule
    /// lists: an ad element is hidden, shown on the allowlisted site, and
    /// hidden again after leaving it, all in one tab.
    func testBlockingSwitchesInOneTabAcrossSites() async throws {
        let suite = "iw-rules-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = BrowserSettings(defaults: defaults)
        let store = SitePolicyStore(defaults: defaults)
        store.update(url: URL(string: "https://allowed.example/"), settings: settings) { $0.blockAds = false }
        let engine = BlockingEngine(settings: settings)
        await engine.start()
        try XCTSkipIf(engine.contentLists.isEmpty, "no rule lists compiled")
        let model = BrowserViewModel(settings: settings, policyStore: store, blocking: engine, downloads: DownloadManager())
        let tab = model.tabs[0]
        let webView = tab.wake()
        webView.frame = NSRect(x: 0, y: 0, width: 400, height: 300)

        func adDisplay(on site: String) async throws -> String {
            // The tab stays the navigation delegate, so its decidePolicyFor
            // runs; this helper only observes the load finishing.
            let loaded = expectation(description: "load \(site)")
            let observation = webView.observe(\.isLoading, options: [.new]) { _, change in
                if change.newValue == false { loaded.fulfill() }
            }
            webView.loadHTMLString("<html><body><ins class='adsbygoogle' id='ad'>ad</ins></body></html>",
                                   baseURL: URL(string: site)!)
            await fulfillment(of: [loaded], timeout: 10)
            observation.invalidate()
            try await Task.sleep(for: .milliseconds(300))
            return try await webView.evaluateJavaScript("getComputedStyle(document.getElementById('ad')).display") as? String ?? "?"
        }

        let first = try await adDisplay(on: "https://news.example/")
        let onAllowed = try await adDisplay(on: "https://allowed.example/")
        let after = try await adDisplay(on: "https://other.example/")
        XCTAssertEqual(first, "none", "ads are hidden by default")
        XCTAssertNotEqual(onAllowed, "none", "the allowlisted site shows them")
        XCTAssertEqual(after, "none", "leaving the allowlisted site blocks again")
    }
}
