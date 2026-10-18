import XCTest
import WebKit

/// Before moving site-specific cosmetics from `.*` + if-domain to a url-filter
/// on the document itself: does WebKit apply css-display-none from a
/// document-type match, including inside same-site frames, and does a
/// document-scoped exception still cancel universal cosmetics without touching
/// network blocks?
@MainActor
final class DocumentScopedCosmeticProbe: XCTestCase {

    private let host = #"^[a-z][a-z0-9+.-]*://([^/?#]+\\.)?"#

    private func run(rules: String, html: String, base: String, script: String) async throws -> [String: Any] {
        let list: WKContentRuleList = try await withCheckedThrowingContinuation { c in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "test-docscope-\(abs(rules.hashValue))",
                                                                    encodedContentRuleList: rules) { l, e in
                if let l { c.resume(returning: l) } else { c.resume(throwing: e!) }
            }
        }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(list)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 800, height: 600), configuration: config)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString(html, baseURL: URL(string: base)!)
        try await waiter.wait()
        try await Task.sleep(for: .milliseconds(600))
        let raw = try await webView.evaluateJavaScript(script) as? String ?? "{}"
        return (try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]) ?? [:]
    }

    func testDocumentScopedCosmeticApplies() async throws {
        let rules = """
        [{"trigger":{"url-filter":"\(host)site\\\\.example[:/]","resource-type":["document"]},
          "action":{"type":"css-display-none","selector":".promo, #banner"}}]
        """
        let html = #"<html><body><div class="promo" id="p">p</div><div id="banner">b</div><div id="keep">k</div></body></html>"#
        let script = #"JSON.stringify({ promo: getComputedStyle(p).display, banner: getComputedStyle(banner).display, keep: getComputedStyle(keep).display })"#
        let onSite = try await run(rules: rules, html: html, base: "https://www.site.example/article", script: script)
        let offSite = try await run(rules: rules, html: html, base: "https://other.example/", script: script)
        print("\n=== DOCUMENT-SCOPED COSMETIC ===\n  on site:  \(onSite)\n  off site: \(offSite)\n")
        XCTAssertEqual(onSite["promo"] as? String, "none")
        XCTAssertEqual(onSite["banner"] as? String, "none", "merged selector list applies fully")
        XCTAssertNotEqual(onSite["keep"] as? String, "none")
        XCTAssertNotEqual(offSite["promo"] as? String, "none", "must not apply to other sites")
    }

    func testDocumentScopedExceptionDoesNotCancelUniversalCosmetic() async throws {
        let rules = """
        [
          {"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":".generic-ad"}},
          {"trigger":{"url-filter":"\(host)exempt\\\\.example[:/]","resource-type":["document"]},"action":{"type":"ignore-previous-rules"}},
          {"trigger":{"url-filter":"^https://blocked\\\\.example/"},"action":{"type":"block"}}
        ]
        """
        let html = """
        <html><body><div class="generic-ad" id="ad">ad</div><script>
          window.__img = 'pending'; const i = new Image();
          i.onload = () => window.__img = 'loaded'; i.onerror = () => window.__img = 'failed';
          i.src = 'https://blocked.example/pixel.png';
        </script></body></html>
        """
        let script = #"JSON.stringify({ ad: getComputedStyle(ad).display, requested: performance.getEntriesByType('resource').some(r => r.name.includes('blocked.example')) })"#
        let exempt = try await run(rules: rules, html: html, base: "https://exempt.example/", script: script)
        let normal = try await run(rules: rules, html: html, base: "https://normal.example/", script: script)
        print("\n=== DOCUMENT-SCOPED EXCEPTION ===\n  exempt site: \(exempt)\n  normal site: \(normal)\n")
        // Observed, and load-bearing for the compiler: a document-scoped
        // exception does NOT cancel WebKit's universal cosmetic stylesheet. Page
        // exceptions therefore keep the `.*` + if-domain form (which does).
        XCTAssertEqual(exempt["ad"] as? String, "none",
                       "if this starts failing, WebKit changed and document-scoped page exceptions become possible")
        XCTAssertEqual(normal["ad"] as? String, "none", "control: universal cosmetic applies elsewhere")
        XCTAssertEqual(exempt["requested"] as? Bool, false, "network blocks below the exception must still apply")
    }
}
