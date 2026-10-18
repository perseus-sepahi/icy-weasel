import SwiftUI
import WebKit

struct FindBar: View {
    @Bindable var model: BrowserViewModel
    @FocusState private var focused: Bool
    @State private var found: Bool?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in page", text: $model.findText)
                .textFieldStyle(.plain)
                .tint(Theme.selection)
                .focused($focused)
                .onSubmit { search(backwards: NSEvent.modifierFlags.contains(.shift)) }
                .frame(maxWidth: 260)
            if found == false {
                Text("Not found").font(.system(size: 11)).foregroundStyle(Theme.warning)
            }
            Button { search(backwards: true) } label: { Image(systemName: "chevron.up") }
                .buttonStyle(.plain).help("Previous (⇧⏎)")
            Button { search(backwards: false) } label: { Image(systemName: "chevron.down") }
                .buttonStyle(.plain).help("Next (⏎)")
            Spacer()
            Button("Done") { model.showFindBar = false }
                .buttonStyle(.plain)
                .keyboardShortcut(.escape, modifiers: [])
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Theme.chromeTint.opacity(0.35))
        .onAppear { focused = true }
        .onChange(of: model.findText) { _, _ in search(backwards: false) }
    }

    private func search(backwards: Bool) {
        guard let webView = model.selectedTab?.webView, !model.findText.isEmpty else { found = nil; return }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        webView.find(model.findText, configuration: configuration) { result in
            found = result.matchFound
        }
    }
}
