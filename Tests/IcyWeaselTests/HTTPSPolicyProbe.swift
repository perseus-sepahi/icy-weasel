import XCTest
import WebKit

/// Records what WebKit's native HTTPS-only policy actually does, so the tab's
/// failure attribution is written against observed errors, not guesses.
/// Network-dependent: `TEST_RUNNER_IW_NETWORK_TESTS=1`.
@available(macOS 15.2, *)
@MainActor
final class HTTPSPolicyProbe: XCTestCase {

    final class Recorder: NSObject, WKNavigationDelegate {
        var events: [String] = []
        var continuation: CheckedContinuation<Void, Never>?
        let policy: WKWebpagePreferences.UpgradeToHTTPSPolicy
        init(policy: WKWebpagePreferences.UpgradeToHTTPSPolicy) { self.policy = policy }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     preferences: WKWebpagePreferences,
                     decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
            events.append("decide \(action.request.url?.absoluteString ?? "nil") main=\(action.targetFrame?.isMainFrame ?? false)")
            preferences.preferredHTTPSNavigationPolicy = policy
            decisionHandler(.allow, preferences)
        }
        func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
            events.append("redirect -> \(webView.url?.absoluteString ?? "nil")")
        }
        func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
            events.append("commit \(webView.url?.absoluteString ?? "nil")")
        }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            events.append("finish \(webView.url?.absoluteString ?? "nil")")
            continuation?.resume(); continuation = nil
        }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            let e = error as NSError
            events.append("failProvisional domain=\(e.domain) code=\(e.code) url=\(e.userInfo[NSURLErrorFailingURLStringErrorKey] ?? "?") desc=\(e.localizedDescription)")
            continuation?.resume(); continuation = nil
        }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            let e = error as NSError
            events.append("fail domain=\(e.domain) code=\(e.code)")
            continuation?.resume(); continuation = nil
        }
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IW_NETWORK_TESTS"] == "1")
    }

    private func visit(_ url: String) async -> [String] {
        let recorder = Recorder(policy: .errorOnFailure)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = recorder
        await withCheckedContinuation { c in
            recorder.continuation = c
            webView.load(URLRequest(url: URL(string: url)!))
            Task { try? await Task.sleep(for: .seconds(25)); recorder.continuation?.resume(); recorder.continuation = nil }
        }
        return recorder.events
    }

    func testObservedBehaviour() async {
        for url in ["http://neverssl.com/", "http://example.com/", "http://this-host-does-not-exist-iw.invalid/"] {
            let events = await visit(url)
            print("\n=== HTTPS policy: \(url)\n  " + events.joined(separator: "\n  "))
        }
    }
}
