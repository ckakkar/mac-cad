import AppKit
import SwiftUI

/// SwiftUI's `@State` resolves to a macro whose compiler plugin ships with Xcode,
/// not the Command Line Tools this project builds with. The property wrapper
/// itself is identical, so views use it through this alias.
typealias ViewState<Value> = SwiftUI.State<Value>

/// Application preferences (⌘,). Values persist in user defaults and apply to
/// every open drawing; drawing geometry never depends on them.
@MainActor @Observable final class AppSettings {
    static let shared = AppSettings()
    @ObservationIgnored private let defaults = UserDefaults.standard

    enum Background: String, CaseIterable, Identifiable {
        case dark, light
        var id: String { rawValue }
        var title: String { rawValue.capitalized }
    }
    /// Running object snap modes, using AutoCAD's names (OSNAP).
    static let snapModes: [(key: String, title: String)] = [
        ("endpoint", "Endpoint"), ("midpoint", "Midpoint"), ("center", "Center"), ("node", "Node"),
        ("quadrant", "Quadrant"), ("intersection", "Intersection"), ("insertion", "Insertion"),
        ("perpendicular", "Perpendicular"), ("tangent", "Tangent"), ("nearest", "Nearest"),
    ]
    static let defaultSnapModes: Set<String> = ["endpoint", "midpoint", "center", "node", "quadrant", "intersection", "insertion", "perpendicular", "tangent"]
    static let polarIncrements: [Double] = [90, 45, 30, 22.5, 18, 15, 10, 5]

    var background: Background { didSet { defaults.set(background.rawValue, forKey: "background") } }
    /// Crosshair arm length as a percentage of the canvas (CURSORSIZE).
    var crosshairSize: Double { didSet { defaults.set(crosshairSize, forKey: "crosshairSize") } }
    /// Pickbox and grip sizes in points (PICKBOX, GRIPSIZE).
    var pickboxSize: Double { didSet { defaults.set(pickboxSize, forKey: "pickboxSize") } }
    var gripSize: Double { didSet { defaults.set(gripSize, forKey: "gripSize") } }
    /// Object snap aperture in points (APERTURE).
    var apertureSize: Double { didSet { defaults.set(apertureSize, forKey: "apertureSize") } }
    var snapMarker: Bool { didSet { defaults.set(snapMarker, forKey: "snapMarker") } }
    var snapTooltip: Bool { didSet { defaults.set(snapTooltip, forKey: "snapTooltip") } }
    var selectionPreview: Bool { didSet { defaults.set(selectionPreview, forKey: "selectionPreview") } }
    var showUCSIcon: Bool { didSet { defaults.set(showUCSIcon, forKey: "showUCSIcon") } }
    var showToolLabels: Bool { didSet { defaults.set(showToolLabels, forKey: "showToolLabels") } }
    var snapModes: Set<String> { didSet { defaults.set(Array(snapModes).sorted(), forKey: "snapModes") } }
    var polarIncrement: Double { didSet { defaults.set(polarIncrement, forKey: "polarIncrement") } }
    /// Mouse wheel forward zooms in, as in AutoCAD; true reverses it (ZOOMWHEEL 1).
    var reverseWheelZoom: Bool { didSet { defaults.set(reverseWheelZoom, forKey: "reverseWheelZoom") } }
    /// Trackpad two-finger scrolling and Magic Mouse swipes pan by default; this makes them zoom.
    var gestureScrollZooms: Bool { didSet { defaults.set(gestureScrollZooms, forKey: "gestureScrollZooms") } }

    private init() {
        let store = UserDefaults.standard
        func number(_ key: String, _ fallback: Double, _ range: ClosedRange<Double>) -> Double {
            guard let n = store.object(forKey: key) as? Double, n.isFinite else { return fallback }
            return min(max(n, range.lowerBound), range.upperBound)
        }
        func flag(_ key: String, _ fallback: Bool) -> Bool { store.object(forKey: key) as? Bool ?? fallback }
        background = Background(rawValue: store.string(forKey: "background") ?? "") ?? .dark
        crosshairSize = number("crosshairSize", 5, 1...100)
        pickboxSize = number("pickboxSize", 5, 2...20)
        gripSize = number("gripSize", 7, 4...16)
        apertureSize = number("apertureSize", 10, 4...30)
        snapMarker = flag("snapMarker", true)
        snapTooltip = flag("snapTooltip", true)
        selectionPreview = flag("selectionPreview", true)
        showUCSIcon = flag("showUCSIcon", true)
        showToolLabels = flag("showToolLabels", true)
        let modes = Set(store.stringArray(forKey: "snapModes") ?? []).intersection(Self.snapModes.map(\.key))
        snapModes = store.object(forKey: "snapModes") == nil ? Self.defaultSnapModes : modes
        let increment = number("polarIncrement", 45, 1...90)
        polarIncrement = Self.polarIncrements.contains(increment) ? increment : 45
        reverseWheelZoom = flag("reverseWheelZoom", false)
        gestureScrollZooms = flag("gestureScrollZooms", false)
    }

    /// Model-space colors. AutoCAD shows white (ACI 7) objects as black on a light background.
    var canvasColor: NSColor { background == .dark ? NSColor(srgbRed: 0.13, green: 0.15, blue: 0.18, alpha: 1) : .white }
    var gridColor: SIMD4<Float> { background == .dark ? [0.22, 0.25, 0.30, 0.55] : [0.80, 0.82, 0.86, 0.9] }
    var majorGridColor: SIMD4<Float> { background == .dark ? [0.28, 0.32, 0.38, 0.8] : [0.68, 0.71, 0.76, 0.9] }
    var axisColor: SIMD4<Float> { background == .dark ? [0.36, 0.42, 0.50, 0.9] : [0.55, 0.60, 0.67, 1] }
    var crosshairColor: NSColor { background == .dark ? .white : .black }
    func displayColor(_ c: SIMD4<Float>) -> SIMD4<Float> {
        guard background == .light, c.x > 0.75, c.y > 0.75, c.z > 0.75 else { return c }
        return SIMD4<Float>(0.08, 0.09, 0.11, c.w)
    }
}

/// Native Settings window with toolbar tabs.
@MainActor final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    private init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        func tab<V: View>(_ title: String, _ symbol: String, _ view: V) {
            let host = NSHostingController(rootView: view.frame(width: 480).fixedSize())
            host.sizingOptions = .preferredContentSize
            let item = NSTabViewItem(viewController: host)
            item.label = title; item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        tab("General", "gearshape", GeneralSettings())
        tab("Drafting", "pencil.and.ruler", DraftingPreferences())
        tab("Selection", "cursorarrow.rays", SelectionSettings())
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.title = "Settings"
        if !window.setFrameUsingName("MacCAD.Settings") { window.center() }
        window.setFrameAutosaveName("MacCAD.Settings")
        super.init(window: window)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

private struct GeneralSettings: View {
    @Bindable var settings = AppSettings.shared
    var body: some View {
        Form {
            Section("Model space") {
                Picker("Background", selection: $settings.background) { ForEach(AppSettings.Background.allCases) { Text($0.title).tag($0) } }
                Toggle("Show UCS icon", isOn: $settings.showUCSIcon)
            }
            Section("Palettes") {
                Toggle("Show labels in Tool Sets", isOn: $settings.showToolLabels)
            }
            Section("Navigation") {
                Toggle("Reverse mouse wheel zoom direction", isOn: $settings.reverseWheelZoom)
                Toggle("Trackpad and Magic Mouse scrolling zooms instead of panning", isOn: $settings.gestureScrollZooms)
                Text("A mouse wheel always zooms toward the cursor. Pinch zooms, two-finger double-tap zooms to extents, and middle- or Option-drag pans.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Text("Window, palette and command line layout follow each drawing window. Drawing units and layers are saved with each drawing.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).scrollDisabled(true)
    }
}

private struct DraftingPreferences: View {
    @Bindable var settings = AppSettings.shared
    var body: some View {
        Form {
            Section("Crosshairs") {
                LabeledContent("Crosshair size") {
                    HStack { Slider(value: $settings.crosshairSize, in: 1...100); Text("\(Int(settings.crosshairSize))%").monospacedDigit().frame(width: 40, alignment: .trailing) }
                }
            }
            Section("AutoSnap") {
                Toggle("Show snap marker", isOn: $settings.snapMarker)
                Toggle("Show snap tooltip", isOn: $settings.snapTooltip)
                LabeledContent("Aperture size") {
                    HStack { Slider(value: $settings.apertureSize, in: 4...30); Text("\(Int(settings.apertureSize)) pt").monospacedDigit().frame(width: 40, alignment: .trailing) }
                }
            }
            Section("Object snap modes") {
                SnapModeGrid()
            }
        }.formStyle(.grouped).scrollDisabled(true)
    }
}

private struct SelectionSettings: View {
    @Bindable var settings = AppSettings.shared
    var body: some View {
        Form {
            Section("Selection") {
                LabeledContent("Pickbox size") {
                    HStack { Slider(value: $settings.pickboxSize, in: 2...20); Text("\(Int(settings.pickboxSize)) pt").monospacedDigit().frame(width: 40, alignment: .trailing) }
                }
                Toggle("Highlight objects under the cursor", isOn: $settings.selectionPreview)
            }
            Section("Grips") {
                LabeledContent("Grip size") {
                    HStack { Slider(value: $settings.gripSize, in: 4...16); Text("\(Int(settings.gripSize)) pt").monospacedDigit().frame(width: 40, alignment: .trailing) }
                }
                Text("Click a grip to make it hot, then click or enter a point to stretch the object. Escape cancels.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).scrollDisabled(true)
    }
}

/// Checkboxes for running object snap modes, shared by Settings and Drafting Settings.
struct SnapModeGrid: View {
    @Bindable var settings = AppSettings.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 6) {
                ForEach(0..<5) { row in
                    GridRow {
                        ForEach(0..<2) { column in
                            let mode = AppSettings.snapModes[row * 2 + column]
                            Toggle(mode.title, isOn: Binding(get: { settings.snapModes.contains(mode.key) }, set: { on in
                                if on { settings.snapModes.insert(mode.key) } else { settings.snapModes.remove(mode.key) }
                            }))
                        }
                    }
                }
            }
            HStack {
                Button("Select All") { settings.snapModes = Set(AppSettings.snapModes.map(\.key)) }
                Button("Clear All") { settings.snapModes = [] }
                Button("Defaults") { settings.snapModes = AppSettings.defaultSnapModes }
            }.controlSize(.small)
        }
    }
}
