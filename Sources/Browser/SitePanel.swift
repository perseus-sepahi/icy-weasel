import SwiftUI

/// Per-site controls — the "escape hatch" half of the security posture.
struct SitePanel: View {
    @Bindable var model: BrowserViewModel

    var body: some View {
        let tab = model.selectedTab
        let policy = tab?.policy ?? .permissive
        let site = PublicSuffix.registrableDomain(of: tab?.url)

        VStack(alignment: .leading, spacing: 14) {
            header(site: site, tab: tab)

            if site != nil {
                Divider()
                VStack(spacing: 10) {
                    toggle("Block ads & trackers", systemImage: "hand.raised.fill",
                           isOn: policy.blockAds) { v in model.updateSitePolicy { $0.blockAds = v } }
                    toggle("HTTPS only", systemImage: "lock.fill",
                           isOn: policy.httpsOnly) { v in model.updateSitePolicy { $0.httpsOnly = v } }
                    toggle("Block third-party cookies", systemImage: "circle.hexagongrid.fill",
                           isOn: policy.blockThirdPartyCookies) { v in model.updateSitePolicy { $0.blockThirdPartyCookies = v } }
                    toggle("Resist fingerprinting", systemImage: "touchid",
                           isOn: policy.resistFingerprinting) { v in model.updateSitePolicy { $0.resistFingerprinting = v } }
                    toggle("Allow pop-ups", systemImage: "rectangle.on.rectangle",
                           isOn: policy.allowPopups) { v in model.updateSitePolicy { $0.allowPopups = v } }
                    toggle("Allow JavaScript", systemImage: "curlybraces",
                           isOn: policy.javaScript) { v in model.updateSitePolicy { $0.javaScript = v } }
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label("JavaScript engine", systemImage: "cpu")
                        .font(.system(size: 12))
                    Picker("JavaScript engine", selection: Binding(
                        get: { policy.javaScriptHardening },
                        set: { level in model.updateSitePolicy { $0.javaScriptHardening = level } }
                    )) {
                        Text("Full speed").tag(JavaScriptHardening.standard)
                        Text("Hardened").tag(JavaScriptHardening.hardened)
                        Text("Lockdown").tag(JavaScriptHardening.lockdown)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .controlSize(.small)
                    Text(policy.javaScriptHardening.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if policy.isCustomised {
                    Divider()
                    Button {
                        model.resetSitePolicy()
                    } label: {
                        Label("Reset to global defaults", systemImage: "arrow.uturn.backward")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.iceDeep)
                }
            }

            Divider()
            engineStatus
        }
        .padding(16)
        .frame(width: 300)
    }

    private func header(site: String?, tab: Tab?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(site ?? "No site loaded")
                .font(.system(size: 15, weight: .semibold))
            if let tab {
                HStack(spacing: 12) {
                    stat(value: tab.blockedEstimate, label: "blocked (est.)")
                    stat(value: tab.strippedParameters.count, label: "params stripped")
                }
            }
        }
    }

    private func stat(value: Int, label: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text("\(value)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.iceDeep)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    private func toggle(_ title: String, systemImage: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 12))
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    @ViewBuilder
    private var engineStatus: some View {
        let engine = model.blocking
        HStack(spacing: 6) {
            switch engine.state {
            case .idle:
                Image(systemName: "circle.dotted").foregroundStyle(.secondary)
                Text("Blocker idle")
            case .loading(let message):
                ProgressView().controlSize(.mini)
                Text(message)
            case .ready(let rules, let lists):
                Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.ice)
                Text("\(rules.formatted()) rules in \(lists) compiled list\(lists == 1 ? "" : "s")")
            case .failed(let message):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.danger)
                Text(message).lineLimit(2)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
    }
}
