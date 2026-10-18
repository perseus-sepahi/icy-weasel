import XCTest
import SwiftUI
@testable import Icy_Weasel

/// Which ingredient of a tab makes a title-bar click get lost?
@MainActor
final class TitlebarClickBisect: XCTestCase {

    private func model() -> BrowserViewModel {
        let suite = "iw-bisect-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = BrowserSettings(defaults: defaults)
        let m = BrowserViewModel(settings: settings, policyStore: SitePolicyStore(defaults: defaults),
                                 blocking: BlockingEngine(settings: settings), downloads: DownloadManager())
        m.tabs[0].title = "First"
        m.openTab(url: nil, inBackground: false)   // second tab selected; first tab spans x 78–298
        return m
    }

    private func clickFirstTab<V: View>(_ label: String, model m: BrowserViewModel, _ view: V) async throws -> String {
        let window = NSWindow(contentRect: CGRect(x: 300, y: 300, width: 1000, height: 600),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: view)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(400))
        let point = NSPoint(x: 150, y: window.frame.height - 21)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            try await Task.sleep(for: .milliseconds(80))
        }
        try await Task.sleep(for: .milliseconds(200))
        return "  \(label.padding(toLength: 34, withPad: " ", startingAt: 0)) \(m.selectedTab?.title == "First" ? "clicked" : "LOST (selected: \(m.selectedTab?.title ?? "?"))")"
    }

    func testRealTabStrip() async throws {
        var lines: [String] = []
        let a = model()
        lines.append(try await clickFirstTab("TabStrip alone", model: a,
            VStack(spacing: 0) { TabStrip(model: a); Spacer() }.ignoresSafeArea(.container, edges: .top)))
        let c = model()
        lines.append(try await clickFirstTab("TabStrip + IceWindowChrome bg", model: c,
            VStack(spacing: 0) { TabStrip(model: c); Spacer() }.background(IceWindowChrome()).ignoresSafeArea(.container, edges: .top)))
        let d = model()
        lines.append(try await clickFirstTab("TabStrip + toolbar", model: d,
            VStack(spacing: 0) { TabStrip(model: d); BrowserToolbar(model: d); Spacer() }.ignoresSafeArea(.container, edges: .top)))
        let e = model()
        lines.append(try await clickFirstTab("TabStrip + toolbar + NewTabPage", model: e,
            VStack(spacing: 0) { TabStrip(model: e); BrowserToolbar(model: e); NewTabPage(model: e) }.ignoresSafeArea(.container, edges: .top)))
        let b = model()
        lines.append(try await clickFirstTab("full BrowserContent", model: b, BrowserContent(model: b)))
        print("\n=== REAL TAB STRIP (click first tab at x=150, y=21) ===\n" + lines.joined(separator: "\n") + "\n")
        // Regression: the new-tab page's decorative backdrop covered the tab strip.
        XCTAssertFalse(lines.contains { $0.contains("LOST") }, lines.joined(separator: "\n"))
    }
}
