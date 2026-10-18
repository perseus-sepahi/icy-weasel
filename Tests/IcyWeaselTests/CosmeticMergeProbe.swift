import XCTest
import WebKit

/// Establishes how WebKit treats merged cosmetic selectors, before the compiler
/// relies on merging: does one invalid selector poison a whole merged rule, and
/// does wrapping the list in :is() contain the damage?
@MainActor
final class CosmeticMergeProbe: XCTestCase {

    private func hidden(selector: String, id: String) async throws -> [String: String] {
        let escaped = selector.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let json = #"[{"trigger":{"url-filter":".*"},"action":{"type":"css-display-none","selector":"\#(escaped)"}}]"#
        let list: WKContentRuleList? = await withCheckedContinuation { c in
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "test-merge-\(id)", encodedContentRuleList: json) {
                l, _ in c.resume(returning: l)
            }
        }
        guard let list else { return ["compiled": "no"] }
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(list)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString(#"<html><body><div class="a" id="a">a</div><div class="b" id="b">b</div><div class="c" id="c">c</div></body></html>"#,
                               baseURL: URL(string: "https://merge.example/")!)
        try await waiter.wait()
        try await Task.sleep(for: .milliseconds(200))
        var out = ["compiled": "yes"]
        for element in ["a", "b", "c"] {
            let display = try await webView.evaluateJavaScript("getComputedStyle(document.getElementById('\(element)')).display") as? String
            out[element] = display == "none" ? "hidden" : "visible"
        }
        return out
    }

    func testMergeSemantics() async throws {
        let cases: [(String, String)] = [
            ("plain list, all valid", ".a, .b"),
            ("plain list, one invalid", ".a, .bad[[, .b"),
            ("invalid first", ".bad[[, .a, .b"),
            ("invalid last", ".a, .b, .bad[["),
            ("invalid + later :is()", ".a, .bad[[, :is(.b)"),
            ("invalid + earlier :is()", ":is(.a), .bad[[, .b"),
            ("invalid + :not()", ".a, .bad[[, :not(.x).b"),
            ("unknown pseudo", ".a, .b:-abp-contains(x)"),
            ("bad attribute op", ".a, .b[x^^=1]"),
            (":is(), all valid", ":is(.a, .b)"),
            (":is(), one invalid", ":is(.a, .bad[[, .b)"),
            ("lone invalid selector", ".bad[["),
            (":is() with :has()", ":is(.a:has(+ .b), .c)"),
        ]
        var report = "\n=== COSMETIC MERGE SEMANTICS (elements .a .b .c) ===\n"
        for (i, (name, selector)) in cases.enumerated() {
            let r = try await hidden(selector: selector, id: "\(i)")
            report += "  \(name.padding(toLength: 28, withPad: " ", startingAt: 0)) compiled=\(r["compiled"]!)  a=\(r["a"] ?? "-") b=\(r["b"] ?? "-") c=\(r["c"] ?? "-")\n"
        }
        // Scale: one rule carrying 3,000 selectors.
        let many = ":is(" + (0..<3000).map { ".ad-slot-\($0)" }.joined(separator: ", ") + ", .b)"
        let big = try await hidden(selector: many, id: "big")
        report += "  3,000-selector :is()       compiled=\(big["compiled"]!)  b=\(big["b"] ?? "-")\n"
        print(report)
    }
}
