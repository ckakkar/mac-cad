use crate::geometry::{bulge_arc, Bounds, Point, Transform};
use crate::model::{Document, Entity, Shape};
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
}
#[derive(Clone, Debug, Serialize)]
pub struct Label {
    pub at: Point,
    pub text: String,
    pub height: f64,
    pub rotation: f64,
    pub color: [f32; 4],
    pub entity: u64,
}
#[derive(Default)]
pub struct Batch {
    pub segments: Vec<Segment>,
    pub triangles: Vec<Triangle>,
    pub labels: Vec<Label>,
}
impl Batch {
    fn line(&mut self, a: Point, b: Point, color: [f32; 4], entity: u64) {
        self.segments.push(Segment {
            ax: a.x,
            ay: a.y,
            bx: b.x,
            by: b.y,
            color,
            entity,
        });
    }
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
        for l in &self.labels {
            let w = l.height * l.text.chars().count() as f64 * 0.65;
            let t = Transform::translation(l.at).compose(Transform::rotation(
                Point::default(),
                l.rotation,
                1.0,
            ));
            add(&[
                t.apply(Point::new(0.0, 0.0)),
                t.apply(Point::new(w, 0.0)),
                t.apply(Point::new(w, l.height)),
                t.apply(Point::new(0.0, l.height)),
            ]);
        }
        bounds
    }
}

pub fn entity_batch(doc: &Document, e: &Entity, tolerance: f64) -> Batch {
    let mut b = Batch::default();
    let color = doc
        .layer(&e.layer)
        .map_or([0.8, 0.85, 0.9, 1.0], |l| l.color);
    append_shape(
        &mut b,
        doc,
        &e.shape,
        Transform::IDENTITY,
        color,
        e.id,
        tolerance,
        0,
    );
    b
}
#[allow(clippy::too_many_arguments)]
fn append_shape(
    out: &mut Batch,
    doc: &Document,
    shape: &Shape,
    t: Transform,
    color: [f32; 4],
    id: u64,
    tolerance: f64,
    depth: u32,
) {
    if depth > 16 {
        return;
    }
    let mut line = |a: Point, b: Point| out.line(t.apply(a), t.apply(b), color, id);
    match shape {
        Shape::Line { a, b } => line(*a, *b),
        Shape::Circle { center, radius } => {
            append_arc(out, *center, *radius, 0.0, TAU, t, color, id, tolerance)
        }
        Shape::Arc {
            center,
            radius,
            start,
            sweep,
        } => append_arc(
            out, *center, *radius, *start, *sweep, t, color, id, tolerance,
        ),
        Shape::Polyline { vertices, closed } => {
            let count = if *closed {
                vertices.len()
            } else {
                vertices.len().saturating_sub(1)
            };
            for i in 0..count {
                let a = &vertices[i];
                let b = &vertices[(i + 1) % vertices.len()];
                if let Some((c, r, s, w)) = bulge_arc(a.point, b.point, a.bulge) {
                    append_arc(out, c, r, s, w, t, color, id, tolerance);
                } else {
                    out.line(t.apply(a.point), t.apply(b.point), color, id);
                }
            }
        }
        Shape::Text {
            at,
            text,
            height,
            rotation,
        } => out.labels.push(Label {
            at: t.apply(*at),
            text: text.clone(),
            height: height * t.scale(),
            rotation: rotation + t.angle(),
            color,
            entity: id,
        }),
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
            line(*a, aa);
            line(*b, bb);
            line(aa, bb);
            let size = doc_unit_text_height(doc);
            for p in [aa, bb] {
                line(p + (u + n) * (-size * 0.3), p + (u + n) * (size * 0.3));
            }
            out.labels.push(Label {
                at: t.apply((aa + bb) * 0.5 + n * (size * 0.2)),
                text: format!("{:.2}", if *aligned { d.length() } else { d.x.abs() }),
                height: size * t.scale(),
                rotation: u.y.atan2(u.x) + t.angle(),
                color,
                entity: id,
            });
        }
        Shape::Hatch {
            boundary,
            pattern,
            spacing,
        } => {
            for i in 0..boundary.len() {
                line(boundary[i], boundary[(i + 1) % boundary.len()]);
            }
            if pattern == "solid" {
                for i in 1..boundary.len() - 1 {
                    let a = t.apply(boundary[0]);
                    let b = t.apply(boundary[i]);
                    let c = t.apply(boundary[i + 1]);
                    let mut fill = color;
                    fill[3] = 0.20;
                    out.triangles.push(Triangle {
                        ax: a.x,
                        ay: a.y,
                        bx: b.x,
                        by: b.y,
                        cx: c.x,
                        cy: c.y,
                        color: fill,
                    });
                }
            } else if let Some(b) = Bounds::from_points(boundary) {
                let lo = b.min.y - b.max.x;
                let hi = b.max.y - b.min.x;
                // Limit pathological hatch density without affecting editable data.
                let step = spacing.max((hi - lo) / 10_000.0);
                let mut k = (lo / step).floor() * step;
                while k <= hi {
                    let mut hits = Vec::new();
                    for i in 0..boundary.len() {
                        let a = boundary[i];
                        let z = boundary[(i + 1) % boundary.len()];
                        let fa = a.y - a.x - k;
                        let fz = z.y - z.x - k;
                        if (fa <= 0.0 && fz > 0.0) || (fz <= 0.0 && fa > 0.0) {
                            hits.push(a + (z - a) * (fa / (fa - fz)));
                        }
                    }
                    hits.sort_by(|a, b| a.x.total_cmp(&b.x));
                    for pair in hits.as_chunks::<2>().0 {
                        out.line(t.apply(pair[0]), t.apply(pair[1]), color, id);
                    }
                    k += step;
                }
            }
        }
        Shape::Insert {
            block,
            at,
            scale,
            rotation,
        } => {
            if let Some(shapes) = doc.blocks.get(block) {
                let local = Transform::translation(*at).compose(Transform::rotation(
                    Point::default(),
                    *rotation,
                    *scale,
                ));
                for s in shapes {
                    append_shape(
                        out,
                        doc,
                        s,
                        t.compose(local),
                        color,
                        id,
                        tolerance,
                        depth + 1,
                    );
                }
            }
        }
    }
}
#[allow(clippy::too_many_arguments)]
fn append_arc(
    out: &mut Batch,
    c: Point,
    r: f64,
    start: f64,
    sweep: f64,
    t: Transform,
    color: [f32; 4],
    id: u64,
    tol: f64,
) {
    let radius = (r * t.scale()).max(1e-12);
    let step = (2.0 * (1.0 - (tol / radius).clamp(1e-9, 1.0)).acos()).clamp(0.001, 0.2);
    let count = (sweep.abs() / step).ceil().clamp(2.0, 8192.0) as usize;
    let point = |theta: f64| t.apply(c + Point::new(theta.cos(), theta.sin()) * r);
    let mut a = point(start);
    for i in 1..=count {
        let b = point(start + sweep * i as f64 / count as f64);
        out.line(a, b, color, id);
        a = b;
    }
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
    if depth > 16 {
        return None;
    }
    let points: Vec<Point> = match s {
        Shape::Line { a, b } => vec![*a, *b],
        Shape::Circle { center, radius } | Shape::Arc { center, radius, .. } => vec![
            *center - Point::new(*radius, *radius),
            *center + Point::new(*radius, *radius),
            *center + Point::new(-radius, *radius),
            *center + Point::new(*radius, -radius),
        ],
        Shape::Polyline { vertices, closed } => {
            let mut p: Vec<_> = vertices.iter().map(|v| v.point).collect();
            let n = if *closed {
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
                    p.extend([
                        c - Point::new(r, r),
                        c + Point::new(r, r),
                        c + Point::new(-r, r),
                        c + Point::new(r, -r),
                    ]);
                }
            }
            p
        }
        Shape::Hatch { boundary, .. } => boundary.clone(),
        Shape::Insert {
            block,
            at,
            scale,
            rotation,
        } => {
            let local = t.compose(Transform::translation(*at).compose(Transform::rotation(
                Point::default(),
                *rotation,
                *scale,
            )));
            return doc
                .blocks
                .get(block)?
                .iter()
                .filter_map(|s| shape_bounds(doc, s, local, depth + 1))
                .reduce(|a, b| a.union(b));
        }
        _ => {
            let e = Entity {
                id: 0,
                layer: "0".into(),
                shape: s.clone(),
            };
            let b = entity_batch(doc, &e, 1.0).bounds()?;
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
