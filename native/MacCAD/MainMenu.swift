import AppKit

/// The menu bar follows AutoCAD for Mac's order and published Mac shortcuts,
/// with standard macOS items (Settings, Services, Open Recent, Window tabs).
/// Items without a target travel the responder chain to the active drawing.
@MainActor enum MainMenu {
    static func build(appDelegate: AppDelegate, documents: NSDocumentController) -> NSMenu {
        let main = NSMenu()
        func menu(_ title: String) -> NSMenu { let item = NSMenuItem(title: title, action: nil, keyEquivalent: ""); let m = NSMenu(title: title); item.submenu = m; main.addItem(item); return m }
        @discardableResult func add(_ m: NSMenu, _ title: String, _ action: Selector?, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil, object: Any? = nil, tag: Int = 0, image: NSImage? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
            i.keyEquivalentModifierMask = modifiers; i.target = target; i.representedObject = object; i.tag = tag; i.image = image
            m.addItem(i); return i
        }
        func submenu(_ m: NSMenu, _ title: String, image: NSImage? = nil) -> NSMenu { let i = NSMenuItem(title: title, action: nil, keyEquivalent: ""); i.image = image; let s = NSMenu(title: title); i.submenu = s; m.addItem(i); return s }
        func tool(_ m: NSMenu, _ tool: Tool, _ title: String? = nil, key: String = "", option: String? = nil) {
            let i = add(m, title ?? tool.title, #selector(DrawingDocument.startTool(_:)), key, object: option.map { "\(tool.rawValue)|\($0)" } ?? tool.rawValue, image: CADIcon.image(for: tool, size: 16))
            i.toolTip = tool.tooltip
        }
        func command(_ m: NSMenu, _ title: String, _ text: String, key: String = "", _ modifiers: NSEvent.ModifierFlags = .command) {
            add(m, title, #selector(DrawingDocument.runCADCommand(_:)), key, modifiers, object: text)
        }
        func fkey(_ n: Int) -> String { String(UnicodeScalar(NSF1FunctionKey + n - 1)!) }

        // MacCAD
        let app = menu("MacCAD")
        add(app, "About MacCAD", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        add(app, "Check for Updates…", #selector(AppDelegate.checkUpdates(_:)), target: appDelegate)
        app.addItem(.separator())
        add(app, "Settings…", #selector(AppDelegate.showSettings(_:)), ",", target: appDelegate)
        app.addItem(.separator())
        let services = submenu(app, "Services"); NSApp.servicesMenu = services
        app.addItem(.separator())
        add(app, "Hide MacCAD", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp)
        add(app, "Show All", #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        app.addItem(.separator())
        add(app, "Quit MacCAD", #selector(NSApplication.terminate(_:)), "q", target: NSApp)

        // File
        let file = menu("File")
        add(file, "New", #selector(NSDocumentController.newDocument(_:)), "n", target: documents)
        add(file, "Open…", #selector(NSDocumentController.openDocument(_:)), "o", target: documents)
        let recent = submenu(file, "Open Recent")
        add(recent, "Clear Menu", #selector(NSDocumentController.clearRecentDocuments(_:)), target: documents)
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w")
        add(file, "Close All", #selector(AppDelegate.closeAll(_:)), "w", [.command, .option], target: appDelegate)
        add(file, "Save", #selector(NSDocument.save(_:)), "s")
        add(file, "Save As…", #selector(NSDocument.saveAs(_:)), "s", [.command, .shift])
        add(file, "Duplicate", #selector(NSDocument.duplicate(_:)))
        add(file, "Rename…", #selector(NSDocument.rename(_:)))
        add(file, "Move To…", #selector(NSDocument.move(_:)))
        add(file, "Revert to Saved", #selector(NSDocument.revertToSaved(_:)))
        file.addItem(.separator())
        let export = submenu(file, "Export")
        add(export, "DXF…", #selector(DrawingDocument.exportDXF(_:)), "e", [.command, .shift])
        add(export, "PDF…", #selector(DrawingDocument.exportPDF(_:)))
        file.addItem(.separator())
        add(file, "Page Setup…", #selector(NSDocument.runPageLayout(_:)), "p", [.command, .shift])
        add(file, "Print…", #selector(NSDocument.printDocument(_:)), "p")

        // Edit
        let edit = menu("Edit")
        add(edit, "Undo", #selector(DrawingDocument.undoCommand(_:)), "z")
        add(edit, "Redo", #selector(DrawingDocument.redoCommand(_:)), "z", [.command, .shift])
        let redoY = add(edit, "Redo", #selector(DrawingDocument.redoCommand(_:)), "y")
        redoY.isHidden = true; redoY.allowsKeyEquivalentWhenHidden = true
        edit.addItem(.separator())
        add(edit, "Cut", #selector(NSText.cut(_:)), "x")
        add(edit, "Copy", #selector(NSText.copy(_:)), "c")
        add(edit, "Paste", #selector(NSText.paste(_:)), "v")
        add(edit, "Delete", #selector(NSText.delete(_:)))
        add(edit, "Select All", #selector(NSText.selectAll(_:)), "a")
        add(edit, "Deselect All", #selector(DrawingDocument.deselectAll(_:)), "a", [.command, .option])
        command(edit, "Select Similar", "SELECTSIMILAR")

        // View
        let view = menu("View")
        add(view, "Tool Sets", #selector(DrawingDocument.toggleToolSets(_:)), "1")
        add(view, "Command Line", #selector(DrawingDocument.toggleCommandLine(_:)), "3")
        add(view, "Layers", #selector(DrawingDocument.toggleLayers(_:)), "4")
        add(view, "Properties Inspector", #selector(DrawingDocument.toggleProperties(_:)), "5")
        let inspector = add(view, "Properties Inspector", #selector(DrawingDocument.showProperties(_:)), "i")
        inspector.isHidden = true; inspector.allowsKeyEquivalentWhenHidden = true
        add(view, "Status Bar", #selector(DrawingDocument.toggleStatusBar(_:)), "6")
        add(view, "Command History", #selector(DrawingDocument.toggleCommandHistory(_:)), fkey(2), [])
        view.addItem(.separator())
        add(view, "Clean Screen", #selector(DrawingDocument.toggleCleanScreen(_:)), "0")
        add(view, "Hide All Palettes", #selector(DrawingDocument.togglePalettes(_:)), "h", [.command, .shift])
        view.addItem(.separator())
        let zoom = submenu(view, "Zoom")
        add(zoom, "Zoom In", #selector(DrawingDocument.zoomIn(_:)), "=")
        let plus = add(zoom, "Zoom In", #selector(DrawingDocument.zoomIn(_:)), "+")
        plus.isHidden = true; plus.allowsKeyEquivalentWhenHidden = true
        add(zoom, "Zoom Out", #selector(DrawingDocument.zoomOut(_:)), "-")
        zoom.addItem(.separator())
        add(zoom, "Extents", #selector(DrawingDocument.zoomExtents(_:)))
        add(zoom, "Window", #selector(DrawingDocument.zoomWindow(_:)))
        add(zoom, "Previous", #selector(DrawingDocument.zoomPrevious(_:)))
        add(view, "Pan", #selector(DrawingDocument.panView(_:)))
        view.addItem(.separator())
        add(view, "Regen", #selector(DrawingDocument.regenerate(_:)), "r")
        view.addItem(.separator())
        add(view, "Show Toolbar", #selector(NSWindow.toggleToolbarShown(_:)), "t", [.command, .option])
        add(view, "Customize Toolbar…", #selector(NSWindow.runToolbarCustomizationPalette(_:)))
        add(view, "Enter Full Screen", #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])

        // Insert
        let insert = menu("Insert")
        tool(insert, .insert, "Block")
        tool(insert, .block, "Create Block")

        // Format
        let format = menu("Format")
        add(format, "Layer…", #selector(DrawingDocument.showLayersPalette(_:)))
        let layerTools = submenu(format, "Layer Tools")
        command(layerTools, "Make Object's Layer Current", "LAYMCUR")
        command(layerTools, "Layer Isolate", "LAYISO")
        command(layerTools, "Layer Unisolate", "LAYUNISO")
        command(layerTools, "Layer Off", "LAYOFF")
        command(layerTools, "Turn All Layers On", "LAYON")
        command(layerTools, "Layer Lock", "LAYLOCK")
        command(layerTools, "Unlock All Layers", "LAYUNLOCK")
        format.addItem(.separator())
        add(format, "Units…", #selector(DrawingDocument.showUnits(_:)))
        format.addItem(.separator())
        add(format, "Lineweight Display", #selector(DrawingDocument.toggleDraftingAid(_:)), tag: DraftingAid.allCases.firstIndex(of: .lineweight)!)

        // Tools
        let tools = menu("Tools")
        let inquiry = submenu(tools, "Inquiry")
        tool(inquiry, .measure, "Distance")
        command(inquiry, "Area and Length of Selection", "AREA")
        let utilities = submenu(tools, "Drawing Utilities")
        command(utilities, "Purge Unused Blocks and Layers", "PURGE")
        command(utilities, "Delete Duplicate Objects", "OVERKILL")
        tools.addItem(.separator())
        for aid in DraftingAid.allCases where aid != .lineweight {
            let key: (String, NSEvent.ModifierFlags)
            switch aid {
            case .grid: key = (fkey(7), [])
            case .snap: key = ("b", .command)
            case .ortho: key = ("l", .command)
            case .polar: key = ("u", .command)
            case .osnap: key = (fkey(3), [])
            case .dynamicInput: key = ("d", [.command, .shift])
            case .lineweight: key = ("", .command)
            }
            add(tools, aid.help.replacingOccurrences(of: #" \(F\d+\)"#, with: "", options: .regularExpression), #selector(DrawingDocument.toggleDraftingAid(_:)), key.0, key.1, tag: DraftingAid.allCases.firstIndex(of: aid)!)
        }
        tools.addItem(.separator())
        add(tools, "Drafting Settings…", #selector(DrawingDocument.showDraftingSettings(_:)))

        // Draw
        let draw = menu("Draw")
        tool(draw, .line); tool(draw, .polyline); tool(draw, .rectangle); tool(draw, .polygon)
        let circle = submenu(draw, "Circle", image: CADIcon.image(for: .circle, size: 16))
        tool(circle, .circle, "Center, Radius"); tool(circle, .circle, "Center, Diameter", option: "__DIAMETER")
        tool(circle, .circle, "2-Point", option: "2P"); tool(circle, .circle, "3-Point", option: "3P")
        let arc = submenu(draw, "Arc", image: CADIcon.image(for: .arc, size: 16))
        tool(arc, .arc, "3-Point"); tool(arc, .arc, "Center, Start, End", option: "C")
        let ellipse = submenu(draw, "Ellipse", image: CADIcon.image(for: .ellipse, size: 16))
        tool(ellipse, .ellipse, "Axis, End"); tool(ellipse, .ellipse, "Center", option: "C")
        tool(draw, .spline); tool(draw, .point)
        draw.addItem(.separator())
        tool(draw, .hatch, "Hatch")
        draw.addItem(.separator())
        let text = submenu(draw, "Text", image: CADIcon.image(for: .text, size: 16))
        command(text, "Single Line Text", "TEXT")
        command(text, "Multiline Text", "MTEXT")
        draw.addItem(.separator())
        tool(draw, .block, "Block")

        // Dimension
        let dimension = menu("Dimension")
        tool(dimension, .dimension, "Linear"); tool(dimension, .alignedDimension, "Aligned")
        tool(dimension, .radius, "Radius"); tool(dimension, .diameter, "Diameter")
        dimension.addItem(.separator())
        tool(dimension, .leader, "Leader")

        // Modify
        let modify = menu("Modify")
        add(modify, "Properties", #selector(DrawingDocument.showProperties(_:)))
        command(modify, "Match Properties", "MATCHPROP")
        modify.addItem(.separator())
        tool(modify, .erase); tool(modify, .copy); tool(modify, .mirror); tool(modify, .offset)
        let array = submenu(modify, "Array", image: CADIcon.image(for: .arrayRect, size: 16))
        tool(array, .arrayRect, "Rectangular Array"); tool(array, .arrayPolar, "Polar Array")
        tool(modify, .move); tool(modify, .rotate); tool(modify, .scale)
        tool(modify, .trim); tool(modify, .extend); tool(modify, .breakLine); tool(modify, .join)
        tool(modify, .chamfer); tool(modify, .fillet)
        modify.addItem(.separator())
        tool(modify, .explode)
        let polyline = submenu(modify, "Object")
        command(polyline, "Close Polyline", "CLOSE")
        command(polyline, "Open Polyline", "OPEN")
        command(polyline, "Reverse", "REVERSE")

        // Window
        let window = menu("Window")
        add(window, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m")
        add(window, "Zoom", #selector(NSWindow.performZoom(_:)))
        window.addItem(.separator())
        add(window, "Bring All to Front", #selector(NSApplication.arrangeInFront(_:)), target: NSApp)
        NSApp.windowsMenu = window

        // Help
        let help = menu("Help")
        add(help, "MacCAD Help", #selector(AppDelegate.help(_:)), "/", target: appDelegate)
        add(help, "Command Reference", #selector(DrawingDocument.showCommandReference(_:)))
        add(help, "AutoCAD Parity Status", #selector(AppDelegate.parity(_:)), target: appDelegate)
        help.addItem(.separator())
        add(help, "Release Notes", #selector(AppDelegate.releaseNotes(_:)), target: appDelegate)
        add(help, "Report an Issue…", #selector(AppDelegate.reportIssue(_:)), target: appDelegate)
        NSApp.helpMenu = help
        return main
    }
}
