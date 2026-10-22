import AppKit
import UniformTypeIdentifiers

/// Scaled vector output shared by Export PDF and Print.
@MainActor enum PDFPlot {
    static let papers: [(name: String, mm: (Double, Double))] = [("A4", (210, 297)), ("A3", (297, 420)), ("A2", (420, 594)), ("A1", (594, 841)), ("A0", (841, 1189)), ("Letter", (215.9, 279.4)), ("Legal", (215.9, 355.6)), ("Tabloid", (279.4, 431.8))]
    static func millimeters(per units: String) -> Double { ["mm": 1, "cm": 10, "m": 1000, "in": 25.4, "ft": 304.8][units] ?? 1 }

    /// Export PDF… opens a save sheet whose accessory holds the plot options.
    static func export(_ editor: EditorModel, window: NSWindow?) {
        let field = NSTextField(string: "100"); field.placeholderString = "Fit or 100"
        let paper = NSPopUpButton(); paper.addItems(withTitles: papers.map(\.name)); paper.selectItem(withTitle: "A3")
        let orientation = NSPopUpButton(); orientation.addItems(withTitles: ["Landscape", "Portrait"])
        let output = NSPopUpButton(); output.addItems(withTitles: ["Monochrome", "Drawing colors"])
        let selection = NSButton(checkboxWithTitle: "Plot selection only", target: nil, action: nil); selection.isEnabled = !editor.selection.isEmpty
        let lineWeights = NSButton(checkboxWithTitle: "Plot object lineweights", target: nil, action: nil); lineWeights.state = .on
        func label(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.alignment = .right; return l }
        let grid = NSGridView(views: [[label("Paper:"), paper], [label("Orientation:"), orientation], [label("Scale 1:"), field], [label("Plot style:"), output], [NSGridCell.emptyContentView, selection], [NSGridCell.emptyContentView, lineWeights]])
        grid.rowSpacing = 8; grid.columnSpacing = 10; grid.column(at: 0).xPlacement = .trailing
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        grid.translatesAutoresizingMaskIntoConstraints = false; accessory.addSubview(grid)
        NSLayoutConstraint.activate([grid.centerXAnchor.constraint(equalTo: accessory.centerXAnchor), grid.topAnchor.constraint(equalTo: accessory.topAnchor, constant: 12), grid.bottomAnchor.constraint(equalTo: accessory.bottomAnchor, constant: -12)])
        let panel = NSSavePanel(); panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = ((editor.document?.displayName ?? "Drawing") as NSString).deletingPathExtension + ".pdf"
        panel.accessoryView = accessory; panel.message = "Enter Fit to fit the drawing, or a scale denominator such as 100 for 1:100."
        let completion: (NSApplication.ModalResponse) -> Void = { result in
            guard result == .OK, let url = panel.url else { return }
            let size = papers[max(paper.indexOfSelectedItem, 0)].mm, landscape = orientation.indexOfSelectedItem == 0
            let page = CGRect(x: 0, y: 0, width: (landscape ? size.1 : size.0) * 72 / 25.4, height: (landscape ? size.0 : size.1) * 72 / 25.4)
            let fit = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "fit"
            let requested = Double(field.stringValue) ?? 0
            guard fit || requested > 0 && requested.isFinite else { editor.show(CoreError.message("Enter Fit or a positive scale denominator")); return }
            let monochrome = output.indexOfSelectedItem == 0, selectionOnly = selection.state == .on, weights = lineWeights.state == .on
            Task {
                do {
                    let b = try await plotBounds(editor, selectionOnly: selectionOnly)
                    let denominator = fit ? fitDenominator(b, page: page, units: editor.units) : requested
                    let scale = millimeters(per: editor.units) / denominator * 72 / 25.4
                    if (b.max.x - b.min.x) * scale > page.width - 48 || (b.max.y - b.min.y) * scale > page.height - 48, let window {
                        let warning = NSAlert(); warning.messageText = "Drawing exceeds this sheet at 1:\(denominator.formatted())"
                        warning.informativeText = "The PDF will clip content to the selected paper. Choose Fit or a larger scale denominator to fit the drawing."
                        warning.addButton(withTitle: "Export Clipped"); warning.addButton(withTitle: "Cancel")
                        guard await warning.beginSheetModal(for: window) == .alertFirstButtonReturn else { return }
                    }
                    var scene = try await editor.core.scene(bounds: b, tolerance: 0.05 / scale, highlight: false)
                    if selectionOnly { scene = filtered(scene, to: Set(editor.selection)) }
                    try write(scene, bounds: b, page: page, scale: scale, url: url, monochrome: monochrome, lineWeights: weights)
                    editor.message = "Exported \(paper.titleOfSelectedItem ?? "") PDF at 1:\(denominator.formatted())"
                    editor.append(HistoryLine(text: editor.message, kind: .info))
                } catch { editor.show(error) }
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: completion) } else { completion(panel.runModal()) }
    }
    static func plotBounds(_ editor: EditorModel, selectionOnly: Bool) async throws -> CADBounds {
        if selectionOnly {
            let state = try await editor.core.request(["op": "measure"])
            guard let raw = state["bounds"], !(raw is NSNull) else { throw CoreError.message("The selection has no drawable bounds") }
            return try JSONDecoder().decode(CADBounds.self, from: JSONSerialization.data(withJSONObject: raw))
        }
        guard let value = await editor.extents() else { throw CoreError.message("The drawing is empty") }
        return value
    }
    static func fitDenominator(_ b: CADBounds, page: CGRect, units: String, margin: CGFloat = 48) -> Double {
        let points = millimeters(per: units) * 72 / 25.4
        let width = (b.max.x - b.min.x) * points / Double(page.width - margin)
        let height = (b.max.y - b.min.y) * points / Double(page.height - margin)
        return max(width, height, 1e-6)
    }
    static func filtered(_ scene: Scene, to ids: Set<UInt64>) -> Scene {
        var scene = scene
        scene.segments.removeAll { !ids.contains($0.entity) }; scene.labels.removeAll { !ids.contains($0.entity) }; scene.triangles.removeAll { !ids.contains($0.entity) }
        return scene
    }
    static func write(_ scene: Scene, bounds: CADBounds, page: CGRect, scale: Double, url: URL, monochrome: Bool = true, lineWeights: Bool = true) throws {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { throw CoreError.message("Cannot create PDF output") }
        var box = page
        guard let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw CoreError.message("Cannot create PDF context") }
        context.beginPDFPage(nil)
        context.setFillColor(NSColor.white.cgColor); context.fill(page)
        render(scene, in: context, bounds: bounds, area: page.insetBy(dx: 24, dy: 24), scale: scale, monochrome: monochrome, lineWeights: lineWeights)
        context.endPDFPage(); context.closePDF()
        try (data as Data).write(to: url, options: .atomic)
    }
    /// Draws `scene` centered in `area` at `scale` points per drawing unit, on white paper.
    static func render(_ scene: Scene, in context: CGContext, bounds: CADBounds, area: CGRect, scale: Double, monochrome: Bool, lineWeights: Bool) {
        context.saveGState()
        context.clip(to: area)
        let center = bounds.min + (bounds.max - bounds.min) * 0.5
        context.translateBy(x: area.midX, y: area.midY); context.scaleBy(x: scale, y: scale); context.translateBy(x: -center.x, y: -center.y)
        // White (ACI 7) objects plot black, as they do on white paper in AutoCAD.
        func ink(_ r: Float, _ g: Float, _ b: Float) -> CGColor {
            if monochrome || (r > 0.75 && g > 0.75 && b > 0.75) { return NSColor.black.cgColor }
            return CGColor(red: CGFloat(r), green: CGFloat(g), blue: CGFloat(b), alpha: 1)
        }
        for t in scene.triangles {
            context.setFillColor(monochrome ? CGColor(gray: 0.88, alpha: 1) : CGColor(red: CGFloat(t.color.0), green: CGFloat(t.color.1), blue: CGFloat(t.color.2), alpha: CGFloat(max(t.color.3, 0.35))))
            context.move(to: CGPoint(x: t.ax, y: t.ay)); context.addLine(to: CGPoint(x: t.bx, y: t.by)); context.addLine(to: CGPoint(x: t.cx, y: t.cy)); context.closePath(); context.fillPath()
        }
        context.setLineCap(.round)
        for s in scene.segments {
            context.setStrokeColor(ink(s.color.0, s.color.1, s.color.2))
            context.setLineWidth((lineWeights ? max(Double(s.line_weight) * 72 / 25.4, 0.25) : 0.36) / scale)
            context.move(to: CGPoint(x: s.ax, y: s.ay)); context.addLine(to: CGPoint(x: s.bx, y: s.by)); context.strokePath()
        }
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        for l in scene.labels {
            context.saveGState(); context.translateBy(x: l.at.x, y: l.at.y); context.rotate(by: l.rotation)
            let font = NSFont.systemFont(ofSize: l.height)
            (l.text as NSString).draw(at: NSPoint(x: 0, y: font.descender), withAttributes: [.font: font, .foregroundColor: NSColor(cgColor: ink(l.color[0], l.color[1], l.color[2])) ?? .black])
            context.restoreGState()
        }
        NSGraphicsContext.restoreGraphicsState()
        context.restoreGState()
    }
}
