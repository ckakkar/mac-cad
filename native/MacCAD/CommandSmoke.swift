import AppKit

/// End-to-end prompt sequences use the shipped coordinator and real Rust core.
@MainActor enum CommandSmoke {
    static func run() async throws {
        func require(_ condition:Bool,_ message:String) throws {if !condition{throw CoreError.message("Command workflow: "+message)}}
        let model = EditorModel(core:CADCore())
        await model.refresh()
        let window = NSWindow(contentRect:NSRect(x:0,y:0,width:600,height:400),styleMask:[.titled],backing:.buffered,defer:false)
        let controller = DrawingWindowController(window:window);window.delegate = controller
        let field = CADCommandField(model:model);window.contentView?.addSubview(field)
        guard let editor = window.fieldEditor(true,for:field) as? CADFieldEditor else {throw CoreError.message("Command field did not receive its dedicated CAD field editor")}
        editor.commandModel = model
        func key(_ code:UInt16,_ characters:String,_ flags:NSEvent.ModifierFlags = []) throws -> NSEvent {
            guard let e = NSEvent.keyEvent(with:.keyDown,location:.zero,modifierFlags:flags,timestamp:0,windowNumber:window.windowNumber,context:nil,characters:characters,charactersIgnoringModifiers:characters,isARepeat:false,keyCode:code) else {throw CoreError.message("Cannot create command key fixture")};return e
        }
        func feed(_ inputs:[String]) async {for input in inputs{model.execute(input)};await model.waitForIdle()}
        func document() async throws -> [String:Any] {try await model.core.request(["op":"serialize"])}
        func shapes() async throws -> [[String:Any]] {let d = try await document();return (d["entities"] as? [String:[String:Any]] ?? [:]).sorted{(UInt64($0.key) ?? 0)<(UInt64($1.key) ?? 0)}.map(\.value)}
        model.commandText = "L";editor.keyDown(with:try key(49," "));await model.waitForIdle()
        try require(model.tool == .line && model.entityCount == 0,"Space must start an alias without inserting a blank")
        await feed(["0,0","@100<0","@100<90","U","@0,100","C"])
        try require(model.entityCount == 3 && !model.session.active,"LINE must continue, undo its last segment and close")
        editor.keyDown(with:try key(49," "));await model.waitForIdle()
        try require(model.tool == .line && model.session.points.isEmpty,"Blank Space must repeat the command, without replaying old coordinates")
        model.cancel();await model.waitForIdle()
        await feed(["M","A","","0,0","@5,10"])
        try require(model.entityCount == 3 && model.selection.isEmpty && !model.session.active,"Command-first MOVE must select, confirm and move")
        let moved = try await shapes();let start = moved[0]["a"] as? [String:Double]
        try require(start?["x"] == 5 && start?["y"] == 10,"MOVE must use the entered displacement")
        await feed(["C","200,200","D","50"])
        let circles = try await shapes();let circle = circles.last
        try require(circle?["kind"] as? String == "circle" && circle?["radius"] as? Double == 25,"Circle diameter prompt must produce the correct radius")
        await feed(["E","L",""])
        try require(model.entityCount == 3,"ERASE Last must remove only the last object")
        await feed(["C","2P","0,0","10,0"])
        let twoPoint = try await shapes()
        try require(twoPoint.last?["radius"] as? Double == 5,"2-point circle must use a diameter")
        await feed(["C","3P","1,0","0,1","-1,0"])
        let threePoint = try await shapes()
        try require(abs((threePoint.last?["radius"] as? Double ?? 0)-1)<1e-9,"3-point circle must pass through the supplied points")
        await feed(["C","300,0","0"])
        try require(model.session.stage == .radius && model.entityCount == 5,"Invalid radius must preserve the current prompt and drawing")
        await feed(["75"])
        try require(model.entityCount == 6 && !model.session.active,"A corrected radius must complete the retained command")
        await feed(["T","500,500","50","30"])
        try require(!model.spaceSubmits,"Space must remain literal while entering annotation text")
        await feed(["Living room north"])
        let annotations = try await shapes();let annotation = annotations.last
        try require(annotation?["text"] as? String == "Living room north" && abs((annotation?["rotation"] as? Double ?? 0)-Double.pi/6)<1e-9,"Text must retain spaces and numeric rotation")
        await feed(["POL","6","0,0","C","100"])
        let polygons = try await shapes();let polygon = polygons.last
        try require((polygon?["vertices"] as? [Any])?.count == 6,"Polygon must prompt for side count and construction mode")
        model.choose(.line);await model.waitForIdle();model.enterPoint(.zero);model.choose(.circle);await model.waitForIdle()
        try require(model.tool == .circle && model.session.points.isEmpty,"Palette tools must interrupt a pending gesture")
        model.cancel();await model.waitForIdle()
        var fitted = false;var zoomed = 0.0
        model.fitView = {fitted = true};model.zoomBy = {zoomed = $0}
        await feed(["Z","E","ZOOM 2X"])
        try require(fitted && zoomed == 2,"ZOOM option and factor prompts must invoke navigation")
        model.operation(["op":"select","ids":[1]]);await model.waitForIdle()
        await feed(["O","10","0,1000",""])
        try require(model.entityCount == 9 && model.selection.isEmpty,"OFFSET must accept distance and side then finish on Return")
        let expected = try await document()
        model.choose(.move);await model.waitForIdle();model.enterPoint(.zero);model.cancel();await model.waitForIdle()
        let cancelled = try await document()
        try require(NSDictionary(dictionary:expected).isEqual(to:cancelled),"Escape must cancel pending geometry without changing the document")
        let prior = model.grid;editor.keyDown(with:try key(98,""));try require(model.grid != prior,"F7 must toggle the grid from a command input")
        model.commandText = "CI";let delegate = CommandTextDelegate(model);let textView = NSTextView()
        _ = delegate.control(field,textView:textView,doCommandBy:#selector(NSResponder.insertTab(_:)))
        try require(model.commandText == "CIRCLE","Tab completion must resolve a command")
        let textField = NSTextField();try require(window.fieldEditor(true,for:textField) is CADFieldEditor == false,"Ordinary text fields must retain the standard field editor")
        let mixed = EditorModel(core:CADCore());await mixed.refresh()
        for input in ["L","0,0","10,0"]{mixed.execute(input)};await mixed.waitForIdle()
        mixed.layer("0",values:["color":[1,0,0,1]]);await mixed.waitForIdle()
        let beforeMixedUndo = try await mixed.core.request(["op":"serialize"])
        mixed.execute("U");await mixed.waitForIdle()
        let afterMixedUndo = try await mixed.core.request(["op":"serialize"])
        try require(NSDictionary(dictionary:beforeMixedUndo).isEqual(to:afterMixedUndo) && mixed.session.points.count == 2,"LINE Undo must not undo an intervening layer edit or consume its pending points")
        let compound = EditorModel(core:CADCore());await compound.refresh()
        func build(_ inputs:[String]) async {for input in inputs{compound.execute(input)};await compound.waitForIdle()}
        await build(["LINE 0,0 10,0","AR","A","","2","3","100","200"])
        try require(compound.entityCount == 6 && !compound.session.active,"Rectangular array prompts must create the requested copies")
        await build(["B","L","","door","200,200","I","door","500,0","2","90"])
        try require(compound.entityCount == 7 && compound.blocks.contains("door"),"Block creation and insert prompts must preserve references")
        await build(["X","L","","BR","L","","500,10"])
        try require(compound.entityCount == 8,"Command-first explode and break must operate on the accepted selection")
        let joined = EditorModel(core:CADCore());await joined.refresh()
        for input in ["LINE 0,0 10,0","LINE 10,0 20,0","J","A",""]{joined.execute(input)}
        await joined.waitForIdle();try require(joined.entityCount == 1,"JOIN must accept selection after invocation")
        for input in ["X","A",""]{joined.execute(input)}
        await joined.waitForIdle();try require(joined.entityCount == 2,"EXPLODE must accept selection after invocation")
        try await nativeWorkflows(require)
        print("Command workflows passed: Space/Return, repeat, selection-first/command-first, line Close/Undo, polar input, circle options, error recovery, text spaces/rotation, polygon, tool interruption, zoom, offset side, cancellation, function keys, completion and field-editor isolation.")
        print("Native workflows passed: hot grips, grip cancel, MATCHPROP, Edit Undo inside LINE, undo titles, prompt options, autocomplete, circle diameter menu, layer rename.")
    }

    /// Workflows behind the native workspace: grips, menus, inspector and command line.
    static func nativeWorkflows(_ require: (Bool, String) throws -> Void) async throws {
        func entity(_ model: EditorModel, _ id: Int) async throws -> [String: Any] {
            let d = try await model.core.request(["op": "serialize"])
            return (d["entities"] as? [String: [String: Any]])?[String(id)] ?? [:]
        }
        let grips = EditorModel(core: CADCore()); await grips.refresh()
        grips.execute("LINE 0,0 100,0"); grips.operation(["op": "select", "ids": [1]]); await grips.waitForIdle()
        try require(grips.grips.count == 3, "A selected line must expose endpoint and midpoint grips")
        grips.startGrip(grips.grips[1]); await grips.waitForIdle()
        try require(grips.session.stage == .grip && grips.session.prompt.contains("STRETCH"), "Clicking a grip must make it hot")
        grips.execute("@0,50"); await grips.waitForIdle()
        let stretched = try await entity(grips, 1)["b"] as? [String: Double]
        try require(stretched?["x"] == 100 && stretched?["y"] == 50, "Relative input must stretch from the hot grip")
        try require(grips.undoLabel == "Grip Edit" && grips.selection == [1] && !grips.session.active, "Grip edits must be undoable and keep the selection")
        grips.startGrip(grips.grips[0]); grips.cancel(); await grips.waitForIdle()
        try require(!grips.session.active && grips.selection == [1], "Escape must cool a hot grip without deselecting")
        grips.undo(); await grips.waitForIdle()
        let restored = try await entity(grips, 1)["b"] as? [String: Double]
        try require(restored?["y"] == 0, "Undo must restore the stretched grip")

        let match = EditorModel(core: CADCore()); await match.refresh()
        match.layer("Walls", values: ["create": true]); match.execute("LINE 0,0 10,0")
        match.layer("0", values: ["current": true]); match.execute("LINE 0,10 10,10")
        match.execute("MA"); await match.waitForIdle()
        try require(match.session.stage == .matchSource && match.selecting, "MATCHPROP must ask for a source object")
        match.operation(["op": "pick", "point": ["x": 5.0, "y": 0.0], "tolerance": 1.0, "extend": true, "mode": "add"]); await match.waitForIdle()
        try require(match.session.stage == .selection && match.selection.isEmpty, "Picking a source must advance to destination selection")
        match.operation(["op": "pick", "point": ["x": 5.0, "y": 10.0], "tolerance": 1.0, "extend": true, "mode": "add"])
        match.execute(""); await match.waitForIdle()
        let destination = try await entity(match, 2)
        try require(destination["layer"] as? String == "Walls" && !match.session.active, "MATCHPROP must copy the source layer to destinations")

        let lines = EditorModel(core: CADCore()); await lines.refresh()
        for input in ["L", "0,0", "10,0", "20,0"] { lines.execute(input) }
        await lines.waitForIdle()
        lines.undo(); await lines.waitForIdle()
        try require(lines.entityCount == 1 && lines.tool == .line && lines.session.points.count == 2, "Edit ▸ Undo inside LINE must remove only the last segment")
        lines.cancel(); lines.undo(); await lines.waitForIdle()
        try require(lines.entityCount == 0 && lines.redoLabel == "Line", "Edit ▸ Undo outside a command must undo the last change")

        let document = DrawingDocument()
        document.editor.execute("CIRCLE 0,0 5"); await document.editor.waitForIdle()
        let undoItem = NSMenuItem(title: "Undo", action: #selector(DrawingDocument.undoCommand(_:)), keyEquivalent: "z")
        try require(document.validateUserInterfaceItem(undoItem) && undoItem.title == "Undo Circle", "Edit ▸ Undo must name the action it undoes")
        let copyItem = NSMenuItem(title: "Copy", action: #selector(DrawingDocument.copy(_:)), keyEquivalent: "c")
        try require(!document.validateUserInterfaceItem(copyItem), "Copy must be disabled without a selection")

        let parts = CommandSession.options(in: "LINE Specify next point [Close/Undo] · Return to finish:")
        try require(parts.options == ["Close", "Undo"] && parts.lead.hasPrefix("LINE"), "Prompt options must parse into clickable keywords")
        try require(CommandCatalog.suggestions(for: "L").first == "LINE" && CommandCatalog.suggestions(for: "co").first == "COPY" && CommandCatalog.suggestions(for: "0,0").isEmpty, "Autocomplete must rank alias targets first and ignore coordinates")

        let circle = EditorModel(core: CADCore()); await circle.refresh()
        circle.choose(.circle, option: "__DIAMETER"); await circle.waitForIdle()
        circle.enterPoint(.zero); await circle.waitForIdle()
        try require(circle.session.stage == .radius && circle.session.prompt.contains("Diameter"), "Circle ▸ Center, Diameter must prompt for a diameter")
        circle.execute("40"); await circle.waitForIdle()
        try require(try await entity(circle, 1)["radius"] as? Double == 20, "A 40 unit diameter must make a 20 unit radius")

        circle.layer("Walls", values: ["create": true]); circle.layer("Walls", values: ["rename": "A-WALL"]); await circle.waitForIdle()
        try require(circle.layers.contains { $0.name == "A-WALL" } && circle.currentLayer == "A-WALL", "Layer rename must update the palette and current layer")
    }
}
