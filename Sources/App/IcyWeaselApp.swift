import SwiftUI
import WebKit

@main
struct IcyWeaselApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var services = AppServices()

    var body: some Scene {
        WindowGroup("Icy Weasel", id: "browser") {
            BrowserWindow(isPrivate: false)
                .environment(services)
                .frame(minWidth: 640, minHeight: 420)
                // Links from other apps open as a tab here, not in a new window.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 860)
        .commands { BrowserCommands(services: services) }

        WindowGroup("Private Window", id: "private") {
            BrowserWindow(isPrivate: true)
                .environment(services)
                .frame(minWidth: 640, minHeight: 420)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1320, height: 860)

        Settings {
            SettingsView()
                .environment(services)
        }
    }
}

/// App-wide singletons shared by every window.
@MainActor
@Observable
final class AppServices {
    let settings = BrowserSettings()
    let policyStore = SitePolicyStore()
    let blocking: BlockingEngine
    let downloads = DownloadManager()
    let library = BrowsingLibrary.persistent()
    private var sessionRestoreClaimed = false

    func claimSessionRestore() -> Bool {
        defer { sessionRestoreClaimed = true }
        return !sessionRestoreClaimed
    }
    /// The focused window's model, so menu commands act on the right window.
    weak var activeBrowser: BrowserViewModel?
    private var windows: [WeakBrowser] = []

    private struct WeakBrowser { weak var model: BrowserViewModel? }

    /// macOS says memory is running low: free background tabs right away
    /// instead of waiting for their idle timers.
    private var memoryPressure: DispatchSourceMemoryPressure?

    private func watchMemoryPressure() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.relieveMemoryPressure() }
        }
        source.resume()
        memoryPressure = source
    }

    func relieveMemoryPressure() {
        windows.compactMap(\.model).forEach { $0.relieveMemoryPressure() }
    }

    func register(_ browser: BrowserViewModel) {
        windows.removeAll { $0.model == nil || $0.model === browser }
        windows.append(WeakBrowser(model: browser))
    }

    /// A global setting changed: every open window's tabs must pick it up, not
    /// just the frontmost one.
    func reapplyEverywhere() {
        windows.removeAll { $0.model == nil }
        windows.forEach { $0.model?.reapplyGlobalPolicy() }
    }

    static weak var shared: AppServices?

    init() {
        blocking = BlockingEngine(settings: settings)
        Self.shared = self
        settings.applyAppearance()
        watchMemoryPressure()
        Task { await blocking.start() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Private windows share nothing with disk; standard windows keep
        // cookies but nothing that would outlive a "clear on quit".
        NSWindow.allowsAutomaticWindowTabbing = false
        // Lets navigation code tell a real click from a script's synthetic one.
        MainActor.assumeIsolated { UserInput.install() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppServices.shared?.library.flush() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
