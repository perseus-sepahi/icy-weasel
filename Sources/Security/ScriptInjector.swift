import Foundation
import WebKit
import CryptoKit

/// Builds the user scripts installed into every web view.
///
/// Canvas and audio noise is keyed by a *partition seed*: a hash of a secret
/// regenerated every launch and the tab's top-level registrable domain. So:
/// - every frame on one page agrees (no cross-frame inconsistency to detect),
/// - a tracker embedded on two sites sees two unrelated values (unlinkable),
/// - nothing a tracker stored last launch matches this launch.
enum ScriptInjector {

    /// Regenerated per process launch. Never persisted, never sent to a page.
    static let sessionSecret: [UInt8] = {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        precondition(status == errSecSuccess, "system RNG unavailable")
        return bytes
    }()

    /// Partition seed for a top-level URL. Keyed by registrable domain, not
    /// origin, so `news.example.com` and `www.example.com` — one site — agree.
    static func partitionSeed(forTopLevel url: URL?) -> UInt32 {
        let site = PublicSuffix.registrableDomain(of: url) ?? ""
        var hasher = SHA256()
        hasher.update(data: sessionSecret)
        hasher.update(data: Data("|\(site)".utf8))
        return hasher.finalize().prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    static let blockedMessageHandler = "icyWeaselBlocked"

    /// Our own scripts run here, not in the page world. A page can enumerate
    /// `window.webkit.messageHandlers`; a handler named after this browser would
    /// identify every one of its users with a single property check.
    static let isolatedWorld = WKContentWorld.world(name: "IcyWeasel")

    /// Read once; scripts are rebuilt on every cross-site navigation.
    private static let sources: [String: String] = {
        var loaded: [String: String] = [:]
        for name in ["fingerprint-defense", "block-counter", "youtube-adblock"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "js"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                loaded[name] = text
            }
        }
        return loaded
    }()

    static func fingerprintDefense(topLevelURL: URL?) -> WKUserScript? {
        guard let body = sources["fingerprint-defense"] else { return nil }
        let seed = partitionSeed(forTopLevel: topLevelURL)
        let seeded = body.replacingOccurrences(of: "__IW_SEED__", with: String(seed))
        return WKUserScript(
            source: seeded,
            injectionTime: .atDocumentStart,
            // `forMainFrameOnly: false` matters: an iframe is the classic place
            // to run a fingerprinting script the top frame never touches.
            forMainFrameOnly: false
        )
    }

    /// Strategy switch, set from the live A/B in YouTubeAdTests. Both strategies
    /// reach the video in ~4–13 s (stock: 15–17 s of ads) because YouTube holds
    /// playback back server-side. Pruning wins on privacy: the ad and its
    /// tracking beacons are never requested at all.
    static let youTubePrunesSchedule = true

    /// Page world, every frame (embedded players show ads too). The script
    /// returns immediately on any host that is not YouTube.
    static func youTubeAdBlock(pruneSchedule: Bool = youTubePrunesSchedule) -> WKUserScript? {
        guard let body = sources["youtube-adblock"] else { return nil }
        let source = body.replacingOccurrences(of: "__IW_YT_PRUNE__", with: pruneSchedule ? "true" : "false")
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: false)
    }

    static func blockCounter() -> WKUserScript? {
        guard let body = sources["block-counter"] else { return nil }
        // Isolated world: DOM events and computed style are shared across
        // worlds, so counting still works, but nothing is visible to the page.
        return WKUserScript(
            source: body, injectionTime: .atDocumentStart,
            forMainFrameOnly: true, in: isolatedWorld
        )
    }
}
