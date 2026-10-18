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

        func show(_ webView: WKWebView) {
            guard current !== webView else { return }
            current?.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: trailingAnchor),
                webView.topAnchor.constraint(equalTo: topAnchor),
                webView.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
            current = webView
        }
    }
}
