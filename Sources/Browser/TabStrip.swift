import SwiftUI

struct TabStrip: View {
    @Bindable var model: BrowserViewModel
    @State private var hovered: Tab.ID?
    @State private var editingGroup: TabGroup.ID?

    /// Tabs in strip order, with a header wherever a group begins. Grouped tabs
    /// are kept contiguous by the model, so one pass is enough.
    private enum Item: Identifiable {
        case header(TabGroup), tab(Tab)
        var id: String {
            switch self { case .header(let g): return "g-\(g.id)"; case .tab(let t): return "t-\(t.id)" }
        }
    }

    private var items: [Item] {
        var out: [Item] = []
        var previous: UUID?
        for tab in model.tabs {
            let group = model.group(for: tab)
            if let group, group.id != previous { out.append(.header(group)) }
            previous = group?.id
            if group?.isCollapsed != true { out.append(.tab(tab)) }
        }
        return out
    }

    var body: some View {
        HStack(spacing: 0) {
            // Room for the window's traffic-light buttons.
            Color.clear.frame(width: 78)

            // No ScrollView: an NSScrollView in the title-bar region swallowed
            // clicks on tabs. Like Chrome and Safari, tabs shrink to fit instead.
            HStack(spacing: 2) {
                ForEach(items) { item in
                    switch item {
                    case .header(let group): groupChip(group).fixedSize()
                    case .tab(let tab): tabChip(tab)
                    }
                }
                // Right after the last tab, like Chrome, so it's where the eye
                // already is. Fixed size: tabs shrink to make room, never the +.
                newTabButton.fixedSize().padding(.leading, 2)
            }
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.isPrivateWindow {
                Label("Private", systemImage: "eye.slash.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.purple)
                    .padding(.horizontal, 10)
            }
        }
        .padding(.trailing, 6)
        .frame(height: Theme.tabHeight + 10)
    }

    private var newTabButton: some View {
        Button {
            model.openTab(url: nil, inBackground: false)
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .foregroundStyle(.secondary)
        .help("New Tab (⌘T)")
        .accessibilityLabel("New Tab")
        .accessibilityIdentifier("newTabButton")
    }

    private func tabChip(_ tab: Tab) -> some View {
        TabChip(
            tab: tab,
            isSelected: tab.id == model.selectedTab?.id,
            isHovered: hovered == tab.id,
            groupTint: model.group(for: tab)?.tint.color,
            onSelect: { model.select(tab) },
            onClose: { model.close(tab) }
        )
        .onHover { hovered = $0 ? tab.id : (hovered == tab.id ? nil : hovered) }
        .contextMenu {
            Button("New Tab to the Right") { model.openTab(url: nil, inBackground: false, inheritGroupFrom: tab) }
            Button("Duplicate") { model.duplicate(tab) }.disabled(tab.url == nil)
            Divider()
            Button("Add to New Group") { editingGroup = model.createGroup(with: tab).id }
            if !model.groups.filter({ $0.id != tab.groupID }).isEmpty {
                Menu("Add to Group") {
                    ForEach(model.groups.filter { $0.id != tab.groupID }) { group in
                        Button(group.name.isEmpty ? "Unnamed (\(group.tint.rawValue))" : group.name) {
                            model.add(tab, toGroup: group.id)
                        }
                    }
                }
            }
            if tab.groupID != nil { Button("Remove from Group") { model.removeFromGroup(tab) } }
            Divider()
            Button("Close Tab") { model.close(tab) }
            Button("Close Other Tabs") { model.closeOthers(keeping: tab) }.disabled(model.tabs.count < 2)
        }
    }

    private func groupChip(_ group: TabGroup) -> some View {
        let count = model.tabs(in: group.id).count
        return Button {
            model.updateGroup(group.id) { $0.isCollapsed.toggle() }
        } label: {
            HStack(spacing: 4) {
                if group.name.isEmpty {
                    Circle().fill(.white.opacity(0.9)).frame(width: 6, height: 6)
                } else {
                    Text(group.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                }
                if group.isCollapsed {
                    Text("\(count)").font(.system(size: 10, weight: .bold, design: .rounded)).opacity(0.85)
                }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .frame(minWidth: 22, maxWidth: 140, minHeight: 22, maxHeight: 22)
            .background(Capsule().fill(group.tint.color.gradient))
            .padding(.horizontal, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .help(group.isCollapsed ? "Expand group (\(count) tabs)" : "Collapse group")
        .contextMenu {
            Button("Rename and Colour…") { editingGroup = group.id }
            Button("New Tab in Group") {
                if let last = model.tabs(in: group.id).last {
                    model.openTab(url: nil, inBackground: false, inheritGroupFrom: last)
                }
            }
            Divider()
            Button("Ungroup") { model.ungroup(group.id) }
            Button("Close Group") { model.closeGroup(group.id) }
        }
        .popover(isPresented: Binding(get: { editingGroup == group.id }, set: { if !$0 { editingGroup = nil } }),
                 arrowEdge: .bottom) {
            GroupEditor(model: model, groupID: group.id)
        }
    }
}

private struct GroupEditor: View {
    @Bindable var model: BrowserViewModel
    let groupID: TabGroup.ID
    @FocusState private var focused: Bool

    var body: some View {
        let group = model.groups.first { $0.id == groupID }
        VStack(alignment: .leading, spacing: 10) {
            TextField("Group name", text: Binding(
                get: { group?.name ?? "" },
                set: { name in model.updateGroup(groupID) { $0.name = String(name.prefix(40)) } }))
                .textFieldStyle(.roundedBorder).focused($focused)
            HStack(spacing: 7) {
                ForEach(TabGroup.Tint.allCases, id: \.self) { tint in
                    Circle().fill(tint.color.gradient).frame(width: 18, height: 18)
                        .overlay(Circle().strokeBorder(.primary, lineWidth: group?.tint == tint ? 2 : 0))
                        .onTapGesture { model.updateGroup(groupID) { $0.tint = tint } }
                }
            }
        }
        .padding(14).frame(width: 260)
        .onAppear { focused = true }
    }
}

private struct TabChip: View {
    let tab: Tab
    let isSelected: Bool
    let isHovered: Bool
    var groupTint: Color? = nil
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        // The tab strip lives in the title-bar region, where macOS turns a
        // mouse-down on anything that is not a control into a window drag. So
        // the tab body is a real Button (not an onTapGesture), and the close
        // button is its sibling rather than nested inside it.
        Button(action: onSelect) {
            HStack(spacing: 7) {
                icon
                Text(tab.displayTitle)
                    .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(isSelected ? AnyShapeStyle(Theme.frostText) : AnyShapeStyle(.secondary))
                Spacer(minLength: 0)
                // Room for the close button, which sits in an overlay outside this
                // Button (buttons nested in buttons do not work on macOS).
                Color.clear.frame(width: (isHovered || isSelected) ? 18 : 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).focusEffectDisabled()
        .accessibilityLabel(tab.displayTitle)
        .overlay(alignment: .trailing) {
            if isHovered || isSelected {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).focusEffectDisabled()
                .foregroundStyle(.secondary)
                .help("Close Tab (⌘W)")
                .padding(.trailing, 10)
            }
        }
        .frame(minWidth: 36, idealWidth: 200, maxWidth: 220)
        .frame(height: Theme.tabHeight)
        .modifier(TabSurface(isSelected: isSelected, isHovered: isHovered, tint: groupTint))
        .overlay(alignment: .bottom) {
            if let groupTint {
                Capsule().fill(groupTint).frame(height: 2.5).padding(.horizontal, 8).allowsHitTesting(false)
            }
        }
        .opacity(tab.isHibernated && !isSelected ? 0.6 : 1)
        .help(tab.isHibernated ? "\(tab.displayTitle) — sleeping to save memory" : tab.displayTitle)
    }

    @ViewBuilder
    private var icon: some View {
        if tab.isLoading {
            ProgressView().controlSize(.mini).frame(width: 14, height: 14)
        } else if tab.isHibernated {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 10))
                .foregroundStyle(Theme.ice)
                .frame(width: 14, height: 14)
        } else if tab.url?.scheme == "https" {
            Image(systemName: "globe")
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? AnyShapeStyle(Theme.iceGradient) : AnyShapeStyle(.secondary))
                .frame(width: 14, height: 14)
        } else {
            Image(systemName: "square.dashed")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 14, height: 14)
        }
    }
}

/// Selected tab: a pane of ice. Hovered: a breath of frost. Others: nothing,
/// so the window's own glass shows through.
private struct TabSurface: ViewModifier {
    let isSelected: Bool
    let isHovered: Bool
    let tint: Color?

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
        if isSelected {
            content
                .iceGlass(shape, tint: tint ?? Theme.ice, strength: 1.2)
                .shadow(color: Theme.iceDeep.opacity(0.18), radius: 6, y: 2)
        } else {
            content.background(shape.fill(Theme.rim.opacity(isHovered ? 0.12 : 0)))
        }
    }
}
