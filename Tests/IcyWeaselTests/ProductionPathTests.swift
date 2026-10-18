import XCTest
import WebKit
@testable import Icy_Weasel

/// Verifies behaviour through the code paths the app actually uses, where
/// earlier tests used a more convenient path.
@MainActor
final class ProductionPathTests: XCTestCase {

    /// Tabs apply JavaScript hardening per navigation inside decidePolicyFor,
    /// not via the configuration. Prove that path really switches the JIT off.
    final class PolicyDelegate: NSObject, WKNavigationDelegate {
        let hardening: JavaScriptHardening
        var continuation: CheckedContinuation<Void, Never>?
        init(_ hardening: JavaScriptHardening) { self.hardening = hardening }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     preferences: WKWebpagePreferences,
                     decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
            let policy = ResolvedSitePolicy(blockAds: true, httpsOnly: false, javaScript: true,
                                            resistFingerprinting: false, blockThirdPartyCookies: true,
                                            javaScriptHardening: hardening, isCustomised: false)
            WebViewFactory.apply(policy, to: preferences)
            decisionHandler(.allow, preferences)
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            continuation?.resume(); continuation = nil
        }
    }

    private func computeTime(_ hardening: JavaScriptHardening) async throws -> Double {
        let delegate = PolicyDelegate(hardening)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        webView.navigationDelegate = delegate
        await withCheckedContinuation { c in
            delegate.continuation = c
            webView.loadHTMLString("<html><body>jit</body></html>", baseURL: URL(string: "https://jit.example/")!)
        }
        let result = try await webView.callAsyncJavaScript("""
            const run = () => { const t0 = performance.now(); let x = 0;
              for (let i = 0; i < 2e7; i++) x = (x + Math.imul(i, 2654435761)) | 0;
              return performance.now() - t0; };
            run(); return Math.min(run(), run());
            """, arguments: [:], in: nil, contentWorld: .page)
        return try XCTUnwrap(result as? Double)
    }

    func testPerNavigationHardeningActuallyDisablesTheJIT() async throws {
        guard #available(macOS 26.4, *) else { throw XCTSkip("needs securityRestrictionMode") }
        let fast = try await computeTime(.standard)
        let hardened = try await computeTime(.hardened)
        print(String(format: "\n=== PER-NAVIGATION JIT SWITCH ===\n  standard: %.0f ms, hardened: %.0f ms (%.0fx)\n",
                     fast, hardened, hardened / max(fast, 1)))
        XCTAssertGreaterThan(hardened / max(fast, 1), 10,
                             "setting hardening in decidePolicyFor must switch to the interpreter")
    }

    /// Downloads are written by WebKit's networking process, not the app. The
    /// quarantine attribute Gatekeeper relies on must still be present.
    func testDownloadedFilesAreQuarantined() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IW_NETWORK_TESTS"] == "1")
        let manager = DownloadManager()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)

        let download = await webView.startDownload(using: URLRequest(url: URL(string: "https://example.com/")!))
        manager.track(download)
        let entry = try XCTUnwrap(manager.items.first)
        let deadline = Date().addingTimeInterval(30)
        while entry.state == .running, Date() < deadline { try await Task.sleep(for: .milliseconds(200)) }
        XCTAssertEqual(entry.state, .finished, "download did not finish: \(entry.state)")
        let file = try XCTUnwrap(entry.destination)
        defer { try? FileManager.default.removeItem(at: file) }

        let size = getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0)
        var value = "(none)"
        if size > 0 {
            var buffer = [UInt8](repeating: 0, count: size)
            getxattr(file.path, "com.apple.quarantine", &buffer, size, 0, 0)
            value = String(decoding: buffer, as: UTF8.self)
        }
        print("\n=== DOWNLOAD QUARANTINE ===\n  file: \(file.lastPathComponent)\n  com.apple.quarantine: \(value)\n")
        XCTAssertGreaterThan(size, 0, "downloaded file lacks com.apple.quarantine")
    }
}
