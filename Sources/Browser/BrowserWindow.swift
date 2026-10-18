import SwiftUI

struct BrowserWindow: View {
    let isPrivate: Bool
    @Environment(AppServices.self) private var services
    @State private var model: BrowserViewModel?
    @State private var window: NSWindow?

    var body: some View {
        Group {
            if let model {
                BrowserContent(model: model)
                    .onAppear { services.activeBrowser = model }
                    .background(WindowReader { window = $0 })
                    // Only when *this* window becomes key. Unfiltered, every open
                    // window claimed the menu commands on any focus change.
                    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { note in
                        if let window, (note.object as? NSWindow) === window { services.activeBrowser = model }
                    }
                    .onOpenURL { url in
                        guard !isPrivate, ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
                        if model.selectedTab?.url == nil { model.selectedTab?.load(url) }
                        else { model.openTab(url: url, inBackground: false) }
                    }
                    .sheet(isPresented: Binding(get: { model.showHistory }, set: { model.showHistory = $0 })) {
                        HistoryView(model: model)
                    }
            } else {
                Color.clear
            }
        }
        .onAppear {
            guard model == nil else { return }
            let browser = BrowserViewModel(
                settings: services.settings,
                policyStore: services.policyStore,
                blocking: services.blocking,
                downloads: services.downloads,
                isPrivate: isPrivate,
                library: services.library,
                // Only the first normal window restores; later ones start fresh.
                restoreSession: services.claimSessionRestore()
            )
            services.register(browser)
            model = browser
        }
    }
}

struct BrowserContent: View {
    @Bindable var model: BrowserViewModel

    var body: some View {
        VStack(spacing: 0) {
            TabStrip(model: model)
            BrowserToolbar(model: model)
            if model.showFindBar {
                FindBar(model: model)
            }
            // A thin bright edge where the glass meets the page, like cut ice.
            LinearGradient(colors: [Theme.rim.opacity(0.5), Theme.ice.opacity(0.35), Theme.rim.opacity(0.5)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1)
            HStack(spacing: 0) {
                ZStack(alignment: .top) {
                    if let tab = model.selectedTab {
                        page(for: tab)
                        LoadingBar(tab: tab)
                    }
                    SuggestionOverlay(model: model)
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
                .clipShape(Rectangle())   // clips hit-testing as well as drawing
                if model.showAssistant {
                    AssistantPanel(model: model)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            // minWidth/minHeight 0 is the fix for the windowed-mode bug: without
            // it, a page whose content is taller than the window (the new-tab
            // page in a small window) reports that height as its minimum, the
            // whole VStack overflows the window, SwiftUI centres the overflow,
            // and the tab strip slides off the top edge. Full screen hid it only
            // because there was always enough room.
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .top)
            .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // The tab strip and toolbar are real glass: the window is see-through,
        // blurred and tinted cold. Private windows run a violet frost.
        .background {
            ZStack {
                LinearGradient(colors: [(model.isPrivateWindow ? Color.purple : Theme.chromeTint).opacity(0.72),
                                        (model.isPrivateWindow ? Color.indigo : Theme.chromeTintLow).opacity(0.62)],
                               startPoint: .top, endPoint: .bottom)
                // Aurora sheen drifting across the glass.
                LinearGradient(colors: [Theme.aurora.opacity(0.22), .clear, Theme.ice.opacity(0.18)],
                               startPoint: .leading, endPoint: .trailing)
                // Frost catching the light along the top edge.
                LinearGradient(colors: [Theme.rim.opacity(0.22), .clear], startPoint: .top, endPoint: .center)
            }
        }
        .background(IceWindowChrome(privateTint: model.isPrivateWindow))
        .ignoresSafeArea(.container, edges: .top)
    }

    @ViewBuilder
    private func page(for tab: Tab) -> some View {
        if let issue = tab.securityIssue {
            SecurityInterstitial(issue: issue, tab: tab, model: model)
        } else if tab.url == nil {
            NewTabPage(model: model)
        } else {
            WebViewHost(tab: tab)
                .id(tab.id)
        }
    }
}

/// Reads the tab's progress itself. Progress changes dozens of times per page
/// load; read in `BrowserContent`, each tick re-evaluated the whole window.
private struct LoadingBar: View {
    let tab: Tab

    var body: some View {
        if tab.isLoading {
            GeometryReader { proxy in
                Rectangle()
                    .fill(LinearGradient(colors: [Theme.iceDeep, Theme.ice, Theme.aurora], startPoint: .leading, endPoint: .trailing))
                    .iceGlow(Theme.ice, radius: 4)
                    .frame(width: proxy.size.width * max(0.08, tab.estimatedProgress), height: 2)
                    .animation(.easeOut(duration: 0.25), value: tab.estimatedProgress)
            }
            .frame(height: 2)
            .allowsHitTesting(false)
        }
    }
}

/// Same idea for suggestions: only this view re-renders while typing.
private struct SuggestionOverlay: View {
    let model: BrowserViewModel

    var body: some View {
        if !model.suggestions.isEmpty { SuggestionList(model: model) }
    }
}

/// Hands the hosting NSWindow back to SwiftUI.
private struct WindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { onResolve(view.window) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { onResolve(view.window) }
    }
}

struct HistoryView: View {
    @Bindable var model: BrowserViewModel
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let entries = model.library.history.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) || $0.url.absoluteString.localizedCaseInsensitiveContains(query)
        }
        VStack(spacing: 0) {
            HStack {
                TextField("Search history", text: $query).textFieldStyle(.roundedBorder)
                Button("Clear All", role: .destructive) { model.library.clearHistory() }
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(12)
            List(entries.prefix(500)) { entry in
                Button {
                    model.openTab(url: entry.url, inBackground: false); dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.title.isEmpty ? entry.url.absoluteString : entry.title).lineLimit(1)
                        Text("\(entry.url.host ?? "") · \(entry.lastVisit.formatted(.relative(presentation: .named)))")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .buttonStyle(.plain)
                .contextMenu { Button("Remove from History") { model.library.removeHistory(entry) } }
            }
            if entries.isEmpty {
                Text(query.isEmpty ? "No history yet. Private windows never record any." : "No matches")
                    .foregroundStyle(.secondary).padding()
            }
        }
        .frame(width: 560, height: 480)
    }
}
