import XCTest
import WebKit
@testable import Icy_Weasel

/// Live A/B against YouTube: the control arm proves the video is served with an
/// ad schedule, so its absence in the shielded arm is attributable to the script.
/// Network-dependent: `TEST_RUNNER_IW_NETWORK_TESTS=1`.
@MainActor
final class YouTubeAdTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IW_NETWORK_TESTS"] == "1")
    }

    private func observe(_ video: String, prune: Bool?) async throws -> [String: Any] {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        // Record what YouTube delivered *before* any pruning could matter to us:
        // an isolated-world observer can't see page JS objects, so sample from the
        // page world after load instead.
        if let prune, let script = ScriptInjector.youTubeAdBlock(pruneSchedule: prune) {
            config.userContentController.addUserScript(script)
        }
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        webView.customUserAgent = WebViewFactory.standardUserAgent
        let window = NSWindow(contentRect: webView.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false   // ARC owns it; the default double-frees on close()
        window.contentView = webView
        window.orderBack(nil)   // a visible view, or WebKit throttles playback
        defer { window.close() }

        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.load(URLRequest(url: URL(string: "https://www.youtube.com/watch?v=\(video)")!))
        _ = try? await withThrowingTaskGroup(of: Void.self) { g in
            g.addTask { @MainActor in try await waiter.wait() }
            g.addTask { try await Task.sleep(for: .seconds(30)) }
            try await g.next(); g.cancelAll()
        }
        var sawAd = false, played = 0.0
        var first: [String: Any] = [:]
        var firstPlayTick = -1
        var states: [String] = []
        for tick in 0..<90 {   // up to 45 s
            if firstPlayTick >= 0, tick > firstPlayTick + 10 { break }
            try await Task.sleep(for: .milliseconds(500))
            let raw = try await webView.evaluateJavaScript("""
                (function () {
                  const r = window.ytInitialPlayerResponse || {};
                  const p = document.querySelector('.html5-video-player');
                  const v = document.querySelector('video');
                  if (v && v.paused) { v.muted = true; v.play().catch(() => {}); }
                  return JSON.stringify({
                    hasResponse: !!window.ytInitialPlayerResponse,
                    adPlacements: (r.adPlacements || []).length, adSlots: (r.adSlots || []).length,
                    playerAds: (r.playerAds || []).length,
                    adShowing: !!(p && p.classList.contains('ad-showing')),
                    ready: v ? v.readyState : -1, net: v ? v.networkState : -1, err: v && v.error ? v.error.code : 0,
                    cls: p ? Array.from(p.classList).filter(c => /mode|state|ad-|unstarted|buffering|playing|paused/.test(c)).join(' ') : '',
                    time: v ? v.currentTime : -1, status: (r.playabilityStatus || {}).status || '?',
                    enforcement: !!document.querySelector('ytd-enforcement-message-view-model'),
                    title: document.title
                  });
                })()
                """) as? String ?? "{}"
            let o = (try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]) ?? [:]
            if tick == 0 { first = o }
            if o["adShowing"] as? Bool == true { sawAd = true }
            played = max(played, o["time"] as? Double ?? 0)
            let adNow = o["adShowing"] as? Bool == true
            if firstPlayTick < 0, !adNow, (o["time"] as? Double ?? 0) > 0.3 { firstPlayTick = tick }
            let st = "ready=\(o["ready"] ?? "?") \(o["cls"] ?? "")"
            if states.last != st { states.append("t=\(Double(tick) / 2)s \(st)") }
            first["enforcement"] = (first["enforcement"] as? Bool == true) || (o["enforcement"] as? Bool == true)
        }
        first["contentStartedAfter"] = firstPlayTick < 0 ? -1.0 : Double(firstPlayTick) / 2
        first["states"] = states.prefix(8).joined(separator: " | ")
        first["sawAdShowing"] = sawAd
        first["contentSecondsPlayed"] = played
        return first
    }

    func testStrategies() async throws {
        var report = "\n=== YOUTUBE STRATEGIES (seconds until the real video is playing) ===\n"
        var skipStarts: [Double] = [], controlStarts: [Double] = [], pruneStarts: [Double] = []
        var pruneSawAd = false, controlSawAd = false
        for video in ["dQw4w9WgXcQ", "kJQP7kiw5Fk", "9bZkp7q19f0"] {
            for (label, prune) in [("stock WebKit   ", Bool?.none), ("prune schedule ", true), ("instant-skip   ", false)] {
                let r = try await observe(video, prune: prune)
                let start = r["contentStartedAfter"] as? Double ?? -1
                report += "  \(video) \(label) content after \(start)s  adVisibleState=\(r["sawAdShowing"] ?? "?") enforcement=\(r["enforcement"] ?? "?")\n"
                if prune == false { skipStarts.append(start) }
                if prune == nil { controlStarts.append(start); controlSawAd = controlSawAd || (r["sawAdShowing"] as? Bool == true) }
                if prune == true { pruneStarts.append(start); pruneSawAd = pruneSawAd || (r["sawAdShowing"] as? Bool == true) }
            }
        }
        print(report)
        try XCTSkipUnless(controlSawAd, "YouTube served no ads to the control arm; inconclusive")
        XCTAssertFalse(pruneSawAd, "an ad reached the player despite pruning")
        XCTAssertTrue(pruneStarts.allSatisfy { $0 >= 0 }, "every video must still play: \(pruneStarts)")
        XCTAssertTrue(skipStarts.allSatisfy { $0 >= 0 }, "every video must still play: \(skipStarts)")
        let mean = { (v: [Double]) in v.reduce(0, +) / Double(max(1, v.count)) }
        XCTAssertLessThan(mean(pruneStarts), mean(controlStarts.map { $0 < 0 ? 45 : $0 }), "must beat watching the ads")
    }
}
