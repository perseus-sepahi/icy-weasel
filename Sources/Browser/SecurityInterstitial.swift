import SwiftUI

struct SecurityInterstitial: View {
    let issue: Tab.SecurityIssue
    let tab: Tab
    @Bindable var model: BrowserViewModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: icon)
                .font(.system(size: 46, weight: .light))
                .foregroundStyle(Theme.warning)

            Text(issue.summary)
                .font(.system(size: 20, weight: .semibold))

            Text(explanation)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            HStack(spacing: 12) {
                Button("Go Back") {
                    tab.securityIssue = nil
                    if tab.canGoBack { tab.goBack() } else { model.close(tab) }
                }
                .keyboardShortcut(.defaultAction)

                // Only plaintext can be relaxed. There is intentionally no
                // "proceed anyway" for an invalid certificate — that is the one
                // warning users are best protected from being able to click past.
                if case .loadFailed(let url?, _) = issue {
                    Button("Try Again") {
                        tab.securityIssue = nil
                        tab.load(url)
                    }
                }

                if case .insecureTransport(let url) = issue {
                    Button("Allow HTTP for this site") {
                        model.policyStore.update(url: url) { $0.httpsOnly = false }
                        tab.securityIssue = nil
                        tab.applyPolicyChange()
                        tab.load(url)
                    }
                }
            }
            .controlSize(.large)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(IceBackdrop())
    }

    private var icon: String {
        switch issue {
        case .insecureTransport: return "lock.open.trianglebadge.exclamationmark"
        case .certificateInvalid: return "exclamationmark.shield.fill"
        case .loadFailed: return "wifi.exclamationmark"
        }
    }

    private var explanation: String {
        switch issue {
        case .insecureTransport(let url):
            return "\(url.host ?? "This site") could not be reached over an encrypted connection. "
                + "Anyone on your network could read or alter what you send and receive."
        case .certificateInvalid:
            return "The site's identity could not be verified. This can mean someone is "
                + "impersonating it. Icy Weasel will not load it."
        case .loadFailed(let url, let reason):
            return "\(url?.host ?? "The site") couldn't be reached. \(reason)"
        }
    }
}
