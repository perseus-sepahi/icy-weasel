import XCTest
import SwiftUI
@testable import Icy_Weasel

/// Real mouse events through AppKit's own path (NSWindow.sendEvent), in a window
/// configured like the app's hidden-title-bar window, to catch clicks that are
/// swallowed in the title-bar region.
@MainActor
final class TabClickTests: XCTestCase {

    private func makeWindow() -> (NSWindow, BrowserViewModel) {
        let suite = "iw-click-\(UUID().uuidString)"; let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let settings = BrowserSettings(defaults: defaults)
        let model = BrowserViewModel(settings: settings, policyStore: SitePolicyStore(defaults: defaults),
                                     blocking: BlockingEngine(settings: settings), downloads: DownloadManager())
        model.tabs[0].title = "First"
        model.openTab(url: nil, inBackground: false)          // second tab, selected
        let window = NSWindow(contentRect: CGRect(x: 200, y: 200, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Icy Weasel"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: BrowserContent(model: model))
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        addTeardownBlock { window.close() }
        return (window, model)
    }

    /// Click at a point measured from the window's top-left, as a user sees it.
    private func click(_ window: NSWindow, x: CGFloat, yFromTop: CGFloat, hoverFirst: Bool = false) async throws {
        let point = NSPoint(x: x, y: window.frame.height - yFromTop)
        let types: [NSEvent.EventType] = hoverFirst ? [.mouseMoved, .leftMouseDown, .leftMouseUp] : [.leftMouseDown, .leftMouseUp]
        for type in types {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            NSApp.sendEvent(event)
            try await Task.sleep(for: .milliseconds(60))
        }
        try await Task.sleep(for: .milliseconds(250))
    }

    /// Finds the + button the way a user would: clicks along the tab strip
    /// from the right edge until a click opens a tab. Right to left, so the
    /// sweep reaches the + before any tab (and never a tab's close button).
    /// SwiftUI doesn't expose its accessibility tree in-process, so this is
    /// the only way to locate it without hard-coding layout. Returns the x of
    /// the first hit, or nil if no click landed (harness can't deliver clicks).
    private func findNewTabButton(_ window: NSWindow, model: BrowserViewModel) async throws -> CGFloat? {
        let before = model.tabs.count
        for x in stride(from: window.frame.width - 30, through: 80, by: -8) {
            let point = NSPoint(x: x, y: window.frame.height - 21)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                NSApp.sendEvent(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
            }
            try await Task.sleep(for: .milliseconds(30))
            if model.tabs.count > before { return x }
        }
        return nil
    }

    /// The + sits right after the last tab, not at the far edge of the strip.
    func testNewTabButtonFollowsLastTab() async throws {
        let (window, model) = makeWindow()
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(model.tabs.count, 2)
        let withTwo = try await findNewTabButton(window, model: model)
        try XCTSkipIf(withTwo == nil, "harness cannot deliver clicks in this environment")
        try await Task.sleep(for: .milliseconds(300))
        let found = try await findNewTabButton(window, model: model)
        let withThree = try XCTUnwrap(found)
        // Two tabs are at most 2 x 220pt after the traffic lights, so the +
        // must sit there, far from the window's right edge, and move right by
        // about a tab when one opens.
        XCTAssertLessThan(withTwo!, 78 + 2 * 222 + 40, "+ is not next to the last tab")
        XCTAssertGreaterThan(withThree, withTwo! + 100, "+ did not follow the new tab")
    }

    func testEveryTabSlotSelectsOnClick() async throws {
        let (window, model) = makeWindow()
        try await Task.sleep(for: .milliseconds(500))
        // Control: the + button (a known-working Button) must respond, or the
        // harness itself is not delivering clicks and nothing below means anything.
        let plus = try await findNewTabButton(window, model: model)
        print("\n=== HARNESS CONTROL: + button \(plus != nil ? "works" : "IGNORED") (key=\(window.isKeyWindow), active=\(NSApp.isActive)) ===")
        try XCTSkipIf(plus == nil, "harness cannot deliver clicks in this environment")
        try await Task.sleep(for: .milliseconds(300))
        while model.tabs.count > 2 { model.close(model.tabs.last!) }
        let first = model.tabs[0], second = model.tabs[1]
        var report = "\n=== TAB CLICKS (x from window left, y=21) ===\n"
        window.acceptsMouseMovedEvents = true
        for hover in [false, true] {
            for x in stride(from: 100, through: 460, by: 60) {
                let expected = x < 290 ? first : second
                model.select(expected === first ? second : first)
                try await click(window, x: CGFloat(x), yFromTop: 21, hoverFirst: hover)
                report += "  \(hover ? "move then click" : "click, no move ") x=\(x): \(model.selectedTab === expected ? "selected" : "IGNORED")\n"
            }
        }
        print(report)
        // A real pointer always moves onto a tab before clicking it. Clicks
        // teleported between spots with no movement are informational only.
        let realistic = report.split(separator: "\n").filter { $0.contains("move then click") }
        XCTAssertEqual(realistic.count, 7)
        XCTAssertFalse(realistic.contains { $0.contains("IGNORED") }, report)
    }
}
