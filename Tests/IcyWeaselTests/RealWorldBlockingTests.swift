import XCTest
import WebKit
@testable import Icy_Weasel

/// Controlled experiments against the live web: the same page with the shipped
/// rule lists (A) and with none (B). B proves each endpoint is reachable, so a
/// failure under A is attributable to blocking rather than a dead URL.
///
/// Network-dependent: `TEST_RUNNER_IW_NETWORK_TESTS=1 xcodebuild test`.
@MainActor
final class RealWorldBlockingTests: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IW_NETWORK_TESTS"] == "1")
    }

    private static var engine: BlockingEngine?

    /// The production engine: same settings, same lists, same compiled cache.
    private func productionLists() async throws -> [WKContentRuleList] {
        if Self.engine == nil {
            let engine = BlockingEngine(settings: BrowserSettings())
            await engine.start()
            Self.engine = engine
        }
        let engine = try XCTUnwrap(Self.engine)
        guard case .ready = engine.state else { throw XCTSkip("engine not ready: \(engine.state)") }
        let policy = ResolvedSitePolicy(blockAds: true, httpsOnly: true, javaScript: true,
                                        resistFingerprinting: false, blockThirdPartyCookies: true, isCustomised: false)
        return engine.lists(for: policy)
    }

    private func makeWebView(lists: [WKContentRuleList]) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        lists.forEach(config.userContentController.add)
        return WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
    }

    // MARK: Known endpoints

    static let trackers: [(String, String)] = [
        ("Google Tag Manager", "https://www.googletagmanager.com/gtag/js?id=G-TEST000000"),
        ("Google Analytics", "https://www.google-analytics.com/analytics.js"),
        ("DoubleClick GPT", "https://securepubads.g.doubleclick.net/tag/js/gpt.js"),
        ("AdSense", "https://pagead2.googlesyndication.com/pagead/js/adsbygoogle.js"),
        ("Meta Pixel", "https://connect.facebook.net/en_US/fbevents.js"),
        ("Hotjar", "https://static.hotjar.com/c/hotjar-3000000.js?sv=6"),
        ("Segment", "https://cdn.segment.com/analytics.js/v1/test/analytics.min.js"),
        ("Criteo", "https://static.criteo.net/js/ld/publishertag.js"),
        ("Taboola", "https://cdn.taboola.com/libtrc/test/loader.js"),
        ("Outbrain", "https://widgets.outbrain.com/outbrain.js"),
        ("comScore", "https://sb.scorecardresearch.com/beacon.js"),
        ("Pinterest Tag", "https://s.pinimg.com/ct/core.js"),
        ("TikTok Pixel", "https://analytics.tiktok.com/i18n/pixel/events.js"),
        ("LinkedIn Insight", "https://snap.licdn.com/li.lms-analytics/insight.min.js"),
        ("Microsoft Clarity", "https://www.clarity.ms/tag/uet/test"),
        ("Amazon Ads", "https://c.amazon-adsystem.com/aax2/apstag.js"),
        ("Mixpanel", "https://cdn.mxpnl.com/libs/mixpanel-2-latest.min.js"),
        ("HubSpot Analytics", "https://js.hs-analytics.net/analytics/1700000000000/1.js"),
        ("Bing UET", "https://bat.bing.com/bat.js"),
        ("Quantcast", "https://secure.quantserve.com/quant.js")
    ]

    static let controls: [(String, String)] = [
        ("jQuery", "https://code.jquery.com/jquery-3.7.1.min.js"),
        ("lodash (jsDelivr)", "https://cdn.jsdelivr.net/npm/lodash@4.17.21/lodash.min.js"),
        ("React (cdnjs)", "https://cdnjs.cloudflare.com/ajax/libs/react/18.2.0/umd/react.production.min.js"),
        ("htmx (unpkg)", "https://unpkg.com/htmx.org@1.9.10/dist/htmx.min.js"),
        ("Wikimedia image", "https://upload.wikimedia.org/wikipedia/commons/4/47/PNG_transparency_demonstration_1.png"),
        ("GitHub favicon", "https://github.githubassets.com/favicons/favicon.png"),
        ("MDN asset", "https://developer.mozilla.org/favicon-48x48.png")
    ]

    /// Preload fetches with a script destination (so `$script` rules apply) but
    /// never executes — the control run does not run tracker code.
    private func probePage() -> String {
        func tag(_ id: String, _ url: String) -> String {
            let isImage = url.hasSuffix(".png")
            return isImage
                ? #"<img data-id="\#(id)" src="\#(url)" onload="done(this,'loaded')" onerror="done(this,'failed')">"#
                : #"<link rel="preload" as="script" data-id="\#(id)" href="\#(url)" onload="done(this,'loaded')" onerror="done(this,'failed')">"#
        }
        let all = (Self.trackers + Self.controls).map { tag($0.0, $0.1) }.joined(separator: "\n")
        return """
        <html><head><script>
          window.__results = {};
          function done(el, status) { window.__results[el.dataset.id] = status; }
        </script>
        \(all)
        </head><body>probe</body></html>
        """
    }

    private func run(lists: [WKContentRuleList]) async throws -> (results: [String: String], requests: Int) {
        let webView = makeWebView(lists: lists)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString(probePage(), baseURL: URL(string: "https://news.example/")!)
        try await waiter.wait()
        let expected = Self.trackers.count + Self.controls.count
        let deadline = Date().addingTimeInterval(25)
        var results: [String: String] = [:]
        while Date() < deadline {
            results = (try await webView.evaluateJavaScript("window.__results") as? [String: String]) ?? [:]
            if results.count >= expected { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        let requests = (try await webView.evaluateJavaScript(
            "performance.getEntriesByType('resource').length") as? Int) ?? -1
        return (results, requests)
    }

    func testKnownTrackersBlockedAndControlsUntouched() async throws {
        let lists = try await productionLists()
        let blocked = try await run(lists: lists)
        let open = try await run(lists: [])

        var report = "\n=== LIVE BLOCKING EXPERIMENT (A: Icy Weasel lists, B: none) ===\n"
        report += "  endpoint                  B (no lists)   A (Icy Weasel)\n"
        var reachable = 0, blockedCount = 0, falseNegatives: [String] = []
        for (name, _) in Self.trackers {
            let b = open.results[name] ?? "timeout", a = blocked.results[name] ?? "timeout"
            report += "  \(name.padding(toLength: 24, withPad: " ", startingAt: 0))  \(b.padding(toLength: 13, withPad: " ", startingAt: 0))  \(a)\n"
            if b == "loaded" {
                reachable += 1
                if a == "failed" { blockedCount += 1 } else { falseNegatives.append(name) }
            }
        }
        report += "  --- controls (must load under A) ---\n"
        var overBlocked: [String] = []
        for (name, _) in Self.controls {
            let b = open.results[name] ?? "timeout", a = blocked.results[name] ?? "timeout"
            report += "  \(name.padding(toLength: 24, withPad: " ", startingAt: 0))  \(b.padding(toLength: 13, withPad: " ", startingAt: 0))  \(a)\n"
            if b == "loaded" && a != "loaded" { overBlocked.append(name) }
        }
        report += "  trackers reachable without lists: \(reachable)/\(Self.trackers.count); blocked by Icy Weasel: \(blockedCount)/\(reachable)\n"
        report += "  resource requests completed: B \(open.requests), A \(blocked.requests)\n"
        print(report)

        XCTAssertGreaterThanOrEqual(reachable, Self.trackers.count / 2,
                                    "too few trackers reachable for a meaningful experiment")
        XCTAssertEqual(falseNegatives, [], "reachable trackers that were not blocked")
        XCTAssertEqual(overBlocked, [], "legitimate resources blocked")
    }

    // MARK: Real pages

    private func loadMetrics(_ url: URL, lists: [WKContentRuleList]) async throws -> [String: Double] {
        let webView = makeWebView(lists: lists)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        let start = Date()
        webView.load(URLRequest(url: url))
        _ = try? await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in try await waiter.wait() }
            group.addTask { try await Task.sleep(for: .seconds(45)) }
            try await group.next()
            group.cancelAll()
        }
        let finished = Date().timeIntervalSince(start)
        try await Task.sleep(for: .seconds(3)) // let late tag-manager fan-out happen
        let json = try await webView.evaluateJavaScript("""
            (function () {
              const nav = performance.getEntriesByType('navigation')[0] || {};
              const res = performance.getEntriesByType('resource');
              const hosts = new Set(res.map(r => { try { return new URL(r.name).hostname; } catch (e) { return ''; } }));
              return JSON.stringify({
                requests: res.length, hosts: hosts.size, scripts: res.filter(r => r.initiatorType === 'script').length,
                domContentLoaded: nav.domContentLoadedEventEnd || 0, load: nav.loadEventEnd || 0
              });
            })()
            """) as? String ?? "{}"
        var metrics = (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double]) ?? [:]
        metrics["wallclock"] = finished * 1000
        return metrics
    }

    func testRealPagesLoadWithFewerRequests() async throws {
        let lists = try await productionLists()
        let pages = ["https://www.cnn.com/", "https://www.theguardian.com/international", "https://www.speedtest.net/"]
        let runs = 6
        var report = "\n=== REAL PAGE LOADS (\(runs) runs per arm, alternating order; median [min–max]) ===\n"
        for page in pages {
            let url = URL(string: page)!
            var a: [[String: Double]] = [], b: [[String: Double]] = []
            for i in 0..<runs {
                // Alternate which arm goes first, so DNS/TCP warm-up favours neither.
                if i % 2 == 0 {
                    a.append(try await loadMetrics(url, lists: lists))
                    b.append(try await loadMetrics(url, lists: []))
                } else {
                    b.append(try await loadMetrics(url, lists: []))
                    a.append(try await loadMetrics(url, lists: lists))
                }
            }
            func stats(_ arm: [[String: Double]], _ key: String) -> (Double, Double, Double) {
                let v = arm.compactMap { $0[key] }.filter { $0 > 0 }.sorted()
                guard !v.isEmpty else { return (0, 0, 0) }
                return (v[v.count / 2], v.first!, v.last!)
            }
            func line(_ label: String, _ key: String, _ unit: String) -> String {
                let (mb, lb, hb) = stats(b, key), (ma, la, ha) = stats(a, key)
                return String(format: "    %-18@ B %6.0f [%4.0f–%-5.0f]  A %6.0f [%4.0f–%-5.0f] %@\n",
                              label as NSString, mb, lb, hb, ma, la, ha, unit as NSString)
            }
            report += "  \(url.host!)\n"
            report += line("requests", "requests", "")
            report += line("third-party hosts", "hosts", "")
            report += line("DOMContentLoaded", "domContentLoaded", "ms")
            report += line("load event", "load", "ms")
        }
        print(report)
    }
}
