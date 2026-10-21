import AppKit
import Sparkle

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var documents: DrawingDocumentController!
    private var updater: SPUStandardUpdaterController?
    func applicationWillFinishLaunching(_ notification: Notification) {
        documents = DrawingDocumentController()
        let key = Bundle.main.object(forInfoDictionaryKey:"SUPublicEDKey") as? String ?? ""
        if !key.isEmpty { updater = SPUStandardUpdaterController(startingUpdater:true,updaterDelegate:nil,userDriverDelegate:nil) }
        menu()
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps:true)
        if documents.documents.isEmpty { documents.newDocument(nil) }
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        documents.openDocument(withContentsOf:URL(fileURLWithPath:filename),display:true) { _,_,error in if let error { NSApp.presentError(error) } }
        return true
    }
    @objc func checkUpdates(_ sender: Any?) {
        if let updater { updater.checkForUpdates(sender) }
        else { let alert = NSAlert(); alert.messageText = "Updates are not configured in this build";alert.informativeText = "Release builds use signed updates from GitHub. You can check the project's Releases page for downloadable builds.";alert.addButton(withTitle:"View Releases");alert.addButton(withTitle:"Cancel");if alert.runModal() == .alertFirstButtonReturn {NSWorkspace.shared.open(URL(string:"https://github.com/ckakkar/mac-cad/releases")!)} }
    }
    @objc func help(_ sender: Any?) { NSWorkspace.shared.open(URL(string:"https://github.com/ckakkar/mac-cad#readme")!) }
    private func menu() {
        let main = NSMenu()
        func group(_ title: String) -> NSMenu { let item = NSMenuItem();item.title = title;let m = NSMenu(title:title);item.submenu = m;main.addItem(item);return m }
        func item(_ m: NSMenu,_ title: String,_ action: Selector,_ key: String = "",_ target: AnyObject? = nil,_ shift: Bool = false) {
            let i = NSMenuItem(title:title,action:action,keyEquivalent:key);i.target = target;if shift {i.keyEquivalentModifierMask = [.command,.shift]};m.addItem(i)
        }
        let app = group("MacCAD")
        item(app,"About MacCAD",#selector(NSApplication.orderFrontStandardAboutPanel(_:)),"",NSApp)
        item(app,"Check for Updates…",#selector(checkUpdates(_:)),"",self)
        app.addItem(.separator());item(app,"Hide MacCAD",#selector(NSApplication.hide(_:)),"h",NSApp);item(app,"Quit MacCAD",#selector(NSApplication.terminate(_:)),"q",NSApp)
        let file = group("File")
        item(file,"New",#selector(NSDocumentController.newDocument(_:)),"n",documents)
        item(file,"Open…",#selector(NSDocumentController.openDocument(_:)),"o",documents)
        file.addItem(.separator());item(file,"Close",#selector(NSWindow.performClose(_:)),"w")
        item(file,"Save",#selector(NSDocument.save(_:)),"s");item(file,"Save As…",#selector(NSDocument.saveAs(_:)),"s",nil,true)
        file.addItem(.separator());item(file,"Export DXF…",#selector(DrawingDocument.exportDXF(_:)));item(file,"Export Scaled PDF…",#selector(DrawingDocument.exportPDF(_:)),"p")
        let edit = group("Edit")
        item(edit,"Undo",#selector(DrawingDocument.undoCommand(_:)),"z");item(edit,"Redo",#selector(DrawingDocument.redoCommand(_:)),"z",nil,true)
        edit.addItem(.separator());item(edit,"Cut",#selector(NSText.cut(_:)),"x");item(edit,"Copy",#selector(NSText.copy(_:)),"c");item(edit,"Paste",#selector(NSText.paste(_:)),"v");item(edit,"Select All Objects",#selector(DrawingDocument.selectAllObjects(_:)),"a");item(edit,"Erase Objects",#selector(DrawingDocument.eraseObjects(_:)))
        let view = group("View");item(view,"Zoom to Drawing",#selector(DrawingDocument.zoomExtents(_:)),"0");item(view,"Enter Full Screen",#selector(NSWindow.toggleFullScreen(_:)),"f",nil,true)
        let window = group("Window");item(window,"Minimize",#selector(NSWindow.performMiniaturize(_:)),"m");item(window,"Zoom",#selector(NSWindow.performZoom(_:)));NSApp.windowsMenu = window
        let help = group("Help");item(help,"MacCAD on GitHub",#selector(self.help(_:)),"",self);NSApp.helpMenu = help
        NSApp.mainMenu = main
    }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    if CommandLine.arguments.contains("--self-test") {
        Task { exit(await AppSmoke.run()) }
        application.run()
    } else {
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
