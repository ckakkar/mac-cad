import AppKit
import CCadCore

struct CADPoint: Codable, Equatable {
    var x: Double
    var y: Double
    static let zero = CADPoint(x: 0, y: 0)
    static func + (a: Self, b: Self) -> Self { .init(x: a.x+b.x, y: a.y+b.y) }
    static func - (a: Self, b: Self) -> Self { .init(x: a.x-b.x, y: a.y-b.y) }
    static func * (a: Self, b: Double) -> Self { .init(x: a.x*b, y: a.y*b) }
    func distance(_ b: Self) -> Double { hypot(x-b.x, y-b.y) }
    var json: [String: Double] { ["x": x, "y": y] }
    var command: String { "\(x),\(y)" }
}
struct CADBounds: Codable {
    var min: CADPoint
    var max: CADPoint
    func contains(_ other: Self) -> Bool { min.x <= other.min.x && min.y <= other.min.y && max.x >= other.max.x && max.y >= other.max.y }
}
struct CADLayer: Codable, Identifiable {
    var name: String
    var color: [Float]
    var visible: Bool
    var locked: Bool
    var line_type: String
    var line_weight: Float
    var id: String { name }
}
struct CADLabel: Codable {
    var at: CADPoint
    var text: String
    var height: Double
    var rotation: Double
    var color: [Float]
    var entity: UInt64
}
struct Scene {
    var segments: [CadSegment] = []
    var triangles: [CadTriangle] = []
    var labels: [CADLabel] = []
}
enum CoreError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(s) = self { return s }; return nil }
}

/// All Rust handle access, including rendering and file parsing, runs on this
/// document's serial queue. Swift owns immutable snapshots only.
final class CADCore: @unchecked Sendable {
    private let queue = DispatchQueue(label: "xyz.ckakkar.maccad.document", qos: .userInitiated)
    private let queueKey = DispatchSpecificKey<Bool>()
    private let handle: OpaquePointer
    init() { handle = cad_create()!; queue.setSpecific(key:queueKey,value:true) }
    deinit {
        if DispatchQueue.getSpecific(key:queueKey) == true { cad_destroy(handle) }
        else { queue.sync { cad_destroy(handle) } }
    }

    private func perform(_ payload: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let string = String(decoding: data, as: UTF8.self)
        guard let response = string.withCString({ cad_request(handle, $0) }) else { throw CoreError.message("No response from drawing engine") }
        defer { cad_string_free(response) }
        let decoded = try JSONSerialization.jsonObject(with: Data(String(cString: response).utf8)) as? [String: Any] ?? [:]
        guard decoded["ok"] as? Bool == true else { throw CoreError.message(decoded["error"] as? String ?? "Drawing engine error") }
        return decoded["value"] as? [String: Any] ?? [:]
    }
    func request(_ payload: [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in continuation.resume(with: Result { try perform(payload) }) }
        }
    }
    /// NSDocument reads/writes are coordinated by AppKit. The core still stays on
    /// its queue; editing/scene work cannot race serialization.
    func requestSync(_ payload: [String: Any]) throws -> [String: Any] { try queue.sync { try perform(payload) } }

    /// Synchronous scene for AppKit callbacks such as print operations.
    func sceneSync(bounds: CADBounds, tolerance: Double) throws -> Scene {
        try queue.sync { [self] in
            guard let batch = cad_render_plain(handle,bounds.min.x,bounds.min.y,bounds.max.x,bounds.max.y,tolerance) else { throw CoreError.message("Unable to render drawing") }
            defer { cad_batch_free(batch) }
            return try Self.read(batch)
        }
    }
    private static func read(_ batch: OpaquePointer) throws -> Scene {
        var count = 0
        var result = Scene()
        if let p = cad_batch_segments(batch, &count) { result.segments = Array(UnsafeBufferPointer(start: p, count: count)) }
        if let p = cad_batch_triangles(batch, &count) { result.triangles = Array(UnsafeBufferPointer(start: p, count: count)) }
        if let text = cad_batch_labels(batch) {
            defer { cad_string_free(text) }
            result.labels = try JSONDecoder().decode([CADLabel].self, from: Data(String(cString: text).utf8))
        }
        return result
    }
    func scene(bounds: CADBounds, tolerance: Double, highlight:Bool = true) async throws -> Scene {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                let pointer = highlight ? cad_render(handle,bounds.min.x,bounds.min.y,bounds.max.x,bounds.max.y,tolerance):cad_render_plain(handle,bounds.min.x,bounds.min.y,bounds.max.x,bounds.max.y,tolerance)
                guard let batch = pointer else {
                    continuation.resume(throwing: CoreError.message("Unable to render drawing")); return
                }
                defer { cad_batch_free(batch) }
                continuation.resume(with: Result { try Self.read(batch) })
            }
        }
    }
}

struct Camera {
    var center = CADPoint(x: 3000, y: 2000)
    var scale: Double = 0.1 // logical points per drawing unit
    func world(_ p: NSPoint, size: NSSize) -> CADPoint { .init(x: center.x+(p.x-size.width/2)/scale, y: center.y+(p.y-size.height/2)/scale) }
    func screen(_ p: CADPoint, size: NSSize) -> NSPoint { .init(x: (p.x-center.x)*scale+size.width/2, y: (p.y-center.y)*scale+size.height/2) }
    func bounds(size: NSSize, margin: Double = 1) -> CADBounds {
        let half = CADPoint(x: size.width/scale/2*margin, y: size.height/scale/2*margin)
        return CADBounds(min: center-half, max: center+half)
    }
    mutating func fit(_ b: CADBounds, size: NSSize) {
        center = b.min + (b.max-b.min)*0.5
        scale = min(size.width/max(b.max.x-b.min.x, 1), size.height/max(b.max.y-b.min.y, 1))*0.82
        scale = min(max(scale, 1e-8), 1e8)
    }
}
