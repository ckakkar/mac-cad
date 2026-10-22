import AppKit

/// Original vector tool icons drawn on a 20×20 grid. They are template images,
/// so toolbars, menus and the palette tint them for light, dark and selection.
enum CADIcon {
    private static var cache: [String: NSImage] = [:]

    static func image(for tool: Tool, size: CGFloat = 18) -> NSImage {
        let key = "\(tool.rawValue)@\(size)"
        if let image = cache[key] { return image }
        let image: NSImage
        if let symbol = symbol(for: tool), let base = NSImage(systemSymbolName: symbol, accessibilityDescription: tool.title) {
            image = base.withSymbolConfiguration(.init(pointSize: size * 0.8, weight: .regular)) ?? base
        } else {
            image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
                guard let context = NSGraphicsContext.current?.cgContext else { return false }
                context.scaleBy(x: rect.width / 20, y: rect.height / 20)
                NSColor.black.set()
                draw(tool, Pen())
                return true
            }
            image.accessibilityDescription = tool.title
        }
        image.isTemplate = true
        cache[key] = image
        return image
    }

    /// SF Symbols already read well for these generic actions.
    private static func symbol(for tool: Tool) -> String? {
        switch tool {
        case .select: return "cursorarrow"
        case .pan: return "hand.raised"
        case .move: return "arrow.up.and.down.and.arrow.left.and.right"
        case .copy: return "plus.square.on.square"
        case .rotate: return "rotate.right"
        case .erase: return "eraser"
        case .measure: return "ruler"
        case .text: return "textformat"
        case .arrayRect: return "square.grid.3x3"
        case .insert: return "plus.rectangle.on.rectangle"
        default: return nil
        }
    }

    /// Small drawing helper; coordinates are on the 20×20 icon grid.
    private struct Pen {
        func path(_ points: [CGPoint], closed: Bool = false, dashed: Bool = false, width: CGFloat = 1.4) {
            guard let first = points.first else { return }
            let p = NSBezierPath(); p.move(to: first)
            for q in points.dropFirst() { p.line(to: q) }
            if closed { p.close() }
            stroke(p, dashed: dashed, width: width)
        }
        func line(_ a: CGPoint, _ b: CGPoint, dashed: Bool = false, width: CGFloat = 1.4) { path([a, b], dashed: dashed, width: width) }
        func stroke(_ p: NSBezierPath, dashed: Bool = false, width: CGFloat = 1.4) {
            p.lineWidth = width; p.lineCapStyle = .round; p.lineJoinStyle = .round
            if dashed { p.setLineDash([1.8, 1.8], count: 2, phase: 0) }
            p.stroke()
        }
        func circle(_ c: CGPoint, _ r: CGFloat, dashed: Bool = false) {
            stroke(NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)), dashed: dashed)
        }
        func arc(_ c: CGPoint, _ r: CGFloat, _ start: CGFloat, _ end: CGFloat, clockwise: Bool = false, dashed: Bool = false) {
            let p = NSBezierPath(); p.appendArc(withCenter: c, radius: r, startAngle: start, endAngle: end, clockwise: clockwise)
            stroke(p, dashed: dashed)
        }
        /// Grip-like vertex marker.
        func grip(_ c: CGPoint, _ size: CGFloat = 2.6) { NSBezierPath(rect: CGRect(x: c.x - size / 2, y: c.y - size / 2, width: size, height: size)).fill() }
        func dot(_ c: CGPoint, _ r: CGFloat = 1.1) { NSBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)).fill() }
        func arrow(_ tip: CGPoint, from: CGPoint, size: CGFloat = 3) {
            let dx = tip.x - from.x, dy = tip.y - from.y, l = max(hypot(dx, dy), 0.001)
            let u = CGPoint(x: dx / l, y: dy / l), n = CGPoint(x: -u.y, y: u.x)
            let base = CGPoint(x: tip.x - u.x * size, y: tip.y - u.y * size)
            let p = NSBezierPath(); p.move(to: tip)
            p.line(to: CGPoint(x: base.x + n.x * size * 0.45, y: base.y + n.y * size * 0.45))
            p.line(to: CGPoint(x: base.x - n.x * size * 0.45, y: base.y - n.y * size * 0.45)); p.close(); p.fill()
        }
    }
    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    /// Status bar drafting aid icons.
    static func image(for aid: DraftingAid, size: CGFloat = 16) -> NSImage {
        let key = "aid.\(aid.rawValue)@\(size)"
        if let image = cache[key] { return image }
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.scaleBy(x: rect.width / 20, y: rect.height / 20)
            NSColor.black.set()
            let pen = Pen()
            switch aid {
            case .grid:
                for k in stride(from: CGFloat(3), through: 17, by: 4.67) { pen.line(p(k, 3), p(k, 17), width: 1); pen.line(p(3, k), p(17, k), width: 1) }
            case .snap:
                for x in stride(from: CGFloat(4), through: 16, by: 6) { for y in stride(from: CGFloat(4), through: 16, by: 6) { pen.dot(p(x, y), 1.3) } }
                pen.path([p(10, 10), p(14, 6)], width: 1.2); pen.arrow(p(16, 4), from: p(10, 10), size: 3)
            case .ortho:
                pen.path([p(4, 17), p(4, 4), p(17, 4)], width: 1.5); pen.arrow(p(4, 18), from: p(4, 10)); pen.arrow(p(18, 4), from: p(10, 4))
                pen.path([p(4, 8), p(8, 8), p(8, 4)], width: 1)
            case .polar:
                pen.line(p(3, 4), p(18, 4), width: 1.3); pen.line(p(3, 4), p(14, 15), width: 1.3); pen.line(p(3, 4), p(3, 18), dashed: true, width: 1.3)
                pen.arc(p(3, 4), 7, 0, 45)
            case .osnap:
                pen.path([p(5, 5), p(15, 5), p(15, 15), p(5, 15)], closed: true, width: 1.5)
                pen.line(p(10, 1), p(10, 7), width: 1); pen.line(p(10, 13), p(10, 19), width: 1); pen.line(p(1, 10), p(7, 10), width: 1); pen.line(p(13, 10), p(19, 10), width: 1)
            case .dynamicInput:
                pen.path([p(2, 6), p(14, 6), p(14, 13), p(2, 13)], closed: true, width: 1.2); pen.line(p(5, 8), p(5, 11), width: 1.2)
                pen.path([p(13, 11), p(13, 19), p(15.5, 16.5), p(18, 18.5)], width: 1.1)
            case .lineweight:
                pen.line(p(3, 15), p(17, 15), width: 0.8); pen.line(p(3, 10), p(17, 10), width: 1.8); pen.line(p(3, 4.5), p(17, 4.5), width: 3)
            }
            return true
        }
        image.isTemplate = true; image.accessibilityDescription = aid.help
        cache[key] = image
        return image
    }

    private static func draw(_ tool: Tool, _ pen: Pen) {
        switch tool {
        case .line:
            pen.line(p(4, 4), p(16, 16)); pen.grip(p(4, 4)); pen.grip(p(16, 16))
        case .polyline:
            pen.path([p(3, 5), p(7, 15), p(12, 7), p(17, 15)]); [p(3, 5), p(7, 15), p(12, 7), p(17, 15)].forEach { pen.grip($0) }
        case .rectangle:
            pen.path([p(3, 5), p(17, 5), p(17, 15), p(3, 15)], closed: true); pen.grip(p(3, 5)); pen.grip(p(17, 15))
        case .polygon:
            let points = (0..<6).map { i -> CGPoint in let a = CGFloat(i) * .pi / 3; return p(10 + 7 * cos(a), 10 + 7 * sin(a)) }
            pen.path(points, closed: true); pen.dot(p(10, 10))
        case .circle:
            pen.circle(p(10, 10), 7); pen.dot(p(10, 10))
        case .arc:
            pen.arc(p(10, 6), 7, 0, 180); pen.grip(p(3, 6)); pen.grip(p(17, 6)); pen.grip(p(10, 13))
        case .ellipse:
            pen.stroke(NSBezierPath(ovalIn: CGRect(x: 2, y: 5, width: 16, height: 10))); pen.dot(p(10, 10))
        case .spline:
            let s = NSBezierPath(); s.move(to: p(3, 5)); s.curve(to: p(17, 15), controlPoint1: p(7, 20), controlPoint2: p(13, 0)); pen.stroke(s)
            pen.path([p(3, 5), p(7, 20), p(13, 0), p(17, 15)], dashed: true, width: 0.8); pen.grip(p(3, 5)); pen.grip(p(17, 15))
        case .point:
            pen.circle(p(10, 10), 3.2); pen.line(p(10, 4), p(10, 16), width: 1.1); pen.line(p(4, 10), p(16, 10), width: 1.1)
        case .hatch:
            pen.path([p(3, 3), p(17, 3), p(17, 17), p(3, 17)], closed: true)
            for k in stride(from: CGFloat(-8), through: 8, by: 4) { pen.line(p(max(3, 3 + k), max(3, 3 - k)), p(min(17, 17 + k), min(17, 17 - k)), width: 0.9) }
        case .dimension:
            pen.line(p(3, 4), p(3, 15), width: 1); pen.line(p(17, 4), p(17, 15), width: 1); pen.line(p(5, 12), p(15, 12), width: 1.2)
            pen.arrow(p(3.4, 12), from: p(10, 12)); pen.arrow(p(16.6, 12), from: p(10, 12)); pen.line(p(7, 4), p(13, 4), width: 1)
        case .alignedDimension:
            pen.line(p(3, 3), p(6.5, 6.5), width: 1); pen.line(p(13.5, 13.5), p(17, 17), width: 1)
            pen.line(p(3, 9), p(11, 17), width: 1.2); pen.arrow(p(3.3, 9.3), from: p(7, 13)); pen.arrow(p(10.7, 16.7), from: p(7, 13))
            pen.grip(p(5.5, 5.5), 2); pen.grip(p(14.5, 14.5), 2)
        case .radius:
            pen.arc(p(8, 8), 9, -10, 100); pen.line(p(8, 8), p(14, 14), width: 1.2); pen.arrow(p(14.4, 14.4), from: p(8, 8)); pen.dot(p(8, 8))
        case .diameter:
            pen.circle(p(10, 10), 7.5); pen.line(p(5, 5), p(15, 15), width: 1.2); pen.arrow(p(4.8, 4.8), from: p(10, 10)); pen.arrow(p(15.2, 15.2), from: p(10, 10))
        case .leader:
            pen.path([p(3, 4), p(11, 13), p(17, 13)], width: 1.2); pen.arrow(p(3, 4), from: p(7, 8.5), size: 3.4)
            pen.line(p(12, 16.5), p(17, 16.5), width: 1); pen.line(p(12, 10), p(16, 10), width: 1)
        case .scale:
            pen.path([p(3, 3), p(17, 3), p(17, 17), p(3, 17)], closed: true, dashed: true, width: 1)
            pen.path([p(3, 3), p(10, 3), p(10, 10), p(3, 10)], closed: true); pen.line(p(10, 10), p(15, 15)); pen.arrow(p(15.5, 15.5), from: p(10, 10))
        case .mirror:
            pen.line(p(10, 2), p(10, 18), dashed: true, width: 1)
            pen.path([p(8, 4), p(8, 15), p(2, 4)], closed: true); pen.path([p(12, 4), p(12, 15), p(18, 4)], closed: true, dashed: true)
        case .offset:
            pen.path([p(3, 13), p(8, 17), p(17, 17)]); pen.path([p(3, 8), p(9, 12.5), p(17, 12.5)], dashed: true)
            pen.line(p(13, 16), p(13, 8.6), width: 1); pen.arrow(p(13, 7.8), from: p(13, 13), size: 2.6)
        case .trim:
            pen.line(p(11, 2), p(11, 18), width: 1.8); pen.line(p(3, 10), p(11, 10)); pen.line(p(11, 10), p(17, 10), dashed: true)
            pen.line(p(13.5, 7.5), p(16.5, 12.5), width: 1.1); pen.line(p(13.5, 12.5), p(16.5, 7.5), width: 1.1)
        case .extend:
            pen.line(p(17, 2), p(17, 18), width: 1.8); pen.line(p(3, 10), p(9, 10)); pen.line(p(9, 10), p(15, 10), dashed: true)
            pen.arrow(p(16.2, 10), from: p(10, 10), size: 3)
        case .fillet:
            let s = NSBezierPath(); s.move(to: p(4, 17)); s.line(to: p(4, 10)); s.appendArc(withCenter: p(10, 10), radius: 6, startAngle: 180, endAngle: 270); s.line(to: p(17, 4)); pen.stroke(s)
            pen.path([p(4, 10), p(4, 4), p(10, 4)], dashed: true, width: 0.9)
        case .chamfer:
            pen.path([p(4, 17), p(4, 9), p(9, 4), p(17, 4)]); pen.path([p(4, 9), p(4, 4), p(9, 4)], dashed: true, width: 0.9)
            pen.grip(p(4, 9), 2.2); pen.grip(p(9, 4), 2.2)
        case .join:
            pen.line(p(3, 5), p(10, 12)); pen.line(p(10, 12), p(17, 5)); pen.grip(p(10, 12), 3); pen.grip(p(3, 5), 2); pen.grip(p(17, 5), 2)
        case .breakLine:
            pen.line(p(3, 10), p(8, 10)); pen.line(p(12, 10), p(17, 10)); pen.grip(p(8, 10), 2.2); pen.grip(p(12, 10), 2.2)
            pen.path([p(9, 14), p(11, 6)], width: 1)
        case .arrayPolar:
            pen.circle(p(10, 10), 6, dashed: true); for i in 0..<6 { let a = CGFloat(i) * .pi / 3; pen.dot(p(10 + 6 * cos(a), 10 + 6 * sin(a)), 1.7) }
        case .explode:
            pen.path([p(3, 11), p(3, 17), p(9, 17)]); pen.path([p(11, 17), p(17, 17), p(17, 11)])
            pen.path([p(17, 9), p(17, 3), p(11, 3)]); pen.path([p(9, 3), p(3, 3), p(3, 9)]); pen.dot(p(10, 10), 1.3)
        case .block:
            pen.path([p(3, 4), p(14, 4), p(14, 13), p(3, 13)], closed: true); pen.circle(p(8.5, 8.5), 2.4)
            pen.path([p(6, 16), p(17, 16), p(17, 7)], width: 1); pen.grip(p(3, 4), 2.6)
        default:
            pen.circle(p(10, 10), 6)
        }
    }
}
