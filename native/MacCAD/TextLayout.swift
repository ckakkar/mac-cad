import AppKit

/// Draws CAD text: TEXT justification, MTEXT attachment and wrapping, width
/// factor and obliquing. CAD text height is a cap height, so font sizes are
/// derived from each font's cap-height ratio.
@MainActor enum CADText {
    private static var fonts: [String: NSFont] = [:]

    /// The font for a style's font file or family. TrueType names map to the
    /// installed family; SHX stroke fonts substitute a light sans.
    static func baseFont(_ name: String) -> NSFont {
        if let font = fonts[name] { return font }
        var family = (name as NSString).lastPathComponent
        let ext = (family as NSString).pathExtension.lowercased()
        if ["ttf", "otf", "ttc", "shx"].contains(ext) { family = (family as NSString).deletingPathExtension }
        var font: NSFont?
        if ext != "shx" && !family.isEmpty {
            font = NSFont(name: family, size: 100) ?? NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: 100)
            if font == nil, let match = NSFontManager.shared.availableFontFamilies.first(where: { $0.caseInsensitiveCompare(family) == .orderedSame }) {
                font = NSFontManager.shared.font(withFamily: match, traits: [], weight: 5, size: 100)
            }
        }
        let resolved = font ?? NSFont(name: "HelveticaNeue-Light", size: 100) ?? NSFont.systemFont(ofSize: 100, weight: .light)
        fonts[name] = resolved
        return resolved
    }

    /// Draws `l` into `context`. `map` takes drawing coordinates to context
    /// coordinates and `scale` takes drawing lengths to context lengths.
    static func draw(_ l: CADLabel, in context: CGContext, map: (CADPoint) -> CGPoint, scale: CGFloat, color: NSColor) {
        draw(l, origin: map(l.at), align: l.align.map(map), height: CGFloat(l.height) * scale, wrap: CGFloat(l.wrap ?? 0) * scale, color: color, in: context)
    }

    private static func draw(_ l: CADLabel, origin: CGPoint, align: CGPoint?, height: CGFloat, wrap: CGFloat, color: NSColor, in context: CGContext) {
        let base = baseFont(l.font ?? "")
        let capRatio = max(base.capHeight / 100, 0.4)
        var pointSize = height / capRatio
        let widthFactor = CGFloat(l.width_factor ?? 1)
        var rotation = CGFloat(l.rotation)
        var anchor = origin
        var xScale = widthFactor
        let halign = l.halign ?? 0, valign = l.valign ?? 0, attachment = l.attachment ?? 0
        if attachment == 0, (halign == 3 || halign == 5), let align, hypot(align.x - origin.x, align.y - origin.y) > 0 {
            // Aligned and Fit text span the two points; Aligned also scales height.
            let font = base.withSize(pointSize)
            let natural = (l.text as NSString).size(withAttributes: [.font: font]).width * widthFactor
            let span = hypot(align.x - origin.x, align.y - origin.y)
            rotation = atan2(align.y - origin.y, align.x - origin.x)
            if natural > 0 {
                if halign == 3 { pointSize *= span / natural } else { xScale *= span / natural }
            }
        } else if attachment == 0, halign != 0 || valign != 0, let align {
            anchor = align
        }
        let font = base.withSize(pointSize)
        let cap = font.capHeight
        context.saveGState()
        context.translateBy(x: anchor.x, y: anchor.y)
        context.rotate(by: rotation)
        context.concatenate(CGAffineTransform(a: xScale, b: 0, c: tan(CGFloat(l.oblique ?? 0)), d: 1, tx: 0, ty: 0))
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        defer { NSGraphicsContext.current = previous; context.restoreGState() }
        if attachment > 0 {
            let column = Int((attachment - 1) % 3), row = Int((attachment - 1) / 3)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = [.left, .center, .right][column]
            paragraph.lineHeightMultiple = CGFloat(l.line_spacing ?? 1) * 1.08
            let text = NSAttributedString(string: l.text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
            let layoutWidth = wrap > 0 ? wrap / max(xScale, 0.01) : .greatestFiniteMagnitude
            let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
            let measured = text.boundingRect(with: CGSize(width: layoutWidth, height: .greatestFiniteMagnitude), options: options)
            let w: CGFloat = wrap > 0 ? layoutWidth : ceil(measured.width) + 1
            let h: CGFloat = ceil(measured.height)
            // Attachment picks which corner, edge midpoint or center sits on the
            // insertion point; the top of the box is the first line's cap height.
            let x: CGFloat = -CGFloat(column) * w / 2
            let y: CGFloat = CGFloat(row) * h / 2 - h + (font.ascender - cap)
            text.draw(with: CGRect(x: x, y: y, width: w + 2, height: h), options: options)
            return
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let width = (l.text as NSString).size(withAttributes: attributes).width
        var x: CGFloat = 0, baseline: CGFloat = 0
        switch halign {
        case 1, 4: x = -width / 2
        case 2: x = -width
        default: break
        }
        switch halign == 4 ? 2 : valign {
        case 1: baseline = -font.descender
        case 2: baseline = -cap / 2
        case 3: baseline = -cap
        default: break
        }
        // NSString draws from the bottom of the line box; shift so the baseline lands on y.
        (l.text as NSString).draw(at: CGPoint(x: x, y: baseline + font.descender), withAttributes: attributes)
    }
}
