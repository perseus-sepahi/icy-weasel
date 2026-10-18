import SwiftUI

struct BrowserToolbar: View {
    @Bindable var model: BrowserViewModel
    @FocusState private var omniboxFocused: Bool

    var body: some View {
        let tab = model.selectedTab

        HStack(spacing: 6) {
            navButton("chevron.left", help: "Back (⌘[)", enabled: tab?.canGoBack == true) { tab?.goBack() }
            navButton("chevron.right", help: "Forward (⌘])", enabled: tab?.canGoForward == true) { tab?.goForward() }
            if tab?.isLoading == true {
                navButton("xmark", help: "Stop", enabled: true) { tab?.stop() }
            } else {
                navButton("arrow.clockwise", help: "Reload (⌘R)", enabled: tab?.url != nil) { tab?.reload() }
            }

            omnibox(tab: tab)

            if !model.downloads.items.isEmpty {
                DownloadsButton(model: model)
            }
            ShieldButton(model: model)
            Button { model.showAssistant.toggle() } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(model.showAssistant ? AnyShapeStyle(Theme.iceGradient) : AnyShapeStyle(.secondary))
                    .frame(width: 28, height: 28).contentShape(Rectangle())
            }
            .buttonStyle(.plain).focusEffectDisabled()
            .help("Ask a local AI about this page (⌥⌘A)")
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.toolbarHeight)
        .onChange(of: model.isOmniboxFocused) { _, focused in omniboxFocused = focused }
        .onChange(of: omniboxFocused) { _, focused in
            model.isOmniboxFocused = focused
            // Like every browser: focusing the address bar selects the whole
            // address, so typing replaces it instead of appending to it.
            if focused {
                DispatchQueue.main.async { NSApp.sendAction(#selector(NSResponder.selectAll(_:)), to: nil, from: nil) }
            }
        }
    }

    private func omnibox(tab: Tab?) -> some View {
        HStack(spacing: 7) {
            transportIcon(tab: tab)

            TextField("Search privately or enter address", text: $model.omniboxText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .tint(Theme.selection)
                .focused($omniboxFocused)
                .onSubmit { model.submitOmnibox() }
                .autocorrectionDisabled()
                .onKeyPress(.downArrow) { model.moveSuggestion(1); return .handled }
                .onKeyPress(.upArrow) { model.moveSuggestion(-1); return .handled }
                .onKeyPress(.escape) { model.cancelOmniboxEdit(); return .handled }
                .onChange(of: model.omniboxText) { _, _ in model.suggestionIndex = nil }

            if let tab, !tab.availableLogins.isEmpty, !omniboxFocused {
                PasswordFillButton(tab: tab)
            }

            if let url = tab?.url, !omniboxFocused, !model.isPrivateWindow {
                Button { model.toggleBookmark() } label: {
                    Image(systemName: model.library.isBookmarked(url) ? "star.fill" : "star")
                        .font(.system(size: 11))
                        .foregroundStyle(model.library.isBookmarked(url) ? Theme.warning : .secondary)
                }
                .buttonStyle(.plain).focusEffectDisabled().help("Bookmark this page (⌘D)")
            }

            if let tab, !tab.blockedPopups.isEmpty, !omniboxFocused {
                PopupBadge(tab: tab, model: model)
            }

            if let tab, !tab.strippedParameters.isEmpty, !omniboxFocused {
                Label("\(tab.strippedParameters.count)", systemImage: "scissors")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.ice)
                    .help("Removed tracking parameters: \(tab.strippedParameters.joined(separator: ", "))")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: 32)
        .iceGlass(Capsule(), tint: Theme.ice, strength: omniboxFocused ? 1.6 : 0.9)
        .overlay(
            Capsule().strokeBorder(
                LinearGradient(colors: [Theme.aurora, Theme.ice, Theme.iceDeep], startPoint: .leading, endPoint: .trailing),
                lineWidth: omniboxFocused ? 1.5 : 0)
        )
        .iceGlow(Theme.ice, radius: 9, active: omniboxFocused)
        .animation(.easeOut(duration: 0.18), value: omniboxFocused)
    }

    @ViewBuilder
    private func transportIcon(tab: Tab?) -> some View {
        switch tab?.url?.scheme?.lowercased() {
        case "https":
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.iceGradient)
                .help("Encrypted connection")
        case "http":
            Image(systemName: "lock.open.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.warning)
                .help("Not encrypted")
        default:
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
    }

    private func navButton(_ symbol: String, help: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .foregroundStyle(enabled ? .primary : .tertiary)
        .disabled(!enabled)
        .help(help)
    }
}

/// The shield shows what is being blocked and is the entry point to the per-site
/// escape hatch. It is always visible because a security control you cannot see
/// is a security control you forget you turned off.
private struct ShieldButton: View {
    @Bindable var model: BrowserViewModel

    var body: some View {
        let tab = model.selectedTab
        let relaxed = model.isSiteRelaxed

        Button {
            model.showSitePanel.toggle()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: relaxed ? "shield.slash.fill" : "shield.lefthalf.filled")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(relaxed ? Theme.warning : Theme.iceAccent)
                if let count = tab?.blockedEstimate, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .help(relaxed ? "Protections relaxed on this site" : "Protections active")
        .popover(isPresented: $model.showSitePanel, arrowEdge: .bottom) {
            SitePanel(model: model)
        }
    }
}

private struct DownloadsButton: View {
    @Bindable var model: BrowserViewModel

    var body: some View {
        Button { model.showDownloads.toggle() } label: {
            Image(systemName: model.downloads.hasActiveDownloads ? "arrow.down.circle.dotted" : "arrow.down.circle")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(model.downloads.hasActiveDownloads ? Theme.ice : .secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .help("Downloads")
        .popover(isPresented: $model.showDownloads, arrowEdge: .bottom) {
            DownloadsList(manager: model.downloads)
        }
    }
}

private struct DownloadsList: View {
    let manager: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Downloads").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("Clear") { manager.clearFinished() }
                    .buttonStyle(.plain).focusEffectDisabled().font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(manager.items) { item in
                HStack(spacing: 10) {
                    Image(systemName: "doc").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.filename).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        switch item.state {
                        case .running:
                            ProgressView(value: item.fractionCompleted).controlSize(.small)
                        case .finished:
                            Text("Done — quarantined until opened").font(.system(size: 10)).foregroundStyle(.secondary)
                        case .failed(let reason):
                            Text(reason).font(.system(size: 10)).foregroundStyle(Theme.danger).lineLimit(1)
                        case .cancelled:
                            Text("Cancelled").font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if item.state == .running {
                        Button { manager.cancel(item) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.plain).focusEffectDisabled()
                    } else if item.state == .finished {
                        Button { manager.reveal(item) } label: { Image(systemName: "magnifyingglass.circle") }
                            .buttonStyle(.plain).focusEffectDisabled().help("Show in Finder")
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct PopupBadge: View {
    let tab: Tab
    @Bindable var model: BrowserViewModel
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Label("\(tab.blockedPopups.count)", systemImage: "rectangle.on.rectangle.slash")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.warning)
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .help("Pop-ups blocked on this page")
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pop-ups blocked").font(.system(size: 13, weight: .semibold))
                ForEach(tab.blockedPopups, id: \.self) { url in
                    Button {
                        model.openTab(url: url, inBackground: false, isPrivate: tab.isPrivate)
                        showing = false
                    } label: {
                        Label(url.host ?? url.absoluteString, systemImage: "arrow.up.forward.square")
                            .font(.system(size: 12)).lineLimit(1)
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                    .help(url.absoluteString)
                }
                Divider()
                Button("Always allow pop-ups on this site") {
                    model.updateSitePolicy { $0.allowPopups = true }
                    showing = false
                }
                .buttonStyle(.plain).focusEffectDisabled().font(.system(size: 12)).foregroundStyle(Theme.iceDeep)
            }
            .padding(14).frame(width: 280)
        }
    }
}

/// History and bookmark matches under the address bar.
struct SuggestionList: View {
    @Bindable var model: BrowserViewModel

    var body: some View {
        let suggestions = model.suggestions
        VStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, item in
                Button { model.open(item) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: item.isBookmark ? "star.fill" : "clock")
                            .font(.system(size: 10)).foregroundStyle(item.isBookmark ? Theme.warning : .secondary)
                            .frame(width: 14)
                        Text(item.title.isEmpty ? (item.url.host ?? "") : item.title).font(.system(size: 12)).lineLimit(1)
                        Text(item.url.absoluteString).font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).frame(height: 28)
                    .background(index == model.suggestionIndex ? Theme.ice.opacity(0.18) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).focusEffectDisabled()
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .iceGlass(RoundedRectangle(cornerRadius: 14, style: .continuous), tint: Theme.ice, strength: 0.8)
        .shadow(color: Theme.iceDeep.opacity(0.28), radius: 16, y: 8)
        .padding(.leading, 104).padding(.trailing, 84).padding(.top, 2)
    }
}
