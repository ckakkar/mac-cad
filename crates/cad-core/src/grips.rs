//! Grip points for selected objects and the single-grip stretch edits behind
//! AutoCAD-style hot grips. Every edit returns a new shape that is validated and
//! committed through the engine, so grip edits participate in undo/redo.
use crate::{
    commands::Engine,
    curves::arc_through,
    geometry::{bulge_arc, Point, Transform, EPS},
    model::{Shape, Vertex},
};
use serde_json::{json, Value};
use std::f64::consts::FRAC_PI_2;

/// Upper bound on grips reported for a selection; large polylines still edit
/// through numeric commands and the Properties inspector.
const MAX_GRIPS: usize = 2_000;

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Grip {
    pub point: Point,
    pub kind: &'static str,
}
fn grip(point: Point, kind: &'static str) -> Grip {
    Grip { point, kind }
}

/// Grips in a stable order; `stretch` interprets indexes in the same order.
pub fn grips(shape: &Shape) -> Vec<Grip> {
    match shape {
        Shape::Point { at } | Shape::Text { at, .. } | Shape::Insert { at, .. } => {
            vec![grip(*at, "insertion")]
        }
        Shape::Line { a, b } => vec![
            grip(*a, "endpoint"),
            grip(*b, "endpoint"),
            grip((*a + *b) * 0.5, "midpoint"),
        ],
        Shape::Polyline { vertices, closed } => {
            let mut out: Vec<_> = vertices.iter().map(|v| grip(v.point, "vertex")).collect();
            for i in 0..edge_count(vertices.len(), *closed) {
                out.push(grip(
                    edge_midpoint(&vertices[i], &vertices[(i + 1) % vertices.len()]),
                    "midpoint",
                ));
            }
            out
        }
        Shape::Circle { center, radius } => {
            let mut out = vec![grip(*center, "center")];
            for i in 0..4 {
                let a = i as f64 * FRAC_PI_2;
                out.push(grip(
                    *center + Point::new(a.cos(), a.sin()) * *radius,
                    "quadrant",
                ));
            }
            out
        }
        Shape::Arc {
            center,
            radius,
            start,
            sweep,
        } => {
            let at = |a: f64| *center + Point::new(a.cos(), a.sin()) * *radius;
            vec![
                grip(at(*start), "endpoint"),
                grip(at(start + sweep), "endpoint"),
                grip(at(start + sweep * 0.5), "midpoint"),
                grip(*center, "center"),
            ]
        }
        Shape::Ellipse {
            center,
            major,
            ratio,
            ..
        } => {
            let minor = Point::new(-major.y, major.x) * *ratio;
            vec![
                grip(*center, "center"),
                grip(*center + *major, "quadrant"),
                grip(*center - *major, "quadrant"),
                grip(*center + minor, "quadrant"),
                grip(*center - minor, "quadrant"),
            ]
        }
        Shape::Spline { control_points, .. } => {
            control_points.iter().map(|p| grip(*p, "control")).collect()
        }
        Shape::Dimension {
            a,
            b,
            offset,
            aligned,
        } => {
            let (aa, bb, _) = dimension_line(*a, *b, *offset, *aligned);
            vec![
                grip(*a, "endpoint"),
                grip(*b, "endpoint"),
                grip((aa + bb) * 0.5, "midpoint"),
            ]
        }
        Shape::RadialDimension {
            center, edge, at, ..
        } => vec![
            grip(*center, "center"),
            grip(*edge, "endpoint"),
            grip(*at, "insertion"),
        ],
        Shape::Leader { points, .. } => points.iter().map(|p| grip(*p, "vertex")).collect(),
        Shape::Hatch { boundary, .. } => boundary.iter().map(|p| grip(*p, "vertex")).collect(),
    }
}

/// Moves one grip to `to`. Endpoint/vertex grips stretch, center and midpoint
/// grips of lines move, and curve midpoints/quadrants reshape the curve.
pub fn stretch(shape: &Shape, index: usize, to: Point) -> Result<Shape, String> {
    if !to.finite() {
        return Err("Invalid grip location".into());
    }
    let from = grips(shape)
        .get(index)
        .ok_or("That grip no longer exists")?
        .point;
    let delta = to - from;
    let moved = shape.transformed(Transform::translation(delta));
    let out = match shape.clone() {
        Shape::Point { .. } | Shape::Text { .. } | Shape::Insert { .. } => moved,
        Shape::Line { a, b } => match index {
            0 => Shape::Line { a: to, b },
            1 => Shape::Line { a, b: to },
            _ => moved,
        },
        Shape::Polyline {
            mut vertices,
            closed,
        } => {
            let n = vertices.len();
            if index < n {
                vertices[index].point = to;
            } else {
                let i = index - n;
                let j = (i + 1) % n;
                if vertices[i].bulge.abs() < EPS {
                    vertices[i].point = vertices[i].point + delta;
                    vertices[j].point = vertices[j].point + delta;
                } else {
                    // A curved segment's midpoint reshapes the arc through its ends.
                    vertices[i].bulge = match arc_through(vertices[i].point, to, vertices[j].point)
                    {
                        Ok(Shape::Arc { sweep, .. }) => (sweep / 4.0).tan(),
                        _ => 0.0,
                    };
                }
            }
            Shape::Polyline { vertices, closed }
        }
        Shape::Circle { center, radius } => match index {
            0 => Shape::Circle { center: to, radius },
            _ => Shape::Circle {
                center,
                radius: center.distance(to),
            },
        },
        Shape::Arc {
            center,
            radius,
            start,
            sweep,
        } => {
            let at = |a: f64| center + Point::new(a.cos(), a.sin()) * radius;
            let (a, m, b) = (at(start), at(start + sweep * 0.5), at(start + sweep));
            match index {
                0 => arc_through(to, m, b)?,
                1 => arc_through(a, m, to)?,
                2 => arc_through(a, to, b)?,
                _ => moved,
            }
        }
        Shape::Ellipse {
            center,
            major,
            ratio,
            start,
            sweep,
        } => {
            let minor = major.length() * ratio;
            let (major, ratio) = match index {
                0 => return Ok(moved),
                1 | 2 => {
                    let axis = (to - center) * if index == 1 { 1.0 } else { -1.0 };
                    (axis, minor / axis.length().max(EPS))
                }
                _ => {
                    let u = major * (1.0 / major.length());
                    (major, u.cross(to - center).abs() / major.length())
                }
            };
            if ratio > 1.0 + EPS {
                return Err("The major axis must remain longer than the minor axis".into());
            }
            Shape::Ellipse {
                center,
                major,
                ratio: ratio.min(1.0),
                start,
                sweep,
            }
        }
        Shape::Spline {
            degree,
            mut control_points,
            knots,
            weights,
            closed,
        } => {
            control_points[index] = to;
            Shape::Spline {
                degree,
                control_points,
                knots,
                weights,
                closed,
            }
        }
        Shape::Dimension {
            a,
            b,
            offset,
            aligned,
        } => match index {
            0 => Shape::Dimension {
                a: to,
                b,
                offset,
                aligned,
            },
            1 => Shape::Dimension {
                a,
                b: to,
                offset,
                aligned,
            },
            _ => {
                let (_, _, normal) = dimension_line(a, b, offset, aligned);
                Shape::Dimension {
                    a,
                    b,
                    offset: (to - a).dot(normal),
                    aligned,
                }
            }
        },
        Shape::RadialDimension {
            mut center,
            mut edge,
            mut at,
            diameter,
        } => {
            *[&mut center, &mut edge, &mut at][index] = to;
            Shape::RadialDimension {
                center,
                edge,
                at,
                diameter,
            }
        }
        Shape::Leader {
            mut points,
            text,
            height,
        } => {
            points[index] = to;
            Shape::Leader {
                points,
                text,
                height,
            }
        }
        Shape::Hatch {
            mut boundary,
            pattern,
            spacing,
        } => {
            boundary[index] = to;
            Shape::Hatch {
                boundary,
                pattern,
                spacing,
            }
        }
    };
    out.validate().map_err(|_| match out {
        Shape::Hatch { .. } => "Hatch boundaries must remain convex".to_string(),
        _ => "That grip location would make the object degenerate".to_string(),
    })?;
    Ok(out)
}

fn edge_count(vertices: usize, closed: bool) -> usize {
    if closed {
        vertices
    } else {
        vertices.saturating_sub(1)
    }
}
fn edge_midpoint(a: &Vertex, b: &Vertex) -> Point {
    match bulge_arc(a.point, b.point, a.bulge) {
        Some((c, r, s, w)) => {
            let m = s + w * 0.5;
            c + Point::new(m.cos(), m.sin()) * r
        }
        None => (a.point + b.point) * 0.5,
    }
}
/// Dimension line endpoints and its unit normal, matching the renderer.
fn dimension_line(a: Point, b: Point, offset: f64, aligned: bool) -> (Point, Point, Point) {
    let d = b - a;
    let u = if aligned {
        d * (1.0 / d.length().max(EPS))
    } else {
        Point::new(if b.x >= a.x { 1.0 } else { -1.0 }, 0.0)
    };
    let n = Point::new(-u.y, u.x);
    let aa = a + n * offset;
    let bb = if aligned {
        b + n * offset
    } else {
        Point::new(b.x, aa.y)
    };
    (aa, bb, n)
}

impl Engine {
    /// Grips of selected, editable objects, for display by the native canvas.
    pub(crate) fn selection_grips(&self) -> Value {
        let mut out = Vec::new();
        for id in self.selected.iter().take(100) {
            let Some(e) = self.doc.entities.get(id).filter(|e| self.editable(e)) else {
                continue;
            };
            for (index, g) in grips(&e.shape).into_iter().enumerate() {
                if out.len() >= MAX_GRIPS {
                    return Value::Array(out);
                }
                out.push(json!({"id":id,"index":index,"x":g.point.x,"y":g.point.y,"kind":g.kind}));
            }
        }
        Value::Array(out)
    }
    /// Tessellated outline of an object as it would look after a grip edit,
    /// flattened as `[ax, ay, bx, by, …]`. Invalid locations preview nothing.
    pub(crate) fn grip_preview(
        &self,
        id: u64,
        index: usize,
        to: Point,
        tolerance: f64,
    ) -> Vec<f64> {
        let Some(e) = self.doc.entities.get(&id).filter(|e| self.editable(e)) else {
            return Vec::new();
        };
        let Ok(shape) = stretch(&e.shape, index, to) else {
            return Vec::new();
        };
        let preview = crate::model::Entity { shape, ..e.clone() };
        crate::render::entity_geometry(&self.doc, &preview, tolerance)
            .segments
            .iter()
            .take(50_000)
            .flat_map(|s| [s.ax, s.ay, s.bx, s.by])
            .collect()
    }
    /// Commits one grip edit. Hidden/locked objects and stale grips are refused.
    pub(crate) fn move_grip(&mut self, id: u64, index: usize, to: Point) -> Result<(), String> {
        let mut e = self
            .doc
            .entities
            .get(&id)
            .filter(|e| self.editable(e))
            .ok_or("Grip object is missing, hidden or locked")?
            .clone();
        if let Shape::Insert { block, .. } = &e.shape {
            if !self.doc.blocks.contains_key(block) {
                return Err(format!("Unknown block: {block}"));
            }
        }
        e.shape = stretch(&e.shape, index, to)?;
        self.commit(vec![e], Vec::new(), None)
    }
}
