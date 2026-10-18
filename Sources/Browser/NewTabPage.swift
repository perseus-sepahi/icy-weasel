import SwiftUI

/// The new tab page is native SwiftUI, not a web page. A local HTML start page
/// would be a web origin with script execution, which is attack surface for a
/// screen that needs none.
struct NewTabPage: View {
    @Bindable var model: BrowserViewModel

    var body: some View {
        let engine = model.blocking

        GeometryReader { proxy in
        ScrollView(.vertical) {
        VStack(spacing: 28) {
            Spacer(minLength: 16)

            VStack(spacing: 10) {
                Image(systemName: "snowflake")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(Theme.iceGradient)
                    .frame(width: 84, height: 84)
                    .iceGlass(Circle(), tint: Theme.ice, strength: 1.3)
                    .iceGlow(Theme.ice, radius: 18)
                    .padding(.bottom, 4)
                Text("Icy Weasel")
                    .font(.system(size: 32, weight: .semibold, design: .rounded))
                    .foregroundStyle(LinearGradient(colors: [Theme.frostText, Theme.iceDeep], startPoint: .top, endPoint: .bottom))
                Text(model.isPrivateWindow
                     ? "Private window — nothing from this session is written to disk"
                     : "Fast, quiet, and not for sale")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }

            IceGlassGroup(spacing: 14) {
            HStack(spacing: 14) {
                statCard(
                    value: engine.sessionBlockEstimate.formatted(),
                    label: "blocked this session",
                    footnote: "estimate",
                    systemImage: "hand.raised.fill"
                )
                statCard(
                    value: rulesValue(engine.state),
                    label: "filter rules compiled",
                    footnote: "native DFA",
                    systemImage: "bolt.fill"
                )
                statCard(
                    value: model.tabs.filter(\.isHibernated).count.formatted(),
                    label: "tabs sleeping",
                    footnote: "memory freed",
                    systemImage: "moon.zzz.fill"
                )
            }
            }

            if !model.library.bookmarks.isEmpty {
                WrappingRow(spacing: 8) {
                    ForEach(model.library.bookmarks.prefix(12)) { bookmark in
                        Button { model.selectedTab?.load(bookmark.url) } label: {
                            Label(bookmark.title, systemImage: "star.fill")
                                .font(.system(size: 12)).lineLimit(1).frame(maxWidth: 160)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .iceGlass(Capsule(), strength: 0.7, interactive: true)
                        }
                        .buttonStyle(.plain).help(bookmark.url.absoluteString)
                    }
                }
            }

            protectionsRow

            Spacer(minLength: 16)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        // Centred when the window is tall, scrollable when it is short.
        .frame(maxWidth: .infinity, minHeight: proxy.size.height)
        }
        }
        .background(IceBackdrop(privateTint: model.isPrivateWindow))
    }

    private func rulesValue(_ state: BlockingEngine.State) -> String {
        if case .ready(let rules, _) = state { return rules.formatted() }
        if case .loading = state { return "…" }
        return "—"
    }

    private func statCard(value: String, label: String, footnote: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 13))
                .foregroundStyle(Theme.iceGradient)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded))
                .foregroundStyle(Theme.frostText)
                .monospacedDigit()
                .contentTransition(.numericText())
            VStack(alignment: .leading, spacing: 1) {
                Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(footnote).font(.system(size: 10)).foregroundStyle(.tertiary)
            }
        }
        .frame(minWidth: 96, maxWidth: 150, alignment: .leading)
        .padding(16)
        .iceGlass(RoundedRectangle(cornerRadius: 18, style: .continuous), tint: Theme.ice, strength: 0.6)
    }

    private var protectionsRow: some View {
        let s = model.settings
        return WrappingRow(spacing: 8) {
            pill(jitLabel, on: jitHardened)
            pill("HTTPS only", on: s.httpsOnly)
            pill("Ad & tracker blocking", on: s.blockAds)
            pill("Fingerprint defence", on: s.resistFingerprinting)
            pill("Link cleaning", on: s.stripTrackingParameters)
            pill("3rd-party cookies blocked", on: s.blockThirdPartyCookies)
        }
    }

    /// Reports what the engine is actually doing: before macOS 26.4 there is no
    /// JIT-only switch, so "Hardened" cannot take effect there.
    private var jitHardened: Bool {
        switch model.settings.javaScriptHardening {
        case .standard: return false
        case .lockdown: return true
        case .hardened:
            if #available(macOS 26.4, *) { return true }
            return false
        }
    }

    private var jitLabel: String {
        model.settings.javaScriptHardening == .lockdown ? "Lockdown mode" : "JIT disabled"
    }

    private func pill(_ title: String, on: Bool) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(on ? Theme.iceAccent : Theme.warning)
                .frame(width: 6, height: 6)
                .iceGlow(on ? Theme.ice : Theme.warning, radius: 3)
            Text(title).font(.system(size: 11)).lineLimit(1).fixedSize()
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .iceGlass(Capsule(), strength: 0.5)
        .foregroundStyle(on ? .secondary : .primary)
    }
}

/// Lays children out left to right, wrapping to new centred rows as needed.
struct WrappingRow: Layout {
    var spacing: CGFloat = 8

    private func rows(_ subviews: Subviews, width: CGFloat) -> [[(Int, CGSize)]] {
        var rows: [[(Int, CGSize)]] = [[]]
        var x: CGFloat = 0
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > width, !rows[rows.count - 1].isEmpty { rows.append([]); x = 0 }
            rows[rows.count - 1].append((i, size))
            x += size.width + spacing
        }
        return rows
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .greatestFiniteMagnitude
        let laidOut = rows(subviews, width: width)
        let height = laidOut.reduce(0) { $0 + ($1.map(\.1.height).max() ?? 0) } + spacing * CGFloat(max(0, laidOut.count - 1))
        let widest = laidOut.map { $0.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(0, $0.count - 1)) }.max() ?? 0
        return CGSize(width: min(widest, width), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in rows(subviews, width: bounds.width) {
            let rowWidth = row.reduce(0) { $0 + $1.1.width } + spacing * CGFloat(max(0, row.count - 1))
            var x = bounds.minX + (bounds.width - rowWidth) / 2
            let rowHeight = row.map(\.1.height).max() ?? 0
            for (index, size) in row {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + spacing
        }
    }
}
