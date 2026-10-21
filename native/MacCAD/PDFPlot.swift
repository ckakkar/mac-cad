import AppKit
import UniformTypeIdentifiers

@MainActor enum PDFPlot {
    static func export(_ editor: EditorModel) {
        let alert = NSAlert(); alert.messageText = "Export scaled PDF"
        alert.informativeText = "A3 landscape · centered model extents · drawing units are converted to millimeters. Content outside the printable sheet is clipped."
        let field = NSTextField(string:"100"); field.frame = NSRect(x:0,y:0,width:180,height:26); field.placeholderString = "Scale denominator (1:100)"; alert.accessoryView = field
        alert.addButton(withTitle:"Export…"); alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, let denominator = Double(field.stringValue), denominator > 0, denominator.isFinite else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = "Drawing.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                guard let b = await editor.extents() else { throw CoreError.message("The drawing is empty") }
                let factor: Double = ["mm":1,"cm":10,"m":1000,"in":25.4,"ft":304.8][editor.units] ?? 1
                let scale = factor/denominator*72/25.4
                let page = CGRect(x:0,y:0,width:420*72/25.4,height:297*72/25.4)
                if (b.max.x-b.min.x)*scale > page.width-48 || (b.max.y-b.min.y)*scale > page.height-48 {
                    let warning = NSAlert(); warning.messageText = "Drawing exceeds this sheet at 1:\(denominator.formatted())"; warning.informativeText = "The PDF will clip content to A3. Choose a larger scale denominator to fit the drawing."; warning.addButton(withTitle:"Export Clipped"); warning.addButton(withTitle:"Cancel")
                    guard warning.runModal() == .alertFirstButtonReturn else { return }
                }
                let scene = try await editor.core.scene(bounds:b,tolerance:0.05/scale)
                try write(scene,bounds:b,page:page,scale:scale,url:url)
                editor.message = "Exported A3 PDF at 1:\(denominator.formatted())"
            } catch { editor.show(error) }
        }
    }
    static func write(_ scene: Scene, bounds: CADBounds, page: CGRect, scale: Double, url: URL) throws {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data:data as CFMutableData) else { throw CoreError.message("Cannot create PDF output") }
        var box = page
        guard let context = CGContext(consumer:consumer,mediaBox:&box,nil) else { throw CoreError.message("Cannot create PDF context") }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor); context.fill(page)
        context.clip(to:page.insetBy(dx:24,dy:24))
        let center = bounds.min + (bounds.max-bounds.min)*0.5
        context.translateBy(x:page.midX,y:page.midY); context.scaleBy(x:scale,y:scale); context.translateBy(x:-center.x,y:-center.y)
        context.setStrokeColor(NSColor.black.cgColor); context.setLineWidth(0.6/scale)
        for t in scene.triangles {
            context.setFillColor(CGColor(gray:0.88,alpha:1));context.move(to:CGPoint(x:t.ax,y:t.ay));context.addLine(to:CGPoint(x:t.bx,y:t.by));context.addLine(to:CGPoint(x:t.cx,y:t.cy));context.closePath();context.fillPath()
        }
        for s in scene.segments { context.move(to:CGPoint(x:s.ax,y:s.ay));context.addLine(to:CGPoint(x:s.bx,y:s.by)) }
        context.strokePath()
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
        for l in scene.labels {
            context.saveGState(); context.translateBy(x:l.at.x,y:l.at.y);context.rotate(by:l.rotation)
            (l.text as NSString).draw(at:.zero,withAttributes:[.font:NSFont.systemFont(ofSize:l.height),.foregroundColor:NSColor.black]);context.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage();context.closePDF()
        try (data as Data).write(to:url,options:.atomic)
    }
}
