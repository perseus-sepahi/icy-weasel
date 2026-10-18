import Foundation
import os

struct FilterListSource: Identifiable, Hashable, Codable, Sendable {
    var id: String
    var title: String
    var detail: String
    var url: URL
    /// Enabled out of the box. Annoyance and social lists are opt-in because
    /// they break more sites than they fix.
    var defaultEnabled: Bool
}

enum FilterListCatalog {
    static let all: [FilterListSource] = [
        .init(id: "easylist", title: "EasyList",
              detail: "The baseline advertising filter list.",
              url: URL(string: "https://easylist.to/easylist/easylist.txt")!,
              defaultEnabled: true),
        .init(id: "easyprivacy", title: "EasyPrivacy",
              detail: "Tracking pixels, analytics and beacons.",
              url: URL(string: "https://easylist.to/easylist/easyprivacy.txt")!,
              defaultEnabled: true),
        .init(id: "ubo-filters", title: "uBlock Origin — Core",
              detail: "uBO's own additions on top of EasyList.",
              url: URL(string: "https://ublockorigin.github.io/uAssets/filters/filters.txt")!,
              defaultEnabled: true),
        .init(id: "ubo-privacy", title: "uBlock Origin — Privacy",
              detail: "Extra tracker coverage.",
              url: URL(string: "https://ublockorigin.github.io/uAssets/filters/privacy.txt")!,
              defaultEnabled: true),
        .init(id: "ubo-badware", title: "uBlock Origin — Badware",
              detail: "Sites known to distribute malware or unwanted software.",
              url: URL(string: "https://ublockorigin.github.io/uAssets/filters/badware.txt")!,
              defaultEnabled: true),
        .init(id: "peter-lowe", title: "Peter Lowe's List",
              detail: "Long-standing ad and tracking server blocklist.",
              url: URL(string: "https://pgl.yoyo.org/adservers/serverlist.php?hostformat=adblockplus&showintro=0&mimetype=plaintext")!,
              defaultEnabled: true),
        .init(id: "adguard-tracking", title: "AdGuard Tracking Protection",
              detail: "AdGuard's tracker list, Safari-targeted build.",
              url: URL(string: "https://filters.adtidy.org/extension/safari/filters/3.txt")!,
              defaultEnabled: true),
        .init(id: "fanboy-annoyance", title: "Fanboy's Annoyances",
              detail: "Cookie banners, newsletter popups, chat widgets. Breaks some sites.",
              url: URL(string: "https://secure.fanboy.co.nz/fanboy-annoyance.txt")!,
              defaultEnabled: false),
        .init(id: "adguard-social", title: "AdGuard Social Media",
              detail: "Share buttons and embedded social widgets.",
              url: URL(string: "https://filters.adtidy.org/extension/safari/filters/4.txt")!,
              defaultEnabled: false)
    ]

    static func source(id: String) -> FilterListSource? { all.first { $0.id == id } }
}

/// Fetches and caches filter lists on disk.
///
/// Every fetch is a plain unconditional GET over HTTPS with no cookies, no
/// credentials and an ephemeral session — a browser that promises privacy must
/// not leak a stable identity while downloading its own privacy lists.
actor FilterListFetcher {
    private let log = Logger(subsystem: "com.icyweasel.browser", category: "filters")
    private let cacheDirectory: URL
    private let session: URLSession

    init() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("IcyWeasel/FilterLists", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        cacheDirectory = base

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.urlCache = nil
        config.httpAdditionalHeaders = ["User-Agent": "IcyWeasel/0.1 (+filter-updater)"]
        config.timeoutIntervalForRequest = 30
        session = URLSession(configuration: config)
    }

    private func cacheURL(for source: FilterListSource) -> URL {
        cacheDirectory.appendingPathComponent("\(source.id).txt")
    }

    func cachedText(for source: FilterListSource) -> String? {
        try? String(contentsOf: cacheURL(for: source), encoding: .utf8)
    }

    func cacheAge(for source: FilterListSource) -> TimeInterval? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: cacheURL(for: source).path),
              let modified = attrs[.modificationDate] as? Date
        else { return nil }
        return Date().timeIntervalSince(modified)
    }

    /// Returns cached text immediately if it is younger than `maxAge`, otherwise
    /// downloads. On a network failure the stale cache is used — blocking with
    /// week-old rules beats not blocking at all.
    func text(for source: FilterListSource, maxAge: TimeInterval = 86_400 * 3) async -> String? {
        if let age = cacheAge(for: source), age < maxAge, let cached = cachedText(for: source) {
            return cached
        }
        do {
            var request = URLRequest(url: source.url)
            request.httpShouldHandleCookies = false
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            guard let text = String(data: data, encoding: .utf8), text.count > 200 else {
                throw URLError(.cannotDecodeContentData)
            }
            try? text.write(to: cacheURL(for: source), atomically: true, encoding: .utf8)
            log.notice("Updated \(source.id, privacy: .public) (\(data.count) bytes)")
            return text
        } catch {
            log.error("Fetch failed for \(source.id, privacy: .public): \(error.localizedDescription)")
            return cachedText(for: source)
        }
    }
}
