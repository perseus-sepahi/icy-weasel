import XCTest
import WebKit
@testable import Icy_Weasel

/// Which trigger keys and values WebKit's content-rule compiler accepts, and —
/// for the ones the page-scoped exception design depends on — whether they
/// *behave* as assumed in a real web view.
@MainActor
final class TriggerDialectProbe: XCTestCase {

    private func accepts(_ json: String, id: String) async -> Bool {
        await withCheckedContinuation { c in
            WKContentRuleListStore.default().compileContentRuleList(
                forIdentifier: "test-trigger-\(id)", encodedContentRuleList: json
            ) { list, _ in c.resume(returning: list != nil) }
        }
    }

    func testTriggerDialect() async {
        let cases: [(String, String)] = [
            ("if-domain", #"{"url-filter":".*","if-domain":["*example.com"]}"#),
            ("if-domain entity gmx.*", #"{"url-filter":".*","if-domain":["*gmx.*"]}"#),
            ("if-top-url", #"{"url-filter":".*","if-top-url":["^https?://([^/]+\\.)?example\\.com/search"]}"#),
            ("unless-top-url", #"{"url-filter":".*","unless-top-url":["^https?://example\\.com/"]}"#),
            ("if-frame-url", #"{"url-filter":".*","if-frame-url":["^https?://example\\.com/"]}"#),
            ("load-context top-frame", #"{"url-filter":".*","load-context":["top-frame"]}"#),
            ("resource-type fetch", #"{"url-filter":".*","resource-type":["fetch"]}"#),
            ("resource-type websocket", #"{"url-filter":".*","resource-type":["websocket"]}"#),
            ("resource-type ping", #"{"url-filter":".*","resource-type":["ping"]}"#),
            ("resource-type other", #"{"url-filter":".*","resource-type":["other"]}"#),
            ("if-domain + if-top-url", #"{"url-filter":".*","if-domain":["*a.com"],"if-top-url":["^https://a\\.com/"]}"#),
        ]
        var report = "\nWebKit trigger dialect:\n"
        for (i, (name, trigger)) in cases.enumerated() {
            let ok = await accepts(#"[{"trigger":\#(trigger),"action":{"type":"block"}}]"#, id: "\(i)")
            report += "  \(ok ? "ACCEPT" : "reject")  \(name)\n"
        }
        print(report)
    }

    /// The ordering trick the compiler relies on: an `ignore-previous-rules`
    /// placed *between* cosmetic and network rules must cancel the cosmetic
    /// rules above it and leave the network block below it working.
    func testOrderScopedExceptionCancelsOnlyRulesAboveIt() async throws {
        let json = #"""
        [
          {"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".generic-ad"}},
          {"trigger":{"url-filter":".*","if-domain":["*page.example"]},"action":{"type":"ignore-previous-rules"}},
          {"trigger":{"url-filter":"^https://blocked\\.example/"},"action":{"type":"block"}}
        ]
        """#
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { c in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "test-order", encodedContentRuleList: json) { l, e in
                if let l { c.resume(returning: l) } else { c.resume(throwing: e!) }
            }
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(list)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString("""
            <html><body><div class="generic-ad" id="ad">ad</div>
            <script>
              window.__img = 'pending';
              const i = new Image();
              i.onload = () => window.__img = 'loaded';
              i.onerror = () => window.__img = 'failed';
              i.src = 'https://blocked.example/pixel.png';
            </script></body></html>
            """, baseURL: URL(string: "https://page.example/")!)
        try await waiter.wait()
        try await Task.sleep(for: .milliseconds(500))
        let display = try await webView.evaluateJavaScript("getComputedStyle(document.getElementById('ad')).display") as? String
        let resources = try await webView.evaluateJavaScript(
            "performance.getEntriesByType('resource').map(r => r.name).join(',')") as? String ?? ""
        print("\n=== ORDER-SCOPED EXCEPTION ===\n  cosmetic display: \(display ?? "?")\n  resource entries: [\(resources)]\n")
        XCTAssertNotEqual(display, "none", "the exception above should cancel the cosmetic rule")
        XCTAssertFalse(resources.contains("blocked.example"), "the network block below the exception must still apply")
    }
}
