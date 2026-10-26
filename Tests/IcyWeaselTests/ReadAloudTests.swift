import XCTest
import WebKit
import SwiftUI
@testable import Icy_Weasel

/// Read Page Aloud: what text is read, and that Phonon really speaks it.
/// The Phonon tests skip themselves on a Mac or build that can't run it
/// (Intel, macOS 14, or no `scripts/fetch-phonon.sh` yet).
@MainActor
final class ReadAloudTests: XCTestCase {

    private func page(_ body: String) async throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString("<html><head><title>T</title></head><body>\(body)</body></html>",
                               baseURL: URL(string: "https://example.com/")!)
        try await waiter.wait()
        return webView
    }

    func testReadsTheArticleNotTheChrome() async throws {
        let webView = try await page("""
            <header><nav><a href="/">Home</a> <a href="/news">News</a></nav></header>
            <aside><p>Subscribe to our newsletter for daily updates and offers.</p></aside>
            <article>
              <h1>Glaciers are retreating</h1>
              <p>The ice has thinned   by a third
                 since 1980.</p>
              <figure><img src="x.png"><figcaption>The glacier in 2024.</figcaption></figure>
              <pre><code>let x = 1</code></pre>
              <ul><li>First point.</li><li>Second point.</li></ul>
              <p style="display:none">Hidden text.</p>
            </article>
            <footer><p>© Example News</p></footer>
            """)
        let text = await PageReader.readableText(from: webView)
        XCTAssertEqual(text, [
            "Glaciers are retreating",
            "The ice has thinned by a third since 1980.",
            "The glacier in 2024.",
            "First point.", "Second point.",
        ])
    }

    func testWithoutAnArticleFindsTheDensestBlock() async throws {
        let webView = try await page("""
            <div id="menu"><p>Menu</p></div>
            <div id="story"><p>One long paragraph of the story itself.</p><p>And another one after it.</p></div>
            <div id="links"><p>Related</p></div>
            """)
        let text = await PageReader.readableText(from: webView)
        XCTAssertEqual(text, ["One long paragraph of the story itself.", "And another one after it."])
    }

    func testReadsOnlyTheSelectionWhenThereIsOne() async throws {
        let webView = try await page("<article><p id=a>Read this sentence.</p><p>But not this one.</p></article>")
        _ = try await webView.evaluateJavaScript(
            "getSelection().selectAllChildren(document.getElementById('a')); true")
        let text = await PageReader.readableText(from: webView)
        XCTAssertEqual(text, ["Read this sentence."])
    }

    func testCleaningDropsSymbolsAndCapsLength() {
        XCTAssertEqual(PageReader.cleaned(["  Hello \n world ", "—", "•", "", "42"]), ["Hello world", "42"])
        let long = String(repeating: "word ", count: 30_000)
        let capped = PageReader.cleaned([long, long])
        XCTAssertEqual(capped.count, 1, "stops before going past the character limit")
    }

    // MARK: Phonon

    func testVoiceListMatchesTheModel() throws {
        guard let model = PhononEngine.bundledModel else { throw XCTSkip("Phonon's model is not in this build") }
        let files = try FileManager.default.contentsOfDirectory(atPath: model.appendingPathComponent("voices").path)
        let names = Set(files.map { ($0 as NSString).deletingPathExtension })
        XCTAssertEqual(Set(PhononEngine.voices), names.subtracting(["default"]))
        XCTAssertTrue(PhononEngine.voices.contains(PhononEngine.defaultVoice))
    }

    func testPhononSpeaksIntelligibleAudio() throws {
        guard PhononEngine.isSupported else { throw XCTSkip("Phonon can't run on this Mac or build") }
        let done = expectation(description: "spoken")
        var samples: [Float] = []
        var failure: Error?
        PhononEngine.shared.speak("Icy Weasel can read this page to you.", voice: "Hugh", onAudio: { chunk in
            samples += chunk
            return true
        }, completion: { error in
            failure = error
            done.fulfill()
        })
        // The first load compiles the model for this Mac.
        wait(for: [done], timeout: 120)
        XCTAssertNil(failure)
        let seconds = Double(samples.count) / PhononEngine.sampleRate
        let rms = sqrt(samples.reduce(0) { $0 + $1 * $1 } / Float(max(1, samples.count)))
        XCTAssertGreaterThan(seconds, 1.0, "a sentence is more than a second long")
        XCTAssertLessThan(seconds, 6.0)
        XCTAssertGreaterThan(rms, 0.01, "speech, not silence")
    }

    func testReaderPlaysThroughToTheEnd() async throws {
        guard PhononEngine.isSupported else { throw XCTSkip("Phonon can't run on this Mac or build") }
        let defaults = UserDefaults(suiteName: "ReadAloudTests")!
        defaults.removePersistentDomain(forName: "ReadAloudTests")
        let settings = BrowserSettings(defaults: defaults)
        settings.readAloudRate = 2   // through the time-pitch unit, and quicker
        let reader = PageReader(settings: settings)
        XCTAssertTrue(reader.usesPhonon)
        reader.speak(["One.", "Two."])
        var sawReading = false
        let deadline = Date().addingTimeInterval(120)
        while reader.isActive && Date() < deadline {
            if reader.state == .reading { sawReading = true }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(sawReading)
        XCTAssertEqual(reader.state, .idle, "finishes by itself once the last audio has played")
        XCTAssertNil(reader.problem)
    }

    func testAppleVoiceReadsWhenChosen() async throws {
        let suite = "iw-readaloud-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = BrowserSettings(defaults: defaults)
        settings.readAloudVoice = BrowserSettings.systemReadAloudVoice
        let reader = PageReader(settings: settings)
        XCTAssertFalse(reader.usesPhonon, "the same path Intel Macs and macOS 14 take")
        reader.speak(["One."])
        XCTAssertEqual(reader.state, .reading)
        let deadline = Date().addingTimeInterval(30)
        while reader.isActive && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(reader.state, .idle, "finishes by itself")
    }

    func testStopSilencesAndFreesTheEngine() async throws {
        guard PhononEngine.isSupported else { throw XCTSkip("Phonon can't run on this Mac or build") }
        let settings = BrowserSettings(defaults: UserDefaults(suiteName: "ReadAloudTests")!)
        let reader = PageReader(settings: settings)
        // Far more than the 20 s generation may run ahead, so generation is
        // blocked waiting for room when stop arrives.
        reader.speak(Array(repeating: "This sentence repeats for a long while so that reading takes minutes.", count: 60))
        let deadline = Date().addingTimeInterval(120)
        while reader.state != .reading && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        reader.stop()
        XCTAssertEqual(reader.state, .idle)

        // The shared engine must be free again, not stuck behind the old reading.
        let done = expectation(description: "engine free")
        PhononEngine.shared.speak("Again.", voice: "Zoey", onAudio: { _ in true }, completion: { _ in done.fulfill() })
        await fulfillment(of: [done], timeout: 10)
    }
}

/// The whole feature in a real browser window: an article in a tab, the
/// toolbar's action (the same one ⌥⌘R runs), Phonon speaking, pause, resume,
/// and closing the tab silencing it.
@MainActor
final class ReadAloudWindowTests: XCTestCase {
    func testReadsAnArticleInABrowserWindow() async throws {
        guard PhononEngine.isSupported else { throw XCTSkip("Phonon can't run on this Mac or build") }
        let suite = "iw-readaloud-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = BrowserSettings(defaults: defaults)
        let model = BrowserViewModel(settings: settings, policyStore: SitePolicyStore(defaults: defaults),
                                     blocking: BlockingEngine(settings: settings), downloads: DownloadManager())
        let size = CGSize(width: 1000, height: 640)
        let host = NSHostingView(rootView: BrowserContent(model: model).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host

        let tab = try XCTUnwrap(model.selectedTab)
        // A real tab web view with the browser's configuration, given the
        // page directly so the test needs no network.
        let webView = tab.wake()
        webView.loadHTMLString("""
            <html><body><nav>Home · News</nav><article><h1>Glaciers</h1>
            <p>The ice has thinned by a third since 1980, and it is still retreating every summer.</p>
            </article></body></html>
            """, baseURL: URL(string: "https://example.com/")!)
        var ready = false
        for _ in 0..<100 where !ready {
            try await Task.sleep(nanoseconds: 50_000_000)
            ready = (try? await webView.evaluateJavaScript("document.querySelector('article') !== null")) as? Bool == true
        }
        XCTAssertTrue(ready)
        tab.url = URL(string: "https://example.com/")

        model.toggleReadAloud()
        XCTAssertEqual(model.reader.tabID, tab.id)
        try await waitFor(model.reader, .reading)

        model.toggleReadAloud()
        XCTAssertEqual(model.reader.state, .paused)
        model.toggleReadAloud()
        XCTAssertEqual(model.reader.state, .reading)

        model.close(tab)
        XCTAssertEqual(model.reader.state, .idle, "closing the tab being read goes quiet")
    }

    private func waitFor(_ reader: PageReader, _ state: PageReader.State) async throws {
        let deadline = Date().addingTimeInterval(60)
        while reader.state != state && Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertEqual(reader.state, state, reader.problem ?? "")
    }
}
