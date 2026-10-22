import AppKit

/// Plot options shown in the system print panel, like AutoCAD's Print/Plot dialog.
@MainActor final class PlotOptions: NSViewController, NSPrintPanelAccessorizing {
    static let scales: [Double?] = [nil, 1, 2, 5, 10, 20, 25, 50, 100, 200, 500, 1000]
    @objc dynamic var area = 0 // Extents, Selection, Display
    @objc dynamic var scaleIndex = 0
    @objc dynamic var monochrome = true
    @objc dynamic var lineWeights = true
    let hasSelection: Bool
    init(hasSelection: Bool) { self.hasSelection = hasSelection; super.init(nibName: nil, bundle: nil); title = "Plot" }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    var denominator: Double? { Self.scales[scaleIndex] }

    override func loadView() {
        func popup(_ titles: [String], _ key: String) -> NSPopUpButton {
            let p = NSPopUpButton(); p.addItems(withTitles: titles); p.bind(.selectedIndex, to: self, withKeyPath: key); return p
        }
        func label(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.alignment = .right; return l }
        let areaPopup = popup(["Extents", "Selection", "Display"], "area")
        areaPopup.item(at: 1)?.isEnabled = hasSelection; areaPopup.autoenablesItems = false
        let scalePopup = popup(Self.scales.map { $0.map { "1:\($0.formatted())" } ?? "Fit to Paper" }, "scaleIndex")
        let style = popup(["Monochrome", "Drawing Colors"], "monochromeIndex")
        let weights = NSButton(checkboxWithTitle: "Plot object lineweights", target: nil, action: nil); weights.bind(.value, to: self, withKeyPath: "lineWeights")
        let grid = NSGridView(views: [[label("Plot area:"), areaPopup], [label("Plot scale:"), scalePopup], [label("Plot style:"), style], [NSGridCell.emptyContentView, weights]])
        grid.rowSpacing = 8; grid.columnSpacing = 10; grid.column(at: 0).xPlacement = .trailing
        let note = NSTextField(wrappingLabelWithString: "Scales use the drawing's units. Print at 100% in the printer settings to keep an exact scale.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize); note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [grid, note]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 20, bottom: 12, right: 20)
        view = stack
    }
    @objc dynamic var monochromeIndex: Int {
        get { monochrome ? 0 : 1 }
        set { monochrome = newValue == 0 }
    }
    @objc class func keyPathsForValuesAffectingMonochromeIndex() -> Set<String> { ["monochrome"] }
    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [[.itemName: "Plot Area", .itemDescription: ["Extents", "Selection", "Display"][area]],
         [.itemName: "Plot Scale", .itemDescription: denominator.map { "1:\($0.formatted())" } ?? "Fit to Paper"],
         [.itemName: "Plot Style", .itemDescription: monochrome ? "Monochrome" : "Drawing Colors"]]
    }
    func keyPathsForValuesAffectingPreview() -> Set<String> { ["area", "scaleIndex", "monochrome", "lineWeights"] }
}

/// One-page plot of model space, laid out on the printer's imageable area.
@MainActor final class PlotView: NSView {
    let options: PlotOptions
    let units: String
    let scene: Scene
    let selection: Set<UInt64>
    let extents: CADBounds
    let selectionBounds: CADBounds?
    let display: CADBounds?
    init(options: PlotOptions, units: String, scene: Scene, selection: Set<UInt64>, extents: CADBounds, selectionBounds: CADBounds?, display: CADBounds?, size: NSSize) {
        self.options = options; self.units = units; self.scene = scene; self.selection = selection
        self.extents = extents; self.selectionBounds = selectionBounds; self.display = display
        super.init(frame: NSRect(origin: .zero, size: size))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { false }
    override func knowsPageRange(_ range: NSRangePointer) -> Bool {
        if let info = NSPrintOperation.current?.printInfo { setFrameSize(info.imageablePageBounds.size) }
        range.pointee = NSRange(location: 1, length: 1); return true
    }
    override func rectForPage(_ page: Int) -> NSRect { bounds }
    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let b: CADBounds
        var drawn = scene
        switch options.area {
        case 1 where selectionBounds != nil: b = selectionBounds!; drawn = PDFPlot.filtered(scene, to: selection)
        case 2 where display != nil: b = display!
        default: b = extents
        }
        let page = bounds
        let denominator = options.denominator ?? PDFPlot.fitDenominator(b, page: page, units: units, margin: 0)
        let scale = PDFPlot.millimeters(per: units) / denominator * 72 / 25.4
        PDFPlot.render(drawn, in: context, bounds: b, area: page, scale: scale, monochrome: options.monochrome, lineWeights: options.lineWeights)
    }
}

@MainActor enum PlotPrinting {
    /// Builds the print operation for File ▸ Print (⌘P), using the document's page setup.
    static func operation(for document: DrawingDocument, settings: [NSPrintInfo.AttributeKey: Any]) throws -> NSPrintOperation {
        let editor = document.editor
        let info = document.printInfo.copy() as! NSPrintInfo
        info.dictionary().addEntries(from: settings)
        let imageable = info.imageablePageBounds
        info.leftMargin = imageable.minX; info.bottomMargin = imageable.minY
        info.rightMargin = info.paperSize.width - imageable.maxX; info.topMargin = info.paperSize.height - imageable.maxY
        info.horizontalPagination = .clip; info.verticalPagination = .clip
        info.isHorizontallyCentered = true; info.isVerticallyCentered = true
        let state = try document.core.requestSync(["op": "state"])
        guard let raw = state["bounds"], !(raw is NSNull) else { throw CoreError.message("The drawing is empty") }
        let extents = try JSONDecoder().decode(CADBounds.self, from: JSONSerialization.data(withJSONObject: raw))
        var selectionBounds: CADBounds?
        if !editor.selection.isEmpty, let measured = try? document.core.requestSync(["op": "measure"]), let raw = measured["bounds"], !(raw is NSNull) {
            selectionBounds = try? JSONDecoder().decode(CADBounds.self, from: JSONSerialization.data(withJSONObject: raw))
        }
        let display = editor.visibleBounds?()
        var all = extents
        if let d = display { all = CADBounds(min: CADPoint(x: min(all.min.x, d.min.x), y: min(all.min.y, d.min.y)), max: CADPoint(x: max(all.max.x, d.max.x), y: max(all.max.y, d.max.y))) }
        let span = max(all.max.x - all.min.x, all.max.y - all.min.y, 1e-6)
        let scene = try document.core.sceneSync(bounds: all, tolerance: span / 20_000)
        let options = PlotOptions(hasSelection: selectionBounds != nil)
        let view = PlotView(options: options, units: editor.units, scene: scene, selection: Set(editor.selection), extents: extents, selectionBounds: selectionBounds, display: display, size: imageable.size)
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.jobTitle = document.displayName
        operation.printPanel.options.formUnion([.showsPaperSize, .showsOrientation, .showsPreview, .showsCopies])
        operation.printPanel.addAccessoryController(options)
        return operation
    }
}
