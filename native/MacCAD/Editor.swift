import AppKit
import SwiftUI

enum Tool: String, CaseIterable, Identifiable {
    case select, pan, join, explode, breakLine, arrayRect, arrayPolar, block, insert, line, polyline, rectangle, circle, arc, ellipse, spline, polygon, point, text, dimension, alignedDimension, radius, diameter, leader, hatch, erase, move, copy, rotate, scale, mirror, offset, trim, extend, fillet, chamfer, measure
    var id: String { rawValue }
    var title:String {
        switch self {case .alignedDimension:return "Aligned Dimension";case .arrayRect:return "Array";case .arrayPolar:return "Polar Array";case .breakLine:return "Break";default:return rawValue.capitalized}
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .pan: return "hand.draw"
        case .join:return "point.3.connected.trianglepath.dotted"
        case .explode:return "square.stack.3d.up.slash"
        case .breakLine:return "scissors"
        case .arrayRect:return "square.grid.3x3"
        case .arrayPolar:return "circle.grid.3x3"
        case .block,.insert:return "shippingbox"
        case .erase: return "trash"
        case .line: return "line.diagonal"
        case .polyline: return "point.topleft.down.to.point.bottomright.curvepath"
        case .rectangle: return "rectangle"
        case .circle: return "circle"
        case .arc: return "circle.dashed"
        case .ellipse: return "oval"
        case .spline: return "point.topleft.down.to.point.bottomright.curvepath"
        case .polygon: return "hexagon"
        case .point: return "plus"
        case .text: return "textformat"
        case .dimension, .alignedDimension: return "arrow.left.and.right"
        case .radius, .diameter: return "arrow.up.right.circle"
        case .leader: return "arrow.up.left.and.down.right.and.arrow.up.right.and.down.left"
        case .hatch: return "square.on.square.dashed"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .copy: return "plus.square.on.square"
        case .rotate: return "rotate.right"
        case .scale: return "arrow.up.left.and.arrow.down.right"
        case .mirror: return "arrow.left.and.right.righttriangle.left.righttriangle.right"
        case .offset: return "square.on.square"
        case .trim: return "scissors"
        case .extend: return "arrow.up.right"
        case .fillet: return "point.topleft.down.to.point.bottomright.curvepath"
        case .chamfer: return "line.3.horizontal.decrease"
        case .measure: return "ruler"
        }
    }
    var prompt: String {
        switch self {
        case .select: return "Click to add · Shift-click to remove · Return/Space repeats last command"
        case .erase: return "Select objects · Return to erase"
        case .pan: return "Drag to pan · Return/Space or Escape to finish"
        case .join,.explode:return "Select objects · Return to apply"
        case .breakLine:return "Select a line · Pick the break point"
        case .arrayRect,.arrayPolar:return "Select objects · Follow the array prompts"
        case .block:return "Select objects · Enter a name and base point"
        case .insert:return "Enter a block name, insertion point, scale and rotation"
        case .line: return "Specify points · Close/Undo · Space/Return to finish"
        case .polyline: return "Specify vertices · Close/Undo · Space/Return to finish"
        case .rectangle: return "Pick opposite corners"
        case .circle: return "Specify center [2P/3P], then radius/diameter"
        case .arc: return "Specify three points · Center option available"
        case .ellipse: return "Specify major axis endpoints, then minor radius · Center option available"
        case .spline: return "Pick spline control points · Return to finish"
        case .polygon: return "Enter side count, center, construction mode and radius"
        case .point: return "Pick a point"
        case .text: return "Pick the text insertion point"
        case .dimension, .alignedDimension: return "Pick two points, then dimension offset"
        case .radius, .diameter: return "Pick circle center, edge and annotation position"
        case .leader: return "Pick arrow location, then text position"
        case .hatch: return "Pick opposite corners for a rectangular hatch"
        case .move, .copy: return "Select objects before or after starting · Specify base and destination"
        case .rotate: return "Select objects · Pick base point, then enter angle"
        case .scale: return "Select objects · Pick base point, then enter scale factor"
        case .mirror: return "Select objects · Pick two mirror axis points"
        case .offset: return "Enter distance · Select objects · Pick offset side"
        case .trim, .extend: return "Select lines · Pick boundary endpoints, then side to trim/extend"
        case .fillet: return "Enter radius · Select two intersecting lines"
        case .chamfer: return "Enter distances · Select two intersecting lines"
        case .measure: return "Pick two points to measure distance"
        }
    }
}

@MainActor final class EditorModel: ObservableObject {
    let core: CADCore
    weak var document: DrawingDocument?
    @Published var session = CommandSession()
    var tool:Tool {session.tool}
    var selecting:Bool {(!session.active && tool == .select) || session.selecting}
    @Published var dynamicInput = true
    @Published var gridSnap = false
    @Published var snapSpacing = 100.0
    @Published var showTools = true
    @Published var showLayers = true
    @Published var showStatus = true
    @Published var inputHistory:[String] = []
    @Published var lastCommand:String?
    private var previousSelection:[UInt64] = []
    private var work:Task<Void,Never>?
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
    @Published var showCommandHistory = true
    @Published var showCommandLine = true
    @Published var showProperties = true
    @Published var layerSearch = ""
    @Published var selectionData: [[String:Any]] = []
    @Published var propertyDraft: [String:String] = [:]
    @Published var blocks: [String] = []
    @Published var lineWeights = false
    @Published var drawingTitle = "Untitled"
    @Published var measurement = ""
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
    var acceptScalar: ((Double) -> Void)?
    var finishGesture: (() -> Void)?
    var focusCommandBar:(() -> Void)?
    var zoomBy:((Double) -> Void)?
    var fitWindow:((CADBounds) -> Void)?
    var previousView:(() -> Void)?
    var syncInput:(() -> Void)?
    var syncCommandBar:(() -> Void)?
    var focusCommand: (() -> Void)?
    var zoomWindow: (() -> Void)?
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
        let newUnits = state["units"] as? String ?? units
        if newUnits != units {session.defaults.height = ["mm":150,"cm":15,"m":0.15,"in":6,"ft":0.5][newUnits] ?? 150}
        units = newUnits
        canUndo = state["can_undo"] as? Bool ?? false
        canRedo = state["can_redo"] as? Bool ?? false
        if let entities = state["selection"] as? [[String: Any]], let e = entities.first {
            selectionData = entities
            propertyDraft = [:]
            selectionDescription = selection.count == 1 ? "\((e["kind"] as? String ?? "Object").capitalized) · Layer \(e["layer"] as? String ?? "0")\nID \((e["id"] as? NSNumber)?.stringValue ?? "")" : "\(selection.count) objects selected"
        } else { selectionDescription = "Nothing selected"; selectionData = []; propertyDraft = [:] }
        blocks = state["blocks"] as? [String] ?? []
        drawingTitle = document?.displayName ?? "Untitled"
        if old != revision { document?.updateChangeCount(state["dirty"] as? Bool == false ? .changeCleared : .changeDone) }
        invalidate?()
    }
    private func enqueue(_ action:@escaping @MainActor () async -> Void) {
        let previous = work
        work = Task {if let previous {await previous.value};await action()}
    }
    func waitForIdle() async {await work?.value}
    func operation(_ op:[String:Any]) {
        enqueue { [self] in do {apply(try await core.request(op));updatePrompt()}catch{show(error)} }
    }
    func execute(_ text:String) {enqueue { [self] in await processInput(text) }}
    func runFromMenu(_ text:String) {
        commandText = "";syncInput?();cancelGesture?();enqueue { [self] in session.reset();await processInput(text) }
    }
    private func record(_ text:String) {
        commandHistory.append(text); if commandHistory.count>200 {commandHistory.removeFirst()}
        if !text.isEmpty && !text.hasPrefix("Error: ") && !text.hasPrefix("Distance ") {inputHistory.append(text);if inputHistory.count>200 {inputHistory.removeFirst()}}
    }
    private func updatePrompt() {message = session.prompt;syncInput?();invalidate?()}
    private func processInput(_ text:String) async {
        let trimmed = text.trimmingCharacters(in:.whitespacesAndNewlines)
        let parts = trimmed.split(maxSplits:1,whereSeparator:{$0.isWhitespace})
        let name = Tool.normalized(parts.first.map(String.init) ?? "")
        if name == "CANCEL" {await cancelNow();return}
        let before = session
        do {
            if session.active && (parts.count<2 || session.acceptsSpaces) {
                record(text);try await perform(session.respond(text,cursor:coordinate,selected:selection.count));updatePrompt();return
            }
            if trimmed.isEmpty {
                guard let lastCommand else {return}
                await processInput(lastCommand);return
            }
            record(text)
            if parts.count == 1, let tool = Tool.aliases[name] {
                cancelGesture?();lastCommand = ["MT","MTEXT"].contains(name) ? "MTEXT":tool.commandName
                try await perform(session.start(tool,name:lastCommand!,selected:selection.count));updatePrompt();return
            }
            if ["Z","ZOOM"].contains(name) {
                lastCommand = "ZOOM";session.startZoom()
                if parts.count == 2 {try await perform(session.respond(String(parts[1]),cursor:coordinate,selected:selection.count))}
                updatePrompt();return
            }
            if name == "ZE" {fitView?();return}
            if name == "REGEN" || name == "REGENALL" {invalidate?();return}
            if ["AREA","LIST","MEASUREGEOM"].contains(name) {measureSelection();return}
            if ["GRID","SNAP","OSNAP","ORTHO","POLAR","DYNMODE"].contains(name) {try setting(name,argument:parts.count>1 ? String(parts[1]):nil);return}
            if ["SELECT","SELECTALL"].contains(name) {session.reset();session.name = "SELECT";session.stage = .selection;updatePrompt();return}
            // Full numeric commands remain available for pasted scripts/reference examples.
            session.reset();cancelGesture?()
            let command = (["X":"EXPLODE","J":"JOIN","PU":"PURGE","MA":"MATCHPROP","REC":"RECT","RECTANG":"RECT","RECTANGLE":"RECT","H":"HATCH"][name] ?? name)+(parts.count>1 ? " "+String(parts[1]):"")
            apply(try await core.request(["op":"command","text":command]))
            lastCommand = Tool.aliases[name]?.commandName ?? command.split(separator:" ").first.map(String.init)
            updatePrompt()
        } catch {
            session = before;message = error.localizedDescription;record("Error: "+error.localizedDescription);syncInput?();invalidate?()
        }
    }
    func enterPoint(_ point:CADPoint) {
        enqueue { [self] in
            let before = session
            do {try await perform(session.point(point,selected:selection.count));commandText = "";updatePrompt()}
            catch {session = before;message = error.localizedDescription;record("Error: "+error.localizedDescription);invalidate?()}
        }
    }
    private func perform(_ effects:[CommandSession.Effect]) async throws {
        for effect in effects {
            switch effect {
            case .command(let text):
                if !selection.isEmpty {previousSelection = selection}
                apply(try await core.request(["op":"command","text":text]))
            case .add(let shape): apply(try await core.request(["op":"add","shapes":[shape]]))
            case .clearSelection:
                if !selection.isEmpty {previousSelection = selection}
                apply(try await core.request(["op":"select","ids":[]]))
            case .selectAll: apply(try await core.request(["op":"select_all"]))
            case .selectLast: apply(try await core.request(["op":"select_last"]))
            case .selectPrevious: apply(try await core.request(["op":"select","ids":previousSelection]))
            case .fit: fitView?()
            case .zoom(let amount):zoomBy?(amount)
            case .zoomWindow(let bounds):fitWindow?(bounds)
            case .previousView:previousView?()
            case .measure(let a,let b):
                measurement = String(format:"Distance %.4f %@ · ΔX %.4f · ΔY %.4f",a.distance(b),units,b.x-a.x,b.y-a.y);record(measurement)
            }
        }
    }
    func submit() {let text = commandText;commandText = "";execute(text);syncInput?()}
    var spaceSubmits:Bool {
        if session.acceptsSpaces {return false}
        let parts = commandText.uppercased().split(whereSeparator:{$0.isWhitespace})
        if let first = parts.first,["TEXT","MTEXT","LEADER","MLEADER"].contains(String(first)),parts.count>=4 {return false}
        return true
    }
    func choose(_ tool:Tool) {
        if tool == .select {cancel();return}
        commandText = "";syncInput?();cancelGesture?()
        enqueue { [self] in
            lastCommand = tool.commandName
            let before = session
            do {try await perform(session.start(tool,name:tool.commandName,selected:selection.count));updatePrompt()}
            catch {session = before;message = error.localizedDescription}
        }
    }
    func cancel() {commandText = "";cancelGesture?();enqueue { [self] in await cancelNow() };syncInput?()}
    private func cancelNow() async {
        session.reset();commandText = "";if !selection.isEmpty {previousSelection = selection}
        if let state = try? await core.request(["op":"select","ids":[]]) {apply(state)}
        message = "Command cancelled";syncInput?();invalidate?()
    }
    private func setting(_ name:String,argument:String?) throws {
        let on:Bool?
        if let argument {
            if ["ON","1","3"].contains(argument.uppercased()) {on = true}
            else if ["OFF","0"].contains(argument.uppercased()) {on = false}
            else if name == "SNAP",let n = Double(argument),n.isFinite,n>0 {snapSpacing = n;gridSnap = true;invalidate?();return}
            else {throw CoreError.message("Use ON/OFF or 1/0; SNAP also accepts a positive spacing")}
        }else{on = nil}
        switch name {
        case "GRID":grid = on ?? !grid
        case "SNAP":gridSnap = on ?? !gridSnap
        case "OSNAP":snapping = on ?? !snapping
        case "ORTHO":ortho = on ?? !ortho;if ortho{polar = false}
        case "POLAR":polar = on ?? !polar;if polar{ortho = false}
        default:dynamicInput = on ?? !dynamicInput
        }
        message = "\(name) \(on.map{$0 ? "ON":"OFF"} ?? "toggled")";invalidate?()
    }
    func show(_ error: Error) { errorMessage = error.localizedDescription; message = error.localizedDescription }
    func layer(_ name: String, values: [String: Any]) { var payload = values; payload["op"] = "layer"; payload["name"] = name; operation(payload) }
    func measureSelection() {
        Task { do { let result = try await core.request(["op":"measure"]); let length = result["length"] as? Double ?? 0; let area = result["area"] as? Double ?? 0
            measurement = String(format:"Length %.3f %@ · Area %.3f %@²",length,units,area,units); message = measurement; commandHistory.append(measurement)
        } catch { show(error) } }
    }
    func patch(_ values: [String:Any]) { var v = values; v["op"] = "properties"; operation(v) }
    func copySelection(cut:Bool = false) {
        enqueue { [self] in do {
            let value = try await core.request(["op":"clipboard"])
            let data = try JSONSerialization.data(withJSONObject:value);let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            guard pasteboard.setData(data,forType:.init("xyz.ckakkar.maccad.selection")) else{throw CoreError.message("Cannot copy objects to the clipboard")}
            if cut {
                previousSelection = selection;session.reset();cancelGesture?()
                apply(try await core.request(["op":"command","text":"ERASE"]))
            }
            message = cut ? "Cut objects":"Copied \(selection.count) objects"
        }catch{show(error)} }
    }
    func pasteSelection() {
        guard let data = NSPasteboard.general.data(forType:.init("xyz.ckakkar.maccad.selection")),data.count<=128*1024*1024 else{message = "No MacCAD objects on the clipboard";return}
        enqueue { [self] in do {
            let document = try JSONSerialization.jsonObject(with:data);session.reset();cancelGesture?()
            apply(try await core.request(["op":"paste","document":document,"at":CADPoint(x:150,y:150).json]));updatePrompt()
        }catch{show(error)} }
    }
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
