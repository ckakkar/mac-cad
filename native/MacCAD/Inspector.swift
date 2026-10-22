import SwiftUI
import AppKit

/// The window's inspector: Properties (⌘5) and Layers (⌘4).
struct InspectorView: View {
    @Bindable var model: EditorModel
    var body: some View {
        VStack(spacing: 0) {
            Picker("Inspector", selection: $model.inspectorTab) {
                ForEach(InspectorTab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().padding(.horizontal, 10).padding(.vertical, 8)
            Divider()
            switch model.inspectorTab {
            case .properties: PropertiesPanel(model: model)
            case .layers: LayersPanel(model: model)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

let lineTypes = ["Continuous", "Dashed", "Hidden", "Center", "Dotted"]
let lineWeightValues = [0.0, 0.05, 0.09, 0.13, 0.18, 0.25, 0.35, 0.5, 0.7, 1.0, 1.4, 2.11]
private let varies = "*VARIES*"

// MARK: Properties

struct PropertiesPanel: View {
    @Bindable var model: EditorModel
    private var entities: [[String: Any]] { model.selectionData }
    private var entity: [String: Any] { entities.first ?? [:] }
    private var kind: String { entity["kind"] as? String ?? "" }
    private var id: UInt64 { (entity["id"] as? NSNumber)?.uint64Value ?? 0 }
    var body: some View {
        Form {
            Section { header }
            if model.selection.isEmpty { drawingSection } else {
                generalSection
                if model.selection.count == 1 {
                    Section("Geometry") { GeometryFields(model: model, entity: entity).id(id) }
                    let rows = measurements
                    if !rows.isEmpty { Section("Measurements") { ForEach(rows, id: \.0) { LabeledContent($0.0, value: $0.1) } } }
                } else {
                    Section { Text("Select one object to edit its geometry.").foregroundStyle(.secondary) }
                }
                Section {
                    Button("Measure Length and Area") { model.measureSelection() }
                    if !model.measurement.isEmpty { Text(model.measurement).font(.system(size: 11, design: .monospaced)).textSelection(.enabled) }
                }
            }
        }
        .formStyle(.grouped)
        .controlSize(.small)
    }
    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: Self.icon(for: model.selection.count == 1 ? kind : "")).renderingMode(.template).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private var title: String {
        switch model.selection.count {
        case 0: return "No Selection"
        case 1: return Self.kindTitle(kind)
        default:
            let kinds = Set(entities.compactMap { $0["kind"] as? String })
            return kinds.count == 1 ? "\(model.selection.count) \(Self.kindTitle(kinds.first!))s" : "\(model.selection.count) Objects"
        }
    }
    private var subtitle: String {
        model.selection.isEmpty ? "\(model.entityCount.formatted()) objects in model space" : model.selection.count == 1 ? "ID \(id)" : "Mixed values show *VARIES*"
    }
    static func kindTitle(_ kind: String) -> String {
        ["line": "Line", "polyline": "Polyline", "circle": "Circle", "arc": "Arc", "ellipse": "Ellipse", "spline": "Spline", "point": "Point", "text": "Text",
         "dimension": "Dimension", "radial_dimension": "Radial Dimension", "leader": "Leader", "hatch": "Hatch", "insert": "Block Reference",
         "region": "Hatch", "solid": "2D Solid", "image": "Image", "x_line": "Construction Line"][kind] ?? "Object"
    }
    static func icon(for kind: String) -> NSImage {
        let tool: Tool? = ["line": .line, "polyline": .polyline, "circle": .circle, "arc": .arc, "ellipse": .ellipse, "spline": .spline, "point": .point, "text": .text,
                           "dimension": .dimension, "radial_dimension": .radius, "leader": .leader, "hatch": .hatch, "insert": .insert, "region": .hatch, "solid": .hatch][kind]
        return tool.map { CADIcon.image(for: $0, size: 20) } ?? NSImage(systemSymbolName: "square.dashed", accessibilityDescription: nil)!
    }

    private var drawingSection: some View {
        Section("Drawing") {
            Picker("Current layer", selection: Binding(get: { model.currentLayer }, set: { model.layer($0, values: ["current": true]) })) {
                ForEach(model.layers) { Text($0.name).tag($0.name) }
            }
            LabeledContent("Units") {
                Button(["mm": "Millimeters", "cm": "Centimeters", "m": "Meters", "in": "Inches", "ft": "Feet"][model.units] ?? model.units) { model.showUnits = true }.buttonStyle(.link)
            }
            LabeledContent("Layers", value: "\(model.layers.count)")
            LabeledContent("Blocks", value: "\(model.blocks.count)")
        }
    }

    // General properties apply to every selected object.
    private func common(_ value: ([String: Any]) -> String) -> String {
        let values = Set(entities.map(value))
        return values.count == 1 ? values.first! : varies
    }
    private func style(_ e: [String: Any]) -> [String: Any] { e["style"] as? [String: Any] ?? [:] }
    private var generalSection: some View {
        Section("General") {
            let layer = common { $0["layer"] as? String ?? "0" }
            Picker("Layer", selection: Binding(get: { layer }, set: { if $0 != varies { model.patch(["layer": $0]) } })) {
                if layer == varies { Text(varies).tag(varies) }
                ForEach(model.layers) { l in Text(l.name).tag(l.name) }
            }
            LabeledContent("Color") {
                HStack(spacing: 6) {
                    let byLayer = style(entity)["color"] == nil
                    if byLayer { Text("ByLayer").foregroundStyle(.secondary) }
                    ColorPicker("Color", selection: Binding(get: { color(effectiveColor) }, set: { setStyle("color", components($0)) }), supportsOpacity: false).labelsHidden()
                    if !byLayer { Button("ByLayer") { setStyle("color", NSNull()) }.buttonStyle(.link) }
                }
            }
            let lineType = common { style($0)["line_type"] as? String ?? "ByLayer" }
            Picker("Linetype", selection: Binding(get: { lineType }, set: { v in if v != varies { setStyle("line_type", v == "ByLayer" ? NSNull() : v) } })) {
                if lineType == varies { Text(varies).tag(varies) }
                Text("ByLayer").tag("ByLayer")
                ForEach(lineTypes, id: \.self) { Text($0).tag($0) }
            }
            let weight = common { e in (style(e)["line_weight"] as? NSNumber).map { String(format: "%.2f", $0.doubleValue) } ?? "ByLayer" }
            Picker("Lineweight", selection: Binding(get: { weight }, set: { v in if v != varies { setStyle("line_weight", Double(v).map { $0 as Any } ?? NSNull()) } })) {
                if weight == varies { Text(varies).tag(varies) }
                Text("ByLayer").tag("ByLayer")
                ForEach(lineWeightValues, id: \.self) { Text(String(format: "%.2f mm", $0)).tag(String(format: "%.2f", $0)) }
            }
        }
    }
    private var effectiveColor: [Float] {
        if let c = style(entity)["color"] as? [Double] { return c.map(Float.init) }
        let name = entity["layer"] as? String ?? model.currentLayer
        return model.layers.first(where: { $0.name == name })?.color ?? [0.8, 0.85, 0.9, 1]
    }
    /// Style changes apply per object, keeping each object's other style values.
    private func setStyle(_ key: String, _ value: Any) {
        if model.selection.count == 1 { var s = style(entity); s[key] = value; model.patch(["style": s]); return }
        let command: String
        switch key {
        case "line_type": command = "CHPROP linetype \((value as? String) ?? "ByLayer")"
        case "line_weight": command = "CHPROP lineweight \((value as? Double).map { String($0) } ?? "ByLayer")"
        default:
            guard let c = value as? [Float] else { command = "CHPROP color ByLayer"; break }
            command = String(format: "CHPROP color #%02X%02X%02X", Int(c[0] * 255), Int(c[1] * 255), Int(c[2] * 255))
        }
        model.execute(command)
    }
    private func color(_ c: [Float]) -> Color { Color(red: Double(c[0]), green: Double(c[1]), blue: Double(c[2])) }
    private func components(_ color: Color) -> [Float] { let c = NSColor(color).usingColorSpace(.sRGB) ?? .white; return [Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 1] }

    private var measurements: [(String, String)] {
        func point(_ key: String) -> CADPoint? { (entity[key] as? [String: Double]).flatMap { p in p["x"].flatMap { x in p["y"].map { CADPoint(x: x, y: $0) } } } }
        let f = model.format
        switch kind {
        case "line":
            guard let a = point("a"), let b = point("b") else { return [] }
            let angle = (atan2(b.y - a.y, b.x - a.x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            return [("Length", f(a.distance(b))), ("Angle", "\(f(angle))°"), ("Delta X", f(b.x - a.x)), ("Delta Y", f(b.y - a.y))]
        case "circle":
            guard let r = entity["radius"] as? Double else { return [] }
            return [("Diameter", f(2 * r)), ("Circumference", f(2 * .pi * r)), ("Area", f(.pi * r * r))]
        case "arc":
            guard let r = entity["radius"] as? Double, let sweep = entity["sweep"] as? Double else { return [] }
            return [("Arc length", f(abs(sweep) * r)), ("Chord", f(2 * r * sin(abs(sweep) / 2)))]
        case "dimension":
            guard let a = point("a"), let b = point("b") else { return [] }
            return [("Measurement", f(entity["aligned"] as? Bool == true ? a.distance(b) : abs(b.x - a.x)))]
        default: return []
        }
    }
}

/// Editable geometry rows for one object, with AutoCAD's property names.
private struct GeometryFields: View {
    let model: EditorModel
    let entity: [String: Any]
    @ViewState private var vertex = 0
    private var kind: String { entity["kind"] as? String ?? "" }
    var body: some View {
        switch kind {
        case "point": pointRows("at", "Position")
        case "line": pointRows("a", "Start"); pointRows("b", "End")
        case "circle": pointRows("center", "Center"); number("radius", "Radius")
            ValueField(label: "Diameter", value: model.format((entity["radius"] as? Double ?? 0) * 2)) { raw in commitNumber(raw) { ["radius": $0 / 2] } }
        case "arc": pointRows("center", "Center"); number("radius", "Radius"); angle("start", "Start angle"); angle("sweep", "Total angle")
        case "ellipse": pointRows("center", "Center"); pointRows("major", "Major axis"); number("ratio", "Radius ratio"); angle("start", "Start angle"); angle("sweep", "Total angle")
        case "spline":
            LabeledContent("Degree", value: "\(entity["degree"] as? Int ?? 0)")
            LabeledContent("Control points", value: "\((entity["control_points"] as? [Any])?.count ?? 0)")
            LabeledContent("Closed", value: entity["closed"] as? Bool == true ? "Yes" : "No")
        case "polyline": polylineRows
        case "text": pointRows("at", "Position"); text("text", "Contents"); number("height", "Height"); angle("rotation", "Rotation")
        case "dimension": pointRows("a", "First point"); pointRows("b", "Second point"); number("offset", "Dimension line offset")
        case "radial_dimension": pointRows("center", "Center"); pointRows("edge", "Edge point"); pointRows("at", "Text position")
        case "leader": text("text", "Contents"); number("height", "Text height"); LabeledContent("Vertices", value: "\((entity["points"] as? [Any])?.count ?? 0)")
        case "hatch":
            Picker("Pattern", selection: Binding(get: { entity["pattern"] as? String ?? "solid" }, set: { model.patch(["geometry": ["pattern": $0]]) })) {
                Text("Solid").tag("solid"); Text("Diagonal").tag("diagonal")
            }
            number("spacing", "Spacing")
        case "insert":
            if let dimension = entity["dimension"] as? [String: Any] {
                // Imported dimensions keep their drawn graphics as an anonymous block.
                LabeledContent("Dimension type", value: (dimension["kind"] as? String ?? "").capitalized)
                LabeledContent("Measurement", value: model.format((dimension["measurement"] as? NSNumber)?.doubleValue ?? 0))
                if let text = dimension["text"] as? String, !text.isEmpty { LabeledContent("Text override", value: text) }
                if let style = dimension["style"] as? String, !style.isEmpty { LabeledContent("Dimension style", value: style) }
            } else {
                LabeledContent("Name", value: entity["block"] as? String ?? "")
                pointRows("at", "Position"); number("scale", "Scale"); angle("rotation", "Rotation")
                if let y = value("y_scale") { LabeledContent("Y scale", value: model.format(y)) }
                ForEach(Array((entity["attributes"] as? [[String: Any]] ?? []).enumerated()), id: \.offset) { _, a in
                    LabeledContent(a["tag"] as? String ?? "Attribute", value: a["text"] as? String ?? "")
                }
            }
        case "region":
            LabeledContent("Pattern", value: entity["solid"] as? Bool == true ? "SOLID" : (entity["pattern"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "User defined")
            LabeledContent("Boundary loops", value: "\((entity["loops"] as? [Any])?.count ?? 0)")
        case "image":
            LabeledContent("File", value: ((entity["path"] as? String) ?? "").isEmpty ? "Not found" : (entity["path"] as? String ?? ""))
            pointRows("at", "Position")
        case "x_line": pointRows("at", "Base point"); LabeledContent("Type", value: entity["ray"] as? Bool == true ? "Ray" : "Construction line")
        default: EmptyView()
        }
    }
    private func value(_ key: String) -> Double? { (entity[key] as? NSNumber)?.doubleValue }
    private func pointValue(_ key: String) -> [String: Double]? { entity[key] as? [String: Double] }
    @ViewBuilder private func pointRows(_ key: String, _ label: String) -> some View {
        if let p = pointValue(key) {
            ValueField(label: "\(label) X", value: model.format(p["x"] ?? 0)) { raw in commitNumber(raw) { [key: ["x": $0, "y": p["y"] ?? 0]] } }
            ValueField(label: "\(label) Y", value: model.format(p["y"] ?? 0)) { raw in commitNumber(raw) { [key: ["x": p["x"] ?? 0, "y": $0]] } }
        }
    }
    @ViewBuilder private func number(_ key: String, _ label: String) -> some View {
        if let v = value(key) { ValueField(label: label, value: model.format(v)) { raw in commitNumber(raw) { [key: $0] } } }
    }
    @ViewBuilder private func angle(_ key: String, _ label: String) -> some View {
        if let v = value(key) { ValueField(label: label, value: "\(model.format(v * 180 / .pi))°") { raw in commitNumber(raw.replacingOccurrences(of: "°", with: "")) { [key: $0 * .pi / 180] } } }
    }
    @ViewBuilder private func text(_ key: String, _ label: String) -> some View {
        ValueField(label: label, value: entity[key] as? String ?? "", alignment: .leading) { raw in model.patch(["geometry": [key: raw]]) }
    }
    @ViewBuilder private var polylineRows: some View {
        let vertices = entity["vertices"] as? [[String: Any]] ?? []
        if !vertices.isEmpty {
            let i = min(vertex, vertices.count - 1)
            let p = vertices[i]["point"] as? [String: Double] ?? [:]
            LabeledContent("Vertex") {
                Stepper("\(i + 1) of \(vertices.count)", value: $vertex, in: 0...(vertices.count - 1)).monospacedDigit()
            }
            ValueField(label: "Vertex X", value: model.format(p["x"] ?? 0)) { raw in commitVertex(vertices, i, raw) { v, n in v["point"] = ["x": n, "y": p["y"] ?? 0] } }
            ValueField(label: "Vertex Y", value: model.format(p["y"] ?? 0)) { raw in commitVertex(vertices, i, raw) { v, n in v["point"] = ["x": p["x"] ?? 0, "y": n] } }
            ValueField(label: "Bulge", value: model.format(vertices[i]["bulge"] as? Double ?? 0)) { raw in commitVertex(vertices, i, raw) { v, n in v["bulge"] = n } }
            LabeledContent("Closed") {
                Toggle("Closed", isOn: Binding(get: { entity["closed"] as? Bool == true }, set: { model.execute($0 ? "CLOSE" : "OPEN") })).labelsHidden()
            }
        }
    }
    private func commitNumber(_ raw: String, _ geometry: (Double) -> [String: Any]) {
        guard let n = Double(raw.trimmingCharacters(in: .whitespaces)), n.isFinite else { model.show(CoreError.message("Enter a finite number")); return }
        model.patch(["geometry": geometry(n)])
    }
    private func commitVertex(_ vertices: [[String: Any]], _ i: Int, _ raw: String, _ change: (inout [String: Any], Double) -> Void) {
        guard let n = Double(raw.trimmingCharacters(in: .whitespaces)), n.isFinite else { model.show(CoreError.message("Enter a finite number")); return }
        var copy = vertices; change(&copy[i], n); model.patch(["geometry": ["vertices": copy]])
    }
}

/// A labeled value that commits on Return or when focus leaves the field.
private struct ValueField: View {
    let label: String
    let value: String
    var alignment: TextAlignment = .trailing
    let commit: (String) -> Void
    @ViewState private var draft: String?
    @FocusState private var focused: Bool
    var body: some View {
        LabeledContent(label) {
            TextField(label, text: Binding(get: { draft ?? value }, set: { draft = $0 }))
                .labelsHidden().multilineTextAlignment(alignment).monospacedDigit()
                .focused($focused)
                .onSubmit(apply)
                .onChange(of: focused) { if !focused { apply() } }
        }
    }
    private func apply() {
        guard let text = draft else { return }
        draft = nil
        if text != value { commit(text) }
    }
}

// MARK: Layers

struct LayersPanel: View {
    @Bindable var model: EditorModel
    @ViewState private var selected: String?
    @ViewState private var renaming = ""
    private var filtered: [CADLayer] { model.layers.filter { model.layerSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(model.layerSearch) } }
    private var detail: CADLayer? { model.layers.first { $0.name == (selected ?? model.currentLayer) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                iconButton("New Layer", "plus.rectangle.on.rectangle", action: newLayer)
                iconButton("Delete Layer", "minus.square") { if let name = selected { model.layer(name, values: ["delete": true]); selected = nil } }.disabled(selected == nil || selected == "0")
                iconButton("Set Current", "checkmark.circle") { if let name = selected { model.layer(name, values: ["current": true]) } }.disabled(selected == nil)
                Divider().frame(height: 16).padding(.horizontal, 4)
                iconButton("Isolate Layer", "square.on.square.intersection.dashed") { if let name = selected ?? Optional(model.currentLayer) { model.layer(name, values: ["isolate": true]) } }
                iconButton("Turn All Layers On", "eye") { model.execute("LAYON") }
                iconButton("Unlock All Layers", "lock.open") { model.execute("LAYUNLOCK") }
                Spacer()
            }
            .padding(.horizontal, 8).padding(.top, 8)
            TextField("Search Layers", text: $model.layerSearch).textFieldStyle(.roundedBorder).controlSize(.small).padding(.horizontal, 10).padding(.vertical, 6)
            List(selection: $selected) {
                ForEach(filtered) { layer in
                    LayerRow(model: model, layer: layer).tag(layer.name)
                        .contextMenu {
                            Button("Set Current") { model.layer(layer.name, values: ["current": true]) }
                            Button("Isolate") { model.layer(layer.name, values: ["isolate": true]) }
                            Divider()
                            Button(layer.visible ? "Turn Off" : "Turn On") { model.layer(layer.name, values: ["visible": !layer.visible]) }
                            Button(layer.locked ? "Unlock" : "Lock") { model.layer(layer.name, values: ["locked": !layer.locked]) }
                            Divider()
                            Button("Delete") { model.layer(layer.name, values: ["delete": true]) }.disabled(layer.name == "0" || layer.name == model.currentLayer)
                        }
                }
            }
            .listStyle(.inset)
            .frame(minHeight: 140)
            .onDeleteCommand { if let name = selected { model.layer(name, values: ["delete": true]) } }
            if let layer = detail {
                Form {
                    Section("Layer “\(layer.name)”") {
                        if layer.name != "0" {
                            LabeledContent("Name") {
                                TextField("Name", text: $renaming).labelsHidden().onSubmit { rename(layer) }
                            }
                        }
                        LabeledContent("Color") {
                            LayerColorWell(value: layer.color, label: "Color of \(layer.name)") { model.layer(layer.name, values: ["color": $0]) }.frame(width: 44, height: 18)
                        }
                        Picker("Linetype", selection: Binding(get: { layer.line_type }, set: { model.layer(layer.name, values: ["line_type": $0]) })) {
                            ForEach(lineTypes, id: \.self) { Text($0) }
                        }
                        Picker("Lineweight", selection: Binding(get: { (Double(layer.line_weight) * 100).rounded() / 100 }, set: { model.layer(layer.name, values: ["line_weight": $0]) })) {
                            ForEach(lineWeightValues, id: \.self) { Text(String(format: "%.2f mm", $0)).tag($0) }
                        }
                        Toggle("On", isOn: Binding(get: { layer.visible }, set: { model.layer(layer.name, values: ["visible": $0]) }))
                        Toggle("Locked", isOn: Binding(get: { layer.locked }, set: { model.layer(layer.name, values: ["locked": $0]) }))
                    }
                }
                .formStyle(.grouped).controlSize(.small).frame(height: 300)
                .onAppear { renaming = layer.name }
                .onChange(of: layer.name) { renaming = layer.name }
            }
        }
    }
    private func iconButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 20) }.buttonStyle(.borderless).help(title).accessibilityLabel(title)
    }
    private func newLayer() {
        var n = 1
        while model.layers.contains(where: { $0.name == "Layer\(n)" }) { n += 1 }
        model.layer("Layer\(n)", values: ["create": true]); selected = "Layer\(n)"
    }
    private func rename(_ layer: CADLayer) {
        let name = renaming.trimmingCharacters(in: .whitespaces)
        guard name != layer.name else { return }
        model.layer(layer.name, values: ["rename": name]); selected = name
    }
}

private struct LayerRow: View {
    let model: EditorModel
    let layer: CADLayer
    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.green).opacity(model.currentLayer == layer.name ? 1 : 0)
                .accessibilityHidden(model.currentLayer != layer.name).accessibilityLabel("Current layer")
            RoundedRectangle(cornerRadius: 3).fill(Color(red: Double(layer.color[0]), green: Double(layer.color[1]), blue: Double(layer.color[2])))
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.primary.opacity(0.25), lineWidth: 0.5)).frame(width: 14, height: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(layer.name).lineLimit(1)
                Text("\(layer.line_type) · \(String(format: "%.2f", layer.line_weight)) mm").font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button { model.layer(layer.name, values: ["visible": !layer.visible]) } label: { Image(systemName: layer.visible ? "lightbulb.fill" : "lightbulb.slash") }
                .buttonStyle(.borderless).foregroundStyle(layer.visible ? Color.yellow : Color.secondary).help(layer.visible ? "Turn Off" : "Turn On")
                .accessibilityLabel("\(layer.name) visible").accessibilityValue(layer.visible ? "On" : "Off")
            Button { model.layer(layer.name, values: ["locked": !layer.locked]) } label: { Image(systemName: layer.locked ? "lock.fill" : "lock.open") }
                .buttonStyle(.borderless).foregroundStyle(.secondary).help(layer.locked ? "Unlock" : "Lock")
                .accessibilityLabel("\(layer.name) locked").accessibilityValue(layer.locked ? "Locked" : "Unlocked")
        }
        .font(.system(size: 12))
        .onTapGesture(count: 2) { model.layer(layer.name, values: ["current": true]) }
    }
}

struct LayerColorWell: NSViewRepresentable {
    let value: [Float]
    let label: String
    let changed: ([Float]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(changed) }
    func makeNSView(context: Context) -> NSColorWell {
        let well = NSColorWell(style: .minimal); well.target = context.coordinator; well.action = #selector(Coordinator.change(_:)); well.setAccessibilityLabel(label); return well
    }
    func updateNSView(_ well: NSColorWell, context: Context) { well.color = NSColor(srgbRed: CGFloat(value[0]), green: CGFloat(value[1]), blue: CGFloat(value[2]), alpha: 1); context.coordinator.changed = changed }
    final class Coordinator: NSObject {
        var changed: ([Float]) -> Void
        init(_ changed: @escaping ([Float]) -> Void) { self.changed = changed }
        @objc func change(_ sender: NSColorWell) { let c = sender.color.usingColorSpace(.sRGB) ?? .white; changed([Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent), 1]) }
    }
}
