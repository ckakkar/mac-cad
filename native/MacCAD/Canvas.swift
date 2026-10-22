import AppKit
import MetalKit
import SwiftUI

private struct GPUVertex { var position: SIMD2<Float>; var color: SIMD4<Float>; var width:Float = 1 }
private struct ViewUniforms { var center: SIMD2<Float>; var scale: SIMD2<Float>;var viewport:SIMD2<Float> }

final class MetalDrawing: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let strokePipeline:MTLRenderPipelineState
    var camera = Camera()
    var size = NSSize(width: 1, height: 1)
    var origin = CADPoint.zero
    private var lineBuffer: MTLBuffer?
    private var fillBuffer: MTLBuffer?
    private var lineCount = 0
    private var fillCount = 0
    init(view: MTKView) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw CoreError.message("A Metal-capable GPU is required") }
        self.device = device; self.queue = queue; view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.055, green: 0.067, blue: 0.084, alpha: 1)
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float2 position; float4 color; float width; };
        struct U { float2 center; float2 scale; float2 viewport; };
        struct O { float4 position [[position]]; float4 color; };
        vertex O drawing_vertex(uint i [[vertex_id]], const device V *v [[buffer(0)]], constant U &u [[buffer(1)]]) {
            O o; o.position=float4((v[i].position-u.center)*u.scale,0,1); o.color=v[i].color; return o;
        }
        vertex O stroke_vertex(uint i [[vertex_id]], const device V *v [[buffer(0)]], constant U &u [[buffer(1)]]) {
            uint segment=(i/6)*2; float2 a=(v[segment].position-u.center)*u.scale;float2 b=(v[segment+1].position-u.center)*u.scale;
            float2 direction=(b-a)*u.viewport;float len=length(direction);float2 normal=len>0 ? float2(-direction.y,direction.x)/len : float2(0,1);
            const float2 corners[6]={float2(0,-1),float2(1,-1),float2(1,1),float2(0,-1),float2(1,1),float2(0,1)};
            float2 corner=corners[i%6];float2 p=mix(a,b,corner.x)+normal*corner.y*v[segment].width/u.viewport;
            O o;o.position=float4(p,0,1);o.color=v[segment].color;return o;
        }
        fragment float4 drawing_fragment(O in [[stage_in]]) { return in.color; }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "drawing_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "drawing_fragment")
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.vertexFunction = library.makeFunction(name:"stroke_vertex")
        strokePipeline = try device.makeRenderPipelineState(descriptor:descriptor)
        super.init()
        view.delegate = self; view.isPaused = true; view.enableSetNeedsDisplay = true
    }
    func upload(_ scene: Scene, camera: Camera, size: NSSize, grid: Bool, lineWeights:Bool = false) {
        origin = camera.center
        var lines: [GPUVertex] = []; lines.reserveCapacity(scene.segments.count*2+512)
        var fills: [GPUVertex] = []; fills.reserveCapacity(scene.triangles.count*3)
        let vertex: (Double,Double,SIMD4<Float>) -> GPUVertex = { [origin] x,y,color in .init(position: .init(Float(x-origin.x),Float(y-origin.y)), color: color) }
        if grid {
            let bounds = camera.bounds(size: size, margin: 2)
            let spacing = pow(10, floor(log10(75/camera.scale)))
            var x = floor(bounds.min.x/spacing)*spacing
            var y = floor(bounds.min.y/spacing)*spacing
            let color = SIMD4<Float>(0.16,0.19,0.23,0.6)
            while x <= bounds.max.x && lines.count < 2000 { lines.append(vertex(x,bounds.min.y,color)); lines.append(vertex(x,bounds.max.y,color)); x += spacing }
            while y <= bounds.max.y && lines.count < 4000 { lines.append(vertex(bounds.min.x,y,color)); lines.append(vertex(bounds.max.x,y,color)); y += spacing }
            let axis = SIMD4<Float>(0.28,0.34,0.40,0.75)
            lines.append(vertex(bounds.min.x,0,axis)); lines.append(vertex(bounds.max.x,0,axis))
            lines.append(vertex(0,bounds.min.y,axis)); lines.append(vertex(0,bounds.max.y,axis))
        }
        for s in scene.segments {
            let c = SIMD4<Float>(s.color.0,s.color.1,s.color.2,s.color.3)
            var a = vertex(s.ax,s.ay,c), b = vertex(s.bx,s.by,c)
            a.width = lineWeights ? max(0.75,s.line_weight*2.83465):1;b.width = a.width
            lines.append(a);lines.append(b)
        }
        for t in scene.triangles {
            let c = SIMD4<Float>(t.color.0,t.color.1,t.color.2,t.color.3)
            fills.append(vertex(t.ax,t.ay,c)); fills.append(vertex(t.bx,t.by,c)); fills.append(vertex(t.cx,t.cy,c))
        }
        lineCount = lines.count; fillCount = fills.count
        lineBuffer = lines.isEmpty ? nil : device.makeBuffer(bytes: lines, length: lines.count*MemoryLayout<GPUVertex>.stride, options: .storageModeShared)
        fillBuffer = fills.isEmpty ? nil : device.makeBuffer(bytes: fills, length: fills.count*MemoryLayout<GPUVertex>.stride, options: .storageModeShared)
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        guard size.width > 0, size.height > 0, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable, let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        var uniforms = ViewUniforms(center: .init(Float(camera.center.x-origin.x),Float(camera.center.y-origin.y)),scale: .init(Float(2*camera.scale/size.width),Float(2*camera.scale/size.height)),viewport:.init(Float(size.width),Float(size.height)))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewUniforms>.stride, index: 1)
        if let buffer = fillBuffer { encoder.setVertexBuffer(buffer, offset: 0, index: 0); encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: fillCount) }
        if let buffer = lineBuffer {encoder.setRenderPipelineState(strokePipeline);encoder.setVertexBuffer(buffer,offset:0,index:0);encoder.drawPrimitives(type:.triangle,vertexStart:0,vertexCount:lineCount/2*6)}
        encoder.endEncoding(); command.present(drawable); command.commit()
    }
}

@MainActor final class DrawingCanvas: NSView {
    let model: EditorModel
    private let metal = MTKView()
    private let overlay = CanvasOverlay()
    private var renderer: MetalDrawing?
    var camera = Camera()
    var points:[CADPoint] {model.session.points}
    private let dynamicField:CADCommandField
    private let dynamicPrompt = NSTextField(labelWithString: "")
    private var viewHistory:[Camera] = []
    var cursor = CADPoint.zero
    var snapKind = "none"
    private var scene = Scene()
    private var sceneBounds: CADBounds?
    private var sceneRevision: UInt64 = .max
    private var loading = false
    private var pendingRefresh = false
    private var tracking: NSTrackingArea?
    private var motionSerial = 0
    private var isPanning = false
    private var selectionStart: CADPoint?
    private var selectionEnd: CADPoint?
    private var extendSelection = false
    private var gestureGeneration = 0
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point:NSPoint)->NSView? {
        if !dynamicField.isHidden,dynamicField.frame.contains(point){return dynamicField.hitTest(convert(point,to:dynamicField))}
        return bounds.contains(point) ? self:nil
    }

    init(model: EditorModel) {
        self.model = model;dynamicField = CADCommandField(model:model)
        super.init(frame: .zero)
        addSubview(metal); addSubview(overlay);overlay.canvas = self
        dynamicField.isHidden = true;dynamicField.isBordered = true;dynamicField.drawsBackground = true;dynamicField.backgroundColor = .textBackgroundColor;dynamicField.setAccessibilityLabel("Dynamic CAD input")
        dynamicPrompt.font = .monospacedSystemFont(ofSize:10,weight:.regular);dynamicPrompt.textColor = .labelColor;dynamicPrompt.backgroundColor = .controlBackgroundColor;dynamicPrompt.drawsBackground = true;dynamicPrompt.isHidden = true
        addSubview(dynamicPrompt);addSubview(dynamicField)
        do { renderer = try MetalDrawing(view: metal) } catch { model.show(error) }
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Drawing canvas")
        model.invalidate = { [weak self] in self?.refresh(force: true) }
        model.cancelGesture = { [weak self] in self?.gestureGeneration += 1; self?.selectionStart = nil; self?.selectionEnd = nil; self?.snapKind = "none"; self?.overlay.needsDisplay = true }
        model.fitView = { [weak self] in self?.fit() }
        model.acceptCoordinate = {[weak self] p,relative in guard let self else{return};self.model.enterPoint(relative ? (points.last ?? .zero)+p:p)}
        model.finishGesture = {[weak model] in model?.execute("")}
        model.acceptScalar = {[weak model] in model?.execute(String($0))}
        model.syncInput = {[weak self] in self?.dynamicField.synchronize();self?.model.syncCommandBar?();self?.updateDynamicInput()}
        model.focusCommand = {[weak self] in
            guard let self else{return}
            if self.model.dynamicInput {updateDynamicInput(force:true);dynamicField.focus()}
            else {self.model.showCommandLine = true;self.model.focusCommandBar?()}
        }
        model.zoomBy = {[weak self] amount in self?.zoomCentered(amount)}
        model.fitWindow = {[weak self] b in guard let self else{return};rememberView();camera.fit(b,size:bounds.size);refresh(force:true)}
        model.previousView = {[weak self] in guard let self,let previous = viewHistory.popLast() else{return};camera = previous;refresh(force:true)}

    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layout() { super.layout(); metal.frame = bounds; overlay.frame = bounds; refresh(force: true) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow,.mouseMoved,.mouseEnteredAndExited,.inVisibleRect], owner: self); addTrackingArea(t); tracking = t
    }
    func fit() {
        Task { if let b = await model.extents() { rememberView();camera.fit(b, size: bounds.size); refresh(force: true) } }
    }
    func refresh(force: Bool = false) {
        renderer?.camera = camera; renderer?.size = bounds.size
        updateDynamicInput()
        metal.needsDisplay = true; overlay.needsDisplay = true
        guard bounds.width > 0, bounds.height > 0 else { return }
        let visible = camera.bounds(size: bounds.size)
        if !force, sceneRevision == model.revision, sceneBounds?.contains(visible) == true { return }
        if loading { pendingRefresh = true; return }
        loading = true
        let b = camera.bounds(size: bounds.size, margin: 2)
        let revision = model.revision
        let scale = camera.scale
        Task {
            do {
                let result = try await model.core.scene(bounds: b, tolerance: 0.35/scale)
                scene = result; sceneBounds = b; sceneRevision = revision
                renderer?.upload(result, camera: camera, size: bounds.size, grid: model.grid, lineWeights:model.lineWeights)
                renderer?.camera = camera; renderer?.size = bounds.size
                metal.needsDisplay = true; overlay.needsDisplay = true
            } catch { model.show(error) }
            loading = false
            if pendingRefresh { pendingRefresh = false; refresh(force: true) }
        }
    }
    override func mouseEntered(with event: NSEvent) { NSCursor.crosshair.push() }
    override func mouseExited(with event: NSEvent) { NSCursor.pop(); overlay.needsDisplay = true }
    override func mouseMoved(with event: NSEvent) {
        let p = camera.world(convert(event.locationInWindow, from: nil), size: bounds.size)
        motionSerial += 1; let serial = motionSerial
        cursor = constrained(p); model.coordinate = cursor; snapKind = "none"; overlay.needsDisplay = true
        guard model.snapping else { return }
        Task {
            guard let response = try? await model.core.request(["op":"snap","point":p.json,"tolerance":9/camera.scale,"base":points.last?.json as Any? ?? NSNull()]), serial == motionSerial else { return }
            if let q = response["point"] as? [String:Double] {
                cursor = CADPoint(x:q["x"] ?? p.x,y:q["y"] ?? p.y); snapKind = response["kind"] as? String ?? "none"
                if snapKind == "none" { cursor = constrained(cursor) }
                model.coordinate = cursor; overlay.needsDisplay = true
            }
        }
    }
    func constrained(_ p: CADPoint) -> CADPoint {
        guard let base = points.last else { return model.gridSnap ? CADPoint(x:(p.x/model.snapSpacing).rounded()*model.snapSpacing,y:(p.y/model.snapSpacing).rounded()*model.snapSpacing):p }
        let p = model.gridSnap ? CADPoint(x:(p.x/model.snapSpacing).rounded()*model.snapSpacing,y:(p.y/model.snapSpacing).rounded()*model.snapSpacing):p
        let delta = p-base
        if model.ortho { return abs(delta.x) >= abs(delta.y) ? CADPoint(x:p.x,y:base.y) : CADPoint(x:base.x,y:p.y) }
        if model.polar { let angle = (atan2(delta.y,delta.x)/(.pi/4)).rounded()*(.pi/4); let radius = hypot(delta.x,delta.y); return base+CADPoint(x:cos(angle),y:sin(angle))*radius }
        return p
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.option) || model.tool == .pan { isPanning = true;rememberView(); return }
        let p = camera.world(convert(event.locationInWindow, from:nil),size:bounds.size)
        if model.selecting { selectionStart = p; selectionEnd = nil; extendSelection = event.modifierFlags.contains(.shift); return }
        let generation = gestureGeneration
        Task {
            var q = constrained(p)
            if model.snapping, let result = try? await model.core.request(["op":"snap","point":p.json,"tolerance":9/camera.scale,"base":points.last?.json as Any? ?? NSNull()]), result["kind"] as? String != "none", let v = result["point"] as? [String:Double] { q = CADPoint(x:v["x"] ?? p.x,y:v["y"] ?? p.y) }
            if generation == gestureGeneration { accept(q, shift: event.modifierFlags.contains(.shift)) }
        }
    }
    func accept(_ p:CADPoint,shift:Bool = false) {model.enterPoint(p);overlay.needsDisplay = true}
    func completePath() {model.execute("")}
    private func rememberView() {viewHistory.append(camera);if viewHistory.count>32{viewHistory.removeFirst()}}
    private func zoomCentered(_ amount:Double) {rememberView();camera.scale = min(max(camera.scale*amount,1e-8),1e8);refresh(force:true)}
    private func updateDynamicInput(force:Bool = false) {
        let visible = model.dynamicInput && (force || model.session.active || !model.commandText.isEmpty)
        if !model.dynamicInput,dynamicField.currentEditor() != nil {window?.makeFirstResponder(self)}
        dynamicField.isHidden = !visible;dynamicPrompt.isHidden = !visible
        guard visible else{return}
        dynamicField.synchronize();dynamicPrompt.stringValue = model.session.active ? model.session.prompt:"Command:"
        if dynamicField.currentEditor() == nil || force {
            let p = camera.screen(cursor,size:bounds.size)
            let x = min(max(p.x+18,8),max(8,bounds.width-360)),y = min(max(p.y-58,8),max(8,bounds.height-60))
            dynamicPrompt.frame = NSRect(x:x,y:y+27,width:350,height:22);dynamicField.frame = NSRect(x:x,y:y,width:190,height:25)
        }
    }
    override func rightMouseDown(with event:NSEvent) {
        let menu = NSMenu()
        func action(_ title:String,_ selector:Selector){let item = NSMenuItem(title:title,action:selector,keyEquivalent:"");item.target = self;menu.addItem(item)}
        action(model.session.active ? "Enter":"Repeat \(model.lastCommand ?? "Command")",#selector(enterCommand))
        action("Cancel",#selector(cancelCurrent));menu.addItem(.separator());action("Undo",#selector(undoCommand))
        NSMenu.popUpContextMenu(menu,with:event,for:self)
    }
    @objc private func enterCommand(){model.submit()}
    @objc private func cancelCurrent(){model.cancel()}
    @objc private func undoCommand(){model.execute("UNDO")}
    override func otherMouseDown(with event:NSEvent){if event.buttonNumber == 2 {if event.clickCount == 2{fit()}else{isPanning = true;rememberView()}}}
    override func otherMouseUp(with event:NSEvent){isPanning = false}
    override func mouseDragged(with event: NSEvent) {
        if isPanning { camera.center.x -= event.deltaX/camera.scale; camera.center.y += event.deltaY/camera.scale; refresh() }
        else if selectionStart != nil {selectionEnd = camera.world(convert(event.locationInWindow,from:nil),size:bounds.size);overlay.needsDisplay = true}
        else { mouseMoved(with:event) }
    }
    override func mouseUp(with event: NSEvent) {
        isPanning = false
        guard let start = selectionStart else {return};let end = selectionEnd
        selectionStart = nil;selectionEnd = nil;overlay.needsDisplay = true
        if let end, start.distance(end)*camera.scale>3 {
            model.operation(["op":"select_window","bounds":["min":CADPoint(x:min(start.x,end.x),y:min(start.y,end.y)).json,"max":CADPoint(x:max(start.x,end.x),y:max(start.y,end.y)).json],"crossing":end.x<start.x,"extend":true,"mode":extendSelection ? "remove":"add"])
        } else {model.operation(["op":"pick","point":start.json,"tolerance":7/camera.scale,"extend":true,"mode":extendSelection ? "remove":"add"])}
    }
    override func otherMouseDragged(with event: NSEvent) { guard isPanning else{return};camera.center.x -= event.deltaX/camera.scale; camera.center.y += event.deltaY/camera.scale; refresh() }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas { zoom(exp(event.scrollingDeltaY*0.025),event:event) }
        else { camera.center.x -= event.scrollingDeltaX/camera.scale; camera.center.y += event.scrollingDeltaY/camera.scale; refresh() }
    }
    override func magnify(with event: NSEvent) { zoom(max(0.1,1+event.magnification),event:event) }
    func zoom(_ amount: Double, event: NSEvent) {
        rememberView()
        let p = convert(event.locationInWindow,from:nil)
        let before = camera.world(p,size:bounds.size)
        camera.scale = min(max(camera.scale*amount,1e-8),1e8)
        camera.center = camera.center + before-camera.world(p,size:bounds.size)
        // Retessellate curves/grid at the new screen-space tolerance.
        refresh(force:true)
    }
    override func keyDown(with event:NSEvent) {
        if model.handleCADKey(event) {return}
        switch event.keyCode {
        case 53:model.cancel()
        case 51,117:model.choose(.erase)
        case 36,76:model.submit()
        case 49:
            if model.spaceSubmits {model.submit()}else{model.commandText += " ";model.focusCommand?()}
        default:
            if let text = event.characters,event.modifierFlags.intersection([.command,.control]).isEmpty,!text.isEmpty,text.unicodeScalars.allSatisfy({$0.value>=32}) {model.commandText += text;model.focusCommand?()}
            else{super.keyDown(with:event)}
        }
    }
    fileprivate func drawOverlay() {
        let size = bounds.size
        updateDynamicInput()
        if let start = selectionStart, let end = selectionEnd {
            let a = camera.screen(start,size:size), b = camera.screen(end,size:size)
            let rect = NSRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(a.x-b.x),height:abs(a.y-b.y))
            let color: NSColor = end.x<start.x ? .systemGreen : .systemBlue
            color.withAlphaComponent(0.12).setFill();NSBezierPath(rect:rect).fill();color.setStroke();let outline = NSBezierPath(rect:rect);if end.x<start.x{outline.setLineDash([5,3],count:2,phase:0)};outline.stroke()
        }
        for label in scene.labels {
            let at = camera.screen(label.at,size:size); let height = label.height*camera.scale
            guard height >= 3, height < 2000, at.x > -2000, at.x < size.width+2000, at.y > -2000, at.y < size.height+2000 else { continue }
            NSGraphicsContext.saveGraphicsState()
            let transform = AffineTransform(translationByX:at.x,byY:at.y); (transform as NSAffineTransform).concat()
            NSAffineTransform.rotate(label.rotation*180 / .pi)
            let color = NSColor(srgbRed:CGFloat(label.color[0]),green:CGFloat(label.color[1]),blue:CGFloat(label.color[2]),alpha:1)
            (label.text as NSString).draw(at:.zero,withAttributes:[.font:NSFont.systemFont(ofSize:height),.foregroundColor:color])
            NSGraphicsContext.restoreGraphicsState()
        }
        guard !points.isEmpty else { drawSnap(size); return }
        let path = NSBezierPath(); path.lineWidth = 1.5; path.setLineDash([5,4],count:2,phase:0)
        NSColor.controlAccentColor.setStroke()
        let a = camera.screen(points[0],size:size); let b = camera.screen(cursor,size:size)
        switch model.tool {
        case .rectangle, .hatch: path.appendRect(NSRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(b.x-a.x),height:abs(b.y-a.y)))
        case .select where model.session.name == "ZOOM":path.appendRect(NSRect(x:min(a.x,b.x),y:min(a.y,b.y),width:abs(b.x-a.x),height:abs(b.y-a.y)))
        case .circle, .arc: let r = hypot(b.x-a.x,b.y-a.y); path.appendOval(in:NSRect(x:a.x-r,y:a.y-r,width:r*2,height:r*2))
        default: path.move(to:a); for p in points.dropFirst() { path.line(to:camera.screen(p,size:size)) }; path.line(to:b)
        }
        path.stroke(); drawSnap(size)
    }
    private func drawSnap(_ size: NSSize) {
        guard snapKind != "none" else { return }
        let p = camera.screen(cursor,size:size); NSColor.systemMint.setStroke()
        let marker = NSBezierPath(rect:NSRect(x:p.x-4,y:p.y-4,width:8,height:8)); marker.lineWidth = 1.5; marker.stroke()
    }
}
private final class CanvasOverlay: NSView {
    weak var canvas: DrawingCanvas?
    override var isOpaque: Bool { false }
    override func draw(_ dirtyRect: NSRect) { canvas?.drawOverlay() }
}
struct CanvasHost: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    func makeNSView(context: Context) -> DrawingCanvas { DrawingCanvas(model:model) }
    func updateNSView(_ view: DrawingCanvas, context: Context) {}
}

private extension NSAffineTransform {
    static func rotate(_ degrees: Double) { let t = NSAffineTransform(); t.rotate(byDegrees:degrees); t.concat() }
}
