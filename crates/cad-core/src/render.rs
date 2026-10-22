//! Display tessellation. Geometry stays in the document; batches are disposable
//! view data built for a tolerance in drawing units.
use crate::geometry::{bulge_arc, Bounds, Point, Transform, EPS};
use crate::model::{
    Document, Entity, EntityStyle, Layer, PatternLine, Shape, TextFormat, Vertex, BY_BLOCK_COLOR,
    BY_BLOCK_LINE_TYPE, BY_BLOCK_LINE_WEIGHT,
};
use serde::Serialize;
use std::f64::consts::TAU;

#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Segment {
    pub ax: f64,
    pub ay: f64,
    pub bx: f64,
    pub by: f64,
    pub color: [f32; 4],
    pub entity: u64,
    pub line_weight: f32,
}
#[repr(C)]
#[derive(Clone, Copy, Debug)]
pub struct Triangle {
    pub ax: f64,
    pub ay: f64,
    pub bx: f64,
    pub by: f64,
    pub cx: f64,
    pub cy: f64,
    pub color: [f32; 4],
    pub entity: u64,
}
fn is_one(v: &f64) -> bool {
    *v == 1.0
}
fn is_zero(v: &f64) -> bool {
    *v == 0.0
}
fn is_zero_u8(v: &u8) -> bool {
    *v == 0
}
/// Text drawn by the native layer, which measures glyphs for justification.
#[derive(Clone, Debug, Serialize)]
pub struct Label {
    pub at: Point,
    pub text: String,
    pub height: f64,
    pub rotation: f64,
    pub color: [f32; 4],
    pub entity: u64,
    #[serde(skip_serializing_if = "is_one")]
    pub width_factor: f64,
    #[serde(skip_serializing_if = "is_zero")]
    pub oblique: f64,
    #[serde(skip_serializing_if = "is_zero_u8")]
    pub halign: u8,
    #[serde(skip_serializing_if = "is_zero_u8")]
    pub valign: u8,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub align: Option<Point>,
    #[serde(skip_serializing_if = "is_zero_u8")]
    pub attachment: u8,
    #[serde(skip_serializing_if = "is_zero")]
    pub wrap: f64,
    #[serde(skip_serializing_if = "is_one")]
    pub line_spacing: f64,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub font: String,
}
#[derive(Default)]
pub struct Batch {
    pub segments: Vec<Segment>,
    pub triangles: Vec<Triangle>,
    pub labels: Vec<Label>,
}
impl Batch {
    pub fn bounds(&self) -> Option<Bounds> {
        let mut bounds: Option<Bounds> = None;
        let mut add = |points: &[Point]| {
            if let Some(b) = Bounds::from_points(points) {
                bounds = Some(bounds.map_or(b, |a| a.union(b)));
            }
        };
        for s in &self.segments {
            add(&[Point::new(s.ax, s.ay), Point::new(s.bx, s.by)]);
        }
        for t in &self.triangles {
            add(&[
                Point::new(t.ax, t.ay),
                Point::new(t.bx, t.by),
                Point::new(t.cx, t.cy),
            ]);
        }
        for l in &self.labels {
            add(&label_corners(l));
        }
        bounds
    }
}
/// Approximate extents of a label, for picking and drawing extents.
fn label_corners(l: &Label) -> [Point; 4] {
    let lines = l.text.lines().count().max(1) as f64;
    let longest = l.text.lines().map(|s| s.chars().count()).max().unwrap_or(0) as f64;
    let mut w = l.height * longest * 0.62 * l.width_factor;
    if l.wrap > 0.0 {
        w = w.min(l.wrap.max(l.height));
    }
    let h = l.height * lines * 1.45 * l.line_spacing;
    // Anchor offsets mirror the native layout closely enough for culling.
    let (ox, oy) = if l.attachment > 0 {
        let col = ((l.attachment - 1) % 3) as f64;
        let row = ((l.attachment - 1) / 3) as f64;
        (-w * col * 0.5, -h + h * row * 0.5)
    } else {
        let ox = match l.halign {
            1 | 4 => -w * 0.5,
            2 => -w,
            _ => 0.0,
        };
        (ox, if l.valign == 3 { -l.height } else { 0.0 })
    };
    let base = if l.attachment == 0 && (l.halign != 0 || l.valign != 0) {
        l.align.unwrap_or(l.at)
    } else {
        l.at
    };
    let t = Transform::translation(base).compose(Transform::rotation(
        Point::default(),
        l.rotation,
        1.0,
    ));
    [
        t.apply(Point::new(ox, oy)),
        t.apply(Point::new(ox + w, oy)),
        t.apply(Point::new(ox + w, oy + h)),
        t.apply(Point::new(ox, oy + h)),
    ]
}

/// Resolved drawing properties for one primitive.
#[derive(Clone)]
struct Pen {
    color: [f32; 4],
    weight: f32,
    /// Dash pattern in drawing units; empty draws continuous.
    dashes: Vec<f64>,
}

const MAX_SEGMENTS_PER_ENTITY: usize = 400_000;

struct Painter<'a> {
    doc: &'a Document,
    out: &'a mut Batch,
    id: u64,
    tolerance: f64,
    styled: bool,
}

pub fn entity_batch(doc: &Document, e: &Entity, tolerance: f64) -> Batch {
    paint_entity(doc, e, tolerance, true)
}
/// Continuous, unstyled geometry for picking, snapping and explode.
pub fn entity_geometry(doc: &Document, e: &Entity, tolerance: f64) -> Batch {
    paint_entity(doc, e, tolerance, false)
}
fn paint_entity(doc: &Document, e: &Entity, tolerance: f64, styled: bool) -> Batch {
    let mut out = Batch::default();
    let layer = doc.layer(&e.layer);
    let pen = resolve_pen(doc, &e.style, layer, None, styled);
    Painter {
        doc,
        out: &mut out,
        id: e.id,
        tolerance: tolerance.max(1e-12),
        styled,
    }
    .shape(&e.shape, Transform::IDENTITY, &pen, 0);
    out
}

fn default_color() -> [f32; 4] {
    [0.8, 0.85, 0.9, 1.0]
}
/// AutoCAD property inheritance: explicit values win; ByBlock takes the parent
/// insert's value; ByLayer uses the object's layer, except that objects on layer
/// "0" inside a block take the insert's properties.
fn resolve_pen(
    doc: &Document,
    style: &EntityStyle,
    layer: Option<&Layer>,
    parent: Option<&Pen>,
    styled: bool,
) -> Pen {
    let inherit = |flag: u8| {
        parent.is_some() && (style.by_block & flag != 0 || layer.is_none_or(|l| l.name == "0"))
    };
    let color = match style.color {
        Some(c) if style.by_block & BY_BLOCK_COLOR == 0 => c,
        _ if inherit(BY_BLOCK_COLOR) => parent.unwrap().color,
        _ => layer.map_or_else(default_color, |l| l.color),
    };
    let weight = match style.line_weight {
        Some(w) if style.by_block & BY_BLOCK_LINE_WEIGHT == 0 => w,
        _ if inherit(BY_BLOCK_LINE_WEIGHT) => parent.unwrap().weight,
        _ => layer.map_or(0.25, |l| l.line_weight),
    };
    if !styled {
        return Pen {
            color,
            weight,
            dashes: Vec::new(),
        };
    }
    let dashes = match &style.line_type {
        Some(n)
            if style.by_block & BY_BLOCK_LINE_TYPE == 0 && !n.eq_ignore_ascii_case("ByLayer") =>
        {
            if n.eq_ignore_ascii_case("ByBlock") {
                parent.map(|p| p.dashes.clone()).unwrap_or_default()
            } else {
                dash_pattern(doc, n, style.line_type_scale.unwrap_or(1.0))
            }
        }
        _ if inherit(BY_BLOCK_LINE_TYPE) => parent.unwrap().dashes.clone(),
        _ => layer.map_or_else(Vec::new, |l| {
            dash_pattern(doc, &l.line_type, style.line_type_scale.unwrap_or(1.0))
        }),
    };
    Pen {
        color,
        weight,
        dashes,
    }
}
/// The drawing's own linetype definition, or a built-in for common names.
fn dash_pattern(doc: &Document, name: &str, object_scale: f64) -> Vec<f64> {
    if name.eq_ignore_ascii_case("Continuous") {
        return Vec::new();
    }
    let scale = doc.header.ltscale * object_scale;
    if let Some(def) = doc
        .linetypes
        .iter()
        .find(|(k, _)| k.eq_ignore_ascii_case(name))
        .map(|(_, v)| v)
    {
        return def.pattern.iter().map(|v| v * scale).collect();
    }
    let unit = doc_unit_text_height(doc) / 150.0 * scale;
    let pattern: &[f64] = match name.to_ascii_lowercase().as_str() {
        "center" => &[400.0, -80.0, 60.0, -80.0],
        "dotted" | "dot" => &[0.0, -80.0],
        "hidden" => &[120.0, -60.0],
        "dashed" => &[240.0, -100.0],
        _ => &[],
    };
    pattern.iter().map(|v| v * unit).collect()
}

impl Painter<'_> {
    fn segment(&mut self, a: Point, b: Point, pen: &Pen) {
        self.out.segments.push(Segment {
            ax: a.x,
            ay: a.y,
            bx: b.x,
            by: b.y,
            color: pen.color,
            entity: self.id,
            line_weight: pen.weight,
        });
    }
    fn triangle(&mut self, a: Point, b: Point, c: Point, color: [f32; 4]) {
        self.out.triangles.push(Triangle {
            ax: a.x,
            ay: a.y,
            bx: b.x,
            by: b.y,
            cx: c.x,
            cy: c.y,
            color,
            entity: self.id,
        });
    }
    /// Strokes a polyline in drawing coordinates, applying the pen's dashes
    /// continuously along it. Patterns finer than the display draw solid.
    fn stroke(&mut self, points: &[Point], pen: &Pen) {
        if points.len() < 2 || self.out.segments.len() > MAX_SEGMENTS_PER_ENTITY {
            return;
        }
        let period: f64 = pen.dashes.iter().map(|d| d.abs()).sum();
        if pen.dashes.is_empty() || period < self.tolerance * 6.0 {
            for w in points.windows(2) {
                self.segment(w[0], w[1], pen);
            }
            return;
        }
        let mut index = 0;
        let mut remain = pen.dashes[0].abs();
        for w in points.windows(2) {
            let (a, b) = (w[0], w[1]);
            let length = a.distance(b);
            if length < 1e-12 {
                continue;
            }
            let u = (b - a) * (1.0 / length);
            let mut pos = 0.0;
            while pos < length {
                let end = (pos + remain).min(length);
                let dash = pen.dashes[index];
                if dash > 0.0 {
                    self.segment(a + u * pos, a + u * end, pen);
                } else if dash == 0.0 && remain >= pen.dashes[index].abs() {
                    // Dots are drawn as a very short dash across the line.
                    let d = u * (self.tolerance * 1.5);
                    let p = a + u * pos;
                    self.segment(p - d, p + d, pen);
                }
                remain -= end - pos;
                pos = end;
                if remain < 1e-10 {
                    index = (index + 1) % pen.dashes.len();
                    remain = pen.dashes[index].abs();
                    if remain == 0.0 && pen.dashes.len() == 1 {
                        remain = self.tolerance;
                    }
                }
                if self.out.segments.len() > MAX_SEGMENTS_PER_ENTITY {
                    return;
                }
            }
        }
    }
    fn arc_points(&self, c: Point, r: f64, start: f64, sweep: f64, t: Transform) -> Vec<Point> {
        let radius = (r * t
            .scale()
            .max(t.linear().apply(Point::new(0.0, 1.0)).length()))
        .max(1e-12);
        let step =
            (2.0 * (1.0 - (self.tolerance / radius).clamp(1e-9, 1.0)).acos()).clamp(0.001, 0.25);
        let count = (sweep.abs() / step).ceil().clamp(2.0, 8192.0) as usize;
        (0..=count)
            .map(|i| {
                let a = start + sweep * i as f64 / count as f64;
                t.apply(c + Point::new(a.cos(), a.sin()) * r)
            })
            .collect()
    }
    /// Polyline vertices (with bulges) as display points, in drawing coordinates.
    fn polyline_points(&self, vertices: &[Vertex], closed: bool, t: Transform) -> Vec<Point> {
        let mut out = Vec::with_capacity(vertices.len() + 1);
        if let Some(first) = vertices.first() {
            out.push(t.apply(first.point));
        }
        let n = if closed {
            vertices.len()
        } else {
            vertices.len().saturating_sub(1)
        };
        for i in 0..n {
            let a = &vertices[i];
            let b = &vertices[(i + 1) % vertices.len()];
            if let Some((c, r, s, w)) = bulge_arc(a.point, b.point, a.bulge) {
                out.extend(self.arc_points(c, r, s, w, t).into_iter().skip(1));
            } else {
                out.push(t.apply(b.point));
            }
        }
        out
    }
    fn label(&mut self, l: Label) {
        self.out.labels.push(l);
    }
    #[allow(clippy::too_many_arguments)]
    fn text_label(
        &self,
        at: Point,
        text: &str,
        height: f64,
        rotation: f64,
        format: &TextFormat,
        t: Transform,
        color: [f32; 4],
    ) -> Label {
        let style = self.doc.text_styles.get(&format.style).or_else(|| {
            self.doc
                .text_styles
                .iter()
                .find(|(k, _)| k.eq_ignore_ascii_case(&format.style))
                .map(|(_, v)| v)
        });
        let mirror = t.determinant() < 0.0;
        Label {
            at: t.apply(at),
            text: text.to_string(),
            height: height * t.scale(),
            rotation: if mirror {
                t.angle() - rotation
            } else {
                rotation + t.angle()
            },
            color,
            entity: self.id,
            width_factor: format.width_factor,
            oblique: format.oblique,
            halign: format.halign,
            valign: format.valign,
            align: format.align.map(|p| t.apply(p)),
            attachment: format.attachment,
            wrap: format.wrap * t.scale(),
            line_spacing: format.line_spacing,
            font: style.map(|s| s.font.clone()).unwrap_or_default(),
        }
    }

    fn shape(&mut self, shape: &Shape, t: Transform, pen: &Pen, depth: u32) {
        if depth > 32 || self.out.segments.len() > MAX_SEGMENTS_PER_ENTITY {
            return;
        }
        let tol = self.tolerance;
        match shape {
            Shape::Point { at } => {
                let p = t.apply(*at);
                let mode = self.doc.header.pdmode;
                let size = if self.doc.header.pdsize > 0.0 {
                    self.doc.header.pdsize * t.scale() * 0.5
                } else {
                    tol * 7.0
                };
                match mode & 7 {
                    1 => {}
                    2 => {
                        self.segment(p - Point::new(size, 0.0), p + Point::new(size, 0.0), pen);
                        self.segment(p - Point::new(0.0, size), p + Point::new(0.0, size), pen);
                    }
                    3 => {
                        self.segment(p - Point::new(size, size), p + Point::new(size, size), pen);
                        self.segment(
                            p - Point::new(size, -size),
                            p + Point::new(size, -size),
                            pen,
                        );
                    }
                    4 => self.segment(p, p + Point::new(0.0, size), pen),
                    _ => {
                        let d = tol * 2.0;
                        self.segment(p - Point::new(d, 0.0), p + Point::new(d, 0.0), pen);
                        self.segment(p - Point::new(0.0, d), p + Point::new(0.0, d), pen);
                    }
                }
                if mode & 32 != 0 {
                    let pts = self.arc_points(*at, size / t.scale().max(EPS), 0.0, TAU, t);
                    self.stroke(&pts, pen);
                }
                if mode & 64 != 0 {
                    let pts = [
                        p + Point::new(-size, -size),
                        p + Point::new(size, -size),
                        p + Point::new(size, size),
                        p + Point::new(-size, size),
                        p + Point::new(-size, -size),
                    ];
                    self.stroke(&pts, pen);
                }
            }
            Shape::Ellipse {
                center,
                major,
                ratio,
                start,
                sweep,
            } => {
                let radius = major.length() * t.scale();
                let step = (2.0 * (1.0 - (tol / radius.max(1e-12)).clamp(1e-9, 1.0)).acos())
                    .clamp(0.001, 0.2);
                let count = (sweep.abs() / step).ceil().clamp(8.0, 8192.0) as usize;
                let pts: Vec<_> = (0..=count)
                    .map(|i| {
                        t.apply(crate::curves::ellipse_point(
                            *center,
                            *major,
                            *ratio,
                            start + sweep * i as f64 / count as f64,
                        ))
                    })
                    .collect();
                self.stroke(&pts, pen);
            }
            Shape::Spline {
                degree,
                control_points,
                knots,
                weights,
                closed,
            } => {
                let length: f64 = control_points.windows(2).map(|p| p[0].distance(p[1])).sum();
                let count = ((length * t.scale() / tol).sqrt() * 8.0)
                    .ceil()
                    .clamp(32.0, 8192.0) as usize;
                let lo = knots[*degree];
                let hi = knots[control_points.len()];
                let mut pts: Vec<_> = (0..=count)
                    .map(|i| {
                        t.apply(crate::curves::spline_point(
                            *degree,
                            control_points,
                            knots,
                            weights,
                            lo + (hi - lo) * i as f64 / count as f64,
                        ))
                    })
                    .collect();
                if *closed {
                    pts.push(pts[0]);
                }
                self.stroke(&pts, pen);
            }
            Shape::Line { a, b } => self.stroke(&[t.apply(*a), t.apply(*b)], pen),
            Shape::Circle { center, radius } => {
                let pts = self.arc_points(*center, *radius, 0.0, TAU, t);
                self.stroke(&pts, pen);
            }
            Shape::Arc {
                center,
                radius,
                start,
                sweep,
            } => {
                let pts = self.arc_points(*center, *radius, *start, *sweep, t);
                self.stroke(&pts, pen);
            }
            Shape::Polyline { vertices, closed } => {
                if vertices
                    .iter()
                    .any(|v| v.start_width > 0.0 || v.end_width > 0.0)
                {
                    self.wide_polyline(vertices, *closed, t, pen);
                } else {
                    let pts = self.polyline_points(vertices, *closed, t);
                    self.stroke(&pts, pen);
                }
            }
            Shape::Text {
                at,
                text,
                height,
                rotation,
                format,
            } => {
                let l = self.text_label(*at, text, *height, *rotation, format, t, pen.color);
                self.label(l);
            }
            Shape::RadialDimension {
                center,
                edge,
                at,
                diameter,
            } => {
                let size = doc_unit_text_height(self.doc);
                let direction = (*edge - *center) * (1.0 / center.distance(*edge));
                let normal = Point::new(-direction.y, direction.x);
                for (a, b) in [
                    (*center, *edge),
                    (*edge, *at),
                    (*edge, *edge - direction * size + normal * (size * 0.3)),
                    (*edge, *edge - direction * size - normal * (size * 0.3)),
                ] {
                    self.stroke(&[t.apply(a), t.apply(b)], pen);
                }
                let text = format!(
                    "{}{:.2}",
                    if *diameter { "Ø" } else { "R" },
                    center.distance(*edge) * if *diameter { 2.0 } else { 1.0 }
                );
                let l =
                    self.text_label(*at, &text, size, 0.0, &TextFormat::default(), t, pen.color);
                self.label(l);
            }
            Shape::Leader {
                points,
                text,
                height,
            } => {
                let pts: Vec<_> = points.iter().map(|p| t.apply(*p)).collect();
                self.stroke(&pts, pen);
                let direction =
                    (points[1] - points[0]) * (1.0 / points[0].distance(points[1]).max(1e-12));
                let normal = Point::new(-direction.y, direction.x);
                for side in [1.0, -1.0] {
                    let tip = points[0] + direction * *height + normal * (*height * 0.25 * side);
                    self.stroke(&[t.apply(points[0]), t.apply(tip)], pen);
                }
                if !text.is_empty() {
                    let l = self.text_label(
                        *points.last().unwrap(),
                        text,
                        *height,
                        0.0,
                        &TextFormat::default(),
                        t,
                        pen.color,
                    );
                    self.label(l);
                }
            }
            Shape::Dimension {
                a,
                b,
                offset,
                aligned,
            } => {
                let d = *b - *a;
                let u = if *aligned {
                    d * (1.0 / d.length())
                } else {
                    Point::new(if b.x >= a.x { 1.0 } else { -1.0 }, 0.0)
                };
                let n = Point::new(-u.y, u.x);
                let aa = *a + n * (*offset);
                let bb = if *aligned {
                    *b + n * (*offset)
                } else {
                    Point::new(b.x, aa.y)
                };
                let size = doc_unit_text_height(self.doc);
                for (p, q) in [(*a, aa), (*b, bb), (aa, bb)] {
                    self.stroke(&[t.apply(p), t.apply(q)], pen);
                }
                for p in [aa, bb] {
                    self.stroke(
                        &[
                            t.apply(p + (u + n) * (-size * 0.3)),
                            t.apply(p + (u + n) * (size * 0.3)),
                        ],
                        pen,
                    );
                }
                let text = format!("{:.2}", if *aligned { d.length() } else { d.x.abs() });
                let l = self.text_label(
                    (aa + bb) * 0.5 + n * (size * 0.2),
                    &text,
                    size,
                    u.y.atan2(u.x),
                    &TextFormat::default(),
                    t,
                    pen.color,
                );
                self.label(l);
            }
            Shape::Hatch {
                boundary,
                pattern,
                spacing,
            } => {
                let mut outline: Vec<_> = boundary.iter().map(|p| t.apply(*p)).collect();
                outline.push(outline[0]);
                self.stroke(&outline, pen);
                if pattern == "solid" {
                    let mut fill = pen.color;
                    fill[3] = 0.20;
                    for i in 1..boundary.len() - 1 {
                        self.triangle(
                            t.apply(boundary[0]),
                            t.apply(boundary[i]),
                            t.apply(boundary[i + 1]),
                            fill,
                        );
                    }
                } else {
                    // Limit pathological hatch density without affecting editable data.
                    let loops = vec![boundary
                        .iter()
                        .map(|p| Vertex::new(*p, 0.0))
                        .collect::<Vec<_>>()];
                    let line = PatternLine {
                        angle: std::f64::consts::FRAC_PI_4,
                        origin: Point::default(),
                        offset: Point::new(
                            -spacing / std::f64::consts::SQRT_2,
                            spacing / std::f64::consts::SQRT_2,
                        ),
                        dashes: Vec::new(),
                    };
                    self.pattern(&loops, &[line], t, pen);
                }
            }
            Shape::Region {
                loops,
                solid,
                lines,
                ..
            } => {
                if *solid || lines.is_empty() {
                    self.fill_loops(loops, t, pen.color);
                } else {
                    self.pattern(loops, lines, t, pen);
                }
            }
            Shape::Solid { points } => {
                let p: Vec<_> = points.iter().map(|q| t.apply(*q)).collect();
                self.triangle(p[0], p[1], p[2], pen.color);
                if p.len() == 4 {
                    self.triangle(p[0], p[2], p[3], pen.color);
                }
            }
            Shape::Insert {
                block,
                at,
                scale,
                rotation,
                y_scale,
                attributes,
                ..
            } => {
                let local = t.compose(Shape::insert_transform(*at, *scale, *y_scale, *rotation));
                if let Some(entities) = self.doc.blocks.get(block) {
                    for e in entities {
                        let layer = e.layer.as_deref().and_then(|n| self.doc.layer(n));
                        if layer.is_some_and(|l| l.name != "0" && !l.shown()) {
                            continue;
                        }
                        let child = resolve_pen(self.doc, &e.style, layer, Some(pen), self.styled);
                        self.shape(&e.shape, local, &child, depth + 1);
                    }
                }
                for a in attributes.iter().filter(|a| !a.invisible) {
                    let l = self
                        .text_label(a.at, &a.text, a.height, a.rotation, &a.format, t, pen.color);
                    self.label(l);
                }
            }
            Shape::Image { at, u, v, .. } => {
                let p = [*at, *at + *u, *at + *u + *v, *at + *v, *at];
                let pts: Vec<_> = p.iter().map(|q| t.apply(*q)).collect();
                self.stroke(&pts, pen);
            }
            Shape::XLine { at, direction, ray } => {
                let d = *direction * (1.0 / direction.length());
                let reach = 1e7;
                let a = if *ray { *at } else { *at - d * reach };
                self.stroke(&[t.apply(a), t.apply(*at + d * reach)], pen);
            }
        }
    }

    /// Variable-width polyline segments as filled quads; zero-width spans stroke.
    fn wide_polyline(&mut self, vertices: &[Vertex], closed: bool, t: Transform, pen: &Pen) {
        let n = if closed {
            vertices.len()
        } else {
            vertices.len().saturating_sub(1)
        };
        for i in 0..n {
            let a = &vertices[i];
            let b = &vertices[(i + 1) % vertices.len()];
            let pts = match bulge_arc(a.point, b.point, a.bulge) {
                Some((c, r, s, w)) => self.arc_points(c, r, s, w, Transform::IDENTITY),
                None => vec![a.point, b.point],
            };
            if a.start_width <= 0.0 && a.end_width <= 0.0 {
                let p: Vec<_> = pts.iter().map(|q| t.apply(*q)).collect();
                self.stroke(&p, pen);
                continue;
            }
            let total: f64 = pts
                .windows(2)
                .map(|w| w[0].distance(w[1]))
                .sum::<f64>()
                .max(1e-12);
            let mut run = 0.0;
            for w in pts.windows(2) {
                let (p, q) = (w[0], w[1]);
                let len = p.distance(q);
                if len < 1e-12 {
                    continue;
                }
                let w0 = a.start_width + (a.end_width - a.start_width) * run / total;
                run += len;
                let w1 = a.start_width + (a.end_width - a.start_width) * run / total;
                let n = Point::new(-(q.y - p.y), q.x - p.x) * (1.0 / len);
                let (p0, p1) = (t.apply(p + n * (w0 / 2.0)), t.apply(p - n * (w0 / 2.0)));
                let (q0, q1) = (t.apply(q + n * (w1 / 2.0)), t.apply(q - n * (w1 / 2.0)));
                self.triangle(p0, p1, q1, pen.color);
                self.triangle(p0, q1, q0, pen.color);
            }
        }
    }

    /// Fills boundary loops with the even-odd rule, as hatch fills are drawn.
    fn fill_loops(&mut self, loops: &[Vec<Vertex>], t: Transform, color: [f32; 4]) {
        let polys: Vec<Vec<Point>> = loops
            .iter()
            .map(|l| {
                let mut p = self.polyline_points(l, true, t);
                if p.len() > 1 && p[0].distance(*p.last().unwrap()) < 1e-12 {
                    p.pop();
                }
                p
            })
            .filter(|p| p.len() >= 3)
            .collect();
        // Nesting depth decides outer loops (even) and holes (odd).
        let depth: Vec<usize> = polys
            .iter()
            .enumerate()
            .map(|(i, p)| {
                polys
                    .iter()
                    .enumerate()
                    .filter(|(j, q)| *j != i && point_in_polygon(p[0], q))
                    .count()
            })
            .collect();
        for (i, outer) in polys.iter().enumerate() {
            if depth[i] % 2 == 1 {
                continue;
            }
            let holes: Vec<&Vec<Point>> = polys
                .iter()
                .enumerate()
                .filter(|(j, q)| depth[*j] == depth[i] + 1 && point_in_polygon(q[0], outer))
                .map(|(_, q)| q)
                .collect();
            let mut flat = Vec::with_capacity(
                (outer.len() + holes.iter().map(|h| h.len()).sum::<usize>()) * 2,
            );
            let mut starts = Vec::new();
            let mut all: Vec<Point> = Vec::new();
            for p in outer {
                flat.extend([p.x, p.y]);
                all.push(*p);
            }
            for h in holes {
                starts.push(all.len());
                for p in h {
                    flat.extend([p.x, p.y]);
                    all.push(*p);
                }
            }
            if let Ok(indices) = earcutr::earcut(&flat, &starts, 2) {
                for tri in indices.as_chunks::<3>().0 {
                    self.triangle(all[tri[0]], all[tri[1]], all[tri[2]], color);
                }
            }
        }
    }

    /// Pattern lines clipped to the loops with the even-odd rule. Families too
    /// dense to resolve on screen draw as a light fill instead.
    fn pattern(&mut self, loops: &[Vec<Vertex>], lines: &[PatternLine], t: Transform, pen: &Pen) {
        let polys: Vec<Vec<Point>> = loops
            .iter()
            .map(|l| self.polyline_points(l, true, t))
            .collect();
        let edges: Vec<(Point, Point)> = polys
            .iter()
            .flat_map(|p| {
                let mut e: Vec<_> = p.windows(2).map(|w| (w[0], w[1])).collect();
                if p.len() > 2 && p[0].distance(*p.last().unwrap()) > 1e-12 {
                    e.push((*p.last().unwrap(), p[0]));
                }
                e
            })
            .collect();
        let Some(bounds) = Bounds::from_points(&polys.concat()) else {
            return;
        };
        let linear = t.linear();
        for pl in lines {
            let d0 = linear.apply(Point::new(pl.angle.cos(), pl.angle.sin()));
            let stretch = d0.length().max(1e-12);
            let d = d0 * (1.0 / stretch);
            let n = Point::new(-d.y, d.x);
            let origin = t.apply(pl.origin);
            let offset = linear.apply(pl.offset);
            let spacing = offset.dot(n);
            if spacing.abs() < 1e-12 {
                continue;
            }
            let corners = [
                bounds.min,
                bounds.max,
                Point::new(bounds.min.x, bounds.max.y),
                Point::new(bounds.max.x, bounds.min.y),
            ];
            let (mut lo, mut hi) = (f64::INFINITY, f64::NEG_INFINITY);
            for c in corners {
                let s = (c - origin).dot(n) / spacing;
                lo = lo.min(s);
                hi = hi.max(s);
            }
            if (hi - lo) > 20_000.0 || spacing.abs() < self.tolerance * 2.5 {
                let mut light = pen.color;
                light[3] *= 0.18;
                self.fill_loops(loops, t, light);
                return;
            }
            let dashes: Vec<f64> = pl.dashes.iter().map(|v| v * stretch).collect();
            let line_pen = Pen {
                dashes: Vec::new(),
                ..pen.clone()
            };
            // Each edge's endpoints as signed distances across the family.
            let sides: Vec<(f64, f64)> = edges
                .iter()
                .map(|(p, q)| ((*p - origin).dot(n), (*q - origin).dot(n)))
                .collect();
            for k in (lo.floor() as i64)..=(hi.ceil() as i64) {
                let base = origin + offset * k as f64;
                let shift = spacing * k as f64;
                // An edge crosses when its endpoints lie on opposite sides, with
                // points on the line counted as the positive side. A line that
                // only touches a corner then crosses zero or two edges, never one.
                let mut hits: Vec<f64> = edges
                    .iter()
                    .zip(&sides)
                    .filter_map(|((p, q), (sp, sq))| {
                        let (a, b) = (sp - shift, sq - shift);
                        ((a >= 0.0) != (b >= 0.0)).then(|| {
                            let x = *p + (*q - *p) * (a / (a - b));
                            (x - base).dot(d)
                        })
                    })
                    .collect();
                hits.sort_by(|a, b| a.total_cmp(b));
                for pair in hits.as_chunks::<2>().0 {
                    self.dashed_span(base, d, pair[0], pair[1], &dashes, &line_pen);
                    if self.out.segments.len() > MAX_SEGMENTS_PER_ENTITY {
                        return;
                    }
                }
            }
        }
    }
    /// Draws [t0, t1] of the line base + d·t with a dash list phased from t = 0.
    fn dashed_span(&mut self, base: Point, d: Point, t0: f64, t1: f64, dashes: &[f64], pen: &Pen) {
        let period: f64 = dashes.iter().map(|v| v.abs()).sum();
        if dashes.is_empty() || period < self.tolerance * 3.0 {
            self.segment(base + d * t0, base + d * t1, pen);
            return;
        }
        let mut s = (t0 / period).floor() * period;
        let dot = self.tolerance * 1.2;
        'outer: while s < t1 {
            for &v in dashes {
                let e = s + v.abs();
                if v > 0.0 {
                    let (a, b) = (s.max(t0), e.min(t1));
                    if b > a {
                        self.segment(base + d * a, base + d * b, pen);
                    }
                } else if v == 0.0 && s >= t0 && s <= t1 {
                    self.segment(base + d * (s - dot), base + d * (s + dot), pen);
                }
                s = e;
                if s >= t1 || self.out.segments.len() > MAX_SEGMENTS_PER_ENTITY {
                    break 'outer;
                }
            }
        }
    }
}

fn point_in_polygon(p: Point, poly: &[Point]) -> bool {
    let mut inside = false;
    let n = poly.len();
    for i in 0..n {
        let (a, b) = (poly[i], poly[(i + 1) % n]);
        if (a.y > p.y) != (b.y > p.y) && p.x < a.x + (p.y - a.y) * (b.x - a.x) / (b.y - a.y) {
            inside = !inside;
        }
    }
    inside
}

pub fn doc_unit_text_height(doc: &Document) -> f64 {
    match doc.units.as_str() {
        "m" => 0.15,
        "cm" => 15.0,
        "in" => 6.0,
        "ft" => 0.5,
        _ => 150.0,
    }
}

/// Conservative analytical bounds: never cull a curve because of tessellation error.
pub fn entity_bounds(doc: &Document, e: &Entity) -> Option<Bounds> {
    shape_bounds(doc, &e.shape, Transform::IDENTITY, 0)
}
fn shape_bounds(doc: &Document, s: &Shape, t: Transform, depth: usize) -> Option<Bounds> {
    if depth > 32 {
        return None;
    }
    let circle = |c: Point, r: f64| {
        vec![
            c - Point::new(r, r),
            c + Point::new(r, r),
            c + Point::new(-r, r),
            c + Point::new(r, -r),
        ]
    };
    let polyline = |vertices: &[Vertex], closed: bool| {
        let mut p: Vec<_> = vertices.iter().map(|v| v.point).collect();
        let w = vertices
            .iter()
            .map(|v| v.start_width.max(v.end_width))
            .fold(0.0, f64::max)
            / 2.0;
        let n = if closed {
            vertices.len()
        } else {
            vertices.len().saturating_sub(1)
        };
        for i in 0..n {
            if let Some((c, r, _, _)) = bulge_arc(
                vertices[i].point,
                vertices[(i + 1) % vertices.len()].point,
                vertices[i].bulge,
            ) {
                p.extend(circle(c, r));
            }
        }
        if w > 0.0 {
            p = p.into_iter().flat_map(|q| circle(q, w)).collect();
        }
        p
    };
    let points: Vec<Point> = match s {
        Shape::Point { at } => vec![*at],
        Shape::Ellipse {
            center,
            major,
            ratio,
            ..
        } => {
            let x = (major.x.powi(2) + (major.y * ratio).powi(2)).sqrt();
            let y = (major.y.powi(2) + (major.x * ratio).powi(2)).sqrt();
            vec![
                *center - Point::new(x, y),
                *center + Point::new(x, y),
                *center + Point::new(-x, y),
                *center + Point::new(x, -y),
            ]
        }
        Shape::Spline { control_points, .. } => control_points.clone(),
        Shape::Line { a, b } => vec![*a, *b],
        Shape::Circle { center, radius } | Shape::Arc { center, radius, .. } => {
            circle(*center, *radius)
        }
        Shape::Polyline { vertices, closed } => polyline(vertices, *closed),
        Shape::Hatch { boundary, .. } => boundary.clone(),
        Shape::Region { loops, .. } => loops.iter().flat_map(|l| polyline(l, true)).collect(),
        Shape::Solid { points } => points.clone(),
        Shape::Image { at, u, v, .. } => vec![*at, *at + *u, *at + *v, *at + *u + *v],
        Shape::XLine { at, direction, ray } => {
            let d = *direction * (1e7 / direction.length());
            vec![if *ray { *at } else { *at - d }, *at + d]
        }
        Shape::Insert {
            block,
            at,
            scale,
            rotation,
            y_scale,
            attributes,
            ..
        } => {
            let local = t.compose(Shape::insert_transform(*at, *scale, *y_scale, *rotation));
            let mut b = doc.blocks.get(block).and_then(|entities| {
                entities
                    .iter()
                    .filter_map(|e| shape_bounds(doc, &e.shape, local, depth + 1))
                    .reduce(|a, b| a.union(b))
            });
            for a in attributes.iter().filter(|a| !a.invisible) {
                let at = t.apply(a.at);
                let r = a.height * t.scale() * (a.text.chars().count() as f64 + 1.0);
                let ab = Bounds {
                    min: at - Point::new(r, r),
                    max: at + Point::new(r, r),
                };
                b = Some(b.map_or(ab, |x| x.union(ab)));
            }
            return b;
        }
        _ => {
            let e = Entity {
                id: 0,
                layer: "0".into(),
                style: Default::default(),
                shape: s.clone(),
            };
            let b = entity_geometry(doc, &e, 1.0).bounds()?;
            vec![
                b.min,
                b.max,
                Point::new(b.min.x, b.max.y),
                Point::new(b.max.x, b.min.y),
            ]
        }
    };
    Bounds::from_points(&points.into_iter().map(|p| t.apply(p)).collect::<Vec<_>>())
}
