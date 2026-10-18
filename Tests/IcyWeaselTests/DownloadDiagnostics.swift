import XCTest
import WebKit
@testable import Icy_Weasel

/// Isolates why a WKDownload stalls in the sandboxed app: destination path
/// form (container symlink vs resolved vs temp) and every delegate callback.
/// Network-dependent: `TEST_RUNNER_IW_NETWORK_TESTS=1`.
@MainActor
final class DownloadDiagnostics: XCTestCase {

    final class Probe: NSObject, WKDownloadDelegate {
        let destination: URL
        var events: [String] = []
        var done = false
        let t0 = Date()
        init(destination: URL) { self.destination = destination }
        func stamp(_ s: String) { events.append(String(format: "%6.0fms %@", Date().timeIntervalSince(t0) * 1000, s)) }

        func download(_ download: WKDownload, decideDestinationUsing response: URLResponse,
                      suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
            stamp("decideDestination suggested=\(suggestedFilename) status=\((response as? HTTPURLResponse)?.statusCode ?? -1)")
            try? FileManager.default.removeItem(at: destination)
            completionHandler(destination)
        }
        func download(_ download: WKDownload, willPerformHTTPRedirection response: HTTPURLResponse,
                      newRequest request: URLRequest, decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void) {
            stamp("redirect -> \(request.url?.absoluteString ?? "?")"); decisionHandler(.allow)
        }
        func download(_ download: WKDownload, respondTo challenge: URLAuthenticationChallenge,
                      completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            stamp("challenge \(challenge.protectionSpace.authenticationMethod)"); completionHandler(.performDefaultHandling, nil)
        }
        func downloadDidFinish(_ download: WKDownload) { stamp("didFinish"); done = true }
        func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
            let e = error as NSError
            stamp("didFail \(e.domain) \(e.code) \(e.localizedDescription)"); done = true
        }
    }

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["IW_NETWORK_TESTS"] == "1")
    }

    private func attempt(_ label: String, destination: URL) async -> String {
        let probe = Probe(destination: destination)
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        let download = await webView.startDownload(using: URLRequest(url: URL(string: "https://example.com/")!))
        download.delegate = probe
        probe.stamp("startDownload returned, delegate set")
        let deadline = Date().addingTimeInterval(15)
        while !probe.done, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(100))
        }
        let progress = download.progress
        probe.stamp(String(format: "end: done=%@ progress=%lld/%lld", probe.done ? "yes" : "no",
                           progress.completedUnitCount, progress.totalUnitCount))
        let exists = FileManager.default.fileExists(atPath: destination.path)
        let quarantine = getxattr(destination.path, "com.apple.quarantine", nil, 0, 0, 0) > 0
        if !probe.done { _ = await download.cancel() }
        try? FileManager.default.removeItem(at: destination)
        return "--- \(label): \(destination.path)\n" + probe.events.map { "    " + $0 }.joined(separator: "\n")
            + "\n    file exists=\(exists) quarantined=\(quarantine)"
    }

    func testDownloadDestinations() async {
        let containerDownloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        var report = "\n=== DOWNLOAD DIAGNOSTICS ===\n"
        report += await attempt("container symlink path", destination: containerDownloads.appendingPathComponent("iw-diag-1.html")) + "\n"
        report += await attempt("resolved real path", destination: containerDownloads.resolvingSymlinksInPath().appendingPathComponent("iw-diag-2.html")) + "\n"
        report += await attempt("temporary directory", destination: FileManager.default.temporaryDirectory.appendingPathComponent("iw-diag-3.html")) + "\n"
        print(report)
    }

    /// The exact production path: DownloadManager as the delegate.
    func testDownloadManagerPath() async throws {
        let manager = DownloadManager()
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)
        let t0 = Date()
        func ms() -> String { String(format: "%6.0fms", Date().timeIntervalSince(t0) * 1000) }
        var log: [String] = []
        let download = await webView.startDownload(using: URLRequest(url: URL(string: "https://example.com/")!))
        log.append("\(ms()) startDownload returned")
        manager.track(download)
        log.append("\(ms()) track returned")
        let entry = try XCTUnwrap(manager.items.first)
        var lastLine = ""
        let deadline = Date().addingTimeInterval(12)
        while entry.state == .running, Date() < deadline {
            let line = "state=\(entry.state) fraction=\(entry.fractionCompleted) dest=\(entry.destination?.lastPathComponent ?? "nil") progress=\(download.progress.completedUnitCount)/\(download.progress.totalUnitCount) weakAlive=\(manager.items.first.map { _ in "?" } ?? "")"
            if line != lastLine { log.append("\(ms()) \(line)"); lastLine = line }
            try await Task.sleep(for: .milliseconds(100))
        }
        log.append("\(ms()) loop ended: state=\(entry.state)")
        withExtendedLifetime(download) {}
        if let d = entry.destination { try? FileManager.default.removeItem(at: d) }
        print("\n=== DOWNLOAD MANAGER PATH ===\n" + log.map { "  " + $0 }.joined(separator: "\n") + "\n")
    }
}
