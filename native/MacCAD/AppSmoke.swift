import AppKit
import MetalKit

/// Internal integration check, run by `make check`; never runs during normal use.
@MainActor enum AppSmoke {
    static func run() async -> Int32 {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("maccad-app-smoke-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            defer { try? FileManager.default.removeItem(at:directory) }
            try await CommandSmoke.run()
            let original = DrawingDocument()
            let core = original.core
            for c in ["LINE 0,0 5000,0","CIRCLE 2500,2000 800","TEXT 1000,1000 150 Living room","DIMALIGNED 0,0 5000,0 -400","HATCH solid 200 0,0 1000,0 1000,500 0,500"] { _ = try await core.request(["op":"command","text":c]) }
            _ = try await core.request(["op":"select_all"])
            _ = try await core.request(["op":"command","text":"MOVE 100,200"])
            _ = try await core.request(["op":"command","text":"UNDO"])
            _ = try await core.request(["op":"command","text":"REDO"])
            let expected = try await core.request(["op":"serialize"])
            let url = directory.appendingPathComponent("saved.maccad")
            try original.writeSafely(to:url,ofType:nativeDocumentType,for:.saveOperation)
            let reopened = DrawingDocument()
            try reopened.read(from:Data(contentsOf:url),ofType:nativeDocumentType)
            let actual = try await reopened.core.request(["op":"serialize"])
            guard NSDictionary(dictionary:expected).isEqual(to:actual) else { throw CoreError.message("NSDocument save/reopen changed document geometry") }
            // Recovery data uses the exact same versioned, validated native payload.
            let recovery = try original.data(ofType:nativeDocumentType)
            let recovered = DrawingDocument(); try recovered.read(from:recovery,ofType:nativeDocumentType)
            let bounds = CADBounds(min:.init(x:-1000,y:-1000),max:.init(x:8000,y:5000))
            let scene = try await recovered.core.scene(bounds:bounds,tolerance:0.2)
            guard !scene.segments.isEmpty, !scene.triangles.isEmpty, scene.labels.count == 2 else { throw CoreError.message("Scene data missing after recovery") }
            let view = MTKView(frame:NSRect(x:0,y:0,width:900,height:600))
            let renderer = try MetalDrawing(view:view)
            renderer.upload(scene,camera:Camera(),size:view.bounds.size,grid:.init(spacing:nil,minor:[0.2,0.2,0.2,1],major:[0.3,0.3,0.3,1],axis:[0.4,0.4,0.4,1]),settings:.shared)
            let pdf = directory.appendingPathComponent("drawing.pdf")
            try PDFPlot.write(scene,bounds:bounds,page:CGRect(x:0,y:0,width:1190,height:842),scale:0.1,url:pdf)
            guard try Data(contentsOf:pdf).starts(with:Data("%PDF".utf8)) else { throw CoreError.message("Invalid PDF output") }
            // File ▸ Print builds a one-page plot view through the system print operation.
            let operation = try PlotPrinting.operation(for:original,settings:[:])
            guard let plot = operation.view as? PlotView, plot.dataWithPDF(inside:plot.bounds).starts(with:Data("%PDF".utf8)) else { throw CoreError.message("Print plot view did not render") }
            let fixtures = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent(".build/libredwg-0.14/test/test-data")
            for version in ["2000","2013","2018"] {
                let input = fixtures.appendingPathComponent("\(version)/Line.dwg")
                guard FileManager.default.fileExists(atPath:input.path) else{throw CoreError.message("Missing upstream LibreDWG QA fixture: \(version)/Line.dwg")}
                let conversion = try await DWGImport.convert(input)
                defer{try? FileManager.default.removeItem(at:conversion.file.deletingLastPathComponent())}
                let imported = CADCore();let state = try await imported.request(["op":"import_dxf","path":conversion.file.path])
                guard (state["count"] as? Int ?? 0)>0 else{throw CoreError.message("DWG \(version) fixture imported no geometry")}
                print("Bundled DWG import passed: LibreDWG upstream \(version)/Line.dwg")
            }
            print("App integration passed: NSDocument safe save/reopen, recovery payload, worker queue, binary scene, Metal pipeline and PDF output.")
            return 0
        } catch { fputs("App integration failed: \(error.localizedDescription)\n",stderr); return 1 }
    }
}
