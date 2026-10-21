import AppKit
import MetalKit
import SwiftUI

private struct GPUVertex { var position: SIMD2<Float>; var color: SIMD4<Float> }
private struct ViewUniforms { var center: SIMD2<Float>; var scale: SIMD2<Float> }

final class MetalDrawing: NSObject, MTKViewDelegate {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
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
        struct V { float2 position; float4 color; };
        struct U { float2 center; float2 scale; };
        struct O { float4 position [[position]]; float4 color; };
        vertex O drawing_vertex(uint i [[vertex_id]], const device V *v [[buffer(0)]], constant U &u [[buffer(1)]]) {
            O o; o.position=float4((v[i].position-u.center)*u.scale,0,1); o.color=v[i].color; return o;
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
        super.init()
        view.delegate = self; view.isPaused = true; view.enableSetNeedsDisplay = true
    }
    func upload(_ scene: Scene, camera: Camera, size: NSSize, grid: Bool) {
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
            lines.append(vertex(s.ax,s.ay,c)); lines.append(vertex(s.bx,s.by,c))
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
        var uniforms = ViewUniforms(center: .init(Float(camera.center.x-origin.x),Float(camera.center.y-origin.y)),scale: .init(Float(2*camera.scale/size.width),Float(2*camera.scale/size.height)))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewUniforms>.stride, index: 1)
        if let buffer = fillBuffer { encoder.setVertexBuffer(buffer, offset: 0, index: 0); encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: fillCount) }
        if let buffer = lineBuffer { encoder.setVertexBuffer(buffer, offset: 0, index: 0); encoder.drawPrimitives(type: .line, vertexStart: 0, vertexCount: lineCount) }
        encoder.endEncoding(); command.present(drawable); command.commit()
    }
}

@MainActor final class DrawingCanvas: NSView {
    let model: EditorModel
    private let metal = MTKView()
    private let overlay = CanvasOverlay()
    private var renderer: MetalDrawing?
    var camera = Camera()
    var points: [CADPoint] = []
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
    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { bounds.contains(point) ? self : nil }

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        addSubview(metal); addSubview(overlay); overlay.canvas = self
        do { renderer = try MetalDrawing(view: metal) } catch { model.show(error) }
        setAccessibilityElement(true); setAccessibilityRole(.group); setAccessibilityLabel("Drawing canvas")
        model.invalidate = { [weak self] in self?.refresh(force: true) }
        model.cancelGesture = { [weak self] in self?.points = []; self?.snapKind = "none"; self?.overlay.needsDisplay = true }
        model.fitView = { [weak self] in self?.fit() }
        model.acceptCoordinate = { [weak self] p, relative in
            guard let self else {return}
            self.accept(relative ? (self.points.last ?? .zero)+p : p)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layout() { super.layout(); metal.frame = bounds; overlay.frame = bounds; refresh(force: true) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: .zero, options: [.activeInKeyWindow,.mouseMoved,.mouseEnteredAndExited,.inVisibleRect], owner: self); addTrackingArea(t); tracking = t
    }
    func fit() {
        Task { if let b = await model.extents() { camera.fit(b, size: bounds.size); refresh(force: true) } }
    }
    func refresh(force: Bool = false) {
        renderer?.camera = camera; renderer?.size = bounds.size
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
                renderer?.upload(result, camera: camera, size: bounds.size, grid: model.grid)
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
            guard let response = try? await model.core.request(["op":"snap","point":p.json,"tolerance":9/camera.scale]), serial == motionSerial else { return }
            if let q = response["point"] as? [String:Double] {
                cursor = CADPoint(x:q["x"] ?? p.x,y:q["y"] ?? p.y); snapKind = response["kind"] as? String ?? "none"
                if snapKind == "none" { cursor = constrained(cursor) }
                model.coordinate = cursor; overlay.needsDisplay = true
            }
        }
    }
    func constrained(_ p: CADPoint) -> CADPoint {
        guard let base = points.last else { return p }
        let delta = p-base
        if model.ortho { return abs(delta.x) >= abs(delta.y) ? CADPoint(x:p.x,y:base.y) : CADPoint(x:base.x,y:p.y) }
        if model.polar { let angle = (atan2(delta.y,delta.x)/(.pi/4)).rounded()*(.pi/4); let radius = hypot(delta.x,delta.y); return base+CADPoint(x:cos(angle),y:sin(angle))*radius }
        return p
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        if event.modifierFlags.contains(.option) { isPanning = true; return }
        let p = camera.world(convert(event.locationInWindow, from:nil),size:bounds.size)
        Task {
            var q = constrained(p)
            if model.snapping, let result = try? await model.core.request(["op":"snap","point":p.json,"tolerance":9/camera.scale]), result["kind"] as? String != "none", let v = result["point"] as? [String:Double] { q = CADPoint(x:v["x"] ?? p.x,y:v["y"] ?? p.y) }
            accept(q, shift: event.modifierFlags.contains(.shift))
        }
    }
    func accept(_ p: CADPoint, shift: Bool = false) {
        if model.tool == .select { model.operation(["op":"pick","point":p.json,"tolerance":7/camera.scale,"extend":shift]); return }
        points.append(p); cursor = p
        switch model.tool {
        case .line where points.count == 2: finish("LINE \(points[0].command) \(p.command)")
        case .rectangle where points.count == 2, .hatch where points.count == 2:
            let a = points[0]
            if model.tool == .hatch { finish("HATCH diagonal \(max(a.distance(p)/30,0.01)) \(a.command) \(CADPoint(x:p.x,y:a.y).command) \(p.command) \(CADPoint(x:a.x,y:p.y).command)") }
            else { finish("RECT \(a.command) \(p.command)") }
        case .circle where points.count == 2: finish("CIRCLE \(points[0].command) \(points[0].distance(p))")
        case .arc where points.count == 3:
            let c = points[0]; let a = points[1]-c; let b = p-c
            let start = atan2(a.y,a.x)*180 / .pi
            let sweep = (atan2(b.y,b.x)*180 / .pi-start+360).truncatingRemainder(dividingBy:360)
            finish("ARC \(c.command) \(hypot(a.x,a.y)) \(start) \(sweep)")
        case .dimension where points.count == 3:
            let a = points[0], b = points[1]; let d = b-a
            let offset = ((p.x-a.x)*(-d.y)+(p.y-a.y)*d.x)/hypot(d.x,d.y)
            finish("DIMALIGNED \(a.command) \(b.command) \(offset)")
        case .move where points.count == 2, .copy where points.count == 2: finish("\(model.tool == .move ? "MOVE" : "COPY") \((p-points[0]).command)")
        case .text:
            let alert = NSAlert(); alert.messageText = "Add text"
            let field = NSTextField(string: "Room name"); field.frame = NSRect(x:0,y:0,width:300,height:26); alert.accessoryView = field
            alert.addButton(withTitle:"Add"); alert.addButton(withTitle:"Cancel")
            if alert.runModal() == .alertFirstButtonReturn { finish("TEXT \(p.command) \(model.units == "m" ? 0.15 : 150) \(field.stringValue)") } else { points = [] }
        default: break
        }
        overlay.needsDisplay = true
    }
    func finish(_ text: String) { points = []; model.execute(text); overlay.needsDisplay = true }
    override func mouseDragged(with event: NSEvent) {
        if isPanning { camera.center.x -= event.deltaX/camera.scale; camera.center.y += event.deltaY/camera.scale; refresh() } else { mouseMoved(with:event) }
    }
    override func mouseUp(with event: NSEvent) { isPanning = false }
    override func otherMouseDragged(with event: NSEvent) { camera.center.x -= event.deltaX/camera.scale; camera.center.y += event.deltaY/camera.scale; refresh() }
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) || !event.hasPreciseScrollingDeltas { zoom(exp(event.scrollingDeltaY*0.025),event:event) }
        else { camera.center.x -= event.scrollingDeltaX/camera.scale; camera.center.y += event.scrollingDeltaY/camera.scale; refresh() }
    }
    override func magnify(with event: NSEvent) { zoom(max(0.1,1+event.magnification),event:event) }
    func zoom(_ amount: Double, event: NSEvent) {
        let p = convert(event.locationInWindow,from:nil)
        let before = camera.world(p,size:bounds.size)
        camera.scale = min(max(camera.scale*amount,1e-8),1e8)
        camera.center = camera.center + before-camera.world(p,size:bounds.size)
        // Retessellate curves/grid at the new screen-space tolerance.
        refresh(force:true)
    }
    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53: model.cancel()
        case 51,117: model.execute("ERASE")
        case 36,76: if model.tool == .polyline, points.count >= 2 { finish("PLINE "+points.map(\.command).joined(separator:" ")) }
        default: super.keyDown(with:event)
        }
    }
    fileprivate func drawOverlay() {
        let size = bounds.size
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
