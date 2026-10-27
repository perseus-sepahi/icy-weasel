import Foundation
import CryptoKit
import Observation

/// Downloads Phonon 40m multilingual when the user asks for it in Settings.
///
/// The model is CC BY-NC 4.0, so it never ships inside the app; it is offered
/// as a separate, free download with its licence. The archive comes from
/// Icy Weasel's own GitHub release (made by scripts/export-phonon-multilingual.sh)
/// and must match the SHA-256 pinned here before anything is unpacked.
@MainActor
@Observable
final class PhononModelDownload {
    static let shared = PhononModelDownload()

    static let model = PhononModel.multilingual40m
    static let url = URL(string: "https://github.com/perseus-sepahi/icy-weasel/releases/download/phonon-40m-multilingual-1/phonon-40m-multilingual-coreml.zip")!
    static let sha256 = "PENDING_EXPORT"
    static let byteCount: Int64 = 0
    /// False until the export is uploaded and its checksum pinned above;
    /// until then Settings doesn't offer the model.
    static var isPublished: Bool { sha256.count == 64 }

    enum State: Equatable {
        case missing
        case downloading(Double)
        case installing
        case ready
        case failed(String)
    }

    private(set) var state: State
    @ObservationIgnored private var task: Task<Void, Never>?

    private init() {
        state = Self.model.location == nil ? .missing : .ready
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: Self.byteCount, countStyle: .file)
    }

    func start() {
        guard task == nil, state != .ready else { return }
        state = .downloading(0)
        task = Task {
            do {
                try await download()
                PhononEngine.reloadVoices()
                state = .ready
            } catch is CancellationError {
                state = .missing
            } catch {
                state = .failed(error.localizedDescription)
            }
            task = nil
        }
    }

    func cancel() { task?.cancel() }

    func remove() {
        cancel()
        PhononEngine.shared.unload(Self.model)
        if let folder = Self.model.location { try? FileManager.default.removeItem(at: folder) }
        PhononEngine.reloadVoices()
        state = .missing
    }

    // MARK: Download, check, unpack

    private func download() async throws {
        guard let support = PhononEngine.supportDirectory else { throw DownloadError("No Application Support folder.") }
        let fm = FileManager.default
        try fm.createDirectory(at: support, withIntermediateDirectories: true)

        let progress = ProgressRelay(expected: Self.byteCount) { [weak self] fraction in
            Task { @MainActor in
                guard let self, case .downloading = self.state else { return }
                self.state = .downloading(fraction)
            }
        }
        let (archive, response) = try await URLSession.shared.download(from: Self.url, delegate: progress)
        defer { try? fm.removeItem(at: archive) }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw DownloadError("The download server answered \(http.statusCode).")
        }
        try Task.checkCancellation()
        state = .installing

        let staging = support.appendingPathComponent("\(Self.model.rawValue).partial", isDirectory: true)
        try? fm.removeItem(at: staging)
        defer { try? fm.removeItem(at: staging) }
        let expected = Self.sha256
        try await Task.detached(priority: .userInitiated) {
            guard try Self.sha256(of: archive) == expected else {
                throw DownloadError("The download doesn't match its checksum, so it wasn't used.")
            }
            try Self.unzip(archive, into: staging)
        }.value

        let unpacked = staging.appendingPathComponent(Self.model.rawValue, isDirectory: true)
        try Self.checkComplete(unpacked)
        let destination = support.appendingPathComponent(Self.model.rawValue, isDirectory: true)
        try? fm.removeItem(at: destination)
        try fm.moveItem(at: unpacked, to: destination)
        PhononEngine.excludeFromBackup(destination)
    }

    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 8 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    nonisolated static func unzip(_ archive: URL, into folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, folder.path]
        try ditto.run()
        ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw DownloadError("The download couldn't be unpacked.") }
    }

    /// Every file bundle.json lists is there with its size, and nothing in the
    /// archive pointed outside the model folder.
    static func checkComplete(_ folder: URL) throws {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent("bundle.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let files = object["files"] as? [[String: Any]], !files.isEmpty
        else { throw DownloadError("The download isn't a Phonon model.") }
        let root = folder.resolvingSymlinksInPath().path + "/"
        for file in files {
            guard let path = file["path"] as? String, let size = file["size"] as? Int else {
                throw DownloadError("The model's file list is unreadable.")
            }
            let url = folder.appendingPathComponent(path).resolvingSymlinksInPath()
            let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
            guard url.path.hasPrefix(root), (attributes?[.size] as? Int) == size else {
                throw DownloadError("The download is incomplete (\(path)).")
            }
        }
    }

    struct DownloadError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

/// Reports a download's progress as a fraction.
private final class ProgressRelay: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let expected: Int64
    let report: (Double) -> Void
    init(expected: Int64, _ report: @escaping (Double) -> Void) { self.expected = expected; self.report = report }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let total = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : expected
        if total > 0 { report(min(1, Double(totalBytesWritten) / Double(total))) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
}
