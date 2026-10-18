import Foundation

/// Decides what happens when a page navigates to a non-web URL scheme.
///
/// Handing arbitrary schemes to `NSWorkspace` is a real attack surface: `smb://`
/// makes Finder mount an attacker's share (and can leak credentials), and app
/// URL handlers have a long history of remote-code-execution bugs. So: only a
/// user click in the top frame may even ask, the user always confirms, and
/// schemes that reach the filesystem or network shares are refused outright.
enum ExternalSchemePolicy {

    enum Decision: Equatable {
        /// A scheme WebKit renders itself.
        case web
        /// Refused without asking.
        case block(reason: String)
        /// Allowed only if the user confirms.
        case confirm(scheme: String)
    }

    static let webSchemes: Set<String> = ["http", "https", "about", "data", "blob"]

    /// Schemes that mount, browse or execute against local or remote file
    /// systems or shells. No page gets to trigger these, click or not.
    static let forbiddenSchemes: Set<String> = [
        "file", "smb", "cifs", "afp", "nfs", "ftp", "ftps", "sftp", "webdav", "davs",
        "vnc", "ssh", "telnet", "x-man-page", "applescript", "shortcuts"
    ]

    static func decide(url: URL, isMainFrame: Bool, isUserClick: Bool) -> Decision {
        guard let scheme = url.scheme?.lowercased() else { return .block(reason: "no scheme") }
        if webSchemes.contains(scheme) { return .web }
        if forbiddenSchemes.contains(scheme) { return .block(reason: "\(scheme): is never opened from web content") }
        // Subframes and script-driven redirects cannot launch apps: that is how
        // drive-by protocol-handler exploits fire without any interaction.
        guard isMainFrame else { return .block(reason: "subframe") }
        guard isUserClick else { return .block(reason: "no user gesture") }
        return .confirm(scheme: scheme)
    }
}

/// Decides whether a request for a new window becomes a tab.
///
/// WebKit already refuses `window.open` without a user gesture. What is left is
/// the pop-under pattern: a page hooks *any* click and opens an advertiser's
/// site. Those are script-opened and cross-site. A link the user actually
/// clicked (`target="_blank"`) and same-site windows are not.
enum PopupPolicy {
    enum Decision: Equatable { case open, block }

    static func decide(target: URL, opener: URL?, isLinkClick: Bool, siteAllowsPopups: Bool) -> Decision {
        guard let scheme = target.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            // about:blank shells, javascript:, data: — classic pop-under vehicles.
            return siteAllowsPopups && target.absoluteString == "about:blank" ? .open : .block
        }
        if isLinkClick || siteAllowsPopups { return .open }
        return PublicSuffix.isThirdParty(target, relativeTo: opener) ? .block : .open
    }
}
