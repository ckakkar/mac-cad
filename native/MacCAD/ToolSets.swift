import SwiftUI
import AppKit

/// Tool Sets palette (⌘1), shown as the window's native sidebar.
struct ToolSetsView: View {
    @Bindable var model: EditorModel
    @Bindable var settings = AppSettings.shared
    @ViewState private var filter = ""
    @AppStorage("ToolSets.collapsed") private var collapsedRaw = ""
    private var collapsed: Set<String> { Set(collapsedRaw.split(separator: ",").map(String.init)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary)
                TextField("Filter Tools", text: $filter).textFieldStyle(.plain)
                if !filter.isEmpty { Button { filter = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(ToolGroup.allCases) { group in
                        let tools = group.tools.filter(matches)
                        if !tools.isEmpty { section(group, tools) }
                    }
                    if !model.blocks.isEmpty && filter.isEmpty {
                        Menu("Insert \(model.blocks.count == 1 ? "Block" : "Blocks")…") {
                            ForEach(model.blocks, id: \.self) { name in Button(name) { model.choose(.insert); model.execute(name) } }
                        }
                        .menuStyle(.borderlessButton).fixedSize().font(.system(size: 11)).padding(.leading, 12).padding(.top, 2)
                    }
                }
                .padding(.horizontal, 8).padding(.bottom, 12)
            }
        }
        .accessibilityElement(children: .contain).accessibilityLabel("Tool Sets")
    }
    private func matches(_ tool: Tool) -> Bool {
        filter.isEmpty || tool.title.localizedCaseInsensitiveContains(filter) || tool.commandName.localizedCaseInsensitiveContains(filter) || tool.alias?.caseInsensitiveCompare(filter) == .orderedSame
    }
    private func section(_ group: ToolGroup, _ tools: [Tool]) -> some View {
        let expanded = !collapsed.contains(group.rawValue) || !filter.isEmpty
        return VStack(alignment: .leading, spacing: 4) {
            Button {
                var set = collapsed
                if set.contains(group.rawValue) { set.remove(group.rawValue) } else { set.insert(group.rawValue) }
                collapsedRaw = set.sorted().joined(separator: ",")
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).rotationEffect(.degrees(expanded ? 90 : 0))
                    Text(group.rawValue).font(.system(size: 11, weight: .semibold))
                    Spacer()
                }
                .foregroundStyle(.secondary).contentShape(Rectangle())
            }
            .buttonStyle(.plain).padding(.horizontal, 4).padding(.top, 8)
            .accessibilityLabel("\(group.rawValue) tools").accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: settings.showToolLabels ? 58 : 34, maximum: 80), spacing: 2)], spacing: 2) {
                    ForEach(tools) { tool in ToolButton(tool: tool, active: model.tool == tool && model.session.active, showLabel: settings.showToolLabels) { model.choose(tool) } }
                }
            }
        }
    }
}

private struct ToolButton: View {
    let tool: Tool
    let active: Bool
    let showLabel: Bool
    let action: () -> Void
    @ViewState private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(nsImage: tool.image).renderingMode(.template).frame(width: 22, height: 20)
                if showLabel { Text(tool.shortTitle).font(.system(size: 9.5)).lineLimit(1).minimumScaleFactor(0.8) }
            }
            .frame(maxWidth: .infinity, minHeight: showLabel ? 44 : 30)
            .foregroundStyle(active ? Color.accentColor : Color.primary)
            .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.18) : hovering ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tool.tooltip)
        .accessibilityLabel(tool.title)
        .accessibilityHint(tool.prompt)
    }
}
