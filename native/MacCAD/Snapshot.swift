import AppKit

/// Developer verification: `MacCAD --render-snapshot <drawing> <out.pdf> [minX minY maxX maxY]`
/// opens a .maccad, .dxf or .dwg drawing and plots a window of it in color to
/// a PDF, through the same import, scene and text code the app uses. It lets
/// rendered appearance be compared without driving the user interface.
@MainActor enum Snapshot {
    static func run(_ arguments: [String]) async -> Int32 {
        guard let index = arguments.firstIndex(of: "--render-snapshot"), arguments.count > index + 2 else {
            fputs("usage: MacCAD --render-snapshot <drawing> <out.pdf> [minX minY maxX maxY]\n", stderr); return 2
        }
        let input = URL(fileURLWithPath: arguments[index + 1]), output = URL(fileURLWithPath: arguments[index + 2])
        let window = arguments.dropFirst(index + 3).prefix(4).compactMap(Double.init)
        do {
            let core = CADCore()
            let started = Date()
            var state: [String: Any]
            switch input.pathExtension.lowercased() {
            case "dwg":
                let conversion = try await DWGImport.convert(input)
                defer { try? FileManager.default.removeItem(at: conversion.file.deletingLastPathComponent()) }
                state = try await core.request(["op": "import_dxf", "path": conversion.file.path])
            case "dxf": state = try await core.request(["op": "import_dxf", "path": input.path])
            default: state = try await core.request(["op": "open_native", "path": input.path])
            }
            let opened = Date().timeIntervalSince(started)
            var bounds: CADBounds
            if window.count == 4 {
                bounds = CADBounds(min: .init(x: window[0], y: window[1]), max: .init(x: window[2], y: window[3]))
            } else {
                guard let b = state["bounds"], !(b is NSNull) else { throw CoreError.message("The drawing is empty") }
                bounds = try JSONDecoder().decode(CADBounds.self, from: JSONSerialization.data(withJSONObject: b))
            }
            let page = CGRect(x: 0, y: 0, width: 1684, height: 1191)
            // Points per drawing unit that fit the window inside the page margins.
            let scale = min((page.width - 48) / max(bounds.max.x - bounds.min.x, 1e-9), (page.height - 48) / max(bounds.max.y - bounds.min.y, 1e-9))
            let sceneStarted = Date()
            let scene = try await core.scene(bounds: bounds, tolerance: 0.5 / scale, highlight: false)
            let built = Date().timeIntervalSince(sceneStarted)
            // Lineweights stay off, matching the default model-space display (LWDISPLAY off).
            try PDFPlot.write(scene, bounds: bounds, page: page, scale: scale, url: output, monochrome: false, lineWeights: false)
            print(String(format: "opened %.2fs, scene %.2fs: %d objects, %d segments, %d triangles, %d labels", opened, built, state["count"] as? Int ?? 0, scene.segments.count, scene.triangles.count, scene.labels.count))
            for warning in state["diagnostics"] as? [String] ?? [] { print("  \(warning)") }
            return 0
        } catch { fputs("Snapshot failed: \(error.localizedDescription)\n", stderr); return 1 }
    }
}
