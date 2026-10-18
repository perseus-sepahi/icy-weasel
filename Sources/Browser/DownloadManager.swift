import Foundation
import WebKit
import AppKit
import Observation

/// Handles every download the web views start.
///
/// Security posture: files land in ~/Downloads with the `com.apple.quarantine`
/// extended attribute (via `LSFileQuarantineEnabled`), so Gatekeeper inspects
/// them before anything downloaded can run. Nothing is ever opened automatically.
@MainActor
@Observable
final class DownloadManager: NSObject {

    @MainActor
    @Observable
    final class Item: Identifiable {
        enum State: Equatable { case running, finished, failed(String), cancelled }

        let id = UUID()
        let sourceURL: URL?
        var filename: String
        var destination: URL?
        var state: State = .running
        var fractionCompleted: Double = 0
        var totalBytes: Int64 = 0
        /// Strong on purpose. WebKit hands the WKDownload to a delegate callback
        /// and nothing else retains it; held weakly, it is deallocated mid-transfer
        /// and the download silently stalls. Released when the download ends.
        @ObservationIgnored fileprivate var download: WKDownload?
        @ObservationIgnored fileprivate var observation: NSKeyValueObservation?

        fileprivate func finish(_ newState: State) {
            state = newState
            if newState == .finished { fractionCompleted = 1 }
            observation?.invalidate()
            observation = nil
            download = nil
        }

        init(sourceURL: URL?, filename: String) {
            self.sourceURL = sourceURL
            self.filename = filename
        }
    }

    private(set) var items: [Item] = []
    var hasActiveDownloads: Bool { items.contains { $0.state == .running } }

    private func item(for download: WKDownload) -> Item? {
        items.first { $0.download === download }
    }

    func track(_ download: WKDownload) {
        download.delegate = self
        let entry = Item(sourceURL: download.originalRequest?.url, filename: download.originalRequest?.url?.lastPathComponent ?? "download")
        entry.download = download
        entry.observation = download.progress.observe(\.fractionCompleted, options: [.new]) { [weak entry] progress, _ in
            let fraction = progress.fractionCompleted, total = progress.totalUnitCount
            Task { @MainActor in
                entry?.fractionCompleted = fraction
                entry?.totalBytes = total
            }
        }
        items.insert(entry, at: 0)
    }

    func cancel(_ entry: Item) {
        entry.download?.cancel { _ in }
        entry.finish(.cancelled)
    }

    func reveal(_ entry: Item) {
        guard let destination = entry.destination else { return }
        NSWorkspace.shared.activateFileViewerSelecting([destination])
    }

    func clearFinished() {
        items.removeAll { $0.state != .running }
    }

    /// Never overwrite: `report.pdf` becomes `report 2.pdf`.
    static func uniqueDestination(for suggested: String, in directory: URL) -> URL {
        // A server-suggested name is attacker-controlled. Keep only the last path
        // component so "../../Library/LaunchAgents/x.plist" cannot escape.
        let safeName = URL(fileURLWithPath: suggested).lastPathComponent
        let name = safeName.isEmpty || safeName == "/" ? "download" : safeName
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var candidate = directory.appendingPathComponent(name)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            let numbered = ext.isEmpty ? "\(base) \(counter)" : "\(base) \(counter).\(ext)"
            candidate = directory.appendingPathComponent(numbered)
            counter += 1
        }
        return candidate
    }
}

extension DownloadManager: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let directory = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let destination = Self.uniqueDestination(for: suggestedFilename, in: directory)
        if let entry = item(for: download) {
            entry.filename = destination.lastPathComponent
            entry.destination = destination
        }
        completionHandler(destination)
    }

    func downloadDidFinish(_ download: WKDownload) {
        item(for: download)?.finish(.finished)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let entry = item(for: download), entry.state != .cancelled else { return }
        entry.finish(.failed(error.localizedDescription))
    }
}
