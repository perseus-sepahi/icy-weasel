import SwiftUI

struct BrowserCommands: Commands {
    let services: AppServices
    @Environment(\.openWindow) private var openWindow

    private var browser: BrowserViewModel? { services.activeBrowser }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Tab") { browser?.openTab(url: nil, inBackground: false) }
                .keyboardShortcut("t")
            Button("New Window") { openWindow(id: "browser") }
                .keyboardShortcut("n")
            Button("New Private Window") { openWindow(id: "private") }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Divider()
            Button("Open Location…") { browser?.isOmniboxFocused = true }
                .keyboardShortcut("l")
            Button("Close Tab") { browser?.closeSelectedTab() }
                .keyboardShortcut("w")
            Button("Reopen Closed Tab") { browser?.reopenClosedTab() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
            Divider()
            Button("Print…") { browser?.selectedTab?.printPage() }
                .keyboardShortcut("p")
        }

        CommandGroup(after: .textEditing) {
            Button("Find in Page…") { browser?.showFindBar = true }
                .keyboardShortcut("f")
        }

        CommandGroup(after: .toolbar) {
            Button("Zoom In") { browser?.zoom(by: 0.1) }
                .keyboardShortcut("+")
            Button("Zoom Out") { browser?.zoom(by: -0.1) }
                .keyboardShortcut("-")
            Button("Actual Size") { browser?.resetZoom() }
                .keyboardShortcut("0")
        }

        CommandMenu("Navigate") {
            Button("Back") { browser?.selectedTab?.goBack() }
                .keyboardShortcut("[")
            Button("Forward") { browser?.selectedTab?.goForward() }
                .keyboardShortcut("]")
            Button("Reload") { browser?.selectedTab?.reload() }
                .keyboardShortcut("r")
            Divider()
            Button("Next Tab") { browser?.selectTab(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { browser?.selectTab(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Divider()
            ForEach(1...9, id: \.self) { n in
                Button(n == 9 ? "Last Tab" : "Tab \(n)") { browser?.selectTab(number: n) }
                    .keyboardShortcut(KeyEquivalent(Character("\(n)")))
            }
        }

        CommandMenu("Bookmarks") {
            Button("Bookmark This Page") { browser?.toggleBookmark() }
                .keyboardShortcut("d")
            Button("Show History") { browser?.showHistory = true }
                .keyboardShortcut("y")
            Divider()
            ForEach(services.library.bookmarks.prefix(40)) { bookmark in
                Button(bookmark.title) { browser?.openTab(url: bookmark.url, inBackground: false) }
            }
        }

        CommandMenu("Tabs") {
            Button("Group This Tab") {
                if let b = browser, let tab = b.selectedTab { b.createGroup(with: tab) }
            }
            .keyboardShortcut("g", modifiers: [.command, .option])
            Button("Remove Tab from Group") { if let b = browser, let tab = b.selectedTab { b.removeFromGroup(tab) } }
            Button("Duplicate Tab") { if let b = browser, let tab = b.selectedTab { b.duplicate(tab) } }
            Divider()
            Button("Ask AI About This Page") { browser?.showAssistant.toggle() }
                .keyboardShortcut("a", modifiers: [.command, .option])
        }

        CommandMenu("Protection") {
            Button("Site Protections…") { browser?.showSitePanel = true }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Update Filter Lists") {
                Task { await services.blocking.refresh(force: true) }
            }
            Divider()
            Button("Put Idle Tabs to Sleep") { browser?.hibernateIdleTabs() }
        }
    }
}
