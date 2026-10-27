import SwiftUI
import WebKit

struct SettingsView: View {
    var body: some View {
        TabView {
            ProtectionSettings()
                .tabItem { Label("Protection", systemImage: "shield.lefthalf.filled") }
            FilterListSettings()
                .tabItem { Label("Filter Lists", systemImage: "list.bullet.rectangle") }
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            AISettingsView()
                .tabItem { Label("AI", systemImage: "sparkles") }
            PasswordSettingsView()
                .tabItem { Label("Passwords", systemImage: "key") }
            PrivacyDataSettings()
                .tabItem { Label("Data", systemImage: "externaldrive.badge.xmark") }
        }
        .frame(width: 580, height: 560)
    }
}

private struct ProtectionSettings: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var settings = services.settings
        Form {
            Section {
                Toggle("Block ads and trackers", isOn: $settings.blockAds)
                Toggle("HTTPS-only mode", isOn: $settings.httpsOnly)
                Toggle("Block third-party cookies", isOn: $settings.blockThirdPartyCookies)
                Toggle("Resist fingerprinting", isOn: $settings.resistFingerprinting)
                Toggle("Strip tracking parameters from links", isOn: $settings.stripTrackingParameters)
            } header: {
                Text("Defaults for every site")
            } footer: {
                Text("Any of these can be relaxed for a single site from the shield in the toolbar.")
            }

            Section {
                Picker("JavaScript engine", selection: $settings.javaScriptHardening) {
                    ForEach(JavaScriptHardening.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                Text(settings.javaScriptHardening.detail)
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Enable JavaScript", isOn: $settings.javaScriptEnabled)
            } header: {
                Text("JavaScript")
            } footer: {
                Text("Hardened mode removes the JIT compiler — the part of every browser most often used in real exploits. Pages that are mostly content feel the same; heavy web apps (editors, spreadsheets, games) can run many times slower, so give those full speed from the shield instead of lowering this for every site.")
            }

            Section("Signals") {
                Toggle("Send Global Privacy Control", isOn: $settings.globalPrivacyControl)
                Text("Tells sites not to sell or share your data. Legally binding in some jurisdictions, including California. Requires macOS 27.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.blockAds) { services.reapplyEverywhere() }
        .onChange(of: settings.httpsOnly) { services.reapplyEverywhere() }
        .onChange(of: settings.javaScriptEnabled) { services.reapplyEverywhere() }
        .onChange(of: settings.resistFingerprinting) { services.reapplyEverywhere() }
        .onChange(of: settings.blockThirdPartyCookies) { services.reapplyEverywhere() }
        .onChange(of: settings.javaScriptHardening) { services.reapplyEverywhere() }
        .onChange(of: settings.globalPrivacyControl) { services.reapplyEverywhere() }
    }
}

private struct FilterListSettings: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var settings = services.settings
        let engine = services.blocking

        Form {
            Section {
                ForEach(FilterListCatalog.all) { source in
                    Toggle(isOn: Binding(
                        get: { settings.enabledFilterLists.contains(source.id) },
                        set: { on in
                            if on { settings.enabledFilterLists.insert(source.id) }
                            else { settings.enabledFilterLists.remove(source.id) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(source.title)
                            Text(source.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Subscriptions")
                    Spacer()
                    Button("Update Now") { Task { await engine.refresh(force: true) } }
                        .controlSize(.small)
                }
            } footer: {
                statusFooter(engine: engine, settings: settings)
            }

            Section("Custom rules") {
                TextEditor(text: $settings.customFilters)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 90)
                Text("Adblock Plus syntax, e.g. ||example.com^ or example.com##.banner")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func statusFooter(engine: BlockingEngine, settings: BrowserSettings) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            switch engine.state {
            case .ready(let rules, let lists):
                Text("\(rules.formatted()) rules active across \(lists) compiled lists. "
                     + "\(engine.stats.rejected.formatted()) rules skipped (unsupported syntax such as scriptlets and procedural cosmetics).")
            case .loading(let m): Text(m)
            case .failed(let m):  Text("Error: \(m)").foregroundStyle(Theme.danger)
            case .idle:           Text("Not loaded")
            }
            if let date = settings.lastFilterUpdate {
                Text("Last updated \(date.formatted(.relative(presentation: .named)))")
            }
        }
    }
}

private struct GeneralSettings: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var settings = services.settings
        Form {
            Section {
                Picker("Default search engine", selection: $settings.searchEngine) {
                    ForEach(SearchEngine.allCases) { engine in
                        Text(engine.isPrivate || engine == .custom ? engine.title : "\(engine.title) (tracks searches)")
                            .tag(engine)
                    }
                }
                if settings.searchEngine == .custom {
                    TextField("https://example.com/search?q=%s", text: $settings.customSearchTemplate)
                        .font(.system(size: 12, design: .monospaced))
                    let t = settings.customSearchTemplate
                    if !(t.lowercased().hasPrefix("https://") && t.contains("%s")) {
                        Text("Needs an https:// address containing %s where the query goes. Until then, searches use DuckDuckGo.")
                            .font(.caption).foregroundStyle(Theme.warning)
                    }
                }
            } header: {
                Text("Search")
            } footer: {
                Text("Address-bar suggestions come only from your own history and bookmarks. Keystrokes are never sent to a search engine.")
            }

            Section("Look") {
                Picker("Appearance", selection: $settings.appearance) {
                    Text("Match System").tag("system")
                    Text("Frost (light)").tag("light")
                    Text("Glacier (dark)").tag("dark")
                }
                .onChange(of: settings.appearance) { settings.applyAppearance() }
            }

            Section("Startup") {
                Toggle("Restore tabs and groups from last time", isOn: $settings.restoreSession)
            }
            Section {
                Toggle("Put idle tabs to sleep", isOn: $settings.hibernateTabs)
                Stepper("After \(settings.hibernateAfterMinutes) minutes",
                        value: $settings.hibernateAfterMinutes, in: 1...120)
                    .disabled(!settings.hibernateTabs)
            } header: {
                Text("Performance")
            } footer: {
                Text("A sleeping tab releases its web content process — typically 60–150 MB — and restores its history and scroll position when you return.")
            }
            Section("Windows") {
                Toggle("Open every window as private", isOn: $settings.ephemeralByDefault)
            }
            ReadAloudSettings(settings: settings)
        }
        .formStyle(.grouped)
    }
}

private struct ReadAloudSettings: View {
    @Bindable var settings: BrowserSettings
    @State private var preview: PageReader?
    @State private var previewLanguage: String?
    private let download = PhononModelDownload.shared

    private static let samples = [
        "en": "This is how pages sound when Icy Weasel reads them to you.",
        "fr": "Voici comment Icy Weasel vous lit les pages.",
        "de": "So klingen Seiten, wenn Icy Weasel sie Ihnen vorliest.",
        "es": "Así suenan las páginas cuando Icy Weasel te las lee.",
        "pt": "É assim que as páginas soam quando o Icy Weasel as lê para você.",
    ]

    /// The Phonon model whose voices to offer: the chosen one, or the
    /// built-in English one while the multilingual download is missing.
    private var voiceModel: PhononModel? {
        guard let chosen = settings.readAloudEngine.model else { return nil }
        if chosen.isAvailable { return chosen }
        return PhononModel.english31m.isAvailable ? .english31m : nil
    }

    var body: some View {
        Section {
            if PhononEngine.canRun {
                Picker("Voice model", selection: $settings.readAloudEngine) {
                    ForEach(ReadAloudEngine.offered) { Text($0.title).tag($0) }
                }
                if settings.readAloudEngine == .phonon40mMultilingual {
                    multilingualDownload
                }
            }
            if let model = voiceModel {
                ForEach(model.languages, id: \.self) { language in
                    voiceRow(model: model, language: language)
                }
            } else {
                HStack {
                    Text("Apple's voice, in each page's language").foregroundStyle(.secondary)
                    Spacer()
                    listenButton("en")
                }
            }
            Picker("Speed", selection: $settings.readAloudRate) {
                ForEach([0.75, 1.0, 1.25, 1.5, 1.75, 2.0], id: \.self) { rate in
                    Text(rate == 1 ? "Normal" : String(format: "%g×", rate)).tag(rate)
                }
            }
        } header: {
            Text("Read Aloud")
        } footer: {
            Text(footer)
        }
        // Choosing a model lets you hear it straight away.
        .onChange(of: settings.readAloudEngine) { playSample("en") }
        .onDisappear { preview?.stop() }
    }

    private var footer: String {
        let how = "Read a page with the speaker in the toolbar or ⌥⌘R. It is read in the page's language, on this Mac; nothing is sent anywhere."
        guard PhononEngine.canRun else {
            return "Pages are read with Apple's voices; add more in System Settings › Accessibility › Spoken Content. " + how
        }
        return "Phonon is Gradium's open voice model. Languages the chosen model doesn't speak are read by Apple's voice. " + how
    }

    private func voiceRow(model: PhononModel, language: String) -> some View {
        let name = Locale.current.localizedString(forLanguageCode: language) ?? language
        let binding = Binding<String>(
            get: { PhononEngine.voice(of: model, language: language, preferred: settings.readAloudVoices[language]) ?? "" },
            set: { voice in
                settings.readAloudVoices[language] = voice
                // Choosing a voice plays it, so the menu doubles as a sampler.
                playSample(language)
            })
        return HStack {
            Picker(model.languages.count > 1 ? name : "Voice", selection: binding) {
                ForEach(PhononEngine.voices(of: model).filter { $0.language == language }) { voice in
                    Text(voice.label).tag(voice.name)
                }
            }
            listenButton(language)
        }
    }

    private func listenButton(_ language: String) -> some View {
        let playing = preview?.isActive == true && previewLanguage == language
        return Button(playing ? "Stop" : "Listen") {
            if playing { preview?.stop() } else { playSample(language) }
        }
    }

    /// Says the sample line in the voice now chosen for `language`, cutting
    /// off any sample still playing.
    private func playSample(_ language: String) {
        let reader = preview ?? PageReader(settings: settings)
        preview = reader
        reader.stop()
        previewLanguage = language
        reader.speak([Self.samples[language] ?? Self.samples["en"]!], language: language)
    }

    @ViewBuilder
    private var multilingualDownload: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch download.state {
            case .missing:
                HStack {
                    Text("Not downloaded. Until it is, English pages use Phonon 31M.").foregroundStyle(.secondary)
                    Spacer()
                    Button("Download (\(download.sizeDescription))") { download.start() }
                }
            case .downloading(let fraction):
                HStack {
                    ProgressView(value: fraction)
                    Button("Cancel") { download.cancel() }
                }
            case .installing:
                HStack { ProgressView().controlSize(.small); Text("Checking and unpacking…").foregroundStyle(.secondary) }
            case .ready:
                HStack {
                    Label("Downloaded", systemImage: "checkmark.circle").foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove") { download.remove() }
                }
            case .failed(let message):
                HStack {
                    Text(message).foregroundStyle(Theme.warning)
                    Spacer()
                    Button("Try Again") { download.start() }
                }
            }
            Text("English, French, German, Spanish and Portuguese. Free for non-commercial use only (CC BY-NC 4.0, by Gradium); it is a separate download, not part of Icy Weasel's licence.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct PrivacyDataSettings: View {
    @Environment(AppServices.self) private var services
    @State private var clearing = false
    @State private var lastCleared: Date?

    var body: some View {
        Form {
            Section {
                Button(role: .destructive) {
                    clearing = true
                    let types = WKWebsiteDataStore.allWebsiteDataTypes()
                    WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast) {
                        clearing = false
                        lastCleared = Date()
                    }
                } label: {
                    HStack {
                        Text("Clear all cookies, caches and site data")
                        if clearing { ProgressView().controlSize(.small) }
                    }
                }
                if let lastCleared {
                    Text("Cleared \(lastCleared.formatted(date: .omitted, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } footer: {
                Text("Private windows never write site data to disk, so there is nothing to clear for them.")
            }

            Section("Per-site exceptions") {
                let sites = services.policyStore.customisedSites
                if sites.isEmpty {
                    Text("No sites have relaxed protections.").foregroundStyle(.secondary)
                } else {
                    ForEach(sites, id: \.self) { site in
                        Text(site)
                    }
                    Button("Remove all exceptions", role: .destructive) {
                        services.policyStore.clearAll()
                        services.reapplyEverywhere()
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
