import SwiftUI
import AppKit
import LocalAuthentication
import UniformTypeIdentifiers

/// "Save password?" under the toolbar after the user signs in.
struct PasswordSaveBar: View {
    let tab: Tab
    let offer: Tab.PasswordOffer

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill").foregroundStyle(Theme.iceAccent)
            Text(offer.isUpdate ? "Update the saved password for \(label) on \(offer.host)?"
                                : "Save the password for \(label) on \(offer.host)?")
                .font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Button("Never for This Site") { tab.neverSavePasswords() }.controlSize(.small)
            Button("Not Now") { tab.dismissPasswordOffer() }.controlSize(.small)
            Button(offer.isUpdate ? "Update" : "Save") { tab.savePasswordOffer() }
                .controlSize(.small).keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 7)
        .background(Theme.ice.opacity(0.12))
    }

    private var label: String { offer.username.isEmpty ? "this account" : offer.username }
}

/// The key in the address bar: fills a saved sign-in, only when clicked.
struct PasswordFillButton: View {
    let tab: Tab

    var body: some View {
        Menu {
            ForEach(tab.availableLogins) { login in
                Button("Fill \(login.username.isEmpty ? "password" : login.username)") { Task { await tab.fill(login) } }
            }
            Divider()
            SettingsLink { Text("Manage Passwords…") }
        } label: {
            Image(systemName: "key.fill").font(.system(size: 11))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .foregroundStyle(Theme.iceAccent)
        .help("Fill a saved password")
    }
}

/// Settings > Passwords.
struct PasswordSettingsView: View {
    @Environment(AppServices.self) private var services
    @State private var logins: [SavedLogin] = []
    @State private var search = ""
    @State private var revealed: [String: String] = [:]
    @State private var importResult: String?

    var body: some View {
        @Bindable var settings = services.settings
        Form {
            Section {
                Toggle("Offer to save passwords", isOn: $settings.offerToSavePasswords)
            } footer: {
                Text("""
                    Passwords are stored in your Mac's login keychain, encrypted by macOS, and filled only when you \
                    click the key in the address bar, on the exact site they were saved for. Private windows never save.
                    """)
            }

            Section {
                TextField("Search", text: $search)
                if filtered.isEmpty {
                    Text(logins.isEmpty ? "No saved passwords yet." : "No matches.").foregroundStyle(.secondary)
                }
                ForEach(filtered) { login in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(login.host).font(.system(size: 13, weight: .medium))
                            Text(login.username.isEmpty ? "(no username)" : login.username)
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                            if let shown = revealed[login.id] {
                                Text(verbatim: shown).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                            }
                        }
                        Spacer()
                        Button(revealed[login.id] == nil ? "Show" : "Hide") { Task { await toggleReveal(login) } }
                        Button("Copy") { Task { await copy(login) } }
                        Button("Delete") { PasswordStore.delete(login); reload() }
                    }
                }
            } header: {
                Text("Saved passwords")
            }

            Section {
                HStack {
                    Button("Import Passwords…") { importCSV() }
                    if let importResult { Text(importResult).font(.system(size: 11)).foregroundStyle(.secondary) }
                }
            } header: {
                Text("Import")
            } footer: {
                Text("""
                    Google only syncs passwords inside Chrome, so they can't sync here directly. To bring them over, \
                    export them as a CSV file from passwords.google.com (or from Safari: File > Export > Passwords) \
                    and import it here. Delete the CSV afterwards: it holds your passwords in plain text.
                    """)
            }

            if !settings.neverSavePasswordHosts.isEmpty {
                Section("Never saved for") {
                    ForEach(settings.neverSavePasswordHosts, id: \.self) { host in
                        HStack {
                            Text(host)
                            Spacer()
                            Button("Remove") { settings.neverSavePasswordHosts.removeAll { $0 == host } }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reload)
    }

    private var filtered: [SavedLogin] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? logins : logins.filter { $0.host.contains(q) || $0.username.lowercased().contains(q) }
    }

    private func reload() { logins = PasswordStore.logins(); revealed = [:] }

    /// Showing or copying a password asks for the Mac's password or Touch ID first.
    private func authenticate(_ reason: String) async -> Bool {
        let context = LAContext()
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true
    }

    private func toggleReveal(_ login: SavedLogin) async {
        if revealed[login.id] != nil { revealed[login.id] = nil; return }
        guard await authenticate("show the password for \(login.host)"),
              let password = PasswordStore.password(for: login) else { return }
        revealed[login.id] = password
    }

    private func copy(_ login: SavedLogin) async {
        guard await authenticate("copy the password for \(login.host)"),
              let password = PasswordStore.password(for: login) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(password, forType: .string)
    }

    private func importCSV() {
        let panel = NSOpenPanel()
        panel.message = "Choose a password export (CSV) from Google Password Manager, Chrome, Safari or another password manager."
        panel.allowedContentTypes = [.commaSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let (rows, skipped) = PasswordImport.parse(text)
        let saved = rows.filter { PasswordStore.save(host: $0.host, username: $0.username, password: $0.password) }.count
        importResult = "Imported \(saved) password\(saved == 1 ? "" : "s")" + (skipped > 0 ? ", skipped \(skipped)." : ".")
        reload()
    }
}
