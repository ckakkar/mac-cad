import AppKit
import CCadCore

/// Screen-space drawing over the Metal canvas. Geometry comes from the current
/// scene snapshot; nothing here edits the document.
extension DrawingCanvas {
    private var accent: NSColor { .controlAccentColor }
    private var snapColor: NSColor { settings.background == .dark ? NSColor(srgbRed: 0.35, green: 0.95, blue: 0.45, alpha: 1) : NSColor(srgbRed: 0.05, green: 0.55, blue: 0.15, alpha: 1) }
    private func s(_ p: CADPoint) -> CGPoint { camera.screen(p, size: bounds.size) }

    // MARK: Text layer

    func drawLabels() {
        let size = bounds.size
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let reach = max(size.width, size.height) * 2
        for label in scene.labels {
            let at = camera.screen(label.at, size: size), height = label.height * camera.scale
            // Wrapped paragraphs can extend far from their insertion point.
            let extent = max(reach, CGFloat(label.wrap ?? 0) * camera.scale)
            guard height >= 2.5, height < 4000, at.x > -extent, at.x < size.width + extent, at.y > -extent, at.y < size.height + extent else { continue }
            let c = settings.displayColor(SIMD4<Float>(label.color[0], label.color[1], label.color[2], 1))
            CADText.draw(label, in: context, map: { self.camera.screen($0, size: size) }, scale: camera.scale, color: NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1))
        }
    }

    // MARK: Interaction layer

    func drawInteraction() {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let session = model.session
        drawHover(context)
        drawGhosts(context, session)
        if !gripPreview.isEmpty && session.stage == .grip { strokeWorld(gripPreview, in: context, color: accent, width: 1.5, dash: [6, 4]) }
        drawRubberBand(context, session)
        if !session.active || session.stage == .grip { drawGrips(context, session) }
        drawSelectionWindow(context)
        if wantsPoint && snapKind != "none" { drawSnap(context) }
        if settings.showUCSIcon { drawUCSIcon(context) }
        drawCursor(context, session)
    }

    private func segments(of ids: some Sequence<UInt64>, limit: Int = 30_000) -> [CadSegment] {
        var out: [CadSegment] = []
        for id in ids { if let r = entityRanges[id] { out.append(contentsOf: scene.segments[r]); if out.count > limit { break } } }
        return out
    }
    private func stroke(_ segments: [CadSegment], in context: CGContext, transform: (CADPoint) -> CADPoint = { $0 }, color: NSColor, width: CGFloat, dash: [CGFloat] = []) {
        guard !segments.isEmpty else { return }
        context.saveGState(); context.setStrokeColor(color.cgColor); context.setLineWidth(width); context.setLineDash(phase: 0, lengths: dash); context.setLineCap(.round)
        for seg in segments {
            context.move(to: s(transform(CADPoint(x: seg.ax, y: seg.ay)))); context.addLine(to: s(transform(CADPoint(x: seg.bx, y: seg.by))))
        }
        context.strokePath(); context.restoreGState()
    }
    private func strokeWorld(_ flat: [Double], in context: CGContext, color: NSColor, width: CGFloat, dash: [CGFloat] = []) {
        context.saveGState(); context.setStrokeColor(color.cgColor); context.setLineWidth(width); context.setLineDash(phase: 0, lengths: dash)
        var i = 0
        while i + 3 < flat.count { context.move(to: s(CADPoint(x: flat[i], y: flat[i + 1]))); context.addLine(to: s(CADPoint(x: flat[i + 2], y: flat[i + 3]))); i += 4 }
        context.strokePath(); context.restoreGState()
    }

    /// Selection preview: the object under the pickbox is drawn thicker.
    private func drawHover(_ context: CGContext) {
        guard let id = hoverID, pointer != nil, settings.selectionPreview else { return }
        stroke(segments(of: [id]), in: context, color: accent.withAlphaComponent(0.55), width: 3)
    }
    /// Dragged copies of the selection while MOVE/COPY/ROTATE/MIRROR await their second point.
    private func drawGhosts(_ context: CGContext, _ session: CommandSession) {
        guard session.stage == .points || session.stage == .angle, let base = session.points.first, !model.selection.isEmpty else { return }
        let c = cursor
        let transform: ((CADPoint) -> CADPoint)?
        switch session.tool {
        case .move where session.points.count == 1, .copy where session.points.count == 1:
            let d = c - base; transform = { $0 + d }
        case .rotate where session.stage == .angle:
            let a = atan2(c.y - base.y, c.x - base.x), cs = cos(a), sn = sin(a)
            transform = { p in let v = p - base; return base + CADPoint(x: v.x * cs - v.y * sn, y: v.x * sn + v.y * cs) }
        case .mirror where session.points.count == 1 && c.distance(base) > 1e-9:
            let u = (c - base) * (1 / c.distance(base))
            transform = { p in let v = p - base; let k = v.x * u.x + v.y * u.y; return base + u * (2 * k) - v }
        default: transform = nil
        }
        guard let transform else { return }
        stroke(segments(of: model.selection), in: context, transform: transform, color: accent.withAlphaComponent(0.8), width: 1, dash: [5, 3])
    }

    private func drawRubberBand(_ context: CGContext, _ session: CommandSession) {
        guard session.active, !session.points.isEmpty, pointer != nil || session.stage != .points else { return }
        let points = session.points, a = s(points[0]), b = s(cursor)
        let path = CGMutablePath()
        var measure: (CADPoint, CADPoint)?
        switch session.tool {
        case .rectangle, .hatch:
            path.addRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        case .select where session.name == "ZOOM":
            path.addRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        case .circle:
            if session.circlePoints == 2 {
                let c = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), r = hypot(b.x - a.x, b.y - a.y) / 2
                path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            } else if session.circlePoints == 3 {
                if points.count == 2, let circle = Self.circle(through: a, s(points[1]), b) { path.addEllipse(in: circle) } else { path.move(to: a); path.addLine(to: b) }
            } else {
                let r = hypot(b.x - a.x, b.y - a.y); path.addEllipse(in: CGRect(x: a.x - r, y: a.y - r, width: 2 * r, height: 2 * r)); path.move(to: a); path.addLine(to: b)
                measure = (points[0], cursor)
            }
        case .arc:
            if session.centerMode && points.count == 2 {
                let r = hypot(s(points[1]).x - a.x, s(points[1]).y - a.y), start = atan2(s(points[1]).y - a.y, s(points[1]).x - a.x), end = atan2(b.y - a.y, b.x - a.x)
                path.addArc(center: a, radius: r, startAngle: start, endAngle: end, clockwise: false)
            } else if !session.centerMode && points.count == 2 {
                let m = s(points[1])
                if let circle = Self.circle(through: a, m, b) {
                    let c = CGPoint(x: circle.midX, y: circle.midY), r = circle.width / 2
                    let sa = atan2(a.y - c.y, a.x - c.x), ma = atan2(m.y - c.y, m.x - c.x), ea = atan2(b.y - c.y, b.x - c.x)
                    let ccw = Self.angle(ma, between: sa, and: ea)
                    path.addArc(center: c, radius: r, startAngle: sa, endAngle: ea, clockwise: !ccw)
                } else { path.move(to: a); path.addLine(to: b) }
            } else { path.move(to: a); path.addLine(to: b) }
        case .ellipse:
            if points.count == 2 {
                let center = session.centerMode ? points[0] : (points[0] + points[1]) * 0.5
                let axis = points[1] - center, major = axis.distance(.zero)
                if major > 1e-12 {
                    let u = axis * (1 / major), d = cursor - center, minor = abs(u.x * d.y - u.y * d.x)
                    let c = s(center), rx = major * camera.scale, ry = minor * camera.scale
                    let t = CGAffineTransform(translationX: c.x, y: c.y).rotated(by: atan2(u.y, u.x))
                    path.addEllipse(in: CGRect(x: -rx, y: -ry, width: 2 * rx, height: 2 * ry), transform: t)
                }
            } else { path.move(to: a); path.addLine(to: b) }
        case .polygon where session.stage == .points:
            let n = max(3, session.defaults.sides), r = hypot(b.x - a.x, b.y - a.y), start = atan2(b.y - a.y, b.x - a.x)
            let radius = session.circumscribed ? r / cos(.pi / CGFloat(n)) : r, offset = session.circumscribed ? CGFloat.pi / CGFloat(n) : 0
            for i in 0..<n {
                let angle = start + offset + CGFloat(i) * 2 * .pi / CGFloat(n), q = CGPoint(x: a.x + radius * cos(angle), y: a.y + radius * sin(angle))
                if i == 0 { path.move(to: q) } else { path.addLine(to: q) }
            }
            path.closeSubpath()
        case .dimension, .alignedDimension:
            if points.count == 2 {
                let p0 = points[0], p1 = points[1], d = p1 - p0
                let aligned = session.tool == .alignedDimension
                let u = aligned ? d * (1 / max(d.distance(.zero), 1e-12)) : CADPoint(x: p1.x >= p0.x ? 1 : -1, y: 0)
                let n = CADPoint(x: -u.y, y: u.x), offset = (cursor - p0).x * n.x + (cursor - p0).y * n.y
                let aa = p0 + n * offset, bb = aligned ? p1 + n * offset : CADPoint(x: p1.x, y: aa.y)
                path.move(to: a); path.addLine(to: s(aa)); path.addLine(to: s(bb)); path.addLine(to: s(p1))
            } else { path.move(to: a); path.addLine(to: b); measure = (points[0], cursor) }
        case .move, .copy, .rotate, .scale, .mirror, .measure, .breakLine, .block, .insert, .arrayPolar, .select:
            path.move(to: s(points.last!)); path.addLine(to: b); measure = (points.last!, cursor)
            if session.tool == .mirror { dashedAxis(context, from: points[0], to: cursor) }
        default:
            path.move(to: a); for p in points.dropFirst() { path.addLine(to: s(p)) }
            if session.stage == .points { path.addLine(to: b); measure = (points.last!, cursor) }
        }
        context.saveGState()
        context.setStrokeColor(accent.cgColor); context.setLineWidth(1.25); context.setLineDash(phase: 0, lengths: [6, 4])
        context.addPath(path); context.strokePath(); context.restoreGState()
        if let (p, q) = measure, model.dynamicInput, session.stage == .points || session.stage == .radius || session.stage == .grip, p.distance(q) * camera.scale > 24 {
            drawMeasureTooltip(from: p, to: q)
        }
    }
    private func dashedAxis(_ context: CGContext, from a: CADPoint, to b: CADPoint) {
        guard a.distance(b) > 1e-12 else { return }
        let u = (b - a) * (1 / a.distance(b)), far = Double(max(bounds.width, bounds.height)) * 2 / camera.scale
        context.saveGState(); context.setStrokeColor(accent.withAlphaComponent(0.5).cgColor); context.setLineDash(phase: 0, lengths: [12, 4, 2, 4])
        context.move(to: s(a - u * far)); context.addLine(to: s(a + u * far)); context.strokePath(); context.restoreGState()
    }
    /// AutoCAD-style dimensional input readout: distance and angle along the rubber band.
    private func drawMeasureTooltip(from p: CADPoint, to q: CADPoint) {
        let angle = (atan2(q.y - p.y, q.x - p.x) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
        let text = "\(model.format(p.distance(q)))  ∠ \(String(format: "%.0f", angle))°"
        let a = s(p), b = s(q), mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        let length = max(hypot(b.x - a.x, b.y - a.y), 1), n = CGPoint(x: -(b.y - a.y) / length, y: (b.x - a.x) / length)
        tooltip(text, at: CGPoint(x: mid.x + n.x * 16, y: mid.y + n.y * 16), centered: true)
    }

    private func drawGrips(_ context: CGContext, _ session: CommandSession) {
        let size = settings.gripSize
        let hover = pointer.flatMap { grip(at: $0) }
        for g in model.grips {
            let p = s(g.point)
            guard p.x > -size, p.y > -size, p.x < bounds.width + size, p.y < bounds.height + size else { continue }
            let hot = session.hotGrip.map { $0.id == g.id && $0.index == g.index } ?? false
            let color: NSColor = hot ? NSColor(srgbRed: 0.93, green: 0.18, blue: 0.18, alpha: 1) : g == hover ? NSColor(srgbRed: 0.98, green: 0.45, blue: 0.62, alpha: 1) : NSColor(srgbRed: 0.18, green: 0.45, blue: 0.95, alpha: 1)
            let rect = CGRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size).integral
            context.setFillColor(color.cgColor); context.fill(rect)
            context.setStrokeColor(NSColor.black.withAlphaComponent(0.55).cgColor); context.setLineWidth(1); context.stroke(rect.insetBy(dx: 0.5, dy: 0.5))
        }
    }
    private func drawSelectionWindow(_ context: CGContext) {
        guard let start = selectionStart, let end = selectionEnd else { return }
        let a = s(start), b = s(end)
        let rect = CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
        // Window selection is blue and solid; crossing selection is green and dashed.
        let crossing = end.x < start.x
        let color: NSColor = crossing ? .systemGreen : .systemBlue
        context.saveGState()
        context.setFillColor(color.withAlphaComponent(0.14).cgColor); context.fill(rect)
        context.setStrokeColor(color.cgColor); context.setLineWidth(1)
        if crossing { context.setLineDash(phase: 0, lengths: [5, 3]) }
        context.stroke(rect); context.restoreGState()
    }

    /// AutoSnap markers use AutoCAD's familiar shapes for each object snap mode.
    private func drawSnap(_ context: CGContext) {
        guard settings.snapMarker || settings.snapTooltip else { return }
        let c = s(cursor), r: CGFloat = 6
        if settings.snapMarker {
            let path = CGMutablePath()
            switch snapKind {
            case "endpoint": path.addRect(CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            case "midpoint": path.addLines(between: [CGPoint(x: c.x - r, y: c.y - r * 0.8), CGPoint(x: c.x + r, y: c.y - r * 0.8), CGPoint(x: c.x, y: c.y + r)]); path.closeSubpath()
            case "center": path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            case "node":
                path.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
                path.move(to: CGPoint(x: c.x - r * 0.7, y: c.y - r * 0.7)); path.addLine(to: CGPoint(x: c.x + r * 0.7, y: c.y + r * 0.7))
                path.move(to: CGPoint(x: c.x - r * 0.7, y: c.y + r * 0.7)); path.addLine(to: CGPoint(x: c.x + r * 0.7, y: c.y - r * 0.7))
            case "quadrant": path.addLines(between: [CGPoint(x: c.x, y: c.y - r), CGPoint(x: c.x + r, y: c.y), CGPoint(x: c.x, y: c.y + r), CGPoint(x: c.x - r, y: c.y)]); path.closeSubpath()
            case "intersection":
                path.move(to: CGPoint(x: c.x - r, y: c.y - r)); path.addLine(to: CGPoint(x: c.x + r, y: c.y + r))
                path.move(to: CGPoint(x: c.x - r, y: c.y + r)); path.addLine(to: CGPoint(x: c.x + r, y: c.y - r))
            case "insertion":
                path.addLines(between: [CGPoint(x: c.x - r, y: c.y + r), CGPoint(x: c.x - r, y: c.y - r * 0.2), CGPoint(x: c.x - r * 0.2, y: c.y - r * 0.2), CGPoint(x: c.x - r * 0.2, y: c.y - r), CGPoint(x: c.x + r, y: c.y - r), CGPoint(x: c.x + r, y: c.y + r)]); path.closeSubpath()
            case "perpendicular":
                path.move(to: CGPoint(x: c.x - r, y: c.y + r)); path.addLine(to: CGPoint(x: c.x - r, y: c.y - r)); path.addLine(to: CGPoint(x: c.x + r, y: c.y - r))
                path.move(to: CGPoint(x: c.x - r, y: c.y)); path.addLine(to: c); path.addLine(to: CGPoint(x: c.x, y: c.y - r))
            case "tangent":
                path.addEllipse(in: CGRect(x: c.x - r * 0.8, y: c.y - r * 0.8, width: 1.6 * r, height: 1.6 * r))
                path.move(to: CGPoint(x: c.x - r, y: c.y + r * 0.8)); path.addLine(to: CGPoint(x: c.x + r, y: c.y + r * 0.8))
            case "nearest":
                path.addLines(between: [CGPoint(x: c.x - r, y: c.y + r), CGPoint(x: c.x + r, y: c.y + r), CGPoint(x: c.x - r, y: c.y - r), CGPoint(x: c.x + r, y: c.y - r)]); path.closeSubpath()
            default: path.addRect(CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
            }
            context.saveGState(); context.setStrokeColor(snapColor.cgColor); context.setLineWidth(2); context.addPath(path); context.strokePath(); context.restoreGState()
        }
        // Above-right of the marker, clear of the dynamic input prompt below-right.
        if settings.snapTooltip { tooltip(snapKind.capitalized, at: CGPoint(x: c.x + 12, y: c.y + 12), centered: false) }
    }

    private func drawCursor(_ context: CGContext, _ session: CommandSession) {
        guard let pointer, !isPanning, model.tool != .pan, window?.isKeyWindow != false else { return }
        // In grid snap mode the crosshair jumps between snap increments.
        let p = model.gridSnap || (wantsPoint && (model.ortho || model.polar) && !session.points.isEmpty) ? s(cursor) : pointer
        let color = settings.crosshairColor.withAlphaComponent(0.9)
        context.saveGState(); context.setStrokeColor(color.cgColor); context.setLineWidth(1)
        let x = p.x.rounded() + 0.5, y = p.y.rounded() + 0.5
        let pick = settings.pickboxSize
        if session.stage != .selection {
            let arm = max(settings.crosshairSize / 100 * max(bounds.width, bounds.height), pick + 4)
            let gap = model.selecting ? pick : 0
            context.move(to: CGPoint(x: x - arm, y: y)); context.addLine(to: CGPoint(x: x - gap, y: y))
            context.move(to: CGPoint(x: x + gap, y: y)); context.addLine(to: CGPoint(x: x + arm, y: y))
            context.move(to: CGPoint(x: x, y: y - arm)); context.addLine(to: CGPoint(x: x, y: y - gap))
            context.move(to: CGPoint(x: x, y: y + gap)); context.addLine(to: CGPoint(x: x, y: y + arm))
            context.strokePath()
        }
        if model.selecting { context.stroke(CGRect(x: x - pick, y: y - pick, width: 2 * pick, height: 2 * pick)) }
        context.restoreGState()
    }

    /// The 2D UCS icon marks the X and Y directions of the world coordinate system.
    private func drawUCSIcon(_ context: CGContext) {
        let o = CGPoint(x: 22.5, y: 22.5), l: CGFloat = 34
        let color = settings.crosshairColor.withAlphaComponent(0.7)
        context.saveGState(); context.setStrokeColor(color.cgColor); context.setFillColor(color.cgColor); context.setLineWidth(1.5)
        context.move(to: CGPoint(x: o.x, y: o.y + l)); context.addLine(to: o); context.addLine(to: CGPoint(x: o.x + l, y: o.y)); context.strokePath()
        for (tip, dir) in [(CGPoint(x: o.x + l, y: o.y), CGPoint(x: 1, y: 0)), (CGPoint(x: o.x, y: o.y + l), CGPoint(x: 0, y: 1))] {
            context.move(to: tip); context.addLine(to: CGPoint(x: tip.x - dir.x * 7 - dir.y * 3.5, y: tip.y - dir.y * 7 - dir.x * 3.5))
            context.addLine(to: CGPoint(x: tip.x - dir.x * 7 + dir.y * 3.5, y: tip.y - dir.y * 7 + dir.x * 3.5)); context.closePath(); context.fillPath()
        }
        context.stroke(CGRect(x: o.x - 4, y: o.y - 4, width: 8, height: 8))
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: color]
        ("X" as NSString).draw(at: CGPoint(x: o.x + l + 3, y: o.y - 6), withAttributes: attributes)
        ("Y" as NSString).draw(at: CGPoint(x: o.x - 3, y: o.y + l + 3), withAttributes: attributes)
        context.restoreGState()
    }

    private func tooltip(_ text: String, at point: CGPoint, centered: Bool) {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor.labelColor]
        let size = (text as NSString).size(withAttributes: attributes)
        var rect = CGRect(x: point.x - (centered ? size.width / 2 + 5 : 0), y: point.y - (centered ? size.height / 2 + 2 : 0), width: size.width + 10, height: size.height + 4)
        rect.origin.x = min(max(rect.minX, 4), bounds.width - rect.width - 4); rect.origin.y = min(max(rect.minY, 4), bounds.height - rect.height - 4)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4)
        NSColor.windowBackgroundColor.withAlphaComponent(0.92).setFill(); shape.fill()
        NSColor.separatorColor.setStroke(); shape.lineWidth = 0.5; shape.stroke()
        (text as NSString).draw(at: CGPoint(x: rect.minX + 5, y: rect.minY + 2), withAttributes: attributes)
    }

    static func circle(through a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGRect? {
        let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
        guard abs(d) > 1e-9 else { return nil }
        let a2 = a.x * a.x + a.y * a.y, b2 = b.x * b.x + b.y * b.y, c2 = c.x * c.x + c.y * c.y
        let center = CGPoint(x: (a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d, y: (a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d)
        let r = hypot(a.x - center.x, a.y - center.y)
        guard r < 1e6 else { return nil }
        return CGRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)
    }
    /// Whether `m` lies on the counterclockwise sweep from `start` to `end`.
    static func angle(_ m: CGFloat, between start: CGFloat, and end: CGFloat) -> Bool {
        let tau = 2 * CGFloat.pi
        let sweep = (end - start).truncatingRemainder(dividingBy: tau) + (end < start ? tau : 0)
        let offset = (m - start).truncatingRemainder(dividingBy: tau) + (m < start ? tau : 0)
        return offset <= sweep
    }
}
