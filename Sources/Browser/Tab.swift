import Foundation
import WebKit
import AppKit
import Observation
import os

/// One browser tab.
///
/// A tab owns its `WKWebView` only while it is awake. Hibernating tears the web
/// view down — and with it an entire WebKit content process, typically 60–150 MB
/// — while keeping `interactionState`, which restores the full back/forward list
/// and scroll position on wake. Twenty idle tabs otherwise cost more memory than
/// the rest of the app combined.
@MainActor
@Observable
final class Tab: NSObject, Identifiable {

    enum SecurityIssue: Equatable {
        case insecureTransport(URL)
        case certificateInvalid(String)
        /// Not a security problem — offline, DNS failure — but still needs a page
        /// rather than a silently blank tab.
        case loadFailed(URL?, String)

        var summary: String {
            switch self {
            case .insecureTransport:         return "This site does not support HTTPS"
            case .certificateInvalid(let d): return "Certificate problem: \(d)"
            case .loadFailed:                return "This page couldn't be loaded"
            }
        }
    }

    let id = UUID()
    let isPrivate: Bool

    var title: String = "New Tab"
    var url: URL?
    var isLoading = false
    var estimatedProgress: Double = 0
    var canGoBack = false
    var canGoForward = false
    var blockedEstimate = 0
    var strippedParameters: [String] = []
    var securityIssue: SecurityIssue?
    /// Tab group membership; grouped tabs are kept contiguous in the strip.
    var groupID: UUID?
    /// Pop-ups refused on the current page, offered back to the user in the toolbar.
    var blockedPopups: [URL] = []
    /// Asleep: it had a page, and its content process was released to save
    /// memory. An empty New Tab without a web view isn't asleep, just unused.
    var isHibernated: Bool { webView == nil && (url != nil || interactionState != nil) }

    /// A password the user just signed in with, waiting for "Save" or "Not now".
    struct PasswordOffer: Equatable {
        let host: String
        let username: String
        let password: String
        let isUpdate: Bool
    }
    var passwordOffer: PasswordOffer?
    /// Saved sign-ins for the site whose password field is showing in this tab.
    private(set) var availableLogins: [SavedLogin] = []
    /// The frame (and its site) where a password field was found; filling only
    /// ever targets this frame, and only for logins saved for its exact host.
    private var passwordFrame: WKFrameInfo?
    private var passwordHost: String?
    var lastActive = Date()
    var favicon: NSImage?

    private(set) var webView: WKWebView?
    private var interactionState: Any?
    /// The clean URL we are reloading after stripping parameters, so the
    /// follow-up navigation keeps the "N parameters removed" indicator.
    private var sanitizedReloadTarget: URL?
    /// The plaintext URL the user asked for while an HTTPS upgrade of it is in
    /// flight, so a failure can be attributed to missing HTTPS specifically.
    private var pendingUpgrade: URL?
    /// Site + fingerprinting flag the installed user scripts were built for.
    private var installedScriptsKey: String?
    /// Which rule families are attached (ads, transport/cookies). Internal for tests.
    private(set) var installedListsKey: String?
    /// Where the main frame is going (or is). Sign-in prompts are only shown
    /// for this site, never for a third-party frame or resource on it.
    private var mainFrameTarget: URL?
    /// JavaScript dialogs on the current page, and whether the user asked to
    /// stop seeing them. Both reset when a new page commits.
    private var dialogCount = 0
    private var dialogsSuppressed = false
    /// The policy the attached rule lists were chosen for: the page being
    /// navigated to, which can differ from `url` until the load finishes.
    private var listsPolicy: ResolvedSitePolicy?
    private var pendingURL: URL?
    private var observations: [NSKeyValueObservation] = []
    private let log = Logger(subsystem: "com.icyweasel.browser", category: "tab")

    weak var owner: BrowserViewModel?

    init(url: URL? = nil, isPrivate: Bool = false, owner: BrowserViewModel?) {
        self.isPrivate = isPrivate
        self.owner = owner
        self.pendingURL = url
        self.url = url
        super.init()
    }

    var policy: ResolvedSitePolicy {
        owner?.policyStore.resolve(url: url, settings: owner!.settings) ?? .permissive
    }

    var displayTitle: String {
        if !title.isEmpty && title != "New Tab" { return title }
        if let host = url?.host { return host }
        return "New Tab"
    }

    // MARK: Lifecycle

    /// Creates the web view if needed and restores prior session state.
    @discardableResult
    func wake() -> WKWebView {
        lastActive = Date()
        if let webView { return webView }
        guard let owner else { fatalError("Tab without owner") }

        let configuration = WebViewFactory.makeConfiguration(
            profile: owner.profile,
            policy: policy,
            ruleLists: owner.blocking.lists(for: policy),
            messageHandler: self,
            topLevelURL: url ?? pendingURL
        )
        installedScriptsKey = Self.scriptsKey(url: url ?? pendingURL, policy: policy)
        installedListsKey = Self.listsKey(policy)
        listsPolicy = policy
        let webView = WebViewFactory.makeWebView(configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        self.webView = webView
        observe(webView)

        if let state = interactionState {
            webView.interactionState = state
        } else if let target = pendingURL {
            pendingURL = nil
            load(target)
        }
        return webView
    }

    /// Makes the tab current. Only a tab with a page gets a web view: the New
    /// Tab page is drawn by the app, so an empty tab costs no content process
    /// (15–30 MB each) until it navigates. WebKit keeps a spare process warm,
    /// so the first page loads just as fast.
    func activate() {
        lastActive = Date()
        if url != nil || pendingURL != nil || interactionState != nil { wake() }
    }

    /// Puts the tab to sleep unless the user would notice: it's loading,
    /// playing audio or video, or using the camera or microphone. A sleeping
    /// music tab would simply go silent.
    func hibernateIfQuiet() {
        guard let webView, !isLoading,
              webView.cameraCaptureState == .none, webView.microphoneCaptureState == .none else { return }
        webView.requestMediaPlaybackState { [weak self] state in
            MainActor.assumeIsolated {
                guard let self, state != .playing, self.webView === webView, !self.isLoading else { return }
                self.hibernate()
            }
        }
    }

    /// Closing the tab: release everything now, even mid-load.
    func discard() {
        guard webView != nil else { return }
        tearDown(keepingState: false)
    }

    /// Releases the content process. `interactionState` survives so waking
    /// restores history rather than just reloading the last URL.
    func hibernate() {
        guard webView != nil, !isLoading else { return }
        tearDown(keepingState: true)
    }

    private func tearDown(keepingState: Bool) {
        guard let webView else { return }
        interactionState = keepingState ? webView.interactionState : nil
        isLoading = false
        observations.forEach { $0.invalidate() }
        observations.removeAll()
        for name in [ScriptInjector.blockedMessageHandler, ScriptInjector.passwordMessageHandler] {
            webView.configuration.userContentController.removeScriptMessageHandler(
                forName: name, contentWorld: ScriptInjector.isolatedWorld)
        }
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.stopLoading()
        self.webView = nil
        log.debug("Released tab \(self.displayTitle, privacy: .private)")
    }

    private func observe(_ webView: WKWebView) {
        observations = [
            webView.observe(\.title, options: [.new]) { [weak self] _, change in
                guard let value = change.newValue ?? nil, !value.isEmpty else { return }
                MainActor.assumeIsolated { self?.title = value }
            },
            webView.observe(\.url, options: [.new]) { [weak self] _, change in
                MainActor.assumeIsolated { self?.url = change.newValue ?? nil }
            },
            webView.observe(\.isLoading, options: [.new]) { [weak self] _, change in
                MainActor.assumeIsolated { self?.isLoading = change.newValue ?? false }
            },
            webView.observe(\.estimatedProgress, options: [.new]) { [weak self] _, change in
                MainActor.assumeIsolated { self?.estimatedProgress = change.newValue ?? 0 }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, change in
                MainActor.assumeIsolated { self?.canGoBack = change.newValue ?? false }
            },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, change in
                MainActor.assumeIsolated { self?.canGoForward = change.newValue ?? false }
            }
        ]
    }

    // MARK: Navigation

    func load(_ target: URL) {
        lastActive = Date()
        securityIssue = nil
        blockedEstimate = 0
        strippedParameters = []

        var destination = target
        if let owner, owner.settings.stripTrackingParameters {
            let result = URLSanitizer.sanitize(target)
            destination = result.url
            strippedParameters = result.removed
        }

        guard let webView else {
            pendingURL = destination
            url = destination
            wake()
            return
        }
        webView.load(URLRequest(url: destination))
    }

    func printPage() {
        guard let webView, let window = webView.window else { return }
        let operation = webView.printOperation(with: NSPrintInfo.shared)
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func reload()   { webView?.reloadFromOrigin() }
    func stop()     { webView?.stopLoading() }
    func goBack()   { webView?.goBack() }
    func goForward(){ webView?.goForward() }

    /// Swaps in the current rule lists. No reload: when lists finish compiling
    /// in the background, yanking the page out from under the reader would be
    /// worse than letting the next request pick up the new rules.
    func refreshRuleLists() {
        installRuleLists(for: listsPolicy ?? policy, force: true)
    }

    /// Attaches the rule families a site's policy calls for. Without this on
    /// every main-frame navigation, a tab kept the rules of the first site it
    /// opened: leaving an allowlisted site left the next site unprotected.
    private func installRuleLists(for sitePolicy: ResolvedSitePolicy, force: Bool) {
        guard let webView, let owner else { return }
        listsPolicy = sitePolicy
        let key = Self.listsKey(sitePolicy)
        guard force || key != installedListsKey else { return }
        let controller = webView.configuration.userContentController
        controller.removeAllContentRuleLists()
        for list in owner.blocking.lists(for: sitePolicy) { controller.add(list) }
        installedListsKey = key
    }

    /// Re-applies policy after the user changes it. This one *does* reload,
    /// because the user just asked for different behaviour on this page.
    func applyPolicyChange() {
        guard let webView else { return }
        installedScriptsKey = nil
        installRuleLists(for: policy, force: true)
        webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = policy.javaScript
        webView.reloadFromOrigin()
    }
}

// MARK: - Navigation delegate

extension Tab: WKNavigationDelegate {

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        preferences: WKWebpagePreferences,
        decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void
    ) {
        guard let target = navigationAction.request.url else {
            decisionHandler(.cancel, preferences); return
        }

        let sitePolicy = owner?.policyStore.resolve(url: target, settings: owner!.settings) ?? .permissive
        WebViewFactory.apply(sitePolicy, to: preferences)
        let isMainFrame = navigationAction.targetFrame?.isMainFrame == true
        // This Mac has no certificate for localhost: WebKit's HTTPS upgrade would
        // fail and leave a blank page. Local servers (AI tools, dev servers) load
        // as requested, matching the loopback exemption in the security rules.
        if #available(macOS 15.2, *), Self.isLoopback(target) {
            preferences.preferredHTTPSNavigationPolicy = .keepAsRequested
        }

        // A real click or key press, not a script's synthetic one.
        let activation = UserInput.recentActivation(in: webView.window)
        let userActivated = navigationAction.navigationType == .linkActivated && activation != nil

        // ⌘-click opens a link in a background tab, like every other browser.
        // Only for a real ⌘-click: a script's fake one would open tabs without
        // limit. Only http(s): a data: page opened by the app would escape
        // WebKit's block on top-level data: navigations.
        if userActivated,
           navigationAction.modifierFlags.contains(.command),
           activation?.modifiers.contains(.command) == true,
           ["http", "https"].contains(target.scheme?.lowercased() ?? "") {
            decisionHandler(.cancel, preferences)
            owner?.openTab(url: target, inBackground: !navigationAction.modifierFlags.contains(.shift),
                           isPrivate: isPrivate, inheritGroupFrom: self)
            return
        }

        if navigationAction.shouldPerformDownload {
            decisionHandler(.download, preferences)
            return
        }

        switch ExternalSchemePolicy.decide(
            url: target, isMainFrame: isMainFrame,
            isUserClick: userActivated
        ) {
        case .web:
            break
        case .block:
            decisionHandler(.cancel, preferences)
            return
        case .confirm(let scheme):
            decisionHandler(.cancel, preferences)
            confirmExternalOpen(target, scheme: scheme, from: webView.url)
            return
        }

        // HTTPS-only. A plaintext URL is *not* evidence the site lacks HTTPS —
        // most http:// links point at sites that support it — so never refuse up
        // front. Let the upgrade happen and judge by how it fails.
        if isMainFrame, sitePolicy.httpsOnly,
           target.scheme?.lowercased() == "http", !Self.isLoopback(target)
        {
            pendingUpgrade = target
            if #unavailable(macOS 15.2) {
                // No native policy: upgrade by hand.
                var components = URLComponents(url: target, resolvingAgainstBaseURL: false)
                components?.scheme = "https"
                if components?.port == 80 { components?.port = nil }
                if let upgraded = components?.url {
                    decisionHandler(.cancel, preferences)
                    webView.load(URLRequest(url: upgraded))
                    return
                }
            }
            // On 15.2+, `.errorOnFailure` set above performs the upgrade.
        } else if isMainFrame, target.scheme?.lowercased() == "https", pendingUpgrade != nil,
                  target.host == pendingUpgrade?.host {
            // The manual upgrade's own navigation: keep tracking it.
        } else if isMainFrame {
            pendingUpgrade = nil
        }

        // Strip tracking parameters on main-frame navigations. `isClean` keeps
        // this idempotent so the cancel-and-reload cannot loop.
        if owner?.settings.stripTrackingParameters == true,
           isMainFrame,
           !URLSanitizer.isClean(target)
        {
            let result = URLSanitizer.sanitize(target)
            strippedParameters = result.removed
            sanitizedReloadTarget = result.url
            decisionHandler(.cancel, preferences)
            webView.load(URLRequest(url: result.url))
            return
        }

        if isMainFrame {
            // A fresh main-frame navigation that we did not just rewrite starts
            // with a clean indicator.
            if target == sanitizedReloadTarget {
                sanitizedReloadTarget = nil
            } else {
                strippedParameters = []
            }

            // Only now that the navigation will really happen. Doing it earlier
            // would re-seed the fingerprinting shim for downloads and mailto:
            // links the tab never visits, leaving later frames on the current
            // page with a mismatched seed.
            prepareMainFrameNavigation(to: target, policy: sitePolicy)
        }

        decisionHandler(.allow, preferences)
    }

    private func confirmExternalOpen(_ url: URL, scheme: String, from page: URL?) {
        let appName = NSWorkspace.shared.urlForApplication(toOpen: url)
            .map { FileManager.default.displayName(atPath: $0.path) }
        guard let appName else { return } // nothing handles it; nothing to ask
        let alert = NSAlert()
        alert.messageText = "Open \(appName)?"
        alert.informativeText = "\(page?.host ?? "This page") wants to open a \(scheme): link in \(appName)."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        // Cancel is the default: a stray Return must not launch another app.
        alert.buttons[0].keyEquivalent = ""
        alert.buttons[1].keyEquivalent = "\r"
        if alert.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(url)
        }
    }

    /// Anything WebKit cannot display, or that the server marks as an
    /// attachment, becomes a download instead of a blank page.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let disposition = (navigationResponse.response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Disposition")?.lowercased() ?? ""
        if navigationResponse.isForMainFrame,
           !navigationResponse.canShowMIMEType || disposition.hasPrefix("attachment") {
            decisionHandler(.download)
        } else {
            decisionHandler(.allow)
        }
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        owner?.downloads.track(download)
        owner?.showDownloads = true
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        owner?.downloads.track(download)
        owner?.showDownloads = true
    }

    /// Every committed document gets its own counter in the page, so the tab's
    /// figure must restart too — otherwise the second page's count is compared
    /// against the first page's total and its blocks are never counted.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        passwordFrame = nil
        passwordHost = nil
        availableLogins = []
        dialogCount = 0
        dialogsSuppressed = false
        blockedEstimate = 0
        blockedPopups = []
        pendingUpgrade = nil
        securityIssue = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        url = webView.url
        title = webView.title ?? url?.host ?? "Untitled"
        owner?.recordVisit(tab: self)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        isLoading = false
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        isLoading = false
        let nsError = error as NSError
        let upgradeTarget = pendingUpgrade
        pendingUpgrade = nil

        // Our own cancel-and-reload (sanitising, manual upgrade) and a user
        // pressing Stop both land here. Neither is a failure worth a page.
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
        if nsError.domain == "WebKitErrorDomain", nsError.code == 102 { return } // interrupted by policy change

        securityIssue = Self.classify(nsError, upgradeTarget: upgradeTarget, failingURL: webView.url)
    }

    /// Maps a provisional failure to what the user should be told.
    ///
    /// Codes come from `HTTPSPolicyProbe` against real hosts: a site without
    /// HTTPS times out or refuses port 443 (`-1001`, `-1004`) or fails TLS; a
    /// host that does not exist fails DNS (`-1003`) and must *not* be blamed on
    /// HTTPS, and neither must being offline.
    static func classify(_ error: NSError, upgradeTarget: URL?, failingURL: URL?) -> SecurityIssue {
        let certificateCodes: Set<Int> = [
            NSURLErrorServerCertificateUntrusted, NSURLErrorServerCertificateHasBadDate,
            NSURLErrorServerCertificateHasUnknownRoot, NSURLErrorServerCertificateNotYetValid,
            NSURLErrorClientCertificateRejected, NSURLErrorClientCertificateRequired
        ]
        let noHTTPSCodes: Set<Int> = certificateCodes.union([
            NSURLErrorTimedOut, NSURLErrorCannotConnectToHost,
            NSURLErrorSecureConnectionFailed, NSURLErrorNetworkConnectionLost,
            NSURLErrorAppTransportSecurityRequiresSecureConnection
        ])

        if error.domain == NSURLErrorDomain {
            if let upgradeTarget, noHTTPSCodes.contains(error.code) {
                // The user asked for plaintext; a broken certificate on the
                // upgrade just means HTTPS isn't really offered there.
                return .insecureTransport(upgradeTarget)
            }
            if certificateCodes.contains(error.code) {
                return .certificateInvalid(error.localizedDescription)
            }
        }
        return .loadFailed(upgradeTarget ?? failingURL, error.localizedDescription)
    }

    /// Certificates: never auto-accept a bad one; WebKit's default is to reject
    /// and there is deliberately no override. HTTP Basic/Digest logins get a
    /// prompt — without one, password-protected sites simply fail.
    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        let space = challenge.protectionSpace
        let passwordMethods = [NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodHTTPDigest, NSURLAuthenticationMethodDefault]
        guard passwordMethods.contains(space.authenticationMethod), challenge.previousFailureCount < 3 else {
            completionHandler(.performDefaultHandling, nil); return
        }
        // Only the site you are on may ask. A third-party frame or image
        // asking for a password is a classic way to phish one.
        let pageSite = PublicSuffix.registrableDomain(of: mainFrameTarget ?? webView.url)
        guard let pageSite, PublicSuffix.registrableDomain(ofHost: space.host) == pageSite,
              let window = webView.window else {
            completionHandler(.performDefaultHandling, nil); return
        }
        let alert = NSAlert()
        alert.messageText = "Sign in to \(space.host)"
        alert.informativeText = space.receivesCredentialSecurely
            ? "This site is asking for a username and password."
            : "This site is asking for a username and password over a connection that does not protect them."
        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 260, height: 24)); user.placeholderString = "Username"
        let pass = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); pass.placeholderString = "Password"
        let stack = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 54)); stack.addSubview(user); stack.addSubview(pass)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Sign In"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = user
        // A sheet on this window, not an app-wide modal: the prompt is visibly
        // attached to the page that asked.
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                // Session-only: never written to the keychain without being asked.
                completionHandler(.useCredential, URLCredential(user: user.stringValue, password: pass.stringValue, persistence: .forSession))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }
        }
    }

    /// Fits the web view to the site it is about to show: that site's rule
    /// lists and its user scripts (fingerprint seed, per-site toggles).
    func prepareMainFrameNavigation(to target: URL, policy sitePolicy: ResolvedSitePolicy) {
        guard let webView else { return }
        mainFrameTarget = target
        installRuleLists(for: sitePolicy, force: false)
        let key = Self.scriptsKey(url: target, policy: sitePolicy)
        if key != installedScriptsKey {
            WebViewFactory.installUserScripts(
                into: webView.configuration.userContentController,
                policy: sitePolicy, topLevelURL: target
            )
            installedScriptsKey = key
        }
    }

    static func listsKey(_ policy: ResolvedSitePolicy) -> String {
        "ads=\(policy.blockAds)|transport=\(policy.httpsOnly || policy.blockThirdPartyCookies)"
    }

    private static func scriptsKey(url: URL?, policy: ResolvedSitePolicy) -> String {
        "\(PublicSuffix.registrableDomain(of: url) ?? "")|\(policy.resistFingerprinting)|\(policy.blockAds)"
    }

    private static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "0.0.0.0"].contains(host)
            || host.hasSuffix(".local")
    }
}

// MARK: - UI delegate

extension Tab: WKUIDelegate {

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        // `target="_blank"` and window.open land here. Allowed ones become a real
        // tab; refused ones are listed in the toolbar so nothing is lost.
        guard let target = navigationAction.request.url else { return nil }
        let decision = PopupPolicy.decide(
            target: target, opener: webView.url,
            isLinkClick: navigationAction.navigationType == .linkActivated
                && UserInput.recentActivation(in: webView.window) != nil,
            siteAllowsPopups: policy.allowPopups
        )
        switch decision {
        case .open:
            owner?.openTab(url: target, inBackground: false, isPrivate: isPrivate)
        case .block:
            // Offered back only if it's a normal web address: reopening a
            // data: or javascript: pop-up from the app would bypass WebKit's guards.
            if ["http", "https"].contains(target.scheme?.lowercased() ?? ""),
               !blockedPopups.contains(target), blockedPopups.count < 20 { blockedPopups.append(target) }
        }
        return nil
    }

    // MARK: JavaScript dialogs

    private func dialogTitle(_ frame: WKFrameInfo) -> String {
        "\(frame.securityOrigin.host.isEmpty ? "This page" : frame.securityOrigin.host) says"
    }

    /// Shows a page's dialog as a sheet on its own window. From the second
    /// dialog on, the user can stop the page from showing more; suppressed or
    /// window-less dialogs resolve as if dismissed.
    private func present(_ alert: NSAlert, in webView: WKWebView, dismissed: @escaping () -> Void,
                         completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard !dialogsSuppressed, let window = webView.window else { dismissed(); return }
        dialogCount += 1
        if dialogCount > 1 {
            alert.showsSuppressionButton = true
            alert.suppressionButton?.title = "Don't show more dialogs from this page"
        }
        alert.beginSheetModal(for: window) { [weak self] response in
            if alert.suppressionButton?.state == .on { self?.dialogsSuppressed = true }
            completion(response)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let alert = NSAlert(); alert.messageText = dialogTitle(frame); alert.informativeText = String(message.prefix(2000))
        alert.addButton(withTitle: "OK")
        present(alert, in: webView, dismissed: completionHandler) { _ in completionHandler() }
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = dialogTitle(frame); alert.informativeText = String(message.prefix(2000))
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        present(alert, in: webView, dismissed: { completionHandler(false) }) {
            completionHandler($0 == .alertFirstButtonReturn)
        }
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
        let alert = NSAlert(); alert.messageText = dialogTitle(frame); alert.informativeText = String(prompt.prefix(2000))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24)); field.stringValue = defaultText ?? ""
        alert.accessoryView = field; alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        present(alert, in: webView, dismissed: { completionHandler(nil) }) {
            completionHandler($0 == .alertFirstButtonReturn ? field.stringValue : nil)
        }
    }

    /// `<input type="file">`. Without this, upload buttons do nothing. The page
    /// only ever receives the files the user picks here.
    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping ([URL]?) -> Void) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.begin { completionHandler($0 == .OK ? panel.urls : nil) }
    }

    /// `window.close()` from script closes the tab it opened.
    func webViewDidClose(_ webView: WKWebView) { owner?.close(self) }

    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        // Always ask. `.grant` would hand a page the camera or microphone with no
        // user involvement; `.prompt` routes every request through a dialog.
        decisionHandler(.prompt)
    }
}

// MARK: - Script messages

extension Tab: WKScriptMessageHandler {
    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        guard message.world == ScriptInjector.isolatedWorld else { return }
        if message.name == ScriptInjector.passwordMessageHandler { handlePasswordMessage(message); return }
        // Only the isolated world can reach this handler, but validate anyway:
        // it is cheap, and a counter should never be able to go wild.
        guard message.name == ScriptInjector.blockedMessageHandler,
              message.frameInfo.isMainFrame,
              let body = message.body as? [String: Any],
              let count = body["count"] as? Int,
              (0...10_000).contains(count)
        else { return }
        let delta = max(0, count - blockedEstimate)
        blockedEstimate = count
        owner?.blocking.sessionBlockEstimate += delta
    }
}

// MARK: - Passwords

extension Tab {
    /// The site a frame belongs to, from WebKit's own record of its origin.
    /// Only HTTPS (or this Mac) can save or fill: on plain HTTP a password
    /// would travel unencrypted anyway, and the network could alter the page.
    static func passwordHost(of frame: WKFrameInfo) -> String? {
        let origin = frame.securityOrigin
        let host = origin.host.lowercased()
        guard !host.isEmpty else { return nil }
        if origin.protocol == "https" { return host }
        if origin.protocol == "http", ["localhost", "127.0.0.1"].contains(host) { return host }
        return nil
    }

    fileprivate func handlePasswordMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String,
              let host = Self.passwordHost(of: message.frameInfo) else { return }
        switch type {
        case "formFound":
            // The main frame wins over iframes; otherwise the first form found.
            guard passwordFrame == nil || message.frameInfo.isMainFrame else { return }
            passwordFrame = message.frameInfo
            passwordHost = host
            availableLogins = PasswordStore.logins(for: host)
        case "submitted":
            guard !isPrivate, let settings = owner?.settings, settings.offerToSavePasswords,
                  !settings.neverSavePasswordHosts.contains(host),
                  let password = body["password"] as? String, !password.isEmpty, password.count <= 1_000,
                  let username = (body["username"] as? String).map({ String($0.prefix(500)) }) else { return }
            let existing = PasswordStore.logins(for: host).first { $0.username == username }
            if let existing, PasswordStore.password(for: existing) == password { return }   // already saved
            passwordOffer = PasswordOffer(host: host, username: username, password: password, isUpdate: existing != nil)
        default:
            return
        }
    }

    func savePasswordOffer() {
        guard let offer = passwordOffer else { return }
        PasswordStore.save(host: offer.host, username: offer.username, password: offer.password)
        passwordOffer = nil
        if offer.host == passwordHost { availableLogins = PasswordStore.logins(for: offer.host) }
    }

    func neverSavePasswords() {
        guard let offer = passwordOffer else { return }
        if owner?.settings.neverSavePasswordHosts.contains(offer.host) == false {
            owner?.settings.neverSavePasswordHosts.append(offer.host)
        }
        passwordOffer = nil
    }

    func dismissPasswordOffer() { passwordOffer = nil }

    /// Fills a saved sign-in into the frame that showed the form. Only ever
    /// called from the user clicking the key button, never automatically: a
    /// page could otherwise hide a form to collect filled-in passwords.
    @discardableResult
    func fill(_ login: SavedLogin) async -> Bool {
        guard let webView, let frame = passwordFrame, Self.passwordHost(of: frame) == login.host,
              login.host == passwordHost, let password = PasswordStore.password(for: login) else { return false }
        let script = """
            const visible = (el) => { const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0; };
            const fields = Array.from(document.querySelectorAll('input[type="password"]')).filter(visible);
            const active = document.activeElement;
            const pw = (active && fields.includes(active)) ? active : fields[0];
            if (!pw) return false;
            const set = (el, value) => {
              Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set.call(el, value);
              el.dispatchEvent(new Event("input", { bubbles: true }));
              el.dispatchEvent(new Event("change", { bubbles: true }));
            };
            const scope = pw.form || document;
            let user = scope.querySelector('input[autocomplete~="username"], input[autocomplete~="email"]');
            if (!user || user === pw || !visible(user)) {
              user = null;
              const inputs = Array.from(scope.querySelectorAll("input"));
              for (let i = inputs.indexOf(pw) - 1; i >= 0; i--) {
                const t = (inputs[i].getAttribute("type") || "text").toLowerCase();
                if (["text", "email", "tel"].includes(t) && visible(inputs[i])) { user = inputs[i]; break; }
              }
            }
            if (user && username) set(user, username);
            set(pw, password);
            return true;
            """
        let result = try? await webView.callAsyncJavaScript(
            script, arguments: ["username": login.username, "password": password],
            in: frame, contentWorld: ScriptInjector.isolatedWorld)
        return (result as? Bool) == true
    }
}
