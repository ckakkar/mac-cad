import AppKit
import SwiftUI
import UniformTypeIdentifiers

let nativeDocumentType = "xyz.ckakkar.maccad.drawing"

@MainActor final class DrawingDocument: NSDocument {
    let core: CADCore
    lazy var editor: EditorModel = { let e = EditorModel(core:core); e.document = self; return e }()
    private var imported = false
    override init() { core = CADCore(); super.init(); fileType = nativeDocumentType }
    init(core: CADCore, imported: Bool) { self.core = core; self.imported = imported; super.init(); fileType = nativeDocumentType }
    override class var autosavesInPlace: Bool { true }
    override class var preservesVersions: Bool { true }
    override func makeWindowControllers() {
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:1200,height:800),styleMask:[.titled,.closable,.miniaturizable,.resizable,.fullSizeContentView],backing:.buffered,defer:false)
        window.minSize = NSSize(width:900,height:600)
        window.title = "Untitled"
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView:WorkspaceView(model:editor))
        window.setFrameAutosaveName("MacCAD.Workspace")
        window.center()
        let controller = NSWindowController(window:window)
        addWindowController(controller)
        if imported { updateChangeCount(.changeDone) }
    }
    override func data(ofType typeName: String) throws -> Data {
        guard typeName == nativeDocumentType else { throw CoreError.message("Save as a .maccad drawing. Use Export DXF for exchange files.") }
        let value = try core.requestSync(["op":"serialize"])
        return try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys])
    }
    override func read(from data: Data, ofType typeName: String) throws {
        guard data.count <= 128*1024*1024 else { throw CoreError.message("Native drawing exceeds the alpha's 128 MiB limit") }
        let value = try JSONSerialization.jsonObject(with:data)
        _ = try core.requestSync(["op":"load","document":value])
    }
    override func write(to url: URL, ofType typeName: String) throws {
        guard url.pathExtension.lowercased() == "maccad" else { throw CoreError.message("Native drawings must use .maccad; imported DWG/DXF files cannot be overwritten by native saves.") }
        try super.write(to:url,ofType:typeName)
    }
    override func updateChangeCount(_ change: NSDocument.ChangeType) {
        super.updateChangeCount(change)
        if change == .changeCleared {
            if let state = try? core.requestSync(["op":"state"]), let revision = state["revision"] { _ = try? core.requestSync(["op":"saved","revision":revision]) }
        }
    }
    @objc func undoCommand(_ sender: Any?) { editor.execute("UNDO") }
    @objc func redoCommand(_ sender: Any?) { editor.execute("REDO") }
    @objc func selectAllObjects(_ sender: Any?) { editor.operation(["op":"select_all"]) }
    @objc func eraseObjects(_ sender: Any?) { editor.execute("ERASE") }
    @objc func zoomExtents(_ sender: Any?) { editor.fitView?() }
    @objc func cancelCommand(_ sender: Any?) { editor.cancel() }
    @objc func exportDXF(_ sender: Any?) {
        let alert = NSAlert(); alert.messageText = "Export the supported DXF subset?"
        alert.informativeText = "Exports DXF R2013. Dimensions and hatches become lines/text; solid fills and annotation editing semantics are lost. Layer colors are approximated. Save a native .maccad copy to retain your work."
        alert.addButton(withTitle:"Export DXF…"); alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [UTType(filenameExtension:"dxf") ?? .data]; panel.nameFieldStringValue = "Drawing.dxf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { do { _ = try await core.request(["op":"export_dxf","path":url.path]); editor.message = "Exported DXF R2013 · \(url.lastPathComponent)" } catch { editor.show(error) } }
    }
    @objc func exportPDF(_ sender: Any?) { PDFPlot.export(editor) }
}

@MainActor final class DrawingDocumentController: NSDocumentController {
    override func documentClass(forType typeName: String) -> AnyClass? { DrawingDocument.self }
    override var defaultType: String? { nativeDocumentType }
    override func openDocument(withContentsOf url: URL, display displayDocument: Bool, completionHandler: @escaping (NSDocument?, Bool, Error?) -> Void) {
        let ext = url.pathExtension.lowercased()
        guard ext == "dxf" || ext == "dwg" else { super.openDocument(withContentsOf:url,display:displayDocument,completionHandler:completionHandler); return }
        let alert = NSAlert(); alert.messageText = ext == "dwg" ? "Experimental DWG import" : "Import DXF subset"
        alert.informativeText = "Import creates a new native drawing. Unsupported objects, layouts, styles, fonts, attributes and external references may be omitted or changed. Compare the result with the original before relying on it. The source file will not be overwritten."
        alert.addButton(withTitle:"Import Copy"); alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { completionHandler(nil,false,nil); return }
        Task {
            do {
                let core = CADCore()
                var input = url
                var temporary: URL?
                if ext == "dwg" { input = try await DWGImport.convert(url); temporary = input.deletingLastPathComponent() }
                defer { if let temporary { try? FileManager.default.removeItem(at:temporary) } }
                let state = try await core.request(["op":"import_dxf","path":input.path])
                let doc = DrawingDocument(core:core,imported:true)
                addDocument(doc); doc.makeWindowControllers()
                doc.editor.apply(state)
                if displayDocument { doc.showWindows() }
                doc.editor.fitView?()
                if let warnings = state["diagnostics"] as? [String], !warnings.isEmpty {
                    let notice = NSAlert(); notice.messageText = "Import report"; notice.informativeText = warnings.joined(separator:"\n\n"); notice.runModal()
                }
                completionHandler(doc,false,nil)
            } catch { completionHandler(nil,false,error) }
        }
    }
}

enum DWGImport {
    static func convert(_ source: URL) async throws -> URL {
        try await Task.detached(priority:.userInitiated) {
            // Never execute a drawing-specified command, search PATH, or use a shell.
            let candidates = [Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/dwg2dxf").path,"/opt/homebrew/bin/dwg2dxf","/usr/local/bin/dwg2dxf"]
            guard let executable = candidates.first(where:{FileManager.default.isExecutableFile(atPath:$0)}) else { throw CoreError.message("DWG import requires LibreDWG's dwg2dxf helper. Install the open-source libredwg package, then try again. DWG writing is not supported.") }
            guard (try source.resourceValues(forKeys:[.fileSizeKey]).fileSize ?? 0) <= 128*1024*1024 else { throw CoreError.message("DWG exceeds the 128 MiB import limit") }
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("maccad-dwg-\(UUID().uuidString)",isDirectory:true)
            try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
            let output = dir.appendingPathComponent("import.dxf")
            let log = dir.appendingPathComponent("conversion.log")
            FileManager.default.createFile(atPath:log.path,contents:nil)
            let handle = try FileHandle(forWritingTo:log)
            defer { try? handle.close() }
            let process = Process(); process.executableURL = URL(fileURLWithPath:executable); process.arguments = ["-o",output.path,source.path]; process.standardOutput = handle; process.standardError = handle
            do {
                try process.run()
                let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
                DispatchQueue.global().asyncAfter(deadline:.now()+30,execute:timeout)
                process.waitUntilExit(); timeout.cancel()
                guard process.terminationStatus == 0, FileManager.default.fileExists(atPath:output.path) else { throw CoreError.message("LibreDWG could not convert this drawing (exit \(process.terminationStatus)). No drawing was opened.") }
                return output
            } catch { try? FileManager.default.removeItem(at:dir); throw error }
        }.value
    }
}
