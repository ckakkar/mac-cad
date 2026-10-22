import AppKit
import SwiftUI

struct CADGrip: Equatable {
    var id: UInt64
    var index: Int
    var point: CADPoint
    var kind: String
}
/// High-frequency pointer state, observed only by the status bar readout so
/// pointer motion does not re-render palettes.
@MainActor @Observable final class PointerState {
    var coordinate = CADPoint.zero
}
enum InspectorTab: String, CaseIterable, Identifiable {
    case properties = "Properties", layers = "Layers"
    var id: String { rawValue }
}
struct HistoryLine: Identifiable {
    enum Kind { case input, error, info }
    let id = UUID()
    var text: String
    var kind: Kind
}

@MainActor @Observable final class EditorModel {
    let core: CADCore
    @ObservationIgnored weak var document: DrawingDocument?
    @ObservationIgnored let settings = AppSettings.shared
    let pointer = PointerState()
    var session = CommandSession()
    var tool: Tool { session.tool }
    var selecting: Bool { (!session.active && tool == .select) || session.selecting }

    // Drafting aids (status bar toggles).
    var dynamicInput = true
    var gridSnap = false
    var snapSpacing = 100.0
    var ortho = false
    var polar = false
    var snapping = true
    var grid = true
    var lineWeights = false

    // Palettes. ⌘1 Tool Sets, ⌘3 command line, ⌘4 Layers, ⌘5 Properties, ⌘6 status bar.
    var showTools = true
    var showInspector = true
    var inspectorTab = InspectorTab.properties
    var showCommandLine = true
    var showCommandHistory = false
    var showStatus = true
    var showToolbar = true
    @ObservationIgnored private var cleanScreenRestore: (tools: Bool, inspector: Bool, toolbar: Bool, status: Bool)?
    var cleanScreen: Bool { cleanScreenRestore != nil }

    // Snapshot of the Rust document state.
    var layers: [CADLayer] = []
    var currentLayer = "0"
    var units = "mm"
    var entityCount = 0
    var selection: [UInt64] = []
    var selectionData: [[String: Any]] = []
    var grips: [CADGrip] = []
    var blocks: [String] = []
    var revision: UInt64 = 0
    var canUndo = false
    var canRedo = false
    var undoLabel: String?
    var redoLabel: String?
    var drawingTitle = "Untitled"

    // Command line.
    var commandText = ""
    var suggestionIndex: Int?
    var inputHistory: [String] = []
    var lastCommand: String?
    var commandHistory: [HistoryLine] = []
    var message = "Ready"
    var measurement = ""
    var showCommandReference = false
    var showDraftingSettings = false
    var showUnits = false
    var layerSearch = ""

    @ObservationIgnored private var previousSelection: [UInt64] = []
    @ObservationIgnored private var work: Task<Void, Never>?

    // Canvas and command-line hooks installed by their views.
    @ObservationIgnored var invalidate: (() -> Void)?
    @ObservationIgnored var fitView: (() -> Void)?
    @ObservationIgnored var cancelGesture: (() -> Void)?
    @ObservationIgnored var focusCommandBar: (() -> Void)?
    @ObservationIgnored var zoomBy: ((Double) -> Void)?
    @ObservationIgnored var fitWindow: ((CADBounds) -> Void)?
    @ObservationIgnored var previousView: (() -> Void)?
    @ObservationIgnored var syncInput: (() -> Void)?
    @ObservationIgnored var syncCommandBar: (() -> Void)?
    @ObservationIgnored var focusCommand: (() -> Void)?
    @ObservationIgnored var stateChanged: (() -> Void)?
    @ObservationIgnored var visibleBounds: (() -> CADBounds?)?

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
        if newUnits != units { session.defaults.height = ["mm": 150, "cm": 15, "m": 0.15, "in": 6, "ft": 0.5][newUnits] ?? 150 }
        units = newUnits
        canUndo = state["can_undo"] as? Bool ?? false
        canRedo = state["can_redo"] as? Bool ?? false
        undoLabel = state["undo_label"] as? String
        redoLabel = state["redo_label"] as? String
        selectionData = state["selection"] as? [[String: Any]] ?? []
        grips = (state["grips"] as? [[String: Any]] ?? []).compactMap { g in
            guard let id = (g["id"] as? NSNumber)?.uint64Value, let index = g["index"] as? Int, let x = g["x"] as? Double, let y = g["y"] as? Double else { return nil }
            return CADGrip(id: id, index: index, point: CADPoint(x: x, y: y), kind: g["kind"] as? String ?? "")
        }
        blocks = state["blocks"] as? [String] ?? []
        drawingTitle = document?.displayName ?? "Untitled"
        if old != revision { document?.updateChangeCount(state["dirty"] as? Bool == false ? .changeCleared : .changeDone) }
        invalidate?()
        stateChanged?()
    }
    private func enqueue(_ action: @escaping @MainActor () async -> Void) {
        let previous = work
        work = Task { if let previous { await previous.value }; await action() }
    }
    func waitForIdle() async { await work?.value }
    func operation(_ op: [String: Any]) {
        enqueue { [self] in
            do {
                apply(try await core.request(op))
                try await perform(session.selectionChanged(selection))
                updatePrompt()
            } catch { show(error) }
        }
    }
    func execute(_ text: String) { enqueue { [self] in await processInput(text) } }
    func runFromMenu(_ text: String) {
        commandText = ""; syncInput?(); cancelGesture?()
        enqueue { [self] in session.reset(); await processInput(text) }
    }
    /// Echoes input after its prompt, as AutoCAD's command history does.
    private func record(_ text: String, prompt: String) {
        append(HistoryLine(text: "\(prompt) \(text)", kind: .input))
        if !text.isEmpty { inputHistory.append(text); if inputHistory.count > 200 { inputHistory.removeFirst() } }
    }
    func append(_ line: HistoryLine) {
        commandHistory.append(line); if commandHistory.count > 500 { commandHistory.removeFirst() }
    }
    /// The status bar summarizes state; prompts live in the command line and dynamic input.
    private func updatePrompt() {
        message = session.active ? "" : selection.isEmpty ? "Ready" : "\(selection.count) selected"
        syncInput?(); invalidate?()
    }
    private func fail(_ error: Error, restoring before: CommandSession) {
        session = before; message = error.localizedDescription
        append(HistoryLine(text: error.localizedDescription, kind: .error)); NSSound.beep()
        syncInput?(); invalidate?()
    }
    private func processInput(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        let name = Tool.normalized(parts.first.map(String.init) ?? "")
        if name == "CANCEL" { await cancelNow(); return }
        let before = session
        let prompt = session.prompt
        do {
            if session.active && (parts.count < 2 || session.acceptsSpaces) {
                record(text, prompt: prompt)
                try await perform(session.respond(text, cursor: pointer.coordinate, selected: selection.count)); updatePrompt(); return
            }
            if trimmed.isEmpty {
                guard let lastCommand else { return }
                await processInput(lastCommand); return
            }
            record(text, prompt: prompt)
            if parts.count == 1, let tool = Tool.aliases[name] {
                cancelGesture?(); lastCommand = ["MT", "MTEXT"].contains(name) ? "MTEXT" : tool.commandName
                try await perform(session.start(tool, name: lastCommand!, selected: selection.count)); updatePrompt(); return
            }
            if ["Z", "ZOOM"].contains(name) {
                lastCommand = "ZOOM"; session.startZoom()
                if parts.count == 2 { try await perform(session.respond(String(parts[1]), cursor: pointer.coordinate, selected: selection.count)) }
                updatePrompt(); return
            }
            if name == "ZE" { fitView?(); return }
            if name == "REGEN" || name == "REGENALL" || name == "RE" { invalidate?(); return }
            if ["AREA", "LIST", "LI", "MEASUREGEOM", "AA"].contains(name) { measureSelection(); return }
            if ["GRID", "SNAP", "OSNAP", "ORTHO", "POLAR", "DYNMODE"].contains(name) { try setting(name, argument: parts.count > 1 ? String(parts[1]) : nil); return }
            if ["DS", "DSETTINGS", "OS", "SE"].contains(name) { showDraftingSettings = true; return }
            if ["LA", "LAYER"].contains(name) { show(.layers); return }
            if ["PR", "PROPERTIES", "PROPS"].contains(name) { show(.properties); return }
            if ["UN", "UNITS"].contains(name) && parts.count == 1 { showUnits = true; return }
            if ["OPTIONS", "OP", "PREFERENCES"].contains(name) { SettingsWindowController.shared.showWindow(nil); return }
            if ["MA", "MATCHPROP"].contains(name) && parts.count == 1 { lastCommand = "MATCHPROP"; try await perform(session.startMatchProperties()); updatePrompt(); return }
            if ["SELECT", "SELECTALL"].contains(name) { session.reset(); session.name = "SELECT"; session.stage = .selection; updatePrompt(); return }
            // Full numeric commands remain available for pasted scripts/reference examples.
            session.reset(); cancelGesture?()
            let command = (["X": "EXPLODE", "J": "JOIN", "PU": "PURGE", "MA": "MATCHPROP", "REC": "RECT", "RECTANG": "RECT", "RECTANGLE": "RECT", "H": "HATCH"][name] ?? name) + (parts.count > 1 ? " " + String(parts[1]) : "")
            apply(try await core.request(["op": "command", "text": command]))
            lastCommand = Tool.aliases[name]?.commandName ?? command.split(separator: " ").first.map(String.init)
            updatePrompt()
        } catch {
            fail(error, restoring: before)
        }
    }
    func enterPoint(_ point: CADPoint) {
        enqueue { [self] in
            let before = session
            do { try await perform(session.point(point, selected: selection.count)); commandText = ""; updatePrompt() }
            catch { fail(error, restoring: before) }
        }
    }
    private func perform(_ effects: [CommandSession.Effect]) async throws {
        for effect in effects {
            switch effect {
            case .command(let text):
                if !selection.isEmpty { previousSelection = selection }
                apply(try await core.request(["op": "command", "text": text]))
                if session.tool == .line && text.hasPrefix("LINE ") { session.lineRevisions.append(revision) }
            case .undoLine(let revision): apply(try await core.request(["op": "undo_if_revision", "revision": revision]))
            case .add(let shape): apply(try await core.request(["op": "add", "shapes": [shape]]))
            case .grip(let id, let index, let point): apply(try await core.request(["op": "grip", "id": id, "index": index, "point": point.json]))
            case .clearSelection:
                if !selection.isEmpty { previousSelection = selection }
                apply(try await core.request(["op": "select", "ids": []]))
            case .selectAll: apply(try await core.request(["op": "select_all"]))
            case .selectLast: apply(try await core.request(["op": "select_last"]))
            case .selectPrevious: apply(try await core.request(["op": "select", "ids": previousSelection]))
            case .fit: fitView?()
            case .zoom(let amount): zoomBy?(amount)
            case .zoomWindow(let bounds): fitWindow?(bounds)
            case .previousView: previousView?()
            case .measure(let a, let b):
                measurement = "Distance = \(format(a.distance(b))), Angle = \(format(atan2(b.y - a.y, b.x - a.x) * 180 / .pi))°, ΔX = \(format(b.x - a.x)), ΔY = \(format(b.y - a.y))"
                append(HistoryLine(text: measurement, kind: .info))
            }
        }
    }
    func submit() { let text = commandText; commandText = ""; execute(text); syncInput?() }
    var spaceSubmits: Bool {
        if session.acceptsSpaces { return false }
        let parts = commandText.uppercased().split(whereSeparator: { $0.isWhitespace })
        if let first = parts.first, ["TEXT", "MTEXT", "LEADER", "MLEADER"].contains(String(first)), parts.count >= 4 { return false }
        return true
    }
    func choose(_ tool: Tool) {
        if tool == .select { cancel(); return }
        commandText = ""; syncInput?(); cancelGesture?()
        enqueue { [self] in
            lastCommand = tool.commandName
            let before = session
            record(tool.commandName, prompt: "Command:")
            do { try await perform(session.start(tool, name: tool.commandName, selected: selection.count)); updatePrompt() }
            catch { fail(error, restoring: before) }
        }
    }
    /// Starts a tool and answers its first option, e.g. CIRCLE → 2P.
    func choose(_ tool: Tool, option: String) {
        choose(tool)
        if option == "__DIAMETER" { enqueue { [self] in session.diameter = true; updatePrompt() } } else { execute(option) }
    }
    /// Makes a grip hot; the next point stretches it.
    func startGrip(_ grip: CADGrip) {
        commandText = ""; syncInput?()
        enqueue { [self] in session.startGrip(grip); updatePrompt() }
    }
    func cancel() { commandText = ""; cancelGesture?(); enqueue { [self] in await cancelNow() }; syncInput?() }
    private func cancelNow() async {
        let wasGrip = session.stage == .grip
        session.reset(); commandText = ""
        // Escape at a hot grip cools it, keeping the selection; otherwise it deselects.
        if !wasGrip {
            if !selection.isEmpty { previousSelection = selection }
            if let state = try? await core.request(["op": "select", "ids": []]) { apply(state) }
        }
        message = "*Cancel*"; append(HistoryLine(text: "*Cancel*", kind: .info)); syncInput?(); invalidate?()
    }
    /// Edit ▸ Undo: inside LINE/PLINE/SPLINE it removes the last segment, as U does.
    func undo() {
        let pathTool = session.active && [.line, .polyline, .spline].contains(tool) && session.points.count > 1
        commandText = ""; syncInput?()
        if !pathTool && session.active { cancelGesture?() }
        enqueue { [self] in
            if !pathTool && session.active { session.reset() }
            await processInput(pathTool ? "U" : "UNDO")
        }
    }
    func redo() {
        commandText = ""; syncInput?(); cancelGesture?()
        enqueue { [self] in session.reset(); await processInput("REDO") }
    }
    private func setting(_ name: String, argument: String?) throws {
        let on: Bool?
        if let argument {
            if ["ON", "1", "3"].contains(argument.uppercased()) { on = true }
            else if ["OFF", "0"].contains(argument.uppercased()) { on = false }
            else if name == "SNAP", let n = Double(argument), n.isFinite, n > 0 { snapSpacing = n; gridSnap = true; invalidate?(); return }
            else { throw CoreError.message("Use ON/OFF or 1/0; SNAP also accepts a positive spacing") }
        } else { on = nil }
        switch name {
        case "GRID": grid = on ?? !grid
        case "SNAP": gridSnap = on ?? !gridSnap
        case "OSNAP": snapping = on ?? !snapping
        case "ORTHO": ortho = on ?? !ortho; if ortho { polar = false }
        case "POLAR": polar = on ?? !polar; if polar { ortho = false }
        default: dynamicInput = on ?? !dynamicInput
        }
        message = "\(name) \(on.map { $0 ? "ON" : "OFF" } ?? "toggled")"
        append(HistoryLine(text: message, kind: .info)); invalidate?()
    }
    /// Toggles a drafting aid and echoes its state, as the status bar and function keys do.
    func toggle(_ aid: DraftingAid) {
        switch aid {
        case .grid: grid.toggle()
        case .snap: gridSnap.toggle()
        case .ortho: ortho.toggle(); if ortho { polar = false }
        case .polar: polar.toggle(); if polar { ortho = false }
        case .osnap: snapping.toggle()
        case .dynamicInput: dynamicInput.toggle()
        case .lineweight: lineWeights.toggle()
        }
        let on = isOn(aid)
        append(HistoryLine(text: "<\(aid.title) \(on ? "on" : "off")>", kind: .info))
        invalidate?()
    }
    func isOn(_ aid: DraftingAid) -> Bool {
        switch aid {
        case .grid: return grid
        case .snap: return gridSnap
        case .ortho: return ortho
        case .polar: return polar
        case .osnap: return snapping
        case .dynamicInput: return dynamicInput
        case .lineweight: return lineWeights
        }
    }
    /// Command errors belong in the command history, as in AutoCAD, not in modal alerts.
    func show(_ error: Error) {
        message = error.localizedDescription
        append(HistoryLine(text: error.localizedDescription, kind: .error)); NSSound.beep()
    }
    func show(_ tab: InspectorTab) {
        if showInspector && inspectorTab == tab { showInspector = false } else { inspectorTab = tab; showInspector = true }
    }
    /// ⌘0 Clean Screen hides palettes, toolbar and status bar; again restores them.
    func toggleCleanScreen() {
        if let restore = cleanScreenRestore {
            showTools = restore.tools; showInspector = restore.inspector; showToolbar = restore.toolbar; showStatus = restore.status
            cleanScreenRestore = nil
        } else {
            cleanScreenRestore = (showTools, showInspector, showToolbar, showStatus)
            showTools = false; showInspector = false; showToolbar = false; showStatus = false
        }
    }
    /// ⇧⌘H shows or hides the Tool Sets and inspector palettes together.
    func togglePalettes() {
        let visible = showTools || showInspector
        showTools = !visible; showInspector = !visible
    }
    func layer(_ name: String, values: [String: Any]) { var payload = values; payload["op"] = "layer"; payload["name"] = name; operation(payload) }
    func measureSelection() {
        enqueue { [self] in
            do {
                let result = try await core.request(["op": "measure"])
                let length = result["length"] as? Double ?? 0, area = result["area"] as? Double ?? 0
                measurement = "Length = \(format(length)) \(units), Area = \(format(area)) \(units)²"
                message = measurement; append(HistoryLine(text: measurement, kind: .info))
            } catch { show(error) }
        }
    }
    func patch(_ values: [String: Any]) { var v = values; v["op"] = "properties"; operation(v) }
    func copySelection(cut: Bool = false) {
        enqueue { [self] in
            do {
                let value = try await core.request(["op": "clipboard"])
                let data = try JSONSerialization.data(withJSONObject: value); let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                guard pasteboard.setData(data, forType: .maccadSelection) else { throw CoreError.message("Cannot copy objects to the clipboard") }
                if cut {
                    previousSelection = selection; session.reset(); cancelGesture?()
                    apply(try await core.request(["op": "command", "text": "ERASE"]))
                }
                message = cut ? "Cut \(previousSelection.count) objects" : "Copied \(selection.count) objects"
            } catch { show(error) }
        }
    }
    var canPaste: Bool { NSPasteboard.general.availableType(from: [.maccadSelection]) != nil }
    func pasteSelection() {
        guard let data = NSPasteboard.general.data(forType: .maccadSelection), data.count <= 128 * 1024 * 1024 else { message = "No MacCAD objects on the clipboard"; NSSound.beep(); return }
        enqueue { [self] in
            do {
                let document = try JSONSerialization.jsonObject(with: data); session.reset(); cancelGesture?()
                apply(try await core.request(["op": "paste", "document": document, "at": CADPoint(x: 150, y: 150).json])); updatePrompt()
            } catch { show(error) }
        }
    }
    func extents() async -> CADBounds? {
        guard let state = try? await core.request(["op": "state"]), let b = state["bounds"], !(b is NSNull), let data = try? JSONSerialization.data(withJSONObject: b) else { return nil }
        return try? JSONDecoder().decode(CADBounds.self, from: data)
    }
    /// Linear values at AutoCAD's default four-decimal precision (LUPREC 4).
    func format(_ value: Double) -> String { String(format: "%.4f", value) }
    func demo() {
        guard entityCount == 0 else { return }
        enqueue { [self] in
            do {
                for (name, color) in [("Walls", [0.78, 0.84, 0.90, 1.0]), ("Openings", [0.93, 0.68, 0.34, 1.0]), ("Annotation", [0.42, 0.74, 0.68, 1.0])] {
                    _ = try await core.request(["op": "layer", "name": name, "create": true])
                    _ = try await core.request(["op": "layer", "name": name, "color": color])
                }
                let commands = ["RECT 0,0 8000,6000", "RECT 200,200 7800,5800", "LINE 5000,200 5000,5800", "LINE 5200,200 5200,5800", "LINE 200,3500 5000,3500", "LINE 200,3700 5000,3700"]
                _ = try await core.request(["op": "layer", "name": "Walls", "current": true])
                for c in commands { _ = try await core.request(["op": "command", "text": c]) }
                _ = try await core.request(["op": "layer", "name": "Openings", "current": true])
                for c in ["ARC 1800,200 900 0 90", "LINE 1800,200 1800,1100", "RECT 700,5750 2300,5850", "RECT 5700,5750 7200,5850"] { _ = try await core.request(["op": "command", "text": c]) }
                _ = try await core.request(["op": "layer", "name": "Annotation", "current": true])
                for c in ["TEXT 1400,1900 220 LIVING / DINING", "TEXT 900,4500 180 KITCHEN", "TEXT 5700,3200 180 BEDROOM", "DIM 0,0 8000,0 -650", "DIMALIGNED 8000,0 8000,6000 -650"] { _ = try await core.request(["op": "command", "text": c]) }
                _ = try await core.request(["op": "layer", "name": "0", "current": true])
                await refresh(); fitView?()
            } catch { show(error) }
        }
    }
}

enum DraftingAid: String, CaseIterable, Identifiable {
    case grid, snap, ortho, polar, osnap, dynamicInput, lineweight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .grid: return "Grid"
        case .snap: return "Snap"
        case .ortho: return "Ortho"
        case .polar: return "Polar"
        case .osnap: return "Osnap"
        case .dynamicInput: return "Dynamic Input"
        case .lineweight: return "Lineweight"
        }
    }
    var help: String {
        switch self {
        case .grid: return "Grid Display (F7)"
        case .snap: return "Snap Mode (F9)"
        case .ortho: return "Ortho Mode (F8)"
        case .polar: return "Polar Tracking (F10)"
        case .osnap: return "Object Snap (F3)"
        case .dynamicInput: return "Dynamic Input (F12)"
        case .lineweight: return "Show/Hide Lineweight"
        }
    }
    var symbol: String {
        switch self {
        case .grid: return "grid"
        case .snap: return "dot.squareshape.split.2x2"
        case .ortho: return "angle"
        case .polar: return "scope"
        case .osnap: return "square.dashed.inset.filled"
        case .dynamicInput: return "character.cursor.ibeam"
        case .lineweight: return "line.3.horizontal"
        }
    }
}

extension NSPasteboard.PasteboardType {
    static let maccadSelection = NSPasteboard.PasteboardType("xyz.ckakkar.maccad.selection")
}
