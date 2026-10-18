import XCTest
import WebKit
@testable import Icy_Weasel

/// RAM: empty tabs cost no content process, closed tabs free everything,
/// and sleeping never silences a tab the user is listening to.
@MainActor
final class MemoryEfficiencyTests: XCTestCase {

    private func makeModel() -> BrowserViewModel {
        let suite = "iw-mem-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = BrowserSettings(defaults: defaults)
        return BrowserViewModel(settings: settings, policyStore: SitePolicyStore(defaults: defaults),
                                blocking: BlockingEngine(settings: settings), downloads: DownloadManager())
    }

    private func load(_ tab: Tab, html: String, base: String) async throws {
        let webView = try XCTUnwrap(tab.webView)
        let done = expectation(description: "loaded")
        let observation = webView.observe(\.isLoading, options: [.new]) { _, change in
            if change.newValue == false { done.fulfill() }
        }
        webView.loadHTMLString(html, baseURL: URL(string: base)!)
        await fulfillment(of: [done], timeout: 10)
        observation.invalidate()
    }

    func testEmptyTabsStartNoContentProcess() {
        let model = makeModel()
        for _ in 0..<5 { model.openTab(url: nil, inBackground: false) }
        XCTAssertTrue(model.tabs.allSatisfy { $0.webView == nil }, "New Tab pages need no web view")
        XCTAssertTrue(model.tabs.allSatisfy { !$0.isHibernated }, "and they don't count as sleeping")

        model.selectedTab?.load(URL(string: "https://example.com/")!)
        XCTAssertNotNil(model.selectedTab?.webView, "navigating creates it")
    }

    func testClosedTabsAreFreed() async throws {
        let model = makeModel()
        weak var closedTab: Tab?
        weak var closedWebView: WKWebView?
        try await {
            model.openTab(url: nil, inBackground: false)
            let tab = model.selectedTab!
            tab.wake()
            try await load(tab, html: "<p>hello</p>", base: "https://leak.example/")
            closedTab = tab
            closedWebView = tab.webView
            model.close(tab)
        }()
        // Let WebKit and SwiftUI drop their last references.
        for _ in 0..<20 where closedWebView != nil || closedTab != nil {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(closedTab, "a closed tab is deallocated")
        XCTAssertNil(closedWebView, "and so is its web view, releasing its content process")
    }

    func testClosingATabMidLoadStillReleasesIt() {
        let model = makeModel()
        model.openTab(url: URL(string: "https://example.com/"), inBackground: false)
        let tab = model.selectedTab!
        XCTAssertNotNil(tab.webView)
        tab.isLoading = true            // as if the page were still loading
        model.close(tab)
        XCTAssertNil(tab.webView, "close tears down even while loading; sleep does not")
    }

    /// A second of 440 Hz tone as a WAV data URL, so the test needs no network.
    private static let toneDataURL: String = {
        let rate = 8_000, samples = rate
        var data = Data()
        func le<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); le(UInt32(36 + samples * 2))
        data.append(contentsOf: Array("WAVEfmt ".utf8)); le(UInt32(16)); le(UInt16(1)); le(UInt16(1))
        le(UInt32(rate)); le(UInt32(rate * 2)); le(UInt16(2)); le(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); le(UInt32(samples * 2))
        for i in 0..<samples { le(Int16(sin(Double(i) * 2 * .pi * 440 / Double(rate)) * 3000)) }
        return "data:audio/wav;base64," + data.base64EncodedString()
    }()

    func testATabPlayingAudioIsNotPutToSleep() async throws {
        let model = makeModel()
        model.openTab(url: nil, inBackground: false)
        let player = model.selectedTab!
        player.wake()
        try await load(player, html: "<audio id='a' loop src='\(Self.toneDataURL)'></audio>", base: "https://music.example/")
        player.url = URL(string: "https://music.example/")
        let webView = try XCTUnwrap(player.webView)
        // Start playback without awaiting play()'s promise, and bound every
        // wait: in a headless test host playback may never start at all.
        webView.evaluateJavaScript("document.getElementById('a').play(); true", completionHandler: nil)
        func playbackState() async -> WKMediaPlaybackState {
            let got = expectation(description: "state"); var result: WKMediaPlaybackState = .none
            webView.requestMediaPlaybackState { result = $0; got.fulfill() }
            await fulfillment(of: [got], timeout: 2)
            return result
        }
        var state: WKMediaPlaybackState = .none
        for _ in 0..<10 {
            state = await playbackState()
            if state == .playing { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        try XCTSkipUnless(state == .playing, "audio playback isn't available in this test environment")

        model.openTab(url: nil, inBackground: false)
        model.relieveMemoryPressure()
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertNotNil(player.webView, "a tab playing audio keeps playing")
    }

    func testQuietBackgroundTabsSleepUnderMemoryPressure() async throws {
        let model = makeModel()
        model.openTab(url: nil, inBackground: false)
        let background = model.selectedTab!
        background.wake()
        try await load(background, html: "<p>quiet</p>", base: "https://quiet.example/")
        background.url = URL(string: "https://quiet.example/")
        model.openTab(url: nil, inBackground: false)   // now the background tab isn't selected

        model.relieveMemoryPressure()
        for _ in 0..<30 where background.webView != nil { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(background.webView, "a quiet background tab is put to sleep")
        XCTAssertTrue(background.isHibernated)
    }
}
