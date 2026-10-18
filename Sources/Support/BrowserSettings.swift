import Foundation
import AppKit
import Observation

/// Persisted user preferences.
///
/// Defaults implement the "aggressive, with a per-site escape hatch" posture:
/// everything defensive is on, and `SitePolicyStore` holds the exceptions.
@Observable
final class BrowserSettings {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            Keys.blockAds: true,
            Keys.httpsOnly: true,
            Keys.blockThirdPartyCookies: true,
            Keys.resistFingerprinting: true,
            Keys.stripTrackingParameters: true,
            Keys.blockRemoteFonts: false,
            Keys.javaScriptEnabled: true,
            Keys.ephemeralByDefault: false,
            Keys.hibernateTabs: true,
            Keys.hibernateAfterMinutes: 10,
            Keys.searchEngine: SearchEngine.duckDuckGo.rawValue,
            Keys.javaScriptHardening: JavaScriptHardening.hardened.rawValue,
            Keys.globalPrivacyControl: true,
            Keys.restoreSession: true,
            Keys.enabledFilterLists: FilterListCatalog.all.filter(\.defaultEnabled).map(\.id)
        ])
    }

    private enum Keys {
        static let blockAds = "blockAds"
        static let httpsOnly = "httpsOnly"
        static let blockThirdPartyCookies = "blockThirdPartyCookies"
        static let resistFingerprinting = "resistFingerprinting"
        static let stripTrackingParameters = "stripTrackingParameters"
        static let blockRemoteFonts = "blockRemoteFonts"
        static let javaScriptEnabled = "javaScriptEnabled"
        static let ephemeralByDefault = "ephemeralByDefault"
        static let hibernateTabs = "hibernateTabs"
        static let hibernateAfterMinutes = "hibernateAfterMinutes"
        static let searchEngine = "searchEngine"
        static let enabledFilterLists = "enabledFilterLists"
        static let customFilters = "customFilters"
        static let lastFilterUpdate = "lastFilterUpdate"
        static let homepage = "homepage"
        static let javaScriptHardening = "javaScriptHardening"
        static let globalPrivacyControl = "globalPrivacyControl"
        static let restoreSession = "restoreSession"
        static let customSearchTemplate = "customSearchTemplate"
        static let assistantModel = "assistantModel"
        static let customLocalAIEndpoints = "customLocalAIEndpoints"
        static let cloudAIProviders = "cloudAIProviders"
        static let cloudAIConsent = "cloudAIConsent"
        static let trustedLocalAI = "trustedLocalAI"
        static let appearance = "appearance"
    }

    /// "system", "light" or "dark".
    var appearance: String {
        get { access(keyPath: \.appearance); return defaults.string(forKey: Keys.appearance) ?? "system" }
        set { withMutation(keyPath: \.appearance) { defaults.set(newValue, forKey: Keys.appearance) } }
    }

    @MainActor
    func applyAppearance() {
        switch appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":  NSApp.appearance = NSAppearance(named: .darkAqua)
        default:      NSApp.appearance = nil
        }
    }

    var restoreSession: Bool {
        get { access(keyPath: \.restoreSession); return defaults.bool(forKey: Keys.restoreSession) }
        set { withMutation(keyPath: \.restoreSession) { defaults.set(newValue, forKey: Keys.restoreSession) } }
    }
    var customSearchTemplate: String {
        get { access(keyPath: \.customSearchTemplate); return defaults.string(forKey: Keys.customSearchTemplate) ?? "" }
        set { withMutation(keyPath: \.customSearchTemplate) { defaults.set(newValue, forKey: Keys.customSearchTemplate) } }
    }
    /// The chosen model as "sourceID|model", e.g. "local:11434|qwen3:8b".
    var assistantModel: String {
        get { access(keyPath: \.assistantModel); return defaults.string(forKey: Keys.assistantModel) ?? "" }
        set { withMutation(keyPath: \.assistantModel) { defaults.set(newValue, forKey: Keys.assistantModel) } }
    }
    /// Extra model servers on this Mac (loopback only), for tools on other ports.
    var customLocalAIEndpoints: [String] {
        get { access(keyPath: \.customLocalAIEndpoints); return defaults.stringArray(forKey: Keys.customLocalAIEndpoints) ?? [] }
        set { withMutation(keyPath: \.customLocalAIEndpoints) { defaults.set(newValue, forKey: Keys.customLocalAIEndpoints) } }
    }
    /// Cloud providers the user added. Their API keys are in the keychain.
    var cloudAIProviders: [CloudProviderConfig] {
        get {
            access(keyPath: \.cloudAIProviders)
            guard let data = defaults.data(forKey: Keys.cloudAIProviders) else { return [] }
            return (try? JSONDecoder().decode([CloudProviderConfig].self, from: data)) ?? []
        }
        set { withMutation(keyPath: \.cloudAIProviders) { defaults.set(try? JSONEncoder().encode(newValue), forKey: Keys.cloudAIProviders) } }
    }
    /// Unrecognised local servers the user picked, and so trusts with page text.
    var trustedLocalAI: [String] {
        get { access(keyPath: \.trustedLocalAI); return defaults.stringArray(forKey: Keys.trustedLocalAI) ?? [] }
        set { withMutation(keyPath: \.trustedLocalAI) { defaults.set(newValue, forKey: Keys.trustedLocalAI) } }
    }
    /// Cloud providers the user agreed to send page text to.
    var cloudAIConsent: [String] {
        get { access(keyPath: \.cloudAIConsent); return defaults.stringArray(forKey: Keys.cloudAIConsent) ?? [] }
        set { withMutation(keyPath: \.cloudAIConsent) { defaults.set(newValue, forKey: Keys.cloudAIConsent) } }
    }

    var javaScriptHardening: JavaScriptHardening {
        get {
            access(keyPath: \.javaScriptHardening)
            return JavaScriptHardening(rawValue: defaults.string(forKey: Keys.javaScriptHardening) ?? "") ?? .hardened
        }
        set { withMutation(keyPath: \.javaScriptHardening) { defaults.set(newValue.rawValue, forKey: Keys.javaScriptHardening) } }
    }
    var globalPrivacyControl: Bool {
        get { access(keyPath: \.globalPrivacyControl); return defaults.bool(forKey: Keys.globalPrivacyControl) }
        set { withMutation(keyPath: \.globalPrivacyControl) { defaults.set(newValue, forKey: Keys.globalPrivacyControl) } }
    }

    var blockAds: Bool {
        get { access(keyPath: \.blockAds); return defaults.bool(forKey: Keys.blockAds) }
        set { withMutation(keyPath: \.blockAds) { defaults.set(newValue, forKey: Keys.blockAds) } }
    }
    var httpsOnly: Bool {
        get { access(keyPath: \.httpsOnly); return defaults.bool(forKey: Keys.httpsOnly) }
        set { withMutation(keyPath: \.httpsOnly) { defaults.set(newValue, forKey: Keys.httpsOnly) } }
    }
    var blockThirdPartyCookies: Bool {
        get { access(keyPath: \.blockThirdPartyCookies); return defaults.bool(forKey: Keys.blockThirdPartyCookies) }
        set { withMutation(keyPath: \.blockThirdPartyCookies) { defaults.set(newValue, forKey: Keys.blockThirdPartyCookies) } }
    }
    var resistFingerprinting: Bool {
        get { access(keyPath: \.resistFingerprinting); return defaults.bool(forKey: Keys.resistFingerprinting) }
        set { withMutation(keyPath: \.resistFingerprinting) { defaults.set(newValue, forKey: Keys.resistFingerprinting) } }
    }
    var stripTrackingParameters: Bool {
        get { access(keyPath: \.stripTrackingParameters); return defaults.bool(forKey: Keys.stripTrackingParameters) }
        set { withMutation(keyPath: \.stripTrackingParameters) { defaults.set(newValue, forKey: Keys.stripTrackingParameters) } }
    }
    var blockRemoteFonts: Bool {
        get { access(keyPath: \.blockRemoteFonts); return defaults.bool(forKey: Keys.blockRemoteFonts) }
        set { withMutation(keyPath: \.blockRemoteFonts) { defaults.set(newValue, forKey: Keys.blockRemoteFonts) } }
    }
    var javaScriptEnabled: Bool {
        get { access(keyPath: \.javaScriptEnabled); return defaults.bool(forKey: Keys.javaScriptEnabled) }
        set { withMutation(keyPath: \.javaScriptEnabled) { defaults.set(newValue, forKey: Keys.javaScriptEnabled) } }
    }
    var ephemeralByDefault: Bool {
        get { access(keyPath: \.ephemeralByDefault); return defaults.bool(forKey: Keys.ephemeralByDefault) }
        set { withMutation(keyPath: \.ephemeralByDefault) { defaults.set(newValue, forKey: Keys.ephemeralByDefault) } }
    }
    var hibernateTabs: Bool {
        get { access(keyPath: \.hibernateTabs); return defaults.bool(forKey: Keys.hibernateTabs) }
        set { withMutation(keyPath: \.hibernateTabs) { defaults.set(newValue, forKey: Keys.hibernateTabs) } }
    }
    var hibernateAfterMinutes: Int {
        get { access(keyPath: \.hibernateAfterMinutes); return defaults.integer(forKey: Keys.hibernateAfterMinutes) }
        set { withMutation(keyPath: \.hibernateAfterMinutes) { defaults.set(newValue, forKey: Keys.hibernateAfterMinutes) } }
    }
    var customFilters: String {
        get { access(keyPath: \.customFilters); return defaults.string(forKey: Keys.customFilters) ?? "" }
        set { withMutation(keyPath: \.customFilters) { defaults.set(newValue, forKey: Keys.customFilters) } }
    }
    var homepage: String {
        get { access(keyPath: \.homepage); return defaults.string(forKey: Keys.homepage) ?? "" }
        set { withMutation(keyPath: \.homepage) { defaults.set(newValue, forKey: Keys.homepage) } }
    }
    var lastFilterUpdate: Date? {
        get { access(keyPath: \.lastFilterUpdate); return defaults.object(forKey: Keys.lastFilterUpdate) as? Date }
        set { withMutation(keyPath: \.lastFilterUpdate) { defaults.set(newValue, forKey: Keys.lastFilterUpdate) } }
    }
    var searchEngine: SearchEngine {
        get {
            access(keyPath: \.searchEngine)
            return SearchEngine(rawValue: defaults.string(forKey: Keys.searchEngine) ?? "") ?? .duckDuckGo
        }
        set { withMutation(keyPath: \.searchEngine) { defaults.set(newValue.rawValue, forKey: Keys.searchEngine) } }
    }
    var enabledFilterLists: Set<String> {
        get {
            access(keyPath: \.enabledFilterLists)
            return Set(defaults.stringArray(forKey: Keys.enabledFilterLists) ?? [])
        }
        set {
            withMutation(keyPath: \.enabledFilterLists) {
                defaults.set(Array(newValue).sorted(), forKey: Keys.enabledFilterLists)
            }
        }
    }
}

enum SearchEngine: String, CaseIterable, Identifiable, Sendable {
    case duckDuckGo, startpage, brave, mojeek, kagi, ecosia, qwant, perplexity, bing, yahoo, google, custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .duckDuckGo: return "DuckDuckGo"
        case .startpage:  return "Startpage"
        case .brave:      return "Brave Search"
        case .mojeek:     return "Mojeek"
        case .kagi:       return "Kagi (paid, account needed)"
        case .ecosia:     return "Ecosia"
        case .qwant:      return "Qwant"
        case .perplexity: return "Perplexity"
        case .bing:       return "Bing"
        case .yahoo:      return "Yahoo"
        case .google:     return "Google"
        case .custom:     return "Custom…"
        }
    }

    /// Engines whose business is not profiling searches. The rest are offered
    /// because sometimes you need them, and labelled so the choice is informed.
    var isPrivate: Bool {
        switch self {
        case .duckDuckGo, .startpage, .brave, .mojeek, .kagi, .qwant: return true
        case .ecosia, .perplexity, .bing, .yahoo, .google, .custom: return false
        }
    }

    private var template: String {
        switch self {
        case .duckDuckGo: return "https://duckduckgo.com/?q=%s"
        case .startpage:  return "https://www.startpage.com/sp/search?query=%s"
        case .brave:      return "https://search.brave.com/search?q=%s"
        case .mojeek:     return "https://www.mojeek.com/search?q=%s"
        case .kagi:       return "https://kagi.com/search?q=%s"
        case .ecosia:     return "https://www.ecosia.org/search?q=%s"
        case .qwant:      return "https://www.qwant.com/?q=%s"
        case .perplexity: return "https://www.perplexity.ai/search?q=%s"
        case .bing:       return "https://www.bing.com/search?q=%s"
        case .yahoo:      return "https://search.yahoo.com/search?p=%s"
        case .google:     return "https://www.google.com/search?q=%s"
        case .custom:     return ""
        }
    }

    /// `customTemplate` uses `%s` for the query, the convention every browser
    /// uses for custom engines. Only https templates are accepted: a search
    /// query must not travel in plaintext. Invalid templates fall back to
    /// DuckDuckGo rather than failing the search.
    func searchURL(for query: String, customTemplate: String = "") -> URL? {
        let q = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? query
        var pattern = template
        if self == .custom {
            let t = customTemplate.trimmingCharacters(in: .whitespaces)
            pattern = t.lowercased().hasPrefix("https://") && t.contains("%s") ? t : SearchEngine.duckDuckGo.template
        }
        return URL(string: pattern.replacingOccurrences(of: "%s", with: q))
    }
}

/// How much of WebKit's JavaScript engine is exposed to web content.
///
/// JIT compilers turn attacker-supplied script into native machine code at run
/// time, which is why they are the largest single source of browser exploits.
/// `hardened` removes the JIT entirely while keeping every web feature working.
enum JavaScriptHardening: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Full JIT. Fastest JavaScript, largest attack surface.
    case standard
    /// Interpreter only, extended memory tagging, dedicated content processes.
    case hardened
    /// WebKit Lockdown: no JIT and risky features (e.g. WebAssembly, some web
    /// fonts and media formats) disabled. Breaks some sites.
    case lockdown

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .hardened: return "Hardened (no JIT)"
        case .lockdown: return "Lockdown"
        }
    }

    var detail: String {
        switch self {
        case .standard: return "Fastest JavaScript. Use for demanding web apps you trust."
        case .hardened: return "Removes the JIT compiler, the most exploited part of any browser. Sites keep working; heavy scripts run slower."
        case .lockdown: return "Apple's Lockdown restrictions. Maximum protection for high-risk browsing; some sites break."
        }
    }
}
