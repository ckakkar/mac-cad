use crate::{
    geometry::{bulge_arc, Point, EPS},
    model::{Shape, Vertex},
};
use std::f64::consts::TAU;

pub fn ellipse_point(center: Point, major: Point, ratio: f64, theta: f64) -> Point {
    center + major * theta.cos() + Point::new(-major.y, major.x) * (ratio * theta.sin())
}
pub fn spline_point(
    degree: usize,
    points: &[Point],
    knots: &[f64],
    weights: &[f64],
    u: f64,
) -> Point {
    let n = points.len() - 1;
    let span = if u >= knots[n + 1] {
        n
    } else {
        (degree..=n)
            .find(|&i| u >= knots[i] && u < knots[i + 1])
            .unwrap_or(degree)
    };
    let mut d: Vec<_> = (0..=degree)
        .map(|j| {
            let i = span - degree + j;
            [
                points[i].x * weights[i],
                points[i].y * weights[i],
                weights[i],
            ]
        })
        .collect();
    for r in 1..=degree {
        for j in (r..=degree).rev() {
            let i = span - degree + j;
            let denom = knots[i + degree - r + 1] - knots[i];
            let a = if denom.abs() < f64::EPSILON {
                0.0
            } else {
                (u - knots[i]) / denom
            };
            let before = d[j - 1];
            for (value, previous) in d[j].iter_mut().zip(before) {
                *value = (1.0 - a) * previous + a * (*value);
            }
        }
    }
    Point::new(d[degree][0] / d[degree][2], d[degree][1] / d[degree][2])
}
pub fn clamped_knots(count: usize, degree: usize) -> Vec<f64> {
    (0..count + degree + 1)
        .map(|i| {
            if i <= degree {
                0.0
            } else if i >= count {
                1.0
            } else {
                (i - degree) as f64 / (count - degree) as f64
            }
        })
        .collect()
}
pub fn angle_on_arc(angle: f64, start: f64, sweep: f64) -> bool {
    if sweep >= 0.0 {
        (angle - start).rem_euclid(TAU) <= sweep + EPS
    } else {
        (start - angle).rem_euclid(TAU) <= -sweep + EPS
    }
}
pub fn arc_through(a: Point, b: Point, c: Point) -> Result<Shape, String> {
    let u = b - a;
    let v = c - a;
    let den = 2.0 * u.cross(v);
    if den.abs() < EPS * u.length().max(1.0) * v.length().max(1.0) {
        return Err("Arc points must not be collinear".into());
    }
    let center = a + Point::new(
        v.y * u.dot(u) - u.y * v.dot(v),
        u.x * v.dot(v) - v.x * u.dot(u),
    ) * (1.0 / den);
    let start = (a.y - center.y).atan2(a.x - center.x);
    let middle = (b.y - center.y).atan2(b.x - center.x);
    let end = (c.y - center.y).atan2(c.x - center.x);
    let positive = (end - start).rem_euclid(TAU);
    let sweep = if angle_on_arc(middle, start, positive) {
        positive
    } else {
        positive - TAU
    };
    Ok(Shape::Arc {
        center,
        radius: center.distance(a),
        start,
        sweep,
    })
}
pub fn polyline_edges(vertices: &[Vertex], closed: bool) -> Vec<Shape> {
    let n = if closed {
        vertices.len()
    } else {
        vertices.len().saturating_sub(1)
    };
    (0..n)
        .map(|i| {
            let a = &vertices[i];
            let b = &vertices[(i + 1) % vertices.len()];
            if let Some((center, radius, start, sweep)) = bulge_arc(a.point, b.point, a.bulge) {
                Shape::Arc {
                    center,
                    radius,
                    start,
                    sweep,
                }
            } else {
                Shape::Line {
                    a: a.point,
                    b: b.point,
                }
            }
        })
        .collect()
}
pub fn offset_polyline(vertices: &[Vertex], closed: bool, distance: f64) -> Result<Shape, String> {
    if vertices.iter().any(|v| v.bulge.abs() > EPS) {
        return Err(
            "Polyline offset supports straight segments; explode curved edges first".into(),
        );
    }
    let n = vertices.len();
    let mut edges = Vec::new();
    for s in polyline_edges(vertices, closed) {
        if let Shape::Line { a, b } = s {
            let d = b - a;
            if d.length() < EPS {
                return Err("Polyline has coincident vertices".into());
            }
            let v = Point::new(-d.y, d.x) * (distance / d.length());
            edges.push((a + v, b + v));
        }
    }
    let mut output = Vec::new();
    for i in 0..n {
        let point = if !closed && i == 0 {
            edges[0].0
        } else if !closed && i == n - 1 {
            edges[n - 2].1
        } else {
            let before = edges[(i + edges.len() - 1) % edges.len()];
            let after = edges[i % edges.len()];
            crate::geometry::intersection(before.0, before.1, after.0, after.1).unwrap_or(after.0)
        };
        if point.distance(vertices[i].point) > distance.abs() * 1000.0 + EPS {
            return Err("Offset would create an excessive miter".into());
        }
        output.push(Vertex::new(point, 0.0));
    }
    Ok(Shape::Polyline {
        vertices: output,
        closed,
    })
}
