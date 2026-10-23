import SwiftUI

/// The "ask about this page" side panel, opened from the sparkle button at the
/// top right of the toolbar.
struct AssistantPanel: View {
    @Bindable var model: BrowserViewModel
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        let assistant = model.assistant
        VStack(spacing: 0) {
            header(assistant)
            if let choice = assistant.selected, !choice.source.isLocal {
                cloudBanner(choice)
            }
            Divider().opacity(0.4)
            if let request = assistant.consentRequest {
                consent(request, assistant)
            } else if case .unavailable(let reason) = assistant.status, assistant.messages.isEmpty {
                unavailable(reason, assistant)
            } else {
                conversation(assistant)
            }
            Divider().opacity(0.4)
            composer(assistant)
        }
        .frame(width: 360)
        .background(IceBackdrop().opacity(0.9))
        .overlay(alignment: .leading) {
            LinearGradient(colors: [Theme.rim.opacity(0.6), Theme.ice.opacity(0.3)], startPoint: .top, endPoint: .bottom)
                .frame(width: 1)
        }
        .task { await assistant.refreshModels() }
        .onAppear { focused = true }
    }

    // MARK: Header and model menu

    private func header(_ assistant: PageAssistant) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Theme.iceGradient).iceGlow(Theme.ice, radius: 5)
            Text("Ask about this page").font(.system(size: 13, weight: .semibold))
                .lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            modelMenu(assistant)
            Button { assistant.clear() } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear conversation")
            Button { model.showAssistant = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Close")
        }
        .padding(.horizontal, 12).frame(height: 40)
    }

    private func modelMenu(_ assistant: PageAssistant) -> some View {
        Menu {
            if !assistant.localChoices.isEmpty {
                Section("On this Mac") {
                    ForEach(assistant.localChoices) { choice in item(choice, assistant) }
                }
            }
            if !assistant.cloudChoices.isEmpty {
                Section("Cloud, with your API key") {
                    // One submenu per provider: OpenRouter alone lists hundreds of models.
                    ForEach(Dictionary(grouping: assistant.cloudChoices, by: \.source.name).sorted { $0.key < $1.key },
                            id: \.key) { name, models in
                        Menu(name) {
                            let free = models.filter(\.isFree), paid = models.filter { !$0.isFree }
                            if !free.isEmpty {
                                Section("Free") { ForEach(free) { item($0, assistant, showSource: false) } }
                            }
                            if !paid.isEmpty {
                                Section(free.isEmpty ? "" : "Paid") { ForEach(paid) { item($0, assistant, showSource: false) } }
                            }
                        }
                    }
                }
            }
            if !assistant.stoppedApps.isEmpty || !assistant.stoppedLaunchers.isEmpty {
                Section("Not running") {
                    ForEach(assistant.stoppedApps, id: \.self) { app in Button("Start \(app.name)") { assistant.start(app) } }
                    ForEach(assistant.stoppedLaunchers) { launcher in Button("Start \(launcher.name)") { assistant.start(launcher) } }
                }
            }
            Divider()
            Button("Look for Models Again") { Task { await assistant.refreshModels() } }
            SettingsLink { Text("AI Settings…") }
        } label: {
            Text(assistant.selected.map { $0.displayName } ?? (assistant.status == .checking ? "Looking…" : "No model"))
                .font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
        }
        .menuStyle(.borderlessButton).frame(maxWidth: 120)
        .help("Choose the AI model")
    }

    private func item(_ choice: AIModelChoice, _ assistant: PageAssistant, showSource: Bool = true) -> some View {
        let title = showSource ? "\(choice.displayName)  (\(choice.source.name))" : choice.displayName
        return Button {
            assistant.select(choice)
        } label: {
            if choice.id == assistant.selected?.id {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    /// Always visible while a cloud model is selected: the page leaves the Mac.
    private func cloudBanner(_ choice: AIModelChoice) -> some View {
        Label("Sends the page to \(choice.source.destinationHost)", systemImage: "icloud.and.arrow.up")
            .font(.system(size: 11)).foregroundStyle(Theme.warning)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.bottom, 6)
    }

    // MARK: States

    private func consent(_ request: PageAssistant.ConsentRequest, _ assistant: PageAssistant) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Spacer()
            Image(systemName: "icloud.and.arrow.up").font(.system(size: 26, weight: .light)).foregroundStyle(Theme.warning)
            Text("Send this page to \(request.providerName)?").font(.system(size: 14, weight: .semibold))
            Text("""
                The text of the page you're reading and your questions go to \(request.host) using your API key, \
                and that provider's privacy policy applies. Local models keep everything on this Mac.
                """)
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Don't Send") { assistant.declineCloud() }
                Button("Send to \(request.providerName)") { assistant.allowCloud() }.keyboardShortcut(.defaultAction)
            }
            .controlSize(.regular)
            Text("You'll only be asked once for \(request.providerName).").font(.system(size: 10)).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(20).frame(maxHeight: .infinity)
    }

    private func unavailable(_ reason: String, _ assistant: PageAssistant) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "cpu").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text(reason).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).textSelection(.enabled)
            ForEach(assistant.stoppedApps, id: \.self) { app in
                Button("Start \(app.name)") { assistant.start(app) }.controlSize(.regular)
            }
            ForEach(assistant.stoppedLaunchers) { launcher in
                Button("Start \(launcher.name)") { assistant.start(launcher) }.controlSize(.regular)
            }
            HStack {
                Button("Check Again") { Task { await assistant.refreshModels() } }
                SettingsLink { Text("AI Settings…") }
            }
            .controlSize(.small)
            Spacer()
        }
        .padding(20).frame(maxHeight: .infinity)
    }

    private func conversation(_ assistant: PageAssistant) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if assistant.messages.isEmpty { intro(assistant) }
                    ForEach(assistant.messages) { message in bubble(message, assistant) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
            }
            .onChange(of: assistant.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(maxHeight: .infinity)
    }

    private func intro(_ assistant: PageAssistant) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if let choice = assistant.selected, !choice.source.isLocal {
                Label("Uses \(choice.source.name) with your API key.", systemImage: "key")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            } else {
                Label("Runs on this Mac. The page never leaves it.", systemImage: "lock.shield")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            ForEach(["Summarize this page", "What are the key points?", "Explain the selected text simply",
                     "What claims here should I be skeptical of?"], id: \.self) { prompt in
                Button { send(prompt) } label: {
                    Text(prompt).font(.system(size: 12)).frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .iceGlass(RoundedRectangle(cornerRadius: 12, style: .continuous), strength: 0.6, interactive: true)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func bubble(_ message: PageAssistant.Message, _ assistant: PageAssistant) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 40) }
            Group {
                if message.text.isEmpty && assistant.isGenerating {
                    ProgressView().controlSize(.small)
                } else {
                    Text(LocalizedStringKey(message.text)).font(.system(size: 12.5)).textSelection(.enabled)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .iceGlass(RoundedRectangle(cornerRadius: 14, style: .continuous),
                      tint: isUser ? Theme.iceDeep : Theme.ice, strength: isUser ? 1.6 : 0.5)
            if !isUser { Spacer(minLength: 16) }
        }
    }

    private func composer(_ assistant: PageAssistant) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if !assistant.contextNote.isEmpty {
                Text(assistant.contextNote).font(.system(size: 10)).foregroundStyle(.tertiary).lineLimit(1)
            }
            HStack(spacing: 8) {
                TextField("Ask anything about this page", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain).font(.system(size: 13)).lineLimit(1...4)
                    .tint(Theme.selection)
                    .focused($focused).onSubmit { send(draft) }
                if assistant.isGenerating {
                    Button { assistant.stop() } label: { Image(systemName: "stop.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(Theme.warning).help("Stop")
                } else {
                    Button { send(draft) } label: { Image(systemName: "arrow.up.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(draft.isEmpty ? Color.secondary : Theme.iceDeep)
                        .disabled(draft.isEmpty)
                }
            }
            .font(.system(size: 18))
        }
        .padding(10)
    }

    private func send(_ text: String) {
        model.assistant.ask(text, webView: model.selectedTab?.webView)
        draft = ""
    }
}
