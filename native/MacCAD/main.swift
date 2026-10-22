import AppKit
import Sparkle

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    private var documents: DrawingDocumentController!
    private var updater: SPUStandardUpdaterController?
    func applicationWillFinishLaunching(_ notification: Notification) {
        documents = DrawingDocumentController()
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        if !key.isEmpty { updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil) }
        NSApp.mainMenu = MainMenu.build(appDelegate: self, documents: documents)
        // Window tabs are the drawing file tabs; the system adds tab items to the Window menu.
        NSWindow.allowsAutomaticWindowTabbing = true
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular); NSApp.activate()
    }
    func applicationShouldOpenUntitledFile(_ sender: NSApplication) -> Bool { true }
    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        documents.openDocument(withContentsOf: URL(fileURLWithPath: filename), display: true) { _, _, error in if let error { NSApp.presentError(error) } }
        return true
    }
    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.showWindow(sender) }
    @objc func closeAll(_ sender: Any?) { documents.closeAllDocuments(withDelegate: nil, didCloseAllSelector: nil, contextInfo: nil) }
    @objc func checkUpdates(_ sender: Any?) {
        if let updater { updater.checkForUpdates(sender); return }
        let alert = NSAlert(); alert.messageText = "Updates are not configured in this build"
        alert.informativeText = "Release builds use signed updates from GitHub. You can check the project's Releases page for downloadable builds."
        alert.addButton(withTitle: "View Releases"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(URL(string: "https://github.com/ckakkar/mac-cad/releases")!) }
    }
    @objc func help(_ sender: Any?) { NSWorkspace.shared.open(URL(string: "https://github.com/ckakkar/mac-cad/blob/main/USAGE.md")!) }
    @objc func parity(_ sender: Any?) { NSWorkspace.shared.open(URL(string: "https://github.com/ckakkar/mac-cad/blob/main/docs/AUTOCAD_PARITY.md")!) }
    @objc func releaseNotes(_ sender: Any?) { NSWorkspace.shared.open(URL(string: "https://github.com/ckakkar/mac-cad/releases")!) }
    @objc func reportIssue(_ sender: Any?) { NSWorkspace.shared.open(URL(string: "https://github.com/ckakkar/mac-cad/issues/new")!) }
}

MainActor.assumeIsolated {
    let application = NSApplication.shared
    if CommandLine.arguments.contains("--self-test") {
        Task { exit(await AppSmoke.run()) }
        application.run()
    } else if CommandLine.arguments.contains("--render-snapshot") {
        // No event loop: AppKit would treat the path arguments as documents to
        // open and show windows. The main queue alone runs the snapshot.
        application.setActivationPolicy(.prohibited)
        Task { exit(await Snapshot.run(CommandLine.arguments)) }
        dispatchMain()
    } else {
        let delegate = AppDelegate()
        application.delegate = delegate
        application.run()
    }
}
