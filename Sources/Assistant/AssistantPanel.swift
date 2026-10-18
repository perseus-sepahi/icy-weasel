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
            Divider().opacity(0.4)
            if case .unavailable(let reason) = assistant.status, assistant.messages.isEmpty {
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

    private func header(_ assistant: PageAssistant) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(Theme.iceGradient).iceGlow(Theme.ice, radius: 5)
            Text("Ask about this page").font(.system(size: 13, weight: .semibold))
            Spacer()
            if !assistant.models.isEmpty {
                Picker("Model", selection: Binding(get: { assistant.selectedModel }, set: { assistant.selectedModel = $0 })) {
                    ForEach(assistant.models, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().controlSize(.small).frame(maxWidth: 130)
            }
            Button { assistant.clear() } label: { Image(systemName: "trash") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear conversation")
            Button { model.showAssistant = false } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Close")
        }
        .padding(.horizontal, 12).frame(height: 40)
    }

    private func unavailable(_ reason: String, _ assistant: PageAssistant) -> some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "cpu").font(.system(size: 30, weight: .light)).foregroundStyle(.secondary)
            Text(reason).font(.system(size: 12)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).textSelection(.enabled)
            Button("Check Again") { Task { await assistant.refreshModels() } }.controlSize(.small)
            Spacer()
        }
        .padding(20).frame(maxHeight: .infinity)
    }

    private func conversation(_ assistant: PageAssistant) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if assistant.messages.isEmpty { intro }
                    ForEach(assistant.messages) { message in bubble(message, assistant) }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
            }
            .onChange(of: assistant.messages.last?.text) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
        }
        .frame(maxHeight: .infinity)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Runs on this Mac. The page never leaves it.", systemImage: "lock.shield")
                .font(.system(size: 11)).foregroundStyle(.secondary)
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
