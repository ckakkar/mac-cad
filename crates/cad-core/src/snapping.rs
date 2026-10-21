use crate::{
    commands::Engine,
    curves::{angle_on_arc, ellipse_point, polyline_edges, spline_point},
    geometry::{intersection, nearest_on_segment, Bounds, Point, Transform, EPS},
    model::{Document, Shape},
};
use serde_json::{json, Value};
use std::f64::consts::{FRAC_PI_2, TAU};

#[derive(Clone, Copy)]
enum Curve {
    Line(Point, Point),
    Arc(Point, f64, f64, f64),
}
impl Curve {
    fn contains(self, p: Point) -> bool {
        match self {
            Self::Line(a, b) => nearest_on_segment(p, a, b).distance(p) < 1e-6,
            Self::Arc(c, r, start, sweep) => {
                (p.distance(c) - r).abs() < r * 1e-8 + EPS
                    && angle_on_arc((p.y - c.y).atan2(p.x - c.x), start, sweep)
            }
        }
    }
}
impl Engine {
    pub fn precise_snap(&self, p: Point, tolerance: f64, base: Option<Point>) -> Value {
        let b = Bounds {
            min: p - Point::new(tolerance, tolerance),
            max: p + Point::new(tolerance, tolerance),
        };
        let mut points = Vec::new();
        let mut curves = Vec::new();
        for id in self.ids_in(b) {
            let e = &self.doc.entities[&id];
            if !self.doc.layer(&e.layer).is_some_and(|l| l.visible) {
                continue;
            }
            collect(
                &self.doc,
                &e.shape,
                Transform::IDENTITY,
                &mut points,
                &mut curves,
                0,
            );
        }
        curves.truncate(256);
        for &curve in &curves {
            match curve {
                Curve::Line(a, b) => {
                    points.extend([
                        (a, "endpoint", 0),
                        (b, "endpoint", 0),
                        ((a + b) * 0.5, "midpoint", 2),
                    ]);
                    points.push((nearest_on_segment(p, a, b), "nearest", 9));
                    if let Some(base) = base {
                        let q = nearest_on_segment(base, a, b);
                        if (base - q).dot(b - a).abs() < 1e-6 * (b - a).length().max(1.0) {
                            points.push((q, "perpendicular", 3));
                        }
                    }
                }
                Curve::Arc(c, r, start, sweep) => {
                    if sweep.abs() < TAU - EPS {
                        for a in [start, start + sweep] {
                            points.push((c + Point::new(a.cos(), a.sin()) * r, "endpoint", 0));
                        }
                    }
                    points.push((c, "center", 2));
                    for i in 0..4 {
                        let a = i as f64 * FRAC_PI_2;
                        if angle_on_arc(a, start, sweep) {
                            points.push((c + Point::new(a.cos(), a.sin()) * r, "quadrant", 3));
                        }
                    }
                    let a = (p.y - c.y).atan2(p.x - c.x);
                    if angle_on_arc(a, start, sweep) {
                        points.push((c + Point::new(a.cos(), a.sin()) * r, "nearest", 9));
                    }
                    if let Some(base) = base {
                        let d = base.distance(c);
                        let theta = (base.y - c.y).atan2(base.x - c.x);
                        for a in [theta, theta + std::f64::consts::PI] {
                            if angle_on_arc(a, start, sweep) {
                                points.push((
                                    c + Point::new(a.cos(), a.sin()) * r,
                                    "perpendicular",
                                    3,
                                ));
                            }
                        }
                        if d > r + EPS {
                            let angle = (r / d).acos();
                            for a in [theta - angle, theta + angle] {
                                if angle_on_arc(a, start, sweep) {
                                    points.push((
                                        c + Point::new(a.cos(), a.sin()) * r,
                                        "tangent",
                                        3,
                                    ));
                                }
                            }
                        }
                    }
                }
            }
        }
        for i in 0..curves.len() {
            for j in i + 1..curves.len() {
                for q in crossings(curves[i], curves[j]) {
                    if curves[i].contains(q) && curves[j].contains(q) {
                        points.push((q, "intersection", 1));
                    }
                }
            }
        }
        if let Some((point, kind, _)) = points
            .into_iter()
            .filter(|(q, _, _)| q.finite() && q.distance(p) <= tolerance)
            .min_by(|a, b| {
                a.2.cmp(&b.2)
                    .then(a.0.distance(p).total_cmp(&b.0.distance(p)))
            })
        {
            json!({"point":point,"kind":kind})
        } else {
            json!({"point":p,"kind":"none"})
        }
    }
}
type Candidate = (Point, &'static str, u8);
fn collect(
    doc: &Document,
    s: &Shape,
    t: Transform,
    points: &mut Vec<Candidate>,
    curves: &mut Vec<Curve>,
    depth: usize,
) {
    if depth > 16 || curves.len() > 1024 || points.len() > 4096 {
        return;
    }
    match s {
        Shape::Point { at } => points.push((t.apply(*at), "node", 0)),
        Shape::Line { a, b } => curves.push(Curve::Line(t.apply(*a), t.apply(*b))),
        Shape::Circle { center, radius } => {
            curves.push(Curve::Arc(t.apply(*center), radius * t.scale(), 0.0, TAU))
        }
        Shape::Arc { .. } => {
            if let Shape::Arc {
                center,
                radius,
                start,
                sweep,
            } = s.transformed(t)
            {
                curves.push(Curve::Arc(center, radius, start, sweep));
            }
        }
        Shape::Polyline { vertices, closed } => {
            for s in polyline_edges(vertices, *closed) {
                collect(doc, &s, t, points, curves, depth + 1);
            }
        }
        Shape::Ellipse {
            center,
            major,
            ratio,
            start,
            sweep,
        } => {
            points.push((t.apply(*center), "center", 2));
            for theta in [
                *start,
                start + sweep,
                0.0,
                FRAC_PI_2,
                2.0 * FRAC_PI_2,
                3.0 * FRAC_PI_2,
            ] {
                if angle_on_arc(theta, *start, *sweep) {
                    points.push((
                        t.apply(ellipse_point(*center, *major, *ratio, theta)),
                        "quadrant",
                        3,
                    ));
                }
            }
        }
        Shape::Spline {
            degree,
            control_points,
            knots,
            weights,
            ..
        } => {
            for u in [knots[*degree], knots[control_points.len()]] {
                points.push((
                    t.apply(spline_point(*degree, control_points, knots, weights, u)),
                    "endpoint",
                    0,
                ));
            }
        }
        Shape::Text { at, .. } => points.push((t.apply(*at), "insertion", 0)),
        Shape::Dimension { a, b, .. } => {
            points.push((t.apply(*a), "endpoint", 0));
            points.push((t.apply(*b), "endpoint", 0));
        }
        Shape::RadialDimension {
            center, edge, at, ..
        } => {
            for p in [center, edge, at] {
                points.push((t.apply(*p), "endpoint", 0));
            }
        }
        Shape::Leader {
            points: vertices, ..
        }
        | Shape::Hatch {
            boundary: vertices, ..
        } => {
            for p in vertices {
                points.push((t.apply(*p), "endpoint", 0));
            }
        }
        Shape::Insert {
            block,
            at,
            scale,
            rotation,
        } => {
            let t = t.compose(Transform::translation(*at).compose(Transform::rotation(
                Point::default(),
                *rotation,
                *scale,
            )));
            points.push((t.apply(Point::default()), "insertion", 0));
            if let Some(shapes) = doc.blocks.get(block) {
                for s in shapes {
                    collect(doc, s, t, points, curves, depth + 1);
                }
            }
        }
    }
}
fn crossings(a: Curve, b: Curve) -> Vec<Point> {
    match (a, b) {
        (Curve::Line(a, b), Curve::Line(c, d)) => intersection(a, b, c, d).into_iter().collect(),
        (Curve::Line(a, b), Curve::Arc(c, r, ..)) | (Curve::Arc(c, r, ..), Curve::Line(a, b)) => {
            let u = b - a;
            let v = a - c;
            let aa = u.dot(u);
            if aa < EPS * EPS {
                return vec![];
            }
            let bb = 2.0 * u.dot(v);
            let cc = v.dot(v) - r * r;
            let discr = bb * bb - 4.0 * aa * cc;
            if discr < -EPS {
                return vec![];
            }
            let root = discr.max(0.0).sqrt();
            [(-bb - root) / (2.0 * aa), (-bb + root) / (2.0 * aa)]
                .into_iter()
                .map(|s| a + u * s)
                .collect()
        }
        (Curve::Arc(a, r, ..), Curve::Arc(b, s, ..)) => {
            let d = a.distance(b);
            if d < EPS || d > r + s + EPS || d < (r - s).abs() - EPS {
                return vec![];
            }
            let x = (r * r - s * s + d * d) / (2.0 * d);
            let h = (r * r - x * x).max(0.0).sqrt();
            let u = (b - a) * (1.0 / d);
            let c = a + u * x;
            let n = Point::new(-u.y, u.x) * h;
            vec![c + n, c - n]
        }
    }
}
