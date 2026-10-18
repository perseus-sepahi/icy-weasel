import XCTest
import WebKit
@testable import Icy_Weasel

/// Where does time go, outside the ad-block rules (see SpeedInvestigation for
/// those)? Offline, but slow, so opt-in: `TEST_RUNNER_IW_PERF=1`.
@MainActor
final class PerformanceBenchmarks: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IW_PERF"] == "1")
    }

    private func median(_ v: [Double]) -> Double { v.sorted()[v.count / 2] }

    private func policy(_ hardening: JavaScriptHardening, fingerprinting: Bool = true, ads: Bool = true) -> ResolvedSitePolicy {
        ResolvedSitePolicy(blockAds: ads, httpsOnly: true, javaScript: true, resistFingerprinting: fingerprinting,
                           blockThirdPartyCookies: true, javaScriptHardening: hardening, isCustomised: false)
    }

    private func webView(_ policy: ResolvedSitePolicy, lists: [WKContentRuleList] = []) -> WKWebView {
        let config = WebViewFactory.makeConfiguration(profile: .makePrivate(), policy: policy,
                                                      ruleLists: lists, messageHandler: nil,
                                                      topLevelURL: URL(string: "https://bench.example/"))
        let view = WebViewFactory.makeWebView(configuration: config)
        view.frame = NSRect(x: 0, y: 0, width: 1280, height: 800)
        return view
    }

    private func load(_ view: WKWebView, html: String, base: String = "https://bench.example/") async throws -> Double {
        let waiter = NavigationWaiter()
        view.navigationDelegate = waiter
        let t0 = Date()
        view.loadHTMLString(html, baseURL: URL(string: base)!)
        try await waiter.wait()
        return Date().timeIntervalSince(t0) * 1000
    }

    // MARK: 1. JavaScript execution speed by hardening level

    /// A mixed workload shaped like real app JS: object churn, sorting, string
    /// building, JSON round trips, closures and numeric loops.
    static let jsWorkload = """
    (function () {
      const t0 = performance.now();
      const a = [];
      for (let i = 0; i < 200000; i++) a.push({ id: i, v: (i * 7919) % 1000, s: 'k' + i });
      a.sort((p, q) => p.v - q.v || p.id - q.id);
      let sum = 0; for (const o of a) sum += o.v;
      let str = ''; for (let i = 0; i < 40000; i++) str += i.toString(36);
      const j = JSON.parse(JSON.stringify(a.slice(0, 40000)));
      const m = new Map(); for (let i = 0; i < 100000; i++) m.set('x' + (i % 5000), i);
      let f = 0; for (let i = 0; i < 3000000; i++) f += Math.sqrt(i) * 1.0001;
      const fib = n => n < 2 ? n : fib(n - 1) + fib(n - 2); fib(24);
      return performance.now() - t0 + (sum + j.length + m.size + f + str.length) * 0;
    })()
    """

    func testJavaScriptSpeedByHardening() async throws {
        var report = "\n=== JS WORKLOAD BY HARDENING (median of 5, in-page ms) ===\n"
        for level in [JavaScriptHardening.standard, .hardened, .lockdown] {
            let view = webView(policy(level))
            _ = try await load(view, html: "<html><body>bench</body></html>")
            var runs: [Double] = []
            for _ in 0..<5 {
                let ms = try await view.evaluateJavaScript(Self.jsWorkload) as? Double ?? -1
                runs.append(ms)
            }
            report += String(format: "  %-9@ %8.0f ms   runs %@\n", level.rawValue as NSString, median(runs),
                             runs.map { String(format: "%.0f", $0) }.joined(separator: " ") as NSString)
        }
        print(report)
    }

    // MARK: 2. Cost of our user scripts per document and per frame

    func testUserScriptOverhead() async throws {
        let frames = (0..<20).map { "<iframe srcdoc='<p>frame \($0)</p>'></iframe>" }.joined()
        let pages = [("1 frame", "<html><body><p>hi</p></body></html>"),
                     ("21 frames", "<html><body>\(frames)</body></html>")]
        var report = "\n=== USER-SCRIPT OVERHEAD (hardened; median of 9 loads, same web view) ===\n"
        for (label, html) in pages {
            for scripts in [false, true] {
                let view = webView(policy(.hardened, fingerprinting: scripts, ads: scripts))
                if !scripts { view.configuration.userContentController.removeAllUserScripts() }
                var times: [Double] = []
                for i in 0..<10 {
                    let ms = try await load(view, html: html, base: "https://doc\(i).example/")
                    if i > 0 { times.append(ms) }
                }
                report += String(format: "  %-9@ scripts %@  %6.1f ms\n", label as NSString,
                                 (scripts ? "on " : "off") as NSString, median(times))
            }
        }
        print(report)
    }

    // MARK: 3. Opening a tab

    /// New web view to first document: dominated by spawning a content process.
    func testNewTabLatency() async throws {
        var report = "\n=== NEW TAB -> FIRST DOCUMENT (hardened, trivial page) ===\n"
        var times: [Double] = []
        var views: [WKWebView] = []
        for _ in 0..<6 {
            let t0 = Date()
            let view = webView(policy(.hardened))
            views.append(view)
            _ = try await load(view, html: "<html><body>tab</body></html>")
            times.append(Date().timeIntervalSince(t0) * 1000)
        }
        report += "  per new tab: " + times.map { String(format: "%.0f", $0) }.joined(separator: " ") + " ms\n"
        print(report)
    }

    // MARK: 4. Main-thread work in the library

    private func bigLibrary() throws -> (BrowsingLibrary, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("iw-perf-\(UUID().uuidString)")
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let library = BrowsingLibrary(directory: dir)
        for i in 0..<BrowsingLibrary.historyLimit {
            library.recordVisit(url: URL(string: "https://site\(i % 900).example.com/articles/\(i)/some-long-slug-\(i)")!,
                                title: "Article number \(i) about things")
        }
        return (library, dir)
    }

    func testLibraryCosts() async throws {
        let (library, _) = try bigLibrary()
        var report = "\n=== LIBRARY (\(library.history.count) history entries) ===\n"

        var suggest: [Double] = []
        for q in ["si", "site4", "article", "things", "zz"] {
            let t0 = Date()
            for _ in 0..<10 { _ = library.suggestions(for: q) }
            suggest.append(Date().timeIntervalSince(t0) * 100)
        }
        report += String(format: "  suggestions(for:) per call: median %.2f ms  [%@]\n", median(suggest),
                         suggest.map { String(format: "%.2f", $0) }.joined(separator: " ") as NSString)

        let t0 = Date()
        for _ in 0..<5 { _ = try JSONEncoder().encode(library.history) }
        report += String(format: "  encode history JSON (now off the main thread): %.1f ms per save\n", Date().timeIntervalSince(t0) * 200)

        let t1 = Date()
        for i in 0..<50 { library.recordVisit(url: URL(string: "https://site\(i).example.com/articles/\(4000 + i)/some-long-slug-\(4000 + i)")!, title: "x") }
        report += String(format: "  recordVisit on main thread: %.2f ms per visit\n", Date().timeIntervalSince(t1) * 20)
        print(report)
    }
}

// MARK: - Process swap probe

/// Finding: YouTube's Cross-Origin-Opener-Policy header makes WebKit move the
/// page to a fresh content process at commit, at every hardening level. That
/// is engine behaviour (Safari does it too), not something this app causes.
/// Network-dependent: `TEST_RUNNER_IW_NETWORK_TESTS=1`.
@MainActor
final class ProcessSwapProbe: XCTestCase {
    final class Tracker: NSObject, WKNavigationDelegate {
        var events: [String] = []
        var done: CheckedContinuation<Void, Never>?
        weak var view: WKWebView?
        func pid() -> String { "\((view?.value(forKey: "_webProcessIdentifier") as? Int) ?? -1)" }
        func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { events.append("start@\(pid())") }
        func webView(_ w: WKWebView, didCommit n: WKNavigation!) { events.append("commit@\(pid())") }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) { events.append("finish@\(pid())"); done?.resume(); done = nil }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
            events.append("failProv(\((e as NSError).code))"); done?.resume(); done = nil
        }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) {
            events.append("fail(\((e as NSError).code))"); done?.resume(); done = nil
        }
    }

    func testFirstLoadProcessSwaps() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IW_NETWORK_TESTS"] == "1")
        var report = "\n=== FIRST LOAD IN A NEW TAB: PROCESS SWAPS (real URL: youtube.com/feed) ===\n"
        for level in [JavaScriptHardening.standard, .hardened, .standard, .hardened] {
            let policy = ResolvedSitePolicy(blockAds: true, httpsOnly: true, javaScript: true, resistFingerprinting: true,
                                            blockThirdPartyCookies: true, javaScriptHardening: level, isCustomised: false)
            let config = WebViewFactory.makeConfiguration(profile: .standard, policy: policy, ruleLists: [],
                                                          messageHandler: nil, topLevelURL: nil)
            let t0 = Date()
            let view = WebViewFactory.makeWebView(configuration: config)
            let tracker = Tracker(); tracker.view = view
            view.navigationDelegate = tracker
            // Mirrors Tab: the delegate re-applies the policy per navigation.
            let pidBefore = tracker.pid()
            await withCheckedContinuation { c in
                tracker.done = c
                view.load(URLRequest(url: URL(string: "https://www.youtube.com/feed")!))
            }
            report += String(format: "  %-9@ %5.0f ms  pid before load %@  %@\n", level.rawValue as NSString,
                             Date().timeIntervalSince(t0) * 1000, pidBefore as NSString,
                             tracker.events.joined(separator: " ") as NSString)
        }
        print(report)
    }
}
