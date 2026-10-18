import Foundation
import Observation

/// Per-site deviations from the global posture. Every field is optional: `nil`
/// means "inherit the global setting", so a site pinned years ago still follows
/// later changes to defaults it never overrode.
struct SiteOverride: Codable, Equatable, Sendable {
    var blockAds: Bool?
    var httpsOnly: Bool?
    var javaScript: Bool?
    var resistFingerprinting: Bool?
    var blockThirdPartyCookies: Bool?
    var javaScriptHardening: JavaScriptHardening?
    var allowPopups: Bool?

    var isEmpty: Bool {
        allowPopups == nil &&
        blockAds == nil && httpsOnly == nil && javaScript == nil
            && resistFingerprinting == nil && blockThirdPartyCookies == nil
            && javaScriptHardening == nil
    }

    /// Clears fields that merely restate the global setting. `nil` means
    /// "inherit", and an explicit copy of today's default would stop the site
    /// following tomorrow's change to that default.
    func normalized(against settings: BrowserSettings) -> SiteOverride {
        var o = self
        if o.blockAds == settings.blockAds { o.blockAds = nil }
        if o.httpsOnly == settings.httpsOnly { o.httpsOnly = nil }
        if o.javaScript == settings.javaScriptEnabled { o.javaScript = nil }
        if o.resistFingerprinting == settings.resistFingerprinting { o.resistFingerprinting = nil }
        if o.blockThirdPartyCookies == settings.blockThirdPartyCookies { o.blockThirdPartyCookies = nil }
        if o.javaScriptHardening == settings.javaScriptHardening { o.javaScriptHardening = nil }
        if o.allowPopups == false { o.allowPopups = nil }
        return o
    }
}

struct ResolvedSitePolicy: Equatable, Sendable {
    var blockAds: Bool
    var httpsOnly: Bool
    var javaScript: Bool
    var resistFingerprinting: Bool
    var blockThirdPartyCookies: Bool
    var javaScriptHardening: JavaScriptHardening = .hardened
    var globalPrivacyControl: Bool = true
    var allowPopups: Bool = false
    /// True when any field came from an override rather than the global default.
    var isCustomised: Bool

    static let permissive = ResolvedSitePolicy(
        blockAds: false, httpsOnly: false, javaScript: true,
        resistFingerprinting: false, blockThirdPartyCookies: false,
        javaScriptHardening: .standard, globalPrivacyControl: false,
        isCustomised: true
    )
}

/// Stores overrides keyed by registrable domain, so a setting made on
/// `news.example.co.uk` applies to `example.co.uk` as a whole. Scoping to the
/// full host instead would make the escape hatch useless on any site that
/// spreads itself across subdomains.
@Observable
final class SitePolicyStore {
    private let defaults: UserDefaults
    private let storageKey = "siteOverrides"
    private var overrides: [String: SiteOverride]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([String: SiteOverride].self, from: data) {
            overrides = decoded
        } else {
            overrides = [:]
        }
    }

    var customisedSites: [String] { overrides.keys.sorted() }

    func override(for url: URL?) -> SiteOverride? {
        guard let key = PublicSuffix.registrableDomain(of: url) else { return nil }
        return overrides[key]
    }

    func resolve(url: URL?, settings: BrowserSettings) -> ResolvedSitePolicy {
        let o = override(for: url)
        return ResolvedSitePolicy(
            blockAds: o?.blockAds ?? settings.blockAds,
            httpsOnly: o?.httpsOnly ?? settings.httpsOnly,
            javaScript: o?.javaScript ?? settings.javaScriptEnabled,
            resistFingerprinting: o?.resistFingerprinting ?? settings.resistFingerprinting,
            blockThirdPartyCookies: o?.blockThirdPartyCookies ?? settings.blockThirdPartyCookies,
            javaScriptHardening: o?.javaScriptHardening ?? settings.javaScriptHardening,
            globalPrivacyControl: settings.globalPrivacyControl,
            allowPopups: o?.allowPopups ?? false,
            isCustomised: !(o?.isEmpty ?? true)
        )
    }

    func update(url: URL?, settings: BrowserSettings? = nil, _ mutate: (inout SiteOverride) -> Void) {
        guard let key = PublicSuffix.registrableDomain(of: url) else { return }
        var current = overrides[key] ?? SiteOverride()
        mutate(&current)
        if let settings { current = current.normalized(against: settings) }
        if current.isEmpty { overrides.removeValue(forKey: key) }
        else { overrides[key] = current }
        persist()
    }

    func clear(url: URL?) {
        guard let key = PublicSuffix.registrableDomain(of: url) else { return }
        overrides.removeValue(forKey: key)
        persist()
    }

    func clearAll() {
        overrides.removeAll()
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(overrides) else { return }
        defaults.set(data, forKey: storageKey)
    }
}

/// Derives the registrable domain ("eTLD+1") from a URL.
///
/// A full Public Suffix List is ~10k entries and changes monthly. This carries
/// the multi-label suffixes that actually show up in browsing and falls back to
/// the last two labels. The failure mode is conservative: an unknown multi-label
/// suffix groups a site slightly too broadly for *user preferences*, which is a
/// UI annoyance, not a security boundary. Nothing security-critical keys off it.
enum PublicSuffix {
    private static let multiLabelSuffixes: Set<String> = [
        "co.uk", "org.uk", "me.uk", "ltd.uk", "plc.uk", "net.uk", "sch.uk", "ac.uk", "gov.uk",
        "com.au", "net.au", "org.au", "edu.au", "gov.au", "id.au",
        "co.nz", "net.nz", "org.nz", "govt.nz", "ac.nz",
        "co.za", "org.za", "net.za", "web.za",
        "com.br", "net.br", "org.br", "gov.br", "edu.br",
        "com.mx", "org.mx", "gob.mx",
        "co.jp", "or.jp", "ne.jp", "ac.jp", "go.jp", "lg.jp",
        "co.kr", "or.kr", "ne.kr", "go.kr", "re.kr",
        "com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "ac.cn",
        "com.hk", "org.hk", "net.hk", "edu.hk", "gov.hk",
        "com.tw", "org.tw", "net.tw", "gov.tw", "edu.tw",
        "com.sg", "net.sg", "org.sg", "edu.sg", "gov.sg",
        "com.tr", "org.tr", "net.tr", "gov.tr", "edu.tr",
        "co.in", "net.in", "org.in", "gen.in", "firm.in", "ind.in", "gov.in", "ac.in",
        "com.ar", "net.ar", "org.ar", "gob.ar",
        "com.co", "net.co", "org.co", "gov.co",
        "co.il", "org.il", "net.il", "ac.il", "gov.il",
        "com.ua", "net.ua", "org.ua", "gov.ua",
        "com.ru", "net.ru", "org.ru",
        "com.pl", "net.pl", "org.pl", "gov.pl",
        "com.es", "org.es", "nom.es", "gob.es",
        "com.pt", "org.pt", "gov.pt",
        "com.gr", "net.gr", "org.gr", "gov.gr", "edu.gr",
        "com.my", "net.my", "org.my", "gov.my", "edu.my",
        "com.ph", "net.ph", "org.ph", "gov.ph",
        "com.vn", "net.vn", "org.vn", "gov.vn",
        "com.sa", "net.sa", "org.sa", "gov.sa",
        "com.eg", "net.eg", "org.eg", "gov.eg",
        "com.ng", "net.ng", "org.ng", "gov.ng",
        "co.ke", "or.ke", "ac.ke", "go.ke",
        "github.io", "gitlab.io", "pages.dev", "workers.dev", "netlify.app",
        "vercel.app", "herokuapp.com", "azurewebsites.net", "cloudfront.net",
        "s3.amazonaws.com", "web.app", "firebaseapp.com", "glitch.me",
        "blogspot.com", "wordpress.com", "tumblr.com", "myshopify.com",
        "sharepoint.com", "onmicrosoft.com", "r2.dev", "fly.dev", "onrender.com"
    ]

    static func registrableDomain(of url: URL?) -> String? {
        guard let host = url?.host?.lowercased(), !host.isEmpty else { return nil }
        return registrableDomain(ofHost: host)
    }

    static func registrableDomain(ofHost host: String) -> String? {
        guard !host.isEmpty else { return nil }
        // An IP literal is its own registrable unit.
        if host.allSatisfy({ $0.isNumber || $0 == "." }) || host.contains(":") { return host }

        let labels = host.split(separator: ".").map(String.init)
        guard labels.count >= 2 else { return host }

        if labels.count >= 3 {
            let lastTwo = labels.suffix(2).joined(separator: ".")
            if multiLabelSuffixes.contains(lastTwo) {
                return labels.suffix(3).joined(separator: ".")
            }
        }
        return labels.suffix(2).joined(separator: ".")
    }

    /// Third-party determination for URL sanitising and UI labelling.
    static func isThirdParty(_ url: URL?, relativeTo pageURL: URL?) -> Bool {
        guard let a = registrableDomain(of: url), let b = registrableDomain(of: pageURL) else {
            return false
        }
        return a != b
    }
}
