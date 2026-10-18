import XCTest
import SwiftUI
@testable import Icy_Weasel

/// Regression: in a small (non-full-screen) window the new-tab page's content
/// was taller than the window, the root stack overflowed, and the tab strip slid
/// off the top edge.
@MainActor
final class WindowLayoutTests: XCTestCase {

    private func makeModel() -> BrowserViewModel {
        let suite = "iw-layout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = BrowserSettings(defaults: defaults)
        return BrowserViewModel(settings: settings, policyStore: SitePolicyStore(defaults: defaults),
                                blocking: BlockingEngine(settings: settings), downloads: DownloadManager())
    }

    func testContentNeverDemandsMoreThanTheWindow() {
        let model = makeModel()
        let controller = NSHostingController(rootView: BrowserContent(model: model))
        for size in [CGSize(width: 640, height: 420), CGSize(width: 700, height: 300), CGSize(width: 1400, height: 900)] {
            let fitted = controller.sizeThatFits(in: size)
            XCTAssertLessThanOrEqual(fitted.height, size.height + 0.5, "overflows a \(size) window vertically")
            XCTAssertLessThanOrEqual(fitted.width, size.width + 0.5, "overflows a \(size) window horizontally")
        }
    }

    func testSnapshotAtMinimumWindowSize() throws {
        let model = makeModel()
        let size = CGSize(width: 640, height: 420)
        let host = NSHostingView(rootView: BrowserContent(model: model).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iw-layout-640x420.png")
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("SNAPSHOT: \(url.path)")
    }
}

/// Regression: a non-opaque window lets clicks fall through glass (the
/// WindowServer composites it, so the app's pixels there are transparent).
@MainActor
final class WindowHitTestingTests: XCTestCase {
    func testBrowserWindowStaysOpaqueSoClicksLand() async throws {
        let suite = "iw-hit-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = BrowserSettings(defaults: defaults)
        let model = BrowserViewModel(settings: settings, policyStore: SitePolicyStore(defaults: defaults),
                                     blocking: BlockingEngine(settings: settings), downloads: DownloadManager())
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: BrowserContent(model: model))
        window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))   // let any deferred window tweaks run
        XCTAssertTrue(window.isOpaque, "a non-opaque window passes clicks through glass to the app behind")
        XCTAssertNotEqual(window.backgroundColor, .clear)
    }
}
