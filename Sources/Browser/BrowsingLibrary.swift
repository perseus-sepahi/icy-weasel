import Foundation
import SwiftUI
import Observation

struct HistoryEntry: Codable, Identifiable, Equatable {
    var url: URL
    var title: String
    var lastVisit: Date
    var visits: Int
    var id: URL { url }
}

struct Bookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var url: URL
}

struct TabGroup: Codable, Identifiable, Equatable {
    enum Tint: String, Codable, CaseIterable {
        case blue, purple, pink, red, orange, yellow, green, teal, gray
        var color: Color {
            switch self {
            case .blue: return .blue; case .purple: return .purple; case .pink: return .pink
            case .red: return .red; case .orange: return .orange; case .yellow: return .yellow
            case .green: return .green; case .teal: return .teal; case .gray: return .gray
            }
        }
    }
    var id = UUID()
    var name: String
    var tint: Tint
    var isCollapsed = false
}

/// What a window looked like, for restoring it on the next launch.
struct SavedSession: Codable {
    struct SavedTab: Codable { var url: URL?; var title: String; var groupID: UUID? }
    var tabs: [SavedTab]
    var groups: [TabGroup]
    var selectedIndex: Int
}

/// History, bookmarks and the saved session. One instance is shared by every
/// normal window; private windows never write to it.
///
/// Everything is a plain JSON file inside the app's sandbox container. Nothing
/// here ever leaves the machine.
@MainActor
@Observable
final class BrowsingLibrary {
    private(set) var history: [HistoryEntry] = [] { didSet { revision &+= 1 } }
    private(set) var bookmarks: [Bookmark] = [] { didSet { revision &+= 1 } }
    /// Bumped on every history or bookmark change. Cheap to compare, so views
    /// and caches can tell "unchanged" without diffing thousands of entries.
    private(set) var revision = 0
    private let directory: URL?
    private var saveTask: Task<Void, Never>?
    private let writer = LibraryWriter()
    static let historyLimit = 5_000

    /// `directory: nil` keeps everything in memory (tests, private windows).
    init(directory: URL?) {
        self.directory = directory
        guard let directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        history = Self.load([HistoryEntry].self, from: directory.appendingPathComponent("history.json")) ?? []
        bookmarks = Self.load([Bookmark].self, from: directory.appendingPathComponent("bookmarks.json")) ?? []
    }

    static func persistent() -> BrowsingLibrary {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return BrowsingLibrary(directory: base.appendingPathComponent("IcyWeasel/Library", isDirectory: true))
    }

    // MARK: History

    func recordVisit(url: URL, title: String) {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        if let index = history.firstIndex(where: { $0.url == url }) {
            var entry = history.remove(at: index)
            entry.visits += 1; entry.lastVisit = Date()
            if !title.isEmpty { entry.title = title }
            history.insert(entry, at: 0)
        } else {
            history.insert(HistoryEntry(url: url, title: title, lastVisit: Date(), visits: 1), at: 0)
            if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        }
        scheduleSave()
    }

    func removeHistory(_ entry: HistoryEntry) { history.removeAll { $0.url == entry.url }; scheduleSave() }
    func clearHistory() { history.removeAll(); scheduleSave() }

    // MARK: Bookmarks

    func isBookmarked(_ url: URL?) -> Bool { url.map { u in bookmarks.contains { $0.url == u } } ?? false }

    func toggleBookmark(url: URL, title: String) {
        if let index = bookmarks.firstIndex(where: { $0.url == url }) { bookmarks.remove(at: index) }
        else { bookmarks.append(Bookmark(title: title.isEmpty ? (url.host ?? url.absoluteString) : title, url: url)) }
        scheduleSave()
    }

    func removeBookmark(_ bookmark: Bookmark) { bookmarks.removeAll { $0.id == bookmark.id }; scheduleSave() }

    // MARK: Suggestions

    struct Suggestion: Identifiable, Equatable {
        var url: URL; var title: String; var isBookmark: Bool
        var id: URL { url }
    }

    /// Pre-lowercased search fields. Building these per keystroke meant
    /// thousands of string allocations each time; now it happens once per
    /// library change.
    private struct IndexedEntry {
        let suggestion: Suggestion
        /// Lowercased UTF-8 bytes. Matching is a byte search (memmem), which is
        /// exact for already-lowercased text and far cheaper than String.contains.
        let host: [UInt8], title: [UInt8], full: [UInt8]
        let visits: Int, pathLength: Int
    }

    private static func bytes(_ s: String) -> [UInt8] { Array(s.utf8) }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard needle.count <= haystack.count else { return false }
        return haystack.withUnsafeBytes { h in
            needle.withUnsafeBytes { n in
                memmem(h.baseAddress, h.count, n.baseAddress, n.count) != nil
            }
        }
    }

    private static func hasPrefix(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        needle.count <= haystack.count && haystack.starts(with: needle)
    }
    @ObservationIgnored private var index: [IndexedEntry] = []
    @ObservationIgnored private var indexRevision = -1

    private func searchIndex() -> [IndexedEntry] {
        if indexRevision == revision { return index }
        func entry(_ url: URL, _ title: String, visits: Int, bookmark: Bool) -> IndexedEntry {
            var host = (url.host ?? "").lowercased()
            if host.hasPrefix("www.") { host.removeFirst(4) }
            return IndexedEntry(suggestion: Suggestion(url: url, title: title, isBookmark: bookmark),
                                host: Self.bytes(host), title: Self.bytes(title.lowercased()),
                                full: Self.bytes(url.absoluteString.lowercased()),
                                visits: visits, pathLength: url.path.count)
        }
        var seen = Set<URL>()
        var built: [IndexedEntry] = []
        built.reserveCapacity(bookmarks.count + min(history.count, 2_000))
        for b in bookmarks where seen.insert(b.url).inserted {
            built.append(entry(b.url, b.title, visits: 0, bookmark: true))
        }
        for h in history.prefix(2_000) where seen.insert(h.url).inserted {
            built.append(entry(h.url, h.title, visits: h.visits, bookmark: false))
        }
        index = built
        indexRevision = revision
        return built
    }

    /// Local-only suggestions. Deliberately no search-engine autocomplete: that
    /// would send every keystroke to a third party before you press Return.
    func suggestions(for input: String, limit: Int = 6) -> [Suggestion] {
        let text = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard text.count >= 2 else { return [] }
        let query = Self.bytes(text)
        var scored: [(Double, Suggestion)] = []
        for e in searchIndex() {
            var s: Double
            if Self.hasPrefix(e.host, query) { s = 100 }
            else if Self.contains(e.host, query) { s = 60 }
            else if Self.contains(e.title, query) { s = 40 }
            else if Self.contains(e.full, query) { s = 25 }
            else { continue }
            s += min(30, Double(e.visits) * 3) + (e.suggestion.isBookmark ? 20 : 0) - Double(e.pathLength) * 0.2
            scored.append((s, e.suggestion))
        }
        return scored.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
    }

    // MARK: Session

    /// Called on every page load. Encoding and writing happen on the writer's
    /// queue, never on the main thread.
    func saveSession(_ session: SavedSession) {
        guard let directory else { return }
        writer.write(session, to: directory.appendingPathComponent("session.json"))
    }

    func loadSession() -> SavedSession? {
        directory.flatMap { Self.load(SavedSession.self, from: $0.appendingPathComponent("session.json")) }
    }

    // MARK: Disk

    /// Debounced: a burst of visits (redirect chains, fast browsing) is one
    /// write. The encode of up to 5,000 entries runs off the main thread.
    private func scheduleSave() {
        guard let directory else { return }
        saveTask?.cancel()
        saveTask = Task { [history, bookmarks, writer] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            writer.write(history, to: directory.appendingPathComponent("history.json"))
            writer.write(bookmarks, to: directory.appendingPathComponent("bookmarks.json"))
        }
    }

    /// At quit: writes the latest state and waits for every queued write, so
    /// nothing in flight is lost and nothing older lands after it.
    func flush() {
        guard let directory else { return }
        saveTask?.cancel()
        writer.write(history, to: directory.appendingPathComponent("history.json"))
        writer.write(bookmarks, to: directory.appendingPathComponent("bookmarks.json"))
        writer.drain()
    }

    private static func load<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}

/// One serial queue for every library file. Serial means writes land in the
/// order they were issued, so a slow old write can never overwrite a newer one.
final class LibraryWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.icyweasel.library-writer", qos: .utility)

    func write<T: Encodable>(_ value: T, to url: URL) {
        queue.async {
            guard let data = try? JSONEncoder().encode(value) else { return }
            try? data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        }
    }

    /// Blocks until every write issued so far has finished.
    func drain() { queue.sync {} }
}
