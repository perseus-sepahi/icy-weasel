import XCTest
import WebKit
@testable import Icy_Weasel

/// Regression: fullscreen video was black. Entering element fullscreen, WebKit
/// moves the WKWebView into its own fullscreen window and simply sets its frame.
/// The host had turned off translatesAutoresizingMaskIntoConstraints to pin the
/// view with constraints, so in the fullscreen window it had neither constraints
/// nor an autoresizing mask, and the next layout pass shrank it to nothing.
@MainActor
final class FullscreenHostingTests: XCTestCase {

    func testWebViewKeepsItsSizeWhenMovedLikeWebKitFullscreenDoes() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: config)

        let host = WebViewHost.ContainerView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        host.show(webView)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(webView.frame.size, NSSize(width: 800, height: 500), "fills its tab")

        // What WKFullScreenWindowController does: reparent, set a frame.
        let fullscreenContent = NSView(frame: NSRect(x: 0, y: 0, width: 1512, height: 982))
        let window = NSWindow(contentRect: fullscreenContent.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = fullscreenContent
        webView.removeFromSuperview()
        fullscreenContent.addSubview(webView)
        webView.frame = fullscreenContent.bounds
        fullscreenContent.needsLayout = true
        fullscreenContent.layoutSubtreeIfNeeded()
        XCTAssertEqual(webView.frame.size, NSSize(width: 1512, height: 982), "the video fills the screen")

        // And back: WebKit returns the view to the tab.
        webView.removeFromSuperview()
        host.show(webView)
        host.setFrameSize(NSSize(width: 900, height: 600))
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(webView.frame.size, NSSize(width: 900, height: 600), "fills its tab again, and follows resizes")
    }
}
