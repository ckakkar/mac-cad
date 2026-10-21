import AppKit
import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case select, line, polyline, rectangle, circle, arc, text, dimension, hatch, move, copy
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .line: return "line.diagonal"
        case .polyline: return "point.topleft.down.to.point.bottomright.curvepath"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .arc: return "circle.dashed"
        case .text: return "textformat"
        case .dimension: return "arrow.left.and.right"
        case .hatch: return "square.on.square.dashed"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .copy: return "plus.square.on.square"
        }
    }
    var prompt: String {
        switch self {
        case .select: return "Click an object · Shift-click to add · ⌘A to select all"
        case .line: return "Pick start and end points · Escape to cancel"
        case .polyline: return "Pick vertices · Return to finish · Escape to cancel"
        case .rectangle: return "Pick opposite corners"
        case .circle: return "Pick center, then radius"
        case .arc: return "Pick center, start, then end (counterclockwise)"
        case .text: return "Pick the text insertion point"
        case .dimension: return "Pick two points, then dimension offset"
        case .hatch: return "Pick opposite corners for a rectangular hatch"
        case .move, .copy: return "Select objects first, then pick base and destination"
        }
    }
}

@MainActor final class EditorModel: ObservableObject {
    let core: CADCore
    weak var document: DrawingDocument?
    @Published var tool: Tool = .select
    @Published var layers: [CADLayer] = []
    @Published var currentLayer = "0"
    @Published var units = "mm"
    @Published var entityCount = 0
    @Published var selection: [UInt64] = []
    @Published var selectionDescription = "Nothing selected"
    @Published var revision: UInt64 = 0
    @Published var commandText = ""
    @Published var newLayerName = ""
    @Published var showCommandReference = false
    @Published var message = "Ready"
    @Published var errorMessage: String?
    @Published var coordinate = CADPoint.zero
    @Published var ortho = false
    @Published var polar = false
    @Published var snapping = true
    @Published var grid = true
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var isBusy = false
    @Published var commandHistory: [String] = []
    var invalidate: (() -> Void)?
    var fitView: (() -> Void)?
    var cancelGesture: (() -> Void)?
    var acceptCoordinate: ((CADPoint, Bool) -> Void)?
    init(core: CADCore) { self.core = core }

    func refresh() async {
        do { apply(try await core.request(["op": "state"])) } catch { show(error) }
    }
    func apply(_ state: [String: Any]) {
        let old = revision
        revision = (state["revision"] as? NSNumber)?.uint64Value ?? revision
        entityCount = state["count"] as? Int ?? entityCount
        selection = (state["selected"] as? [NSNumber])?.map(\.uint64Value) ?? []
        if let values = state["layers"], let data = try? JSONSerialization.data(withJSONObject: values), let l = try? JSONDecoder().decode([CADLayer].self, from: data) { layers = l }
        currentLayer = state["current_layer"] as? String ?? currentLayer
        units = state["units"] as? String ?? units
        canUndo = state["can_undo"] as? Bool ?? false
        canRedo = state["can_redo"] as? Bool ?? false
        if let entities = state["selection"] as? [[String: Any]], let e = entities.first {
            selectionDescription = selection.count == 1 ? "\((e["kind"] as? String ?? "Object").capitalized) · Layer \(e["layer"] as? String ?? "0")\nID \((e["id"] as? NSNumber)?.stringValue ?? "")" : "\(selection.count) objects selected"
        } else { selectionDescription = "Nothing selected" }
        if old != revision { document?.updateChangeCount(state["dirty"] as? Bool == false ? .changeCleared : .changeDone) }
        invalidate?()
    }
    func operation(_ op: [String: Any]) {
        Task { do { apply(try await core.request(op)) } catch { show(error) } }
    }
    func execute(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let tools: [String:Tool] = ["L":.line,"LINE":.line,"PL":.polyline,"PLINE":.polyline,"REC":.rectangle,"RECT":.rectangle,"C":.circle,"CIRCLE":.circle,"A":.arc,"ARC":.arc,"T":.text,"TEXT":.text,"DIM":.dimension,"DIMALIGNED":.dimension,"HATCH":.hatch,"M":.move,"MOVE":.move,"CO":.copy,"COPY":.copy,"SELECT":.select]
        if let tool = tools[trimmed.uppercased()] { choose(tool); return }
        if tool != .select, !trimmed.contains(" ") {
            let relative = trimmed.hasPrefix("@")
            let pair = (relative ? String(trimmed.dropFirst()) : trimmed).split(separator:",")
            if pair.count == 2, let x = Double(pair[0]), let y = Double(pair[1]), x.isFinite, y.isFinite {
                acceptCoordinate?(CADPoint(x:x,y:y), relative); return
            }
        }
        if trimmed.uppercased() == "ZOOM EXTENTS" || trimmed.uppercased() == "ZE" { fitView?(); return }
        commandHistory.append(trimmed)
        if commandHistory.count > 30 { commandHistory.removeFirst() }
        message = trimmed
        operation(["op": "command", "text": trimmed])
    }
    func submit() { let text = commandText; commandText = ""; execute(text) }
    func choose(_ tool: Tool) { cancelGesture?(); self.tool = tool; message = tool.prompt; invalidate?() }
    func cancel() { cancelGesture?(); tool = .select; message = "Command cancelled"; invalidate?() }
    func show(_ error: Error) { errorMessage = error.localizedDescription; message = error.localizedDescription }
    func layer(_ name: String, values: [String: Any]) { var payload = values; payload["op"] = "layer"; payload["name"] = name; operation(payload) }
    func extents() async -> CADBounds? {
        guard let state = try? await core.request(["op": "state"]), let b = state["bounds"], !(b is NSNull), let data = try? JSONSerialization.data(withJSONObject: b) else { return nil }
        return try? JSONDecoder().decode(CADBounds.self, from: data)
    }
    func demo() {
        guard entityCount == 0 else { return }
        Task {
            do {
                for (name,color) in [("Walls", [0.78,0.84,0.90,1.0]),("Openings", [0.93,0.68,0.34,1.0]),("Annotation", [0.42,0.74,0.68,1.0])] {
                    _ = try await core.request(["op":"layer","name":name,"create":true])
                    _ = try await core.request(["op":"layer","name":name,"color":color])
                }
                let commands = ["RECT 0,0 8000,6000", "RECT 200,200 7800,5800", "LINE 5000,200 5000,5800", "LINE 5200,200 5200,5800", "LINE 200,3500 5000,3500", "LINE 200,3700 5000,3700"]
                _ = try await core.request(["op":"layer","name":"Walls","current":true])
                for c in commands { _ = try await core.request(["op":"command","text":c]) }
                _ = try await core.request(["op":"layer","name":"Openings","current":true])
                for c in ["ARC 1800,200 900 0 90", "LINE 1800,200 1800,1100", "RECT 700,5750 2300,5850", "RECT 5700,5750 7200,5850"] { _ = try await core.request(["op":"command","text":c]) }
                _ = try await core.request(["op":"layer","name":"Annotation","current":true])
                for c in ["TEXT 1400,1900 220 LIVING / DINING", "TEXT 900,4500 180 KITCHEN", "TEXT 5700,3200 180 BEDROOM", "DIM 0,0 8000,0 -650", "DIMALIGNED 8000,0 8000,6000 -650"] { _ = try await core.request(["op":"command","text":c]) }
                await refresh(); fitView?()
            } catch { show(error) }
        }
    }
}
