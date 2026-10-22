import AppKit
import MetalKit
import SwiftUI

/// The model-space canvas: Metal geometry, a text layer that redraws with the
/// view, and an interaction overlay (crosshair, snaps, grips, previews) that
/// redraws with the pointer.
@MainActor final class DrawingCanvas: NSView {
    let model: EditorModel
    let settings = AppSettings.shared
    private let metal = MTKView()
    private let labels = CanvasLayerView()
    private let overlay = CanvasLayerView()
    private var renderer: MetalDrawing?
    var camera = Camera()
    var points: [CADPoint] { model.session.points }
    private let dynamicField: CADCommandField
    private let dynamicPrompt = NSTextField(labelWithString: "")
    private var viewHistory: [Camera] = []
    private var lastRemembered = Date.distantPast
    private var justFitted = false

    /// Raw pointer location in view coordinates; nil while outside the canvas.
    var pointer: NSPoint?
    /// Snapped and constrained pointer location in drawing coordinates.
    var cursor = CADPoint.zero
    var snapKind = "none"
    var hoverID: UInt64?
    var gripPreview: [Double] = []
    private(set) var scene = Scene()
    /// Each entity's contiguous run of scene segments, for highlight and ghosts.
    private(set) var entityRanges: [UInt64: Range<Int>] = [:]
    private var sceneBounds: CADBounds?
    /// The zoom the current scene was tessellated for.
    private var sceneScale = 0.0
    private var sceneRevision: UInt64 = .max
    private var loading = false
    private var pendingRefresh = false
    private var tracking: NSTrackingArea?
    private var motionSerial = 0
    var isPanning = false { didSet { if isPanning != oldValue { window?.invalidateCursorRects(for: self); overlay.needsDisplay = true } } }
    var selectionStart: CADPoint?
    var selectionEnd: CADPoint?
    private var extendSelection = false
    private var gestureGeneration = 0
    private static let blankCursor = NSCursor(image: NSImage(size: NSSize(width: 1, height: 1)), hotSpot: .zero)

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if !dynamicField.isHidden, dynamicField.frame.contains(local) { return dynamicField.hitTest(local) ?? dynamicField }
        return bounds.contains(local) ? self : nil
    }

    init(model: EditorModel) {
        self.model = model; dynamicField = CADCommandField(model: model)
        super.init(frame: .zero)
        clipsToBounds = true
        wantsLayer = true
        addSubview(metal); addSubview(labels); addSubview(overlay)
        labels.draw = { [weak self] in self?.drawLabels() }
        overlay.draw = { [weak self] in self?.drawInteraction() }
        dynamicField.isHidden = true; dynamicField.isBordered = true; dynamicField.isBezeled = true; dynamicField.bezelStyle = .roundedBezel
        dynamicField.drawsBackground = true; dynamicField.backgroundColor = .textBackgroundColor; dynamicField.controlSize = .small
        dynamicField.font = .monospacedSystemFont(ofSize: 11, weight: .regular); dynamicField.placeholderString = nil
        dynamicField.setAccessibilityLabel("Dynamic input")
        dynamicField.didSubmit = { [weak self] in guard let self else { return }; window?.makeFirstResponder(self); updateDynamicInput() }
        dynamicPrompt.font = .systemFont(ofSize: 11); dynamicPrompt.textColor = .labelColor
        dynamicPrompt.wantsLayer = true; dynamicPrompt.drawsBackground = true; dynamicPrompt.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92)
        dynamicPrompt.layer?.cornerRadius = 4; dynamicPrompt.layer?.borderWidth = 0.5; dynamicPrompt.layer?.borderColor = NSColor.separatorColor.cgColor
        dynamicPrompt.isHidden = true; dynamicPrompt.lineBreakMode = .byTruncatingTail
        addSubview(dynamicPrompt); addSubview(dynamicField)
        do { renderer = try MetalDrawing(view: metal) } catch { model.show(error) }
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Model space drawing canvas")
        model.invalidate = { [weak self] in self?.refresh(force: true) }
        model.cancelGesture = { [weak self] in
            guard let self else { return }
            gestureGeneration += 1; selectionStart = nil; selectionEnd = nil; snapKind = "none"; gripPreview = []; overlay.needsDisplay = true
        }
        model.fitView = { [weak self] in self?.fit() }
        model.syncInput = { [weak self] in self?.dynamicField.synchronize(); self?.model.syncCommandBar?(); self?.updateDynamicInput() }
        model.focusCommand = { [weak self] in
            guard let self else { return }
            if model.dynamicInput && pointer != nil { updateDynamicInput(force: true); dynamicField.focus() }
            else { model.showCommandLine = true; model.focusCommandBar?() }
        }
        model.zoomBy = { [weak self] amount in self?.zoomCentered(amount) }
        model.fitWindow = { [weak self] b in guard let self else { return }; rememberView(); camera.fit(b, size: bounds.size); refresh(force: true) }
        model.previousView = { [weak self] in self?.restorePreviousView() }
        model.visibleBounds = { [weak self] in guard let self, bounds.width > 0 else { return nil }; return camera.bounds(size: bounds.size) }
        observeSettings()
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Preferences changed in Settings repaint every open canvas.
    private func observeSettings() {
        withObservationTracking {
            _ = (settings.background, settings.showUCSIcon, settings.crosshairSize, settings.pickboxSize, settings.gripSize, settings.snapMarker, settings.snapTooltip, settings.selectionPreview)
        } onChange: { [weak self] in
            Task { @MainActor in self?.refresh(force: true); self?.observeSettings() }
        }
    }

    override func layout() {
        super.layout(); metal.frame = bounds; labels.frame = bounds; overlay.frame = bounds; refresh(force: true)
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self); addTrackingArea(t); tracking = t
    }
    /// AutoCAD draws its own crosshair; the system pointer is hidden over model space.
    override func resetCursorRects() {
        addCursorRect(visibleRect, cursor: isPanning || model.tool == .pan ? .openHand : Self.blankCursor)
    }
    /// Model space takes keyboard focus when its window opens, so typing starts commands.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.initialFirstResponder = self
        DispatchQueue.main.async { [weak self] in guard let self, window.firstResponder === window || window.firstResponder is NSTextView else { return }; window.makeFirstResponder(self) }
    }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); refresh(force: true) }

    func fit() {
        Task {
            if let b = await model.extents() { rememberView(); camera.fit(b, size: bounds.size); justFitted = true; refresh(force: true) }
        }
    }
    func refresh(force: Bool = false) {
        renderer?.camera = camera; renderer?.size = bounds.size
        renderer?.clearColor = settings.background == .dark ? MTLClearColor(red: 0.13, green: 0.15, blue: 0.18, alpha: 1) : MTLClearColor(red: 1, green: 1, blue: 1, alpha: 1)
        window?.invalidateCursorRects(for: self)
        updateDynamicInput()
        metal.needsDisplay = true; labels.needsDisplay = true; overlay.needsDisplay = true
        guard bounds.width > 0, bounds.height > 0 else { return }
        let visible = camera.bounds(size: bounds.size)
        // The GPU redraws the cached scene at any zoom; rebuild only when the view
        // leaves it or zooms in far enough that curves would look faceted.
        if !force, sceneRevision == model.revision, sceneBounds?.contains(visible) == true, camera.scale < sceneScale * 1.6 { return }
        if loading { pendingRefresh = true; return }
        loading = true
        let b = camera.bounds(size: bounds.size, margin: 2)
        let revision = model.revision
        let scale = camera.scale
        Task {
            do {
                let result = try await model.core.scene(bounds: b, tolerance: 0.35 / scale)
                scene = result; sceneBounds = b; sceneRevision = revision; sceneScale = scale
                var ranges: [UInt64: Range<Int>] = [:]
                var start = 0
                for i in result.segments.indices where i + 1 == result.segments.count || result.segments[i + 1].entity != result.segments[i].entity {
                    ranges[result.segments[i].entity] = start..<(i + 1); start = i + 1
                }
                entityRanges = ranges
                let grid = model.grid ? MetalDrawing.GridStyle(spacing: model.gridSnap ? model.snapSpacing : nil, minor: settings.gridColor, major: settings.majorGridColor, axis: settings.axisColor) : nil
                renderer?.upload(result, camera: camera, size: bounds.size, grid: grid, lineWeights: model.lineWeights, settings: settings)
                renderer?.camera = camera; renderer?.size = bounds.size
                metal.needsDisplay = true; labels.needsDisplay = true; overlay.needsDisplay = true
            } catch { model.show(error) }
            loading = false
            if pendingRefresh { pendingRefresh = false; refresh(force: true) }
        }
    }

    // MARK: File drops

    /// Dropping drawings onto model space opens them, as dropping on the Dock icon does.
    private func drawingURLs(_ info: NSDraggingInfo) -> [URL] {
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.filter { ["maccad", "dxf", "dwg"].contains($0.pathExtension.lowercased()) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { drawingURLs(sender).isEmpty ? [] : .copy }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = drawingURLs(sender)
        for url in urls { NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in if let error { NSApp.presentError(error) } } }
        return !urls.isEmpty
    }

    // MARK: Pointer

    /// Whether the active prompt expects a point, so object snaps apply.
    var wantsPoint: Bool { model.session.active && !model.session.selecting && model.tool != .pan }
    private var snapTolerance: Double { settings.apertureSize / camera.scale }
    private func snapRequest(_ p: CADPoint) -> [String: Any] {
        ["op": "snap", "point": p.json, "tolerance": snapTolerance, "base": points.last?.json as Any? ?? NSNull(), "modes": Array(settings.snapModes)]
    }
    override func mouseEntered(with event: NSEvent) { pointer = convert(event.locationInWindow, from: nil); overlay.needsDisplay = true }
    override func mouseExited(with event: NSEvent) { pointer = nil; hoverID = nil; overlay.needsDisplay = true; updateDynamicInput() }
    override func mouseMoved(with event: NSEvent) {
        let screen = convert(event.locationInWindow, from: nil)
        pointer = screen
        let p = camera.world(screen, size: bounds.size)
        motionSerial += 1; let serial = motionSerial
        cursor = constrained(p); snapKind = "none"
        if !model.session.active, let grip = grip(at: screen) { cursor = grip.point }
        model.pointer.coordinate = cursor; overlay.needsDisplay = true
        updateDynamicInput()
        if wantsPoint {
            hoverID = nil
            Task {
                if model.snapping, settings.snapModes.isEmpty == false, let response = try? await model.core.request(snapRequest(p)), serial == motionSerial,
                   let q = response["point"] as? [String: Double], let kind = response["kind"] as? String, kind != "none" {
                    cursor = CADPoint(x: q["x"] ?? p.x, y: q["y"] ?? p.y); snapKind = kind
                    model.pointer.coordinate = cursor; overlay.needsDisplay = true
                }
                guard serial == motionSerial, let grip = model.session.hotGrip else { return }
                let preview = try? await model.core.request(["op": "grip_preview", "id": grip.id, "index": grip.index, "point": cursor.json, "tolerance": 0.35 / camera.scale])
                if serial == motionSerial { gripPreview = (preview?["segments"] as? [Double]) ?? []; overlay.needsDisplay = true }
            }
        } else if settings.selectionPreview && !isPanning && model.tool != .pan {
            Task {
                let response = try? await model.core.request(["op": "hover", "point": p.json, "tolerance": settings.pickboxSize / camera.scale])
                guard serial == motionSerial else { return }
                let id = (response?["id"] as? NSNumber)?.uint64Value
                if id != hoverID { hoverID = id; overlay.needsDisplay = true }
            }
        }
    }
    func constrained(_ p: CADPoint) -> CADPoint {
        let s = model.snapSpacing
        let p = model.gridSnap ? CADPoint(x: (p.x / s).rounded() * s, y: (p.y / s).rounded() * s) : p
        guard let base = points.last, wantsPoint else { return p }
        let delta = p - base
        if model.ortho { return abs(delta.x) >= abs(delta.y) ? CADPoint(x: p.x, y: base.y) : CADPoint(x: base.x, y: p.y) }
        if model.polar {
            let step = settings.polarIncrement * .pi / 180
            let angle = (atan2(delta.y, delta.x) / step).rounded() * step
            let radius = hypot(delta.x, delta.y)
            return base + CADPoint(x: cos(angle), y: sin(angle)) * radius
        }
        return p
    }
    /// Grips are live only between commands, as in AutoCAD.
    func grip(at screen: NSPoint) -> CADGrip? {
        guard !model.session.active else { return nil }
        let reach = settings.gripSize / 2 + 2
        return model.grips.first { g in let s = camera.screen(g.point, size: bounds.size); return abs(s.x - screen.x) <= reach && abs(s.y - screen.y) <= reach }
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.option) || model.tool == .pan { isPanning = true; rememberView(); return }
        let screen = convert(event.locationInWindow, from: nil)
        let p = camera.world(screen, size: bounds.size)
        if event.clickCount == 2, !model.session.active {
            // Double-click opens an object's properties, like AutoCAD's quick properties.
            model.operation(["op": "pick", "point": p.json, "tolerance": settings.pickboxSize / camera.scale, "extend": false, "mode": "replace"])
            model.inspectorTab = .properties; model.showInspector = true; return
        }
        if let grip = grip(at: screen) { model.startGrip(grip); gripPreview = []; return }
        if model.selecting { selectionStart = p; selectionEnd = nil; extendSelection = event.modifierFlags.contains(.shift); return }
        let generation = gestureGeneration
        let request = snapRequest(p)
        Task {
            var q = constrained(p)
            if model.snapping, !settings.snapModes.isEmpty, let result = try? await model.core.request(request), result["kind"] as? String != "none", let v = result["point"] as? [String: Double] { q = CADPoint(x: v["x"] ?? p.x, y: v["y"] ?? p.y) }
            if generation == gestureGeneration { model.enterPoint(q); gripPreview = []; overlay.needsDisplay = true }
        }
    }
    override func mouseDragged(with event: NSEvent) {
        if isPanning { pan(event) }
        else if selectionStart != nil {
            pointer = convert(event.locationInWindow, from: nil)
            selectionEnd = camera.world(pointer!, size: bounds.size); overlay.needsDisplay = true
        } else { mouseMoved(with: event) }
    }
    override func mouseUp(with event: NSEvent) {
        isPanning = false
        guard let start = selectionStart else { return }
        let end = selectionEnd
        selectionStart = nil; selectionEnd = nil; overlay.needsDisplay = true
        if let end, start.distance(end) * camera.scale > 3 {
            model.operation(["op": "select_window", "bounds": ["min": CADPoint(x: min(start.x, end.x), y: min(start.y, end.y)).json, "max": CADPoint(x: max(start.x, end.x), y: max(start.y, end.y)).json], "crossing": end.x < start.x, "extend": true, "mode": extendSelection ? "remove" : "add"])
        } else {
            model.operation(["op": "pick", "point": start.json, "tolerance": settings.pickboxSize / camera.scale, "extend": true, "mode": extendSelection ? "remove" : "add"])
        }
    }
    private func pan(_ event: NSEvent) {
        camera.center.x -= event.deltaX / camera.scale; camera.center.y += event.deltaY / camera.scale; justFitted = false; refresh()
    }
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else { return }
        if event.clickCount == 2 { fit() } else { isPanning = true; rememberView() }
    }
    override func otherMouseUp(with event: NSEvent) { isPanning = false }
    override func otherMouseDragged(with event: NSEvent) { if isPanning { pan(event) } }

    // MARK: Navigation

    private func rememberView() { viewHistory.append(camera); if viewHistory.count > 32 { viewHistory.removeFirst() }; lastRemembered = Date() }
    /// Continuous gestures record one Zoom Previous step, not one per event.
    private func rememberGesture(_ event: NSEvent) {
        if event.phase == .began || (event.phase.isEmpty && Date().timeIntervalSince(lastRemembered) > 0.6) { rememberView() }
        if event.phase.isEmpty { lastRemembered = Date() }
    }
    private func restorePreviousView() {
        guard let previous = viewHistory.popLast() else { NSSound.beep(); return }
        camera = previous; justFitted = false; refresh(force: true)
    }
    private func zoomCentered(_ amount: Double) { rememberView(); camera.scale = min(max(camera.scale * amount, 1e-8), 1e8); justFitted = false; refresh() }
    /// A mouse wheel (including smooth-scrolling mice, which send no gesture phases)
    /// zooms about the cursor, as in AutoCAD. Trackpad and Magic Mouse gestures pan
    /// unless Settings makes them zoom; Command-scroll always zooms.
    override func scrollWheel(with event: NSEvent) {
        let gesture = !event.phase.isEmpty || !event.momentumPhase.isEmpty
        guard event.modifierFlags.contains(.command) || !gesture || settings.gestureScrollZooms else {
            camera.center.x -= event.scrollingDeltaX / camera.scale; camera.center.y += event.scrollingDeltaY / camera.scale; justFitted = false; refresh(); return
        }
        // Normalize to the physical direction: forward/away zooms in.
        var forward = event.isDirectionInvertedFromDevice ? -event.scrollingDeltaY : event.scrollingDeltaY
        if settings.reverseWheelZoom { forward = -forward }
        guard forward != 0 else { return }
        rememberGesture(event)
        // Line-based wheels zoom 1.2× per notch; pixel deltas zoom proportionally.
        let factor = event.hasPreciseScrollingDeltas ? exp(max(min(forward, 80), -80) * 0.006) : pow(1.2, max(min(forward, 5), -5))
        zoom(factor, event: event)
    }
    override func magnify(with event: NSEvent) { rememberGesture(event); zoom(max(0.1, 1 + event.magnification), event: event) }
    /// Two-finger double-tap toggles between the drawing extents and the previous view.
    override func smartMagnify(with event: NSEvent) { if justFitted { restorePreviousView() } else { fit() } }
    func zoom(_ amount: Double, event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let before = camera.world(p, size: bounds.size)
        camera.scale = min(max(camera.scale * amount, 1e-8), 1e8)
        camera.center = camera.center + before - camera.world(p, size: bounds.size)
        justFitted = false
        refresh()
    }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        if model.handleCADKey(event) { return }
        switch event.keyCode {
        case 53: model.cancel()
        case 51, 117: if model.selection.isEmpty || model.session.active { NSSound.beep() } else { model.choose(.erase) }
        case 36, 76: model.submit()
        case 49:
            if model.spaceSubmits { model.submit() } else { model.commandText += " "; model.focusCommand?() }
        default:
            if let text = event.characters, event.modifierFlags.intersection([.command, .control]).isEmpty, !text.isEmpty, text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 0xF700 }) { model.commandText += text; model.focusCommand?() }
            else { super.keyDown(with: event) }
        }
    }

    // MARK: Dynamic input

    private func updateDynamicInput(force: Bool = false) {
        let visible = model.dynamicInput && (pointer != nil || force) && (force || model.session.active || !model.commandText.isEmpty)
        if !model.dynamicInput, dynamicField.currentEditor() != nil { window?.makeFirstResponder(self) }
        // The prompt follows the crosshair; the input box appears once the user types.
        let typing = dynamicField.currentEditor() != nil || !model.commandText.isEmpty || force
        dynamicField.isHidden = !(visible && typing); dynamicPrompt.isHidden = !visible
        guard visible else { return }
        dynamicField.synchronize()
        dynamicPrompt.stringValue = " " + (model.session.active ? model.session.prompt : "Enter command:") + " "
        // The tooltip follows the crosshair until the user starts typing into it.
        if dynamicField.currentEditor() == nil || model.commandText.isEmpty || force {
            let p = pointer ?? camera.screen(cursor, size: bounds.size)
            let promptWidth = min(max(dynamicPrompt.intrinsicContentSize.width, 120), 420)
            let x = min(max(p.x + 22, 8), max(8, bounds.width - promptWidth - 8)), y = min(max(p.y - 56, 8), max(8, bounds.height - 60))
            dynamicPrompt.frame = NSRect(x: x, y: y + 26, width: promptWidth, height: 20); dynamicField.frame = NSRect(x: x, y: y, width: 150, height: 22)
        }
    }

    // MARK: Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ key: String = "", _ action: @escaping () -> Void) -> NSMenuItem {
            let i = ClosureMenuItem(title: title, keyEquivalent: key, action: action); menu.addItem(i); return i
        }
        let session = model.session
        if session.active {
            _ = item("Enter") { [model] in model.submit() }
            _ = item("Cancel") { [model] in model.cancel() }
            let options = CommandSession.options(in: session.prompt).options
            if !options.isEmpty {
                menu.addItem(.separator())
                for option in options { _ = item(option.prefix(1).uppercased() + option.dropFirst()) { [model] in model.execute(option) } }
            }
        } else {
            if let last = model.lastCommand { _ = item("Repeat \(last)") { [model] in model.execute(last) } }
            var recent: [String] = []
            for text in model.inputHistory.reversed() where !recent.contains(text) && recent.count < 10 { recent.append(text) }
            if !recent.isEmpty {
                let sub = NSMenu()
                for text in recent { sub.addItem(ClosureMenuItem(title: text, keyEquivalent: "") { [model] in model.execute(text) }) }
                let i = NSMenuItem(title: "Recent Input", action: nil, keyEquivalent: ""); i.submenu = sub; menu.addItem(i)
            }
            menu.addItem(.separator())
            if !model.selection.isEmpty {
                for tool in [Tool.erase, .move, .copy, .scale, .rotate, .mirror] { item(tool == .copy ? "Copy Selection" : tool.title) { [model] in model.choose(tool) }.image = tool.image }
                menu.addItem(.separator())
                _ = item("Cut") { [model] in model.copySelection(cut: true) }
                _ = item("Copy") { [model] in model.copySelection() }
            }
            item("Paste") { [model] in model.pasteSelection() }.isEnabled = model.canPaste
            menu.addItem(.separator())
            item(model.undoLabel.map { "Undo \($0)" } ?? "Undo") { [model] in model.undo() }.isEnabled = model.canUndo
            item(model.redoLabel.map { "Redo \($0)" } ?? "Redo") { [model] in model.redo() }.isEnabled = model.canRedo
            menu.addItem(.separator())
            if model.selection.isEmpty { _ = item("Select All") { [model] in model.operation(["op": "select_all"]) } }
            else {
                _ = item("Deselect All") { [model] in model.operation(["op": "select", "ids": []]) }
                _ = item("Select Similar") { [model] in model.runFromMenu("SELECTSIMILAR") }
                _ = item("Properties") { [model] in model.inspectorTab = .properties; model.showInspector = true }
            }
        }
        menu.addItem(.separator())
        _ = item("Pan") { [model] in model.choose(.pan) }
        let zoom = NSMenu()
        zoom.addItem(ClosureMenuItem(title: "Extents", keyEquivalent: "") { [weak self] in self?.fit() })
        zoom.addItem(ClosureMenuItem(title: "Window", keyEquivalent: "") { [model] in model.runFromMenu("ZOOM W") })
        zoom.addItem(ClosureMenuItem(title: "Previous", keyEquivalent: "") { [weak self] in self?.restorePreviousView() })
        let zoomItem = NSMenuItem(title: "Zoom", action: nil, keyEquivalent: ""); zoomItem.submenu = zoom; menu.addItem(zoomItem)
        menu.addItem(.separator())
        _ = item("Drafting Settings…") { [model] in model.showDraftingSettings = true }
        return menu
    }
}

/// A transparent layer whose drawing is supplied by the canvas.
final class CanvasLayerView: NSView {
    var draw: (() -> Void)?
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func draw(_ dirtyRect: NSRect) { draw?() }
}

/// Menu item that runs a closure, for context menus built on demand.
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(title: String, keyEquivalent: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: keyEquivalent)
        target = self
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }
    @objc private func run() { handler() }
}

struct CanvasHost: NSViewRepresentable {
    let model: EditorModel
    func makeNSView(context: Context) -> DrawingCanvas { DrawingCanvas(model: model) }
    func updateNSView(_ view: DrawingCanvas, context: Context) {}
}
