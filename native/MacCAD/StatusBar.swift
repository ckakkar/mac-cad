import SwiftUI
import AppKit

/// Bottom status bar, following AutoCAD for Mac: the Model tab and cursor
/// coordinates on the left, drafting aid toggles on the right.
struct StatusBar: View {
    @Bindable var model: EditorModel
    @Bindable var settings = AppSettings.shared
    var body: some View {
        HStack(spacing: 10) {
            Text("Model")
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 2)
                .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 4))
                .help("Model space. Paper space layouts are not implemented yet.")
            CoordinateReadout(pointer: model.pointer, model: model)
            Spacer(minLength: 8)
            Text(model.message).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary).frame(maxWidth: 360, alignment: .trailing)
            Divider().frame(height: 14)
            HStack(spacing: 2) {
                AidToggle(model: model, aid: .grid)
                AidToggle(model: model, aid: .snap) {
                    Button("Snap Settings…") { model.showDraftingSettings = true }
                }
                AidToggle(model: model, aid: .ortho)
                AidToggle(model: model, aid: .polar) {
                    Picker("Polar Angle", selection: $settings.polarIncrement) {
                        ForEach(AppSettings.polarIncrements, id: \.self) { Text("\($0.formatted())°").tag($0) }
                    }.pickerStyle(.inline)
                    Divider()
                    Button("Tracking Settings…") { model.showDraftingSettings = true }
                }
                AidToggle(model: model, aid: .osnap) {
                    ForEach(AppSettings.snapModes, id: \.key) { mode in
                        Toggle(mode.title, isOn: Binding(get: { settings.snapModes.contains(mode.key) }, set: { on in
                            if on { settings.snapModes.insert(mode.key) } else { settings.snapModes.remove(mode.key) }
                        }))
                    }
                    Divider()
                    Button("Object Snap Settings…") { model.showDraftingSettings = true }
                }
                AidToggle(model: model, aid: .dynamicInput)
                AidToggle(model: model, aid: .lineweight)
            }
            Divider().frame(height: 14)
            Menu(unitName(model.units)) {
                ForEach(["mm", "cm", "m", "in", "ft"], id: \.self) { unit in
                    Button(unitName(unit)) { model.execute("UNITS \(unit)") }
                }
                Divider()
                Button("Drawing Units…") { model.showUnits = true }
            }
            .menuStyle(.borderlessButton).fixedSize()
            .help("Drawing units. Changing units does not rescale geometry.")
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10).frame(height: 26)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
    private func unitName(_ unit: String) -> String {
        ["mm": "Millimeters", "cm": "Centimeters", "m": "Meters", "in": "Inches", "ft": "Feet"][unit] ?? unit
    }
}

/// Reads only the pointer, so motion updates this text and nothing else.
private struct CoordinateReadout: View {
    let pointer: PointerState
    let model: EditorModel
    var body: some View {
        Text("\(model.format(pointer.coordinate.x)), \(model.format(pointer.coordinate.y)), 0.0000")
            .monospacedDigit().foregroundStyle(.secondary)
            .frame(minWidth: 210, alignment: .leading)
            .accessibilityLabel("Cursor coordinates")
    }
}

/// A status bar toggle; aids with settings show a menu arrow, as in AutoCAD.
private struct AidToggle<MenuContent: View>: View {
    let model: EditorModel
    let aid: DraftingAid
    @ViewBuilder var menu: () -> MenuContent
    init(model: EditorModel, aid: DraftingAid, @ViewBuilder menu: @escaping () -> MenuContent) {
        self.model = model; self.aid = aid; self.menu = menu
    }
    var body: some View {
        let on = model.isOn(aid)
        HStack(spacing: 0) {
            Button { model.toggle(aid) } label: {
                Image(nsImage: CADIcon.image(for: aid)).renderingMode(.template)
                    .frame(width: 24, height: 20)
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
                    .background(on ? Color.accentColor.opacity(0.16) : Color.clear, in: RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
            if MenuContent.self != EmptyView.self {
                Menu { menu() } label: { EmptyView() }
                    .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize().frame(width: 12)
            }
        }
        .help(aid.help)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(aid.help)
        .accessibilityValue(on ? "On" : "Off")
        .accessibilityAddTraits(.isButton)
    }
}
extension AidToggle where MenuContent == EmptyView {
    init(model: EditorModel, aid: DraftingAid) { self.init(model: model, aid: aid) { EmptyView() } }
}
