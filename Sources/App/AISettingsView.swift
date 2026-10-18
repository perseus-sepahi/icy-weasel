import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Settings > AI: what's running on this Mac, extra local servers, and cloud
/// providers with the user's own API key.
struct AISettingsView: View {
    @Environment(AppServices.self) private var services
    @State private var detected: [AIModelChoice] = []
    @State private var scanning = false
    @State private var newLocal = ""

    @State private var preset: CloudPreset = .openAI
    @State private var customName = ""
    @State private var customBaseURL = ""
    @State private var apiKey = ""
    @State private var manualModel = ""
    @State private var addResult: String?
    @State private var adding = false

    var body: some View {
        @Bindable var settings = services.settings
        Form {
            localSection(settings)
            cloudSection(settings)
            addSection(settings)
        }
        .formStyle(.grouped)
        .task { await scan() }
    }

    // MARK: On this Mac

    private func localSection(_ settings: BrowserSettings) -> some View {
        Section {
            if scanning && detected.isEmpty {
                HStack { ProgressView().controlSize(.small); Text("Looking for model servers…").foregroundStyle(.secondary) }
            } else if detected.isEmpty {
                Text("None running right now.").foregroundStyle(.secondary)
            } else {
                ForEach(Dictionary(grouping: detected, by: \.source.name).sorted { $0.key < $1.key }, id: \.key) { name, models in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 13, weight: .medium))
                        Text(models.map(\.displayName).joined(separator: ", ")).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            ForEach(settings.customLocalAIEndpoints, id: \.self) { endpoint in
                HStack {
                    Text(endpoint).font(.system(size: 12, design: .monospaced))
                    Spacer()
                    Button("Remove") { settings.customLocalAIEndpoints.removeAll { $0 == endpoint } }
                }
            }
            HStack {
                TextField("Other local server", text: $newLocal, prompt: Text(verbatim: "http://127.0.0.1:9000"))
                    .font(.system(size: 12, design: .monospaced))
                Button("Add") {
                    settings.customLocalAIEndpoints.append(newLocal.trimmingCharacters(in: .whitespaces))
                    newLocal = ""
                    Task { await scan() }
                }
                .disabled(LocalAIDiscovery.loopbackURL(newLocal) == nil)
            }
            ForEach(settings.localAILaunchers) { launcher in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start \(launcher.name)").font(.system(size: 13, weight: .medium))
                        Text(launcher.resolvedURL()?.path ?? "Script not found, choose it again")
                            .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                    }
                    Spacer()
                    Button("Remove") { settings.localAILaunchers.removeAll { $0.id == launcher.id } }
                }
            }
            HStack {
                Button("Add Start Script…") { chooseLauncher(settings) }
                Button(scanning ? "Looking…" : "Look Again") { Task { await scan() } }.disabled(scanning)
            }
        } header: {
            Text("On this Mac")
        } footer: {
            Text("""
                Detected automatically while running: Ollama, Bonsai, LM Studio, Jan, GPT4All and other servers with \
                an OpenAI-style API. New models appear by themselves. For a model that starts from a script, like \
                Bonsai (Bonsai-demo/scripts/start_llama_server.sh), add the script once and the assistant offers to \
                start it. Local models keep the page on your Mac.
                """)
        }
    }

    // MARK: Cloud

    private func cloudSection(_ settings: BrowserSettings) -> some View {
        Section {
            if settings.cloudAIProviders.isEmpty {
                Text("No cloud providers added.").foregroundStyle(.secondary)
            }
            ForEach(settings.cloudAIProviders) { config in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(config.name).font(.system(size: 13, weight: .medium))
                        Text(AIKeychain.load(config.id) == nil ? "No API key saved" : "API key saved in your keychain")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Remove") {
                        AIKeychain.delete(config.id)
                        settings.cloudAIProviders.removeAll { $0.id == config.id }
                        settings.cloudAIConsent.removeAll { $0 == "cloud:\(config.id)" }
                    }
                }
            }
        } header: {
            Text("Cloud, with your own API key")
        } footer: {
            Text("""
                Optional. A cloud model receives the text of the page you ask about, so the assistant asks before \
                the first send and shows where pages go. Private windows only use local models. Keys are stored \
                in your macOS keychain and sent only to their own provider over HTTPS.
                """)
        }
    }

    private func addSection(_ settings: BrowserSettings) -> some View {
        Section("Add a cloud provider") {
            Picker("Provider", selection: $preset) {
                ForEach(CloudPreset.allCases) { Text($0.title).tag($0) }
            }
            if preset == .custom {
                TextField("Name", text: $customName)
                TextField("API address", text: $customBaseURL, prompt: Text(verbatim: "https://api.example.com/v1"))
                    .font(.system(size: 12, design: .monospaced))
            }
            SecureField("API key", text: $apiKey)
            TextField("Model (optional, if the provider can't list them)", text: $manualModel)
            HStack {
                Button(adding ? "Checking…" : "Add Provider") { Task { await add(settings) } }
                    .disabled(adding || apiKey.isEmpty || draftConfig.baseURL == nil)
                if let addResult { Text(addResult).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            if preset == .custom, !customBaseURL.isEmpty, draftConfig.baseURL == nil {
                Text("The address must start with https:// so your key is never sent unencrypted.")
                    .font(.caption).foregroundStyle(Theme.warning)
            }
        }
    }

    private var draftConfig: CloudProviderConfig {
        CloudProviderConfig(preset: preset, customName: customName, customBaseURL: customBaseURL,
                            manualModel: manualModel.trimmingCharacters(in: .whitespaces))
    }

    // MARK: Actions

    private func chooseLauncher(_ settings: BrowserSettings) {
        let panel = NSOpenPanel()
        panel.message = "Choose the script that starts your model server, for example Bonsai-demo/scripts/start_llama_server.sh"
        panel.prompt = "Add"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.shellScript, .unixExecutable, .script, .item]
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Bonsai-demo/scripts")
        guard panel.runModal() == .OK, let url = panel.url,
              let bookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        else { return }
        let defaults = LocalAILauncher.defaults(for: url)
        settings.localAILaunchers.append(LocalAILauncher(name: defaults.name, bookmark: bookmark, port: defaults.port))
        Task { await scan() }
    }

    private func scan() async {
        scanning = true
        detected = await LocalAIDiscovery.discover(customEndpoints: services.settings.customLocalAIEndpoints,
                                                   launcherPorts: Set(services.settings.localAILaunchers.map(\.port)))
        scanning = false
    }

    private func add(_ settings: BrowserSettings) async {
        let config = draftConfig
        guard let source = config.source else { return }
        adding = true
        defer { adding = false }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let models = await LocalAIDiscovery.models(at: source, apiKey: key)
        guard !models.isEmpty || !config.manualModel.isEmpty else {
            addResult = "Couldn't list models with that key. Check the key, or enter a model name."
            return
        }
        guard AIKeychain.save(key, for: config.id) else {
            addResult = "Couldn't save the key to your keychain."
            return
        }
        settings.cloudAIProviders.append(config)
        addResult = models.isEmpty ? "Added, using \(config.manualModel)." : "Added, \(models.count) models available."
        apiKey = ""; manualModel = ""; customName = ""; customBaseURL = ""
    }
}
