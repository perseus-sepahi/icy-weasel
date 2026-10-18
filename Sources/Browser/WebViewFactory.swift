import Foundation
import WebKit

/// Builds `WKWebView`s with the hardened configuration.
///
/// Isolation between normal and private browsing comes entirely from the
/// `WKWebsiteDataStore`. (`WKProcessPool` was the old mechanism, but since
/// macOS 12 WebKit ignores separate pool instances, so it isolates nothing.)
@MainActor
enum WebViewFactory {

    /// A browsing profile: one cookie jar, cache and storage partition.
    @MainActor
    final class Profile {
        let isPrivate: Bool
        let dataStore: WKWebsiteDataStore

        private init(isPrivate: Bool, dataStore: WKWebsiteDataStore) {
            self.isPrivate = isPrivate
            self.dataStore = dataStore
        }

        static let standard = Profile(isPrivate: false, dataStore: .default())

        /// `.nonPersistent()` returns a *new* store per call. Each private window
        /// owns exactly one, so its tabs share a session with each other (links
        /// opened in a new tab stay logged in) but not with any other window,
        /// and everything is gone when the window closes.
        static func makePrivate() -> Profile {
            Profile(isPrivate: true, dataStore: .nonPersistent())
        }
    }

    static func makeConfiguration(
        profile: Profile,
        policy: ResolvedSitePolicy,
        ruleLists: [WKContentRuleList],
        messageHandler: WKScriptMessageHandler?,
        topLevelURL: URL? = nil
    ) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = profile.dataStore

        // Apple's Safe Browsing equivalent. Costs nothing and catches the
        // phishing pages no filter list will ever enumerate.
        config.preferences.isFraudulentWebsiteWarningEnabled = true
        // Popups only from a genuine user gesture.
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        // Off by default in WKWebView: without it `requestFullscreen()` is
        // rejected, so video players' fullscreen buttons do nothing.
        config.preferences.isElementFullscreenEnabled = true
        apply(policy, to: config.defaultWebpagePreferences)
        // WebKit's own HSTS-preload-backed upgrade, independent of our rules.
        config.upgradeKnownHostsToHTTPS = policy.httpsOnly
        // Background tabs detached from the window are CPU-throttled natively.
        // Throttle rather than suspend: suspension would silently stop chat
        // apps and timers that users expect to keep running.
        config.preferences.inactiveSchedulingPolicy = .throttle
        config.suppressesIncrementalRendering = false
        config.allowsAirPlayForMediaPlayback = false

        let controller = WKUserContentController()
        installUserScripts(into: controller, policy: policy, topLevelURL: topLevelURL)
        if let messageHandler {
            // The controller retains its handlers strongly, and the tab owns the
            // web view that owns this controller. A direct add would be a cycle
            // that leaks every closed tab's entire content process.
            for name in [ScriptInjector.blockedMessageHandler, ScriptInjector.passwordMessageHandler] {
                controller.add(WeakScriptMessageHandler(messageHandler), contentWorld: ScriptInjector.isolatedWorld, name: name)
            }
        }
        for list in ruleLists { controller.add(list) }
        config.userContentController = controller

        return config
    }

    /// (Re)installs the user scripts for a top-level site and policy.
    ///
    /// Called on every main-frame navigation that changes either. That is what
    /// makes the per-site fingerprinting toggle take effect, and what gives each
    /// top-level site its own noise partition. Scripts added here apply to the
    /// next document created in any frame of the web view.
    static func installUserScripts(
        into controller: WKUserContentController,
        policy: ResolvedSitePolicy,
        topLevelURL: URL?
    ) {
        controller.removeAllUserScripts()
        if policy.resistFingerprinting, let script = ScriptInjector.fingerprintDefense(topLevelURL: topLevelURL) {
            controller.addUserScript(script)
        }
        if policy.blockAds, let youtube = ScriptInjector.youTubeAdBlock() {
            controller.addUserScript(youtube)
        }
        if let counter = ScriptInjector.blockCounter() {
            controller.addUserScript(counter)
        }
        if let passwords = ScriptInjector.passwordManager() {
            controller.addUserScript(passwords)
        }
    }

    /// Engine-level protections. These live below JavaScript, so unlike the
    /// fingerprinting shim a page cannot detect or undo them.
    ///
    /// Only main-frame navigations honour these; subframes inherit from their
    /// top frame, which is exactly the scoping a per-site setting wants.
    static func apply(_ policy: ResolvedSitePolicy, to preferences: WKWebpagePreferences) {
        preferences.allowsContentJavaScript = policy.javaScript

        if #available(macOS 26.4, *) {
            switch policy.javaScriptHardening {
            case .standard: preferences.securityRestrictionMode = .none
            case .hardened: preferences.securityRestrictionMode = .maximizeCompatibility
            case .lockdown: preferences.securityRestrictionMode = .lockdown
            }
        } else {
            // Older systems have no JIT-only switch; Lockdown is the closest.
            preferences.isLockdownModeEnabled = policy.javaScriptHardening == .lockdown
        }

        if #available(macOS 15.2, *) {
            // Try HTTPS, and if the site cannot do it, fail instead of silently
            // downgrading. The failure surfaces as our interstitial.
            preferences.preferredHTTPSNavigationPolicy = policy.httpsOnly ? .errorOnFailure : .keepAsRequested
        }

        if #available(macOS 27.0, *) {
            preferences.globalPrivacyControlEnabled = policy.globalPrivacyControl
        }
    }

    static func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.allowsMagnification = true
        // A stable, extremely common UA. A bespoke one would be a fingerprint in
        // itself, which is exactly what the rest of this app is trying to avoid.
        webView.customUserAgent = standardUserAgent
        #if DEBUG
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        #endif
        return webView
    }

    /// Matches current Safari on Apple Silicon. Presenting as Chrome would be a
    /// lie WebKit cannot back up — sites would feed us Blink-only code paths.
    static let standardUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.0 Safari/605.1.15"
}

/// Breaks the retain cycle between `WKUserContentController` and its handler.
final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    private weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
