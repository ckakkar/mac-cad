import AppKit
import MetalKit

private struct GPUVertex { var position: SIMD2<Float>; var color: SIMD4<Float>; var width: Float = 1 }
private struct ViewUniforms { var center: SIMD2<Float>; var scale: SIMD2<Float>; var viewport: SIMD2<Float> }

/// Batched Metal drawing of one scene snapshot. Positions are relative to the
/// camera center at upload time, so GPU floats stay precise far from the origin.
final class MetalDrawing: NSObject, MTKViewDelegate {
    static let sampleCount = 4
    let device: MTLDevice
    let queue: MTLCommandQueue
    let pipeline: MTLRenderPipelineState
    let strokePipeline: MTLRenderPipelineState
    var camera = Camera()
    var size = NSSize(width: 1, height: 1)
    var origin = CADPoint.zero
    var clearColor = MTLClearColor(red: 0.13, green: 0.15, blue: 0.18, alpha: 1)
    private var lineBuffer: MTLBuffer?
    private var fillBuffer: MTLBuffer?
    private var lineCount = 0
    private var fillCount = 0
    init(view: MTKView) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw CoreError.message("A Metal-capable GPU is required") }
        self.device = device; self.queue = queue; view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.sampleCount = Self.sampleCount
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
        descriptor.rasterSampleCount = Self.sampleCount
        descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        descriptor.vertexFunction = library.makeFunction(name: "stroke_vertex")
        strokePipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        super.init()
        view.delegate = self; view.isPaused = true; view.enableSetNeedsDisplay = true
    }
    struct GridStyle {
        var spacing: Double?
        var minor: SIMD4<Float>
        var major: SIMD4<Float>
        var axis: SIMD4<Float>
    }
    @MainActor func upload(_ scene: Scene, camera: Camera, size: NSSize, grid: GridStyle?, lineWeights: Bool = false, settings: AppSettings) {
        origin = camera.center
        var lines: [GPUVertex] = []; lines.reserveCapacity(scene.segments.count * 2 + 4096)
        var fills: [GPUVertex] = []; fills.reserveCapacity(scene.triangles.count * 3)
        let vertex: (Double, Double, SIMD4<Float>) -> GPUVertex = { [origin] x, y, color in .init(position: .init(Float(x - origin.x), Float(y - origin.y)), color: color) }
        if let grid {
            let bounds = camera.bounds(size: size, margin: 2)
            // Adaptive 1-2-5 spacing keeps minor lines at least 12 points apart.
            var spacing = grid.spacing ?? 0
            if spacing * camera.scale < 6 {
                let raw = 12 / camera.scale, decade = pow(10, floor(log10(raw)))
                spacing = [1.0, 2.0, 5.0, 10.0].map { $0 * decade }.first { $0 >= raw } ?? decade * 10
            }
            func add(_ value: Double, horizontal: Bool) {
                let index = Int((value / spacing).rounded())
                let color = abs(value) < spacing * 0.5 ? grid.axis : index % 5 == 0 ? grid.major : grid.minor
                if horizontal { lines.append(vertex(bounds.min.x, value, color)); lines.append(vertex(bounds.max.x, value, color)) }
                else { lines.append(vertex(value, bounds.min.y, color)); lines.append(vertex(value, bounds.max.y, color)) }
            }
            var x = floor(bounds.min.x / spacing) * spacing
            while x <= bounds.max.x && lines.count < 4000 { add(x, horizontal: false); x += spacing }
            var y = floor(bounds.min.y / spacing) * spacing
            while y <= bounds.max.y && lines.count < 8000 { add(y, horizontal: true); y += spacing }
        }
        for s in scene.segments {
            let c = settings.displayColor(SIMD4<Float>(s.color.0, s.color.1, s.color.2, s.color.3))
            var a = vertex(s.ax, s.ay, c), b = vertex(s.bx, s.by, c)
            a.width = lineWeights ? max(1, s.line_weight * 2.83465) : 1; b.width = a.width
            lines.append(a); lines.append(b)
        }
        for t in scene.triangles {
            let c = settings.displayColor(SIMD4<Float>(t.color.0, t.color.1, t.color.2, t.color.3))
            fills.append(vertex(t.ax, t.ay, c)); fills.append(vertex(t.bx, t.by, c)); fills.append(vertex(t.cx, t.cy, c))
        }
        lineCount = lines.count; fillCount = fills.count
        lineBuffer = lines.isEmpty ? nil : device.makeBuffer(bytes: lines, length: lines.count * MemoryLayout<GPUVertex>.stride, options: .storageModeShared)
        fillBuffer = fills.isEmpty ? nil : device.makeBuffer(bytes: fills, length: fills.count * MemoryLayout<GPUVertex>.stride, options: .storageModeShared)
    }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) {
        view.clearColor = clearColor
        guard size.width > 0, size.height > 0, let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable, let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        var uniforms = ViewUniforms(center: .init(Float(camera.center.x - origin.x), Float(camera.center.y - origin.y)), scale: .init(Float(2 * camera.scale / size.width), Float(2 * camera.scale / size.height)), viewport: .init(Float(size.width), Float(size.height)))
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<ViewUniforms>.stride, index: 1)
        if let buffer = fillBuffer { encoder.setVertexBuffer(buffer, offset: 0, index: 0); encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: fillCount) }
        if let buffer = lineBuffer { encoder.setRenderPipelineState(strokePipeline); encoder.setVertexBuffer(buffer, offset: 0, index: 0); encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: lineCount / 2 * 6) }
        encoder.endEncoding(); command.present(drawable); command.commit()
    }
}
