import SwiftUI
import WebKit

/// Hosts whichever tab's web view is current.
///
/// Rebuilding an `NSViewRepresentable` per tab would tear down and recreate the
/// `WKWebView`, discarding the live page. Instead one stable container swaps its
/// single child, so switching tabs is a subview reparent — no reload, no flash.
struct WebViewHost: NSViewRepresentable {
    let tab: Tab

    func makeNSView(context: Context) -> ContainerView {
        let view = ContainerView()
        view.show(tab.wake())
        return view
    }

    func updateNSView(_ view: ContainerView, context: Context) {
        view.show(tab.wake())
    }

    final class ContainerView: NSView {
        private weak var current: WKWebView?

        /// Sized by frame and autoresizing mask, never by constraints. For
        /// fullscreen video WebKit moves the web view into its own window and
        /// just sets a frame; a view with autoresizing turned off (as pinning
        /// with constraints requires) and no constraints there gets laid out to
        /// zero size, which is the black fullscreen screen.
        func show(_ webView: WKWebView) {
            if current === webView, webView.superview === self { return }
            // While WebKit has the view in its fullscreen window, leave it there:
            // pulling it back would leave the fullscreen window empty.
            if current === webView, webView.superview != nil { return }
            if current?.superview === self { current?.removeFromSuperview() }
            webView.translatesAutoresizingMaskIntoConstraints = true
            webView.autoresizingMask = [.width, .height]
            webView.frame = bounds
            addSubview(webView)
            current = webView
        }

        override func layout() {
            super.layout()
            if let current, current.superview === self { current.frame = bounds }
        }
    }
}
