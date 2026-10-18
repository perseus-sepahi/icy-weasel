import XCTest
import WebKit
@testable import Icy_Weasel

/// Isolates what the cosmetic half of the ruleset costs every page.
///
/// WebKit applies `css-display-none` rules by attaching a stylesheet of their
/// selectors. Generic rules apply everywhere, so their selectors take part in
/// style resolution on every page. This measures style+layout for an identical
/// synthetic page under: no lists, network rules only, and the full ruleset.
/// Offline and deterministic — no network variance.
///
/// Gated with the network tests because building rulesets may fetch lists.
@MainActor
final class StyleCostExperiment: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IW_NETWORK_TESTS"] == "1")
    }

    private func lists(named name: String, keepCosmetics: Bool) async throws -> [WKContentRuleList] {
        let fetcher = FilterListFetcher()
        var texts: [String] = []
        for source in FilterListCatalog.all where source.defaultEnabled {
            if let text = await fetcher.text(for: source) { texts.append(text) }
        }
        if !keepCosmetics {
            texts = texts.map { text in
                ContentBlockerStore.lines(of: [text]).filter { !$0.contains("##") && !$0.contains("#@#") }
                    .joined(separator: "\n")
            }
        }
        return try await ContentBlockerStore().buildRuleset(named: name, from: texts).lists
    }

    /// A news-page-shaped DOM: nested containers, many distinct classes and ids.
    private static let benchmark = #"""
        const words = ['article','header','story','card','teaser','media','caption','byline','related',
          'section','content','nav','footer','item','list','title','summary','image','video','meta'];
        function build() {
          const root = document.createElement('main');
          for (let i = 0; i < 400; i++) {
            const card = document.createElement('div');
            card.className = words[i % 20] + ' ' + words[(i * 7) % 20] + '-wrap col-' + (i % 12);
            card.id = 'node-' + i;
            for (let j = 0; j < 6; j++) {
              const child = document.createElement(j % 3 ? 'p' : 'span');
              child.className = words[(i + j) % 20] + '__' + words[(i * j) % 20];
              child.textContent = 'Lorem ipsum ' + i + ' ' + j;
              card.appendChild(child);
            }
            root.appendChild(card);
          }
          return root;
        }
        const samples = [];
        for (let run = 0; run < 9; run++) {
          const tree = build();
          const t0 = performance.now();
          document.body.appendChild(tree);
          void document.body.offsetHeight;          // force style + layout
          getComputedStyle(tree.lastChild).display; // and style on a deep node
          samples.push(performance.now() - t0);
          tree.remove();
          void document.body.offsetHeight;
        }
        samples.sort((a, b) => a - b);
        return JSON.stringify({ median: samples[4], min: samples[0] });
    """#

    private func measure(_ lists: [WKContentRuleList]) async throws -> (median: Double, min: Double) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        lists.forEach(config.userContentController.add)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "https://news.example/")!)
        try await waiter.wait()
        let raw = try await webView.callAsyncJavaScript(Self.benchmark, arguments: [:], in: nil, contentWorld: .page) as? String
        let obj = try JSONSerialization.jsonObject(with: Data((raw ?? "{}").utf8)) as? [String: Double] ?? [:]
        return (obj["median"] ?? -1, obj["min"] ?? -1)
    }

    func testCosmeticStylesheetCost() async throws {
        let full = try await lists(named: "test-style-full", keepCosmetics: true)
        let networkOnly = try await lists(named: "test-style-network", keepCosmetics: false)

        var none: [(Double, Double)] = [], net: [(Double, Double)] = [], all: [(Double, Double)] = []
        for _ in 0..<3 {  // rotate order so warm-up effects don't favour one arm
            none.append(try await measure([]))
            net.append(try await measure(networkOnly))
            all.append(try await measure(full))
        }
        func median(_ runs: [(Double, Double)]) -> Double { runs.map(\.0).sorted()[runs.count / 2] }
        let n = median(none), w = median(net), f = median(all)
        print(String(format: """

            === COSMETIC STYLESHEET COST (2,800-element page, style+layout, median ms) ===
              no lists:            %.1f
              network rules only:  %.1f  (%.2fx)
              full ruleset:        %.1f  (%.2fx)

            """, n, w, w / max(n, 0.1), f, f / max(n, 0.1)))
    }
}
