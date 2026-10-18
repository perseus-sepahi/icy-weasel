import XCTest
import WebKit
@testable import Icy_Weasel

/// Ablation study for the page-load regression seen on theguardian.com:
/// which part of the ruleset costs time, and in which loading phase.
/// Network-dependent: `TEST_RUNNER_IW_NETWORK_TESTS=1`.
@MainActor
final class SpeedInvestigation: XCTestCase {

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IW_NETWORK_TESTS"] == "1")
    }

    enum Part { case network, cosmetic, all }

    private static var cache: [String: [WKContentRuleList]] = [:]

    private func contentLists(_ part: Part) async throws -> [WKContentRuleList] {
        let name = "test-ablation-\(part)"
        if let cached = Self.cache[name] { return cached }
        let fetcher = FilterListFetcher()
        var texts: [String] = []
        for source in FilterListCatalog.all where source.defaultEnabled {
            if let text = await fetcher.text(for: source) { texts.append(text) }
        }
        texts = texts.map { text in
            ContentBlockerStore.lines(of: [text]).filter { line in
                let cosmetic = line.contains("##") || line.contains("#@#")
                switch part {
                case .network:  return !cosmetic
                case .cosmetic: return cosmetic || line.hasPrefix("!")
                case .all:      return true
                }
            }.joined(separator: "\n")
        }
        let lists = try await ContentBlockerStore().buildRuleset(named: name, from: texts).lists
        Self.cache[name] = lists
        return lists
    }

    private func securityLists() async throws -> [WKContentRuleList] {
        let engine = BlockingEngine(settings: BrowserSettings())
        await engine.start()
        return engine.securityLists
    }

    // MARK: Per-process cost, offline

    /// Wall-clock for the first document in a brand-new web view (fresh content
    /// process) versus later documents in the same one.
    private func documentCost(_ lists: [WKContentRuleList]) async throws -> (first: Double, later: Double) {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        lists.forEach(config.userContentController.add)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 768), configuration: config)
        let html = "<html><head><title>t</title></head><body><div class='article'><p>Hello</p></div></body></html>"
        var times: [Double] = []
        for i in 0..<8 {
            let waiter = NavigationWaiter()
            webView.navigationDelegate = waiter
            let t0 = Date()
            webView.loadHTMLString(html, baseURL: URL(string: "https://doc\(i).example/")!)
            try await waiter.wait()
            times.append(Date().timeIntervalSince(t0) * 1000)
        }
        let later = Array(times.dropFirst()).sorted()
        return (times[0], later[later.count / 2])
    }

    func testFreshProcessDocumentCost() async throws {
        let configs: [(String, [WKContentRuleList])] = [
            ("no lists", []),
            ("network rules", try await contentLists(.network)),
            ("cosmetic rules", try await contentLists(.cosmetic)),
            ("full ruleset", try await contentLists(.all))
        ]
        var report = "\n=== DOCUMENT COST (trivial page; median of 3 fresh web views) ===\n"
        report += "  config            first document (new process)   later documents\n"
        for (label, lists) in configs {
            var firsts: [Double] = [], laters: [Double] = []
            for _ in 0..<3 {
                let (f, l) = try await documentCost(lists)
                firsts.append(f); laters.append(l)
            }
            report += String(format: "  %-16@  %14.0f ms %22.0f ms\n", label as NSString,
                             firsts.sorted()[1], laters.sorted()[1])
        }
        print(report)
    }

    // MARK: The Guardian, by phase

    private func phases(_ url: URL, lists: [WKContentRuleList]) async throws -> [String: Double] {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        lists.forEach(config.userContentController.add)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.load(URLRequest(url: url))
        _ = try? await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in try await waiter.wait() }
            group.addTask { try await Task.sleep(for: .seconds(40)) }
            try await group.next(); group.cancelAll()
        }
        let json = try await webView.evaluateJavaScript("""
            (function () {
              const n = performance.getEntriesByType('navigation')[0] || {};
              return JSON.stringify({ ttfb: n.responseStart, html: n.responseEnd, interactive: n.domInteractive,
                                      dcl: n.domContentLoadedEventEnd, load: n.loadEventEnd });
            })()
            """) as? String ?? "{}"
        return (try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Double]) ?? [:]
    }

    func testGuardianAblation() async throws {
        let url = URL(string: "https://www.theguardian.com/international")!
        let security = try await securityLists()
        let network = try await contentLists(.network)
        let cosmetic = try await contentLists(.cosmetic)
        let full = try await contentLists(.all)
        let configs: [(String, [WKContentRuleList])] = [
            ("no lists", []),
            ("security only", security),
            ("network family", network),
            ("cosmetic family", cosmetic),
            ("network+cosmetic", full),
            ("full + security", full + security)
        ]
        var rows: [String: [[String: Any]]] = [:]
        for round in 0..<6 {
            let offset = round % configs.count
            for (label, lists) in Array(configs[offset...]) + Array(configs[..<offset]) {
                rows[label, default: []].append(try await recordedLoad(url, lists: lists))
            }
        }
        var report = "\n=== THE GUARDIAN BY RULE FAMILY (wall clock, median of 6) ===\n"
        report += "  config             lists   wall DCL   wall load\n"
        for (label, lists) in configs {
            func med(_ key: String) -> Double {
                let v = (rows[label] ?? []).compactMap { $0[key] as? Double }.filter { $0 > 0 }.sorted()
                return v.isEmpty ? -1 : v[v.count / 2]
            }
            report += String(format: "  %-18@ %5d %10.0f %11.0f\n", label as NSString, lists.count, med("wallDCL"), med("wallLoad"))
        }
        print(report)
    }

    // MARK: List count

    /// Same rules, different number of compiled lists. If WebKit's per-request
    /// cost scales with list count, fewer larger lists should parse faster.
    func testListCountAblation() async throws {
        let fetcher = FilterListFetcher()
        var texts: [String] = []
        for source in FilterListCatalog.all where source.defaultEnabled {
            if let text = await fetcher.text(for: source) { texts.append(text) }
        }
        let url = URL(string: "https://www.theguardian.com/international")!
        var configs: [(String, [WKContentRuleList])] = [("no lists", [])]
        var report = "\n=== LIST COUNT ABLATION (same rules; The Guardian, 5 runs) ===\n"
        for chunk in [30_000, 80_000, 160_000, 400_000] {
            let t0 = Date()
            do {
                let ruleset = try await ContentBlockerStore().buildRuleset(
                    named: "test-chunks-\(chunk)", from: texts, maxRulesPerChunk: chunk)
                report += String(format: "  compiled %6d/chunk -> %d list(s) in %.1fs (dropped %d)\n",
                                 chunk, ruleset.lists.count, Date().timeIntervalSince(t0), ruleset.droppedByCompiler)
                configs.append(("\(ruleset.lists.count) list(s)", ruleset.lists))
            } catch {
                report += "  compiled \(chunk)/chunk -> FAILED: \(error.localizedDescription)\n"
            }
        }
        var samples: [String: [[String: Double]]] = [:]
        for round in 0..<5 {
            let offset = round % configs.count
            for (label, lists) in Array(configs[offset...]) + Array(configs[..<offset]) {
                samples[label, default: []].append(try await phases(url, lists: lists))
            }
        }
        report += "  config        parse ms (interactive - HTML done)       raw DOMContentLoaded values\n"
        for (label, _) in configs {
            let runs = samples[label] ?? []
            let parse = runs.compactMap { r -> Double? in
                guard let i = r["interactive"], let h = r["html"], i > 0 else { return nil }
                return i - h
            }.sorted()
            let dcl = runs.map { String(format: "%.0f", $0["dcl"] ?? -1) }.joined(separator: " ")
            report += String(format: "  %-12@  median %5.0f  [%@]      %@\n", label as NSString,
                             parse.isEmpty ? -1 : parse[parse.count / 2],
                             parse.map { String(format: "%.0f", $0) }.joined(separator: " ") as NSString,
                             dcl as NSString)
        }
        print(report)
    }

    // MARK: Measurement validity

    final class NavigationRecorder: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        var wallClock: [String: Double] = [:]
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            if let body = m.body as? [String: Any], let event = body["event"] as? String, let t = body["t"] as? Double,
               wallClock[event] == nil {
                wallClock[event] = t
            }
        }
        var commits: [String] = []
        var provisionalStarts = 0
        var finished = false
        var continuation: CheckedContinuation<Void, Never>?
        func webView(_ w: WKWebView, didStartProvisionalNavigation n: WKNavigation!) { provisionalStarts += 1 }
        func webView(_ w: WKWebView, didCommit n: WKNavigation!) { commits.append(w.url?.absoluteString ?? "?") }
        func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
            finished = true; continuation?.resume(); continuation = nil
        }
        func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { continuation?.resume(); continuation = nil }
        func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) {
            continuation?.resume(); continuation = nil
        }
    }

    private func recordedLoad(_ url: URL, lists: [WKContentRuleList]) async throws -> [String: Any] {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        lists.forEach(config.userContentController.add)
        let recorder = NavigationRecorder()
        // Real wall-clock stamps from an isolated world: Date.now() is epoch
        // time, comparable with the moment load() is called, independent of
        // WebKit's Performance timeline origin.
        let world = WKContentWorld.world(name: "timing")
        config.userContentController.add(recorder, contentWorld: world, name: "timing")
        config.userContentController.addUserScript(WKUserScript(source: """
            document.addEventListener('DOMContentLoaded', () =>
              webkit.messageHandlers.timing.postMessage({ event: 'dcl', t: Date.now() }), { once: true });
            window.addEventListener('load', () =>
              webkit.messageHandlers.timing.postMessage({ event: 'load', t: Date.now() }), { once: true });
            """, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: world))
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        webView.navigationDelegate = recorder
        let t0 = Date()
        await withCheckedContinuation { c in
            recorder.continuation = c
            webView.load(URLRequest(url: url))
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(30))
                recorder.continuation?.resume(); recorder.continuation = nil
            }
        }
        let wall = Date().timeIntervalSince(t0) * 1000
        try await Task.sleep(for: .milliseconds(500))
        let raw = try await webView.evaluateJavaScript("""
            (function () {
              const n = performance.getEntriesByType('navigation');
              const e = n[0] || {};
              return JSON.stringify({ entries: n.length, readyState: document.readyState, type: e.type,
                html: e.responseEnd, interactive: e.domInteractive, dcl: e.domContentLoadedEventEnd,
                load: e.loadEventEnd, redirects: e.redirectCount, finalURL: location.href });
            })()
            """) as? String ?? "{}"
        var out = (try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any]) ?? [:]
        let origin = t0.timeIntervalSince1970 * 1000
        out["wallDCL"] = recorder.wallClock["dcl"].map { $0 - origin } ?? -1
        out["wallLoad"] = recorder.wallClock["load"].map { $0 - origin } ?? -1
        out["commits"] = recorder.commits.count
        out["provisional"] = recorder.provisionalStarts
        out["didFinish"] = recorder.finished
        out["wallToFinish"] = wall
        return out
    }

    func testGuardianMeasurementValidity() async throws {
        let url = URL(string: "https://www.theguardian.com/international")!
        let engine = BlockingEngine(settings: BrowserSettings())
        await engine.start()
        let full = engine.contentLists + engine.securityLists
        var rows: [String: [[String: Any]]] = [:]
        for round in 0..<6 {
            let order: [(String, [WKContentRuleList])] = round % 2 == 0 ? [("no lists", []), ("full", full)] : [("full", full), ("no lists", [])]
            for (label, lists) in order { rows[label, default: []].append(try await recordedLoad(url, lists: lists)) }
        }
        var report = "\n=== GUARDIAN: WALL CLOCK vs PERFORMANCE TIMELINE (6 runs each, medians) ===\n"
        report += "  config     wall DCL   wall load   wall didFinish  |  timeline DCL  timeline load\n"
        for label in ["no lists", "full"] {
            func med(_ key: String) -> Double {
                let v = (rows[label] ?? []).compactMap { $0[key] as? Double }.filter { $0 > 0 }.sorted()
                return v.isEmpty ? -1 : v[v.count / 2]
            }
            report += String(format: "  %-9@ %9.0f %11.0f %15.0f  | %13.0f %14.0f\n", label as NSString,
                             med("wallDCL"), med("wallLoad"), med("wallToFinish"), med("dcl"), med("load"))
        }
        print(report)
    }

    // MARK: Which rules cost parse time

    func testRuleCategoryCost() async throws {
        let fetcher = FilterListFetcher()
        var lines: [String] = []
        for source in FilterListCatalog.all where source.defaultEnabled {
            if let text = await fetcher.text(for: source) { lines += ContentBlockerStore.lines(of: [text]) }
        }
        var buckets: [String: [String]] = [:]
        for line in lines {
            guard case .success(let parsed) = AdblockParser.parse(line: line) else { continue }
            let key: String
            switch parsed {
            case .cosmetic(let c):
                key = c.isException ? "cosmetic exceptions" : (c.includeDomains.isEmpty ? "generic cosmetic" : "site cosmetic")
            case .network(let f) where f.isException:
                key = f.pageScope != nil ? "page exceptions" : "network exceptions"
            case .network(let f) where f.isRawRegex:
                key = "regex blocks"
            case .network(let f) where !f.includeDomains.isEmpty || !f.excludeDomains.isEmpty:
                key = "domain= blocks"
            case .network(let f) where f.domainAnchored:
                let pureHost = f.pattern.hasSuffix("^") && !f.pattern.dropLast().contains(where: { "/*^?:=&|".contains($0) })
                key = pureHost && f.resourceTypes.isEmpty && f.loadType == nil ? "||host^ blocks" : "||host/path blocks"
            case .network:
                key = "unanchored blocks"
            }
            buckets[key, default: []].append(line)
        }
        let url = URL(string: "https://www.theguardian.com/international")!
        var configs: [(String, [WKContentRuleList], Int)] = [("no lists", [], 0)]
        for (name, bucket) in buckets.sorted(by: { $0.key < $1.key }) where name != "cosmetic exceptions" {
            let ruleset = try await ContentBlockerStore().buildRuleset(
                named: "test-cat-\(name.replacingOccurrences(of: " ", with: "_"))", from: [bucket.joined(separator: "\n")])
            configs.append((name, ruleset.lists, bucket.count))
        }
        var parse: [String: [Double]] = [:]
        for round in 0..<5 {
            let offset = round % configs.count
            for (label, lists, _) in Array(configs[offset...]) + Array(configs[..<offset]) {
                let r = try await recordedLoad(url, lists: lists)
                if (r["commits"] as? Int) == 1, let dcl = r["wallDCL"] as? Double, dcl > 0 {
                    parse[label, default: []].append(dcl)
                }
            }
        }
        var report = "\n=== WALL-CLOCK DOMContentLoaded BY RULE CATEGORY (The Guardian; median) ===\n"
        for (label, lists, count) in configs {
            let v = (parse[label] ?? []).sorted()
            let median = v.isEmpty ? -1 : v[v.count / 2]
            report += String(format: "  %-22@ %7d rules  %2d list(s)  DCL %5.0f ms  (n=%d)\n",
                             label as NSString, count, lists.count, median, v.count)
        }
        print(report)
    }

    // MARK: Coverage vs cost of list subsets

    /// Which default lists earn their per-request cost? Coverage is measured as
    /// third-party hosts a real page still reaches; cost as wall-clock
    /// DOMContentLoaded.
    func testListSubsetTradeoff() async throws {
        let fetcher = FilterListFetcher()
        func texts(_ ids: [String]) async -> [String] {
            var out: [String] = []
            for id in ids {
                if let source = FilterListCatalog.source(id: id), let text = await fetcher.text(for: source) { out.append(text) }
            }
            return out
        }
        let subsets: [(String, [String])] = [
            ("EasyList+EasyPrivacy", ["easylist", "easyprivacy"]),
            ("+ uBO core/privacy/badware", ["easylist", "easyprivacy", "ubo-filters", "ubo-privacy", "ubo-badware"]),
            ("all 7 defaults", FilterListCatalog.all.filter(\.defaultEnabled).map(\.id))
        ]
        var configs: [(String, [WKContentRuleList], Int)] = [("no lists", [], 0)]
        for (label, ids) in subsets {
            let ruleset = try await ContentBlockerStore().buildRuleset(
                named: "test-subset-\(ids.count)", from: await texts(ids))
            configs.append((label, ruleset.lists, ruleset.stats.converted))
        }
        let pages = ["https://www.speedtest.net/", "https://www.cnn.com/", "https://www.theguardian.com/international"]
        var hosts: [String: [String: [Double]]] = [:], dcl: [String: [String: [Double]]] = [:]
        for round in 0..<3 {
            let offset = round % configs.count
            for (label, lists, _) in Array(configs[offset...]) + Array(configs[..<offset]) {
                for page in pages {
                    let url = URL(string: page)!
                    let r = try await recordedLoad(url, lists: lists)
                    let webHosts = try await thirdPartyHostCount(url, lists: lists)
                    hosts[label, default: [:]][url.host!, default: []].append(Double(webHosts))
                    if let d = r["wallDCL"] as? Double, d > 0 { dcl[label, default: [:]][url.host!, default: []].append(d) }
                }
            }
        }
        func median(_ v: [Double]?) -> Double { guard let v, !v.isEmpty else { return -1 }; return v.sorted()[v.count / 2] }
        var report = "\n=== LIST SUBSETS: COVERAGE vs COST (median of 3) ===\n"
        report += "  config                       rules   | 3rd-party hosts: speedtest  cnn  guardian | wall DCL ms: speedtest   cnn  guardian\n"
        for (label, _, rules) in configs {
            let hs = pages.map { median(hosts[label]?[URL(string: $0)!.host!]) }
            let ds = pages.map { median(dcl[label]?[URL(string: $0)!.host!]) }
            report += String(format: "  %-28@ %7d   | %25.0f %4.0f %9.0f | %22.0f %5.0f %9.0f\n",
                             label as NSString, rules, hs[0], hs[1], hs[2], ds[0], ds[1], ds[2])
        }
        print(report)
    }

    /// Distinct hostnames other than the page's own site among loaded resources.
    private func thirdPartyHostCount(_ url: URL, lists: [WKContentRuleList]) async throws -> Int {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        lists.forEach(config.userContentController.add)
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        let waiter = NavigationWaiter()
        webView.navigationDelegate = waiter
        webView.load(URLRequest(url: url))
        _ = try? await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { @MainActor in try await waiter.wait() }
            group.addTask { try await Task.sleep(for: .seconds(30)) }
            try await group.next(); group.cancelAll()
        }
        try await Task.sleep(for: .seconds(3))
        let site = PublicSuffix.registrableDomain(of: url) ?? ""
        let names = try await webView.evaluateJavaScript(
            "JSON.stringify(performance.getEntriesByType('resource').map(r => r.name))") as? String ?? "[]"
        let urls = (try JSONSerialization.jsonObject(with: Data(names.utf8)) as? [String]) ?? []
        return Set(urls.compactMap { URL(string: $0)?.host }.filter {
            PublicSuffix.registrableDomain(ofHost: $0) != site
        }).count
    }

    /// With the cosmetic cost fixed, does the number of network lists (and so
    /// the number of duplicated exception copies) drive what remains?
    func testNetworkChunkSize() async throws {
        let fetcher = FilterListFetcher()
        var texts: [String] = []
        for source in FilterListCatalog.all where source.defaultEnabled {
            if let text = await fetcher.text(for: source) {
                texts.append(ContentBlockerStore.lines(of: [text]).filter { !$0.contains("##") && !$0.contains("#@#") }
                    .joined(separator: "\n"))
            }
        }
        let url = URL(string: "https://www.theguardian.com/international")!
        var configs: [(String, [WKContentRuleList])] = [("no lists", [])]
        var report = "\n=== NETWORK CHUNK SIZE (The Guardian, wall clock, median of 6) ===\n"
        for size in [30_000, 60_000, 110_000, 250_000] {
            let t0 = Date()
            let ruleset = try await ContentBlockerStore().buildRuleset(named: "test-netchunk-\(size)", from: texts, maxRulesPerChunk: size)
            report += String(format: "  %6d/chunk -> %d list(s), compiled in %.1fs, dropped %d\n",
                             size, ruleset.lists.count, Date().timeIntervalSince(t0), ruleset.droppedByCompiler)
            configs.append(("\(size / 1000)k: \(ruleset.lists.count) lists", ruleset.lists))
        }
        var rows: [String: [Double]] = [:]
        for round in 0..<6 {
            let offset = round % configs.count
            for (label, lists) in Array(configs[offset...]) + Array(configs[..<offset]) {
                let r = try await recordedLoad(url, lists: lists)
                if let d = r["wallDCL"] as? Double, d > 0 { rows[label, default: []].append(d) }
            }
        }
        for (label, _) in configs {
            let v = (rows[label] ?? []).sorted()
            report += String(format: "  %-18@ wall DCL %5.0f ms  [%@]\n", label as NSString, v.isEmpty ? -1 : v[v.count / 2],
                             v.map { String(format: "%.0f", $0) }.joined(separator: " ") as NSString)
        }
        print(report)
    }
}
