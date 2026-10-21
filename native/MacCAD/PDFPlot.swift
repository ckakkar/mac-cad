import AppKit
import UniformTypeIdentifiers

@MainActor enum PDFPlot {
    static func export(_ editor: EditorModel) {
        let alert = NSAlert(); alert.messageText = "Export scaled PDF"
        alert.informativeText = "Choose a paper size and plot scale. Enter Fit to fit the drawing, or a denominator such as 100 for 1:100."
        let field = NSTextField(string:"100")
        let paper = NSPopUpButton();paper.addItems(withTitles:["A4","A3","A2","A1","A0","Letter","Legal","Tabloid"]);paper.selectItem(withTitle:"A3")
        let orientation = NSPopUpButton();orientation.addItems(withTitles:["Landscape","Portrait"])
        let output = NSPopUpButton();output.addItems(withTitles:["Monochrome","Drawing colors"])
        let selection = NSButton(checkboxWithTitle:"Plot selection only",target:nil,action:nil);selection.isEnabled = !editor.selection.isEmpty
        let grid = NSGridView(views:[[NSTextField(labelWithString:"Paper"),paper],[NSTextField(labelWithString:"Orientation"),orientation],[NSTextField(labelWithString:"Scale 1:"),field],[NSTextField(labelWithString:"Output"),output],[NSTextField(labelWithString:"Area"),selection]])
        grid.rowSpacing = 8;grid.columnSpacing = 12;grid.frame = NSRect(x:0,y:0,width:330,height:160);alert.accessoryView = grid
        alert.addButton(withTitle:"Export…"); alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {return}
        let dimensions:[String:(Double,Double)] = ["A4":(210,297),"A3":(297,420),"A2":(420,594),"A1":(594,841),"A0":(841,1189),"Letter":(215.9,279.4),"Legal":(215.9,355.6),"Tabloid":(279.4,431.8)]
        let size = dimensions[paper.titleOfSelectedItem ?? "A3"]!;let landscape = orientation.indexOfSelectedItem == 0
        let page = CGRect(x:0,y:0,width:(landscape ? size.1:size.0)*72/25.4,height:(landscape ? size.0:size.1)*72/25.4)
        let fit = field.stringValue.trimmingCharacters(in:.whitespacesAndNewlines).lowercased() == "fit"
        let requested = Double(field.stringValue) ?? 0
        guard fit || requested>0 && requested.isFinite else {editor.show(CoreError.message("Enter Fit or a positive scale denominator"));return}
        let monochrome = output.indexOfSelectedItem == 0;let selectionOnly = selection.state == .on
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]; panel.nameFieldStringValue = "Drawing.pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            do {
                let b:CADBounds
                if selectionOnly {
                    let state = try await editor.core.request(["op":"measure"])
                    guard let raw = state["bounds"],!(raw is NSNull) else{throw CoreError.message("The selection has no drawable bounds")}
                    b = try JSONDecoder().decode(CADBounds.self,from:JSONSerialization.data(withJSONObject:raw))
                }else{guard let value = await editor.extents() else{throw CoreError.message("The drawing is empty")};b = value}
                let factor: Double = ["mm":1,"cm":10,"m":1000,"in":25.4,"ft":304.8][editor.units] ?? 1
                let denominator = fit ? max((b.max.x-b.min.x)*factor*72/25.4/(page.width-48),(b.max.y-b.min.y)*factor*72/25.4/(page.height-48),1e-6):requested
                let scale = factor/denominator*72/25.4
                if (b.max.x-b.min.x)*scale > page.width-48 || (b.max.y-b.min.y)*scale > page.height-48 {
                    let warning = NSAlert(); warning.messageText = "Drawing exceeds this sheet at 1:\(denominator.formatted())"; warning.informativeText = "The PDF will clip content to the selected paper. Choose Fit or a larger scale denominator to fit the drawing."; warning.addButton(withTitle:"Export Clipped"); warning.addButton(withTitle:"Cancel")
                    guard warning.runModal() == .alertFirstButtonReturn else { return }
                }
                var scene = try await editor.core.scene(bounds:b,tolerance:0.05/scale,highlight:false)
                if selectionOnly {let ids = Set(editor.selection);scene.segments.removeAll{!ids.contains($0.entity)};scene.labels.removeAll{!ids.contains($0.entity)};scene.triangles.removeAll{!ids.contains($0.entity)}}
                try write(scene,bounds:b,page:page,scale:scale,url:url,monochrome:monochrome)
                editor.message = "Exported \(paper.titleOfSelectedItem ?? "") PDF at 1:\(denominator.formatted())"
            } catch { editor.show(error) }
        }
    }
    static func write(_ scene: Scene, bounds: CADBounds, page: CGRect, scale: Double, url: URL,monochrome:Bool = true) throws {
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
            context.setFillColor(monochrome ? CGColor(gray:0.88,alpha:1):CGColor(red:CGFloat(t.color.0),green:CGFloat(t.color.1),blue:CGFloat(t.color.2),alpha:1));context.move(to:CGPoint(x:t.ax,y:t.ay));context.addLine(to:CGPoint(x:t.bx,y:t.by));context.addLine(to:CGPoint(x:t.cx,y:t.cy));context.closePath();context.fillPath()
        }
        for s in scene.segments {context.setStrokeColor(monochrome ? NSColor.black.cgColor:CGColor(red:CGFloat(s.color.0),green:CGFloat(s.color.1),blue:CGFloat(s.color.2),alpha:1));context.setLineWidth(max(Double(s.line_weight)*72/25.4,0.25)/scale);context.move(to:CGPoint(x:s.ax,y:s.ay));context.addLine(to:CGPoint(x:s.bx,y:s.by));context.strokePath()}
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext:context,flipped:false)
        for l in scene.labels {
            context.saveGState(); context.translateBy(x:l.at.x,y:l.at.y);context.rotate(by:l.rotation)
            (l.text as NSString).draw(at:.zero,withAttributes:[.font:NSFont.systemFont(ofSize:l.height),.foregroundColor:monochrome ? NSColor.black:NSColor(srgbRed:CGFloat(l.color[0]),green:CGFloat(l.color[1]),blue:CGFloat(l.color[2]),alpha:1)]);context.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        context.endPDFPage();context.closePDF()
        try (data as Data).write(to:url,options:.atomic)
    }
}
