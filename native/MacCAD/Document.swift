import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Darwin

let nativeDocumentType = "xyz.ckakkar.maccad.drawing"

@MainActor final class DrawingDocument: NSDocument {
    let core: CADCore
    lazy var editor: EditorModel = { let e = EditorModel(core: core); e.document = self; return e }()
    private var imported = false
    override init() { core = CADCore(); super.init(); fileType = nativeDocumentType; hasUndoManager = false }
    init(core: CADCore, imported: Bool) { self.core = core; self.imported = imported; super.init(); fileType = nativeDocumentType; hasUndoManager = false }
    override class var autosavesInPlace: Bool { true }
    override class var preservesVersions: Bool { true }
    override func makeWindowControllers() {
        addWindowController(DrawingWindowController(model: editor))
        if imported { updateChangeCount(.changeDone) }
    }
    var drawingWindow: NSWindow? { windowControllers.first?.window }
    override func data(ofType typeName: String) throws -> Data {
        guard typeName == nativeDocumentType else { throw CoreError.message("Save as a .maccad drawing. Use Export DXF for exchange files.") }
        let value = try core.requestSync(["op": "serialize"])
        return try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
    override func read(from data: Data, ofType typeName: String) throws {
        guard data.count <= 128 * 1024 * 1024 else { throw CoreError.message("Native drawing exceeds the alpha's 128 MiB limit") }
        let value = try JSONSerialization.jsonObject(with: data)
        _ = try core.requestSync(["op": "load", "document": value])
    }
    override func write(to url: URL, ofType typeName: String) throws {
        guard url.pathExtension.lowercased() == "maccad" else { throw CoreError.message("Native drawings must use .maccad; imported DWG/DXF files cannot be overwritten by native saves.") }
        try super.write(to: url, ofType: typeName)
    }
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        if change == .changeCleared {
            if let state = try? core.requestSync(["op": "state"]), let revision = state["revision"] { _ = try? core.requestSync(["op": "saved", "revision": revision]) }
        }
    }

    // MARK: Edit

    @objc func undoCommand(_ sender: Any?) { editor.undo() }
    @objc func redoCommand(_ sender: Any?) { editor.redo() }
    @objc func selectAll(_ sender: Any?) { editor.operation(["op": "select_all"]) }
    @objc func deselectAll(_ sender: Any?) { editor.operation(["op": "select", "ids": []]) }
    @objc func delete(_ sender: Any?) { editor.choose(.erase) }
    @objc func eraseObjects(_ sender: Any?) { editor.execute("ERASE") }
    @objc func copy(_ sender: Any?) { editor.copySelection() }
    @objc func cut(_ sender: Any?) { editor.copySelection(cut: true) }
    @objc func paste(_ sender: Any?) { editor.pasteSelection() }
    @objc func cancelCommand(_ sender: Any?) { editor.cancel() }

    // MARK: Drafting

    /// Menu items carry a tool name, optionally with a first option: "circle|2P".
    @objc func startTool(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let parts = raw.split(separator: "|", maxSplits: 1).map(String.init)
        guard let tool = Tool(rawValue: parts[0]) else { return }
        if parts.count == 2 { editor.choose(tool, option: parts[1]) } else { editor.choose(tool) }
    }
    @objc func startToolFromToolbar(_ sender: Any?) {
        guard let tag = (sender as? NSToolbarItem)?.tag ?? (sender as? NSControl)?.tag, Tool.allCases.indices.contains(tag) else { return }
        editor.choose(Tool.allCases[tag])
    }
    @objc func runCADCommand(_ sender: NSMenuItem) { if let command = sender.representedObject as? String { editor.runFromMenu(command) } }
    @objc func toggleDraftingAid(_ sender: Any?) {
        guard let tag = (sender as? NSMenuItem)?.tag ?? (sender as? NSToolbarItem)?.tag, DraftingAid.allCases.indices.contains(tag) else { return }
        editor.toggle(DraftingAid.allCases[tag])
    }
    @objc func showDraftingSettings(_ sender: Any?) { editor.showDraftingSettings = true }
    @objc func showUnits(_ sender: Any?) { editor.showUnits = true }
    @objc func showCommandReference(_ sender: Any?) { editor.showCommandReference = true }

    // MARK: View

    @objc func toggleToolSets(_ sender: Any?) { editor.showTools.toggle() }
    @objc func toggleCommandLine(_ sender: Any?) { editor.showCommandLine.toggle() }
    @objc func toggleCommandHistory(_ sender: Any?) { editor.showCommandHistory.toggle(); editor.showCommandLine = true }
    @objc func toggleLayers(_ sender: Any?) { editor.show(.layers) }
    @objc func toggleProperties(_ sender: Any?) { editor.show(.properties) }
    @objc func showProperties(_ sender: Any?) { editor.inspectorTab = .properties; editor.showInspector = true }
    @objc func showLayersPalette(_ sender: Any?) { editor.inspectorTab = .layers; editor.showInspector = true }
    @objc func toggleStatusBar(_ sender: Any?) { editor.showStatus.toggle() }
    @objc func toggleCleanScreen(_ sender: Any?) { editor.toggleCleanScreen() }
    @objc func togglePalettes(_ sender: Any?) { editor.togglePalettes() }
    @objc func regenerate(_ sender: Any?) { editor.invalidate?() }
    @objc func zoomIn(_ sender: Any?) { editor.zoomBy?(2) }
    @objc func zoomOut(_ sender: Any?) { editor.zoomBy?(0.5) }
    @objc func zoomExtents(_ sender: Any?) { editor.fitView?() }
    @objc func zoomWindow(_ sender: Any?) { editor.runFromMenu("ZOOM W") }
    @objc func zoomPrevious(_ sender: Any?) { editor.previousView?() }
    @objc func panView(_ sender: Any?) { editor.choose(.pan) }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        let menuItem = item as? NSMenuItem
        let hasSelection = !editor.selection.isEmpty
        func check(_ on: Bool) { menuItem?.state = on ? .on : .off }
        switch item.action {
        case #selector(undoCommand(_:)):
            let lineStep = editor.session.active && [.line, .polyline, .spline].contains(editor.tool) && editor.session.points.count > 1
            menuItem?.title = lineStep ? "Undo Segment" : editor.undoLabel.map { "Undo \($0)" } ?? "Undo"
            return editor.canUndo || lineStep
        case #selector(redoCommand(_:)):
            if menuItem?.isHidden == false { menuItem?.title = editor.redoLabel.map { "Redo \($0)" } ?? "Redo" }
            return editor.canRedo
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)), #selector(deselectAll(_:)): return hasSelection
        case #selector(paste(_:)): return editor.canPaste
        case #selector(selectAll(_:)): return editor.entityCount > 0
        case #selector(runCADCommand(_:)):
            let command = menuItem?.representedObject as? String ?? ""
            let needsSelection = ["SELECTSIMILAR", "OVERKILL", "CLOSE", "OPEN", "REVERSE", "AREA", "LAYMCUR", "LAYISO", "LAYOFF", "LAYLOCK"].contains(command)
            return !needsSelection || hasSelection
        case #selector(toggleDraftingAid(_:)):
            if let tag = menuItem?.tag, DraftingAid.allCases.indices.contains(tag) { check(editor.isOn(DraftingAid.allCases[tag])) }
            return true
        case #selector(toggleToolSets(_:)): check(editor.showTools); return true
        case #selector(toggleCommandLine(_:)): check(editor.showCommandLine); return true
        case #selector(toggleCommandHistory(_:)): check(editor.showCommandHistory && editor.showCommandLine); return true
        case #selector(toggleLayers(_:)): check(editor.showInspector && editor.inspectorTab == .layers); return true
        case #selector(toggleProperties(_:)): check(editor.showInspector && editor.inspectorTab == .properties); return true
        case #selector(toggleStatusBar(_:)): check(editor.showStatus); return true
        case #selector(toggleCleanScreen(_:)): check(editor.cleanScreen); return true
        case #selector(togglePalettes(_:)): menuItem?.title = editor.showTools || editor.showInspector ? "Hide All Palettes" : "Show All Palettes"; return true
        case #selector(zoomPrevious(_:)), #selector(zoomExtents(_:)): return editor.entityCount > 0 || item.action == #selector(zoomPrevious(_:))
        case #selector(exportDXF(_:)), #selector(exportPDF(_:)), #selector(NSDocument.printDocument(_:)): return editor.entityCount > 0
        default: return super.validateUserInterfaceItem(item)
        }
    }

    // MARK: Export and print

    @objc func exportDXF(_ sender: Any?) {
        guard let window = drawingWindow else { return }
        let alert = NSAlert(); alert.messageText = "Export the supported DXF subset?"
        alert.informativeText = "Exports DXF R2013. Dimensions and hatches become lines/text; solid fills and annotation editing semantics are lost. Layer colors are approximated. Keep the native .maccad drawing to retain your work."
        alert.addButton(withTitle: "Export DXF…"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [self] response in
            guard response == .alertFirstButtonReturn else { return }
            let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension: "dxf") ?? .data]
            panel.nameFieldStringValue = (displayName as NSString).deletingPathExtension + ".dxf"
            panel.beginSheetModal(for: window) { [self] result in
                guard result == .OK, let url = panel.url else { return }
                Task {
                    do { _ = try await core.request(["op": "export_dxf", "path": url.path]); editor.message = "Exported DXF R2013 · \(url.lastPathComponent)"; editor.append(HistoryLine(text: editor.message, kind: .info)) }
                    catch { presentError(error, modalFor: window, delegate: nil, didPresent: nil, contextInfo: nil) }
                }
            }
        }
    }
    @objc func exportPDF(_ sender: Any?) { PDFPlot.export(editor, window: drawingWindow) }
    override func printOperation(withSettings printSettings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        try PlotPrinting.operation(for: self, settings: printSettings)
    }
}

@MainActor final class DrawingDocumentController: NSDocumentController {
    override func documentClass(forType typeName: String) -> AnyClass? { DrawingDocument.self }
    override var defaultType: String? { nativeDocumentType }
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool, completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        let ext = url.pathExtension.lowercased()
        guard ext == "dxf" || ext == "dwg" else { super.openDocument(withContentsOf: url, display: displayDocument, completionHandler: completionHandler); return }
        let alert = NSAlert(); alert.messageText = ext == "dwg" ? "Experimental DWG import" : "Import DXF subset"
        alert.informativeText = "Import creates a new native drawing. Unsupported objects, layouts, styles, fonts, attributes and external references may be omitted or changed. Compare the result with the original before relying on it. The source file will not be overwritten."
        alert.addButton(withTitle: "Import Copy"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { completionHandler(nil, false, nil); return }
        Task {
            do {
                let core = CADCore()
                var input = url
                var temporary: URL?
                var conversionWarnings: [String] = []
                if ext == "dwg" { let converted = try await DWGImport.convert(url); input = converted.file; conversionWarnings = converted.warnings; temporary = input.deletingLastPathComponent() }
                defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
                var state = try await core.request(["op": "import_dxf", "path": input.path])
                state["diagnostics"] = (state["diagnostics"] as? [String] ?? []) + conversionWarnings
                let doc = DrawingDocument(core: core, imported: true)
                doc.displayName = (url.lastPathComponent as NSString).deletingPathExtension
                addDocument(doc); doc.makeWindowControllers()
                doc.editor.apply(state)
                if displayDocument { doc.showWindows() }
                doc.editor.fitView?()
                if let warnings = state["diagnostics"] as? [String], !warnings.isEmpty, let window = doc.drawingWindow {
                    let notice = NSAlert(); notice.messageText = "Import report"; notice.informativeText = warnings.joined(separator: "\n\n")
                    notice.beginSheetModal(for: window, completionHandler: nil)
                    for warning in warnings { doc.editor.append(HistoryLine(text: "Import: \(warning)", kind: .info)) }
                }
                completionHandler(doc, false, nil)
            } catch { completionHandler(nil, false, error) }
        }
    }
}

enum DWGImport {
    struct Conversion { let file: URL; let warnings: [String] }
    static func convert(_ source: URL) async throws -> Conversion {
        try await Task.detached(priority: .userInitiated) {
            // Never execute a drawing-specified command, search PATH, or use a shell.
            let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dwg2dxf").path, "/opt/homebrew/bin/dwg2dxf", "/usr/local/bin/dwg2dxf"]
            guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { throw CoreError.message("DWG import requires LibreDWG's dwg2dxf helper. Install the open-source libredwg package, then try again. DWG writing is not supported.") }
            guard (try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 128 * 1024 * 1024 else { throw CoreError.message("DWG exceeds the 128 MiB import limit") }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maccad-dwg-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let output = dir.appendingPathComponent("import.dxf")
            let log = dir.appendingPathComponent("conversion.log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let handle = try FileHandle(forWritingTo: log)
            defer { try? handle.close() }
            let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = ["-o", output.path, source.path]; process.standardOutput = handle; process.standardError = handle
            do {
                try process.run()
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate(); DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if process.isRunning { kill(process.processIdentifier, SIGKILL) } } } }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeout)
                process.waitUntilExit(); timeout.cancel()
                guard process.terminationStatus == 0, FileManager.default.fileExists(atPath: output.path) else { throw CoreError.message("LibreDWG could not convert this drawing (exit \(process.terminationStatus)). No drawing was opened.") }
                let reader = try FileHandle(forReadingFrom: log); defer { try? reader.close() }
                let logData = try reader.read(upToCount: 65536) ?? Data()
                let warnings = String(decoding: logData, as: UTF8.self).split(separator: "\n").filter { $0.contains("Warning:") || $0.contains("ERROR:") }.prefix(40).map(String.init)
                return Conversion(file: output, warnings: warnings)
            } catch { try? FileManager.default.removeItem(at: dir); throw error }
        }.value
    }
}
