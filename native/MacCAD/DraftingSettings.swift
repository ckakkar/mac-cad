import SwiftUI

/// Drafting Settings (DSETTINGS): snap and grid, polar tracking, object snap
/// and dynamic input. Changes apply immediately, like other Mac settings sheets.
struct DraftingSettingsSheet: View {
    @Bindable var model: EditorModel
    @Bindable var settings = AppSettings.shared
    @ViewState private var spacing = ""
    @ViewState private var tab = 0
    var body: some View {
        VStack(spacing: 0) {
            Text("Drafting Settings").font(.headline).padding(.top, 16)
            Picker("Section", selection: $tab) {
                Text("Snap and Grid").tag(0); Text("Polar Tracking").tag(1); Text("Object Snap").tag(2); Text("Dynamic Input").tag(3)
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 20).padding(.top, 12)
            Form {
                switch tab {
                case 0:
                    Toggle("Snap On (F9)", isOn: $model.gridSnap)
                    LabeledContent("Snap spacing") {
                        HStack(spacing: 6) {
                            TextField("Snap spacing", text: $spacing).labelsHidden().frame(width: 110).multilineTextAlignment(.trailing).onSubmit(applySpacing)
                            Text(model.units).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("Grid On (F7)", isOn: $model.grid)
                    Text("The grid follows the snap spacing while Snap is on, and adapts to the zoom level otherwise.").font(.callout).foregroundStyle(.secondary)
                case 1:
                    Toggle("Polar Tracking On (F10)", isOn: $model.polar)
                    Picker("Increment angle", selection: $settings.polarIncrement) {
                        ForEach(AppSettings.polarIncrements, id: \.self) { Text("\($0.formatted())°").tag($0) }
                    }
                    Toggle("Ortho Mode (F8)", isOn: $model.ortho)
                    Text("Ortho and polar tracking constrain points relative to the previous point. Turning one on turns the other off.").font(.callout).foregroundStyle(.secondary)
                case 2:
                    Toggle("Object Snap On (F3)", isOn: $model.snapping)
                    Section("Object snap modes") { SnapModeGrid() }
                default:
                    Toggle("Dynamic Input On (F12)", isOn: $model.dynamicInput)
                    Toggle("Show snap tooltips", isOn: $settings.snapTooltip)
                    Text("Dynamic input shows the prompt beside the crosshair, an input box once you type, and distance and angle while placing points. Coordinates use command-line rules: x,y is absolute and @x,y is relative.").font(.callout).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Settings…") { SettingsWindowController.shared.showWindow(nil) }
                Spacer()
                Button("Done") { applySpacing(); model.showDraftingSettings = false }.keyboardShortcut(.defaultAction)
            }
            .padding([.horizontal, .bottom], 20)
        }
        .frame(width: 540, height: 470)
        .onAppear { spacing = model.format(model.snapSpacing) }
        .onChange(of: model.polar) { if model.polar { model.ortho = false }; model.invalidate?() }
        .onChange(of: model.ortho) { if model.ortho { model.polar = false }; model.invalidate?() }
    }
    private func applySpacing() {
        guard let n = Double(spacing.trimmingCharacters(in: .whitespaces)), n.isFinite, n > 0, n <= 1e9 else { spacing = model.format(model.snapSpacing); NSSound.beep(); return }
        model.snapSpacing = n; model.invalidate?()
    }
}

/// Drawing Units (UNITS). Units are document metadata; geometry is not rescaled.
struct UnitsSheet: View {
    @Bindable var model: EditorModel
    @ViewState private var units = "mm"
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Drawing Units").font(.headline)
            Form {
                Picker("Insertion units", selection: $units) {
                    Text("Millimeters").tag("mm"); Text("Centimeters").tag("cm"); Text("Meters").tag("m"); Text("Inches").tag("in"); Text("Feet").tag("ft")
                }
                LabeledContent("Length type", value: "Decimal")
                LabeledContent("Precision", value: "0.0000")
                LabeledContent("Angle type", value: "Decimal degrees, counterclockwise")
            }
            .formStyle(.grouped)
            Text("Changing units changes how values are interpreted and exported; existing geometry is not rescaled. The change can be undone.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { model.showUnits = false }.keyboardShortcut(.cancelAction)
                Button("OK") { if units != model.units { model.execute("UNITS \(units)") }; model.showUnits = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 440)
        .onAppear { units = model.units }
    }
}
