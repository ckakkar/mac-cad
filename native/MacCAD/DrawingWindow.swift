import AppKit
import SwiftUI

/// Document window: Tool Sets sidebar, model space, and the Properties/Layers
/// inspector in a native split view, under a customizable unified toolbar.
@MainActor final class DrawingWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate {
    private lazy var commandEditor: CADFieldEditor = { let editor = CADFieldEditor(); editor.isFieldEditor = true; return editor }()
    private(set) weak var model: EditorModel?
    private var split: DrawingSplitViewController?
    private var layerItem: NSMenuToolbarItem?
    private var observing = false
    private var applyingChrome = false

    /// Builds the full drawing workspace for a document.
    convenience init(model: EditorModel) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1380, height: 880), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.minSize = NSSize(width: 860, height: 560)
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "MacCAD.Drawing"
        window.toolbarStyle = .unified
        window.titlebarSeparatorStyle = .automatic
        self.init(window: window)
        self.model = model
        window.delegate = self

        let split = DrawingSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: NSHostingController(rootView: ToolSetsView(model: model)))
        sidebar.minimumThickness = 196; sidebar.maximumThickness = 320; sidebar.canCollapse = true
        sidebar.allowsFullHeightLayout = true
        let content = NSSplitViewItem(viewController: NSHostingController(rootView: WorkspaceView(model: model)))
        content.minimumThickness = 420
        let inspector = NSSplitViewItem(inspectorWithViewController: NSHostingController(rootView: InspectorView(model: model)))
        inspector.minimumThickness = 260; inspector.maximumThickness = 420; inspector.canCollapse = true
        [sidebar, content, inspector].forEach(split.addSplitViewItem)
        split.splitView.autosaveName = "MacCAD.Workspace.Split"
        split.onResize = { [weak self] in self?.syncPaletteState() }
        self.split = split
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1380, height: 880))

        let toolbar = NSToolbar(identifier: "MacCAD.DrawingToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.autosavesConfiguration = true
        window.toolbar = toolbar
        if !window.setFrameUsingName("MacCAD.Workspace") { window.center() }
        window.setFrameAutosaveName("MacCAD.Workspace")
        observeModel()
    }

    // MARK: Model observation

    /// Keeps AppKit chrome (palettes, toolbar, subtitle) in step with the model.
    private func observeModel() {
        guard let model, !observing else { return }
        observing = true
        withObservationTracking {
            _ = (model.showTools, model.showInspector, model.showToolbar, model.currentLayer, model.layers.count, model.units, model.selection.count)
        } onChange: { [weak self] in
            Task { @MainActor in self?.observing = false; self?.syncChrome(); self?.observeModel() }
        }
        syncChrome()
    }
    private func syncChrome() {
        guard let model, let split, split.splitViewItems.count == 3 else { return }
        let sidebar = split.splitViewItems[0], inspector = split.splitViewItems[2]
        if sidebar.isCollapsed == model.showTools || inspector.isCollapsed == model.showInspector {
            applyingChrome = true
            NSAnimationContext.runAnimationGroup { _ in
                if sidebar.isCollapsed == model.showTools { sidebar.animator().isCollapsed = !model.showTools }
                if inspector.isCollapsed == model.showInspector { inspector.animator().isCollapsed = !model.showInspector }
            } completionHandler: { [weak self] in Task { @MainActor in self?.applyingChrome = false } }
        }
        if window?.toolbar?.isVisible != model.showToolbar { window?.toolbar?.isVisible = model.showToolbar }
        let units = ["mm": "Millimeters", "cm": "Centimeters", "m": "Meters", "in": "Inches", "ft": "Feet"][model.units] ?? model.units
        window?.subtitle = "Model · \(units)"
        updateLayerItem()
    }
    /// Collapsing a pane by dragging its divider updates the model too.
    func syncPaletteState() {
        guard !applyingChrome, let model, let split, split.splitViewItems.count == 3 else { return }
        let tools = !split.splitViewItems[0].isCollapsed, inspector = !split.splitViewItems[2].isCollapsed
        if model.showTools != tools { model.showTools = tools }
        if model.showInspector != inspector { model.showInspector = inspector }
    }
    @objc func toggleToolSets(_ sender: Any?) { model?.showTools.toggle() }
    @objc func toggleInspectorPane(_ sender: Any?) { model?.showInspector.toggle() }

    // MARK: Field editor

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        guard let field = client as? CADCommandField else { return nil }
        commandEditor.commandModel = field.model; return commandEditor
    }

    // MARK: Toolbar

    private static let undoRedo = NSToolbarItem.Identifier("undoRedo")
    private static let draw = NSToolbarItem.Identifier("drawTools")
    private static let modify = NSToolbarItem.Identifier("modifyTools")
    private static let annotate = NSToolbarItem.Identifier("annotateTools")
    private static let layer = NSToolbarItem.Identifier("currentLayer")
    private static let plot = NSToolbarItem.Identifier("plot")
    private static let aids = NSToolbarItem.Identifier("draftingAids")
    private static let toolSets = NSToolbarItem.Identifier("toolSets")
    private static let inspectorToggle = NSToolbarItem.Identifier("inspectorToggle")
    private static let drawTools: [Tool] = [.line, .polyline, .circle, .arc, .rectangle]
    private static let modifyTools: [Tool] = [.move, .copy, .rotate, .trim, .offset]
    private static let annotateTools: [Tool] = [.text, .dimension, .hatch]
    private static func toolID(_ tool: Tool) -> NSToolbarItem.Identifier { .init("tool.\(tool.rawValue)") }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toolSets, .sidebarTrackingSeparator, Self.undoRedo, .flexibleSpace, Self.draw, Self.modify, .flexibleSpace, .inspectorTrackingSeparator, Self.layer, .flexibleSpace, Self.plot, Self.inspectorToggle]
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.toolSets, Self.inspectorToggle, .sidebarTrackingSeparator, .inspectorTrackingSeparator, Self.undoRedo, Self.draw, Self.modify, Self.annotate, Self.layer, Self.plot, Self.aids, .space, .flexibleSpace]
            + Tool.allCases.filter { $0 != .select }.map(Self.toolID)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case Self.toolSets:
            return button(id, "Tool Sets", NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: "Tool Sets")!, #selector(toggleToolSets(_:)), help: "Show or hide Tool Sets (⌘1)")
        case Self.inspectorToggle:
            return button(id, "Inspector", NSImage(systemSymbolName: "sidebar.trailing", accessibilityDescription: "Inspector")!, #selector(toggleInspectorPane(_:)), help: "Show or hide Properties and Layers (⌘5)")
        case Self.undoRedo:
            let group = NSToolbarItemGroup(itemIdentifier: id)
            group.subitems = [button(.init("undo"), "Undo", NSImage(systemSymbolName: "arrow.uturn.backward", accessibilityDescription: "Undo")!, #selector(DrawingDocument.undoCommand(_:)), help: "Undo (⌘Z)"),
                              button(.init("redo"), "Redo", NSImage(systemSymbolName: "arrow.uturn.forward", accessibilityDescription: "Redo")!, #selector(DrawingDocument.redoCommand(_:)), help: "Redo (⇧⌘Z)")]
            group.label = "Undo/Redo"; group.paletteLabel = "Undo and Redo"
            return group
        case Self.draw: return toolGroup(id, "Draw", Self.drawTools)
        case Self.modify: return toolGroup(id, "Modify", Self.modifyTools)
        case Self.annotate: return toolGroup(id, "Annotate", Self.annotateTools)
        case Self.layer:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.label = "Layer"; item.paletteLabel = "Current Layer"; item.toolTip = "Current layer"
            item.showsIndicator = true
            item.menu = NSMenu()
            layerItem = item; updateLayerItem()
            return item
        case Self.plot:
            return button(id, "Print", NSImage(systemSymbolName: "printer", accessibilityDescription: "Print")!, #selector(NSDocument.printDocument(_:)), help: "Print or plot to PDF (⌘P)")
        case Self.aids:
            let group = NSToolbarItemGroup(itemIdentifier: id)
            group.subitems = [DraftingAid.ortho, .polar, .osnap, .snap].map { aid in
                button(.init("aid.\(aid.rawValue)"), aid.title, CADIcon.image(for: aid, size: 17), #selector(DrawingDocument.toggleDraftingAid(_:)), help: aid.help, tag: DraftingAid.allCases.firstIndex(of: aid)!)
            }
            group.label = "Drafting Aids"; group.paletteLabel = "Drafting Aids"
            return group
        default:
            guard let tool = Tool.allCases.first(where: { Self.toolID($0) == id }) else { return nil }
            return button(id, tool.title, tool.image, #selector(DrawingDocument.startToolFromToolbar(_:)), help: tool.tooltip, tag: Tool.allCases.firstIndex(of: tool)!)
        }
    }
    private func button(_ id: NSToolbarItem.Identifier, _ label: String, _ image: NSImage, _ action: Selector, help: String, tag: Int = 0) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.label = label; item.paletteLabel = label; item.toolTip = help; item.image = image
        item.action = action; item.tag = tag; item.isBordered = true
        return item
    }
    private func toolGroup(_ id: NSToolbarItem.Identifier, _ label: String, _ tools: [Tool]) -> NSToolbarItem {
        let group = NSToolbarItemGroup(itemIdentifier: id)
        group.subitems = tools.map { tool in button(Self.toolID(tool), tool.title, tool.image, #selector(DrawingDocument.startToolFromToolbar(_:)), help: tool.tooltip, tag: Tool.allCases.firstIndex(of: tool)!) }
        group.label = label; group.paletteLabel = "\(label) Tools"
        return group
    }
    private func updateLayerItem() {
        guard let item = layerItem, let model else { return }
        let menu = NSMenu()
        for layer in model.layers {
            let entry = ClosureMenuItem(title: layer.name, keyEquivalent: "") { [weak model] in model?.layer(layer.name, values: ["current": true]) }
            entry.state = layer.name == model.currentLayer ? .on : .off
            entry.image = Self.swatch(layer.color)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem(title: "Layers Palette…", keyEquivalent: "") { [weak model] in model?.inspectorTab = .layers; model?.showInspector = true })
        item.menu = menu
        item.title = model.currentLayer
        item.image = Self.swatch(model.layers.first { $0.name == model.currentLayer }?.color ?? [0.8, 0.85, 0.9, 1])
    }
    private static func swatch(_ c: [Float]) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { rect in
            NSColor(srgbRed: CGFloat(c[0]), green: CGFloat(c[1]), blue: CGFloat(c[2]), alpha: 1).setFill()
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 2.5, yRadius: 2.5); path.fill()
            NSColor.black.withAlphaComponent(0.3).setStroke(); path.lineWidth = 0.5; path.stroke()
            return true
        }
        return image
    }
}

final class DrawingSplitViewController: NSSplitViewController {
    var onResize: (() -> Void)?
    override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification); onResize?()
    }
}
