use crate::geometry::{Point, Transform, EPS};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Vertex {
    pub point: Point,
    #[serde(default)]
    pub bulge: f64,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Shape {
    Line {
        a: Point,
        b: Point,
    },
    Polyline {
        vertices: Vec<Vertex>,
        closed: bool,
    },
    Circle {
        center: Point,
        radius: f64,
    },
    Arc {
        center: Point,
        radius: f64,
        start: f64,
        sweep: f64,
    },
    Text {
        at: Point,
        text: String,
        height: f64,
        rotation: f64,
    },
    Dimension {
        a: Point,
        b: Point,
        offset: f64,
        aligned: bool,
    },
    Hatch {
        boundary: Vec<Point>,
        pattern: String,
        spacing: f64,
    },
    Insert {
        block: String,
        at: Point,
        scale: f64,
        rotation: f64,
    },
}
impl Shape {
    pub fn validate(&self) -> Result<(), String> {
        let positive = |v: f64| v.is_finite() && v > EPS && v <= 1e12;
        let valid = match self {
            Self::Line { a, b } => a.finite() && b.finite() && a.distance(*b) > EPS,
            Self::Polyline { vertices, .. } => {
                vertices.len() >= 2
                    && vertices.len() <= 100_000
                    && vertices
                        .iter()
                        .all(|v| v.point.finite() && v.bulge.is_finite() && v.bulge.abs() <= 1e6)
            }
            Self::Circle { center, radius } => center.finite() && positive(*radius),
            Self::Arc {
                center,
                radius,
                start,
                sweep,
            } => {
                center.finite()
                    && positive(*radius)
                    && start.is_finite()
                    && sweep.is_finite()
                    && sweep.abs() > EPS
                    && sweep.abs() <= std::f64::consts::TAU + EPS
            }
            Self::Text {
                at,
                text,
                height,
                rotation,
            } => at.finite() && positive(*height) && text.len() <= 65536 && rotation.is_finite(),
            Self::Dimension { a, b, offset, .. } => {
                a.finite()
                    && b.finite()
                    && a.distance(*b) > EPS
                    && offset.is_finite()
                    && offset.abs() <= 1e12
            }
            Self::Hatch {
                boundary,
                pattern,
                spacing,
            } => {
                boundary.len() >= 3
                    && boundary.len() <= 10_000
                    && boundary.iter().all(|p| p.finite())
                    && (pattern == "solid" || pattern == "diagonal")
                    && positive(*spacing)
                    && simple_polygon(boundary)
            }
            Self::Insert {
                block,
                at,
                scale,
                rotation,
            } => !block.is_empty() && at.finite() && positive(*scale) && rotation.is_finite(),
        };
        if valid {
            Ok(())
        } else {
            Err("Invalid or degenerate geometry".into())
        }
    }
    pub fn transformed(&self, t: Transform) -> Self {
        match self {
            Self::Line { a, b } => Self::Line {
                a: t.apply(*a),
                b: t.apply(*b),
            },
            Self::Polyline { vertices, closed } => Self::Polyline {
                vertices: vertices
                    .iter()
                    .map(|v| Vertex {
                        point: t.apply(v.point),
                        bulge: if t.determinant() < 0.0 {
                            -v.bulge
                        } else {
                            v.bulge
                        },
                    })
                    .collect(),
                closed: *closed,
            },
            Self::Circle { center, radius } => Self::Circle {
                center: t.apply(*center),
                radius: radius * t.scale(),
            },
            Self::Arc {
                center,
                radius,
                start,
                sweep,
            } => {
                let direction =
                    t.apply(*center + Point::new(start.cos(), start.sin())) - t.apply(*center);
                Self::Arc {
                    center: t.apply(*center),
                    radius: radius * t.scale(),
                    start: direction.y.atan2(direction.x),
                    sweep: if t.determinant() < 0.0 {
                        -sweep
                    } else {
                        *sweep
                    },
                }
            }
            Self::Text {
                at,
                text,
                height,
                rotation,
            } => Self::Text {
                at: t.apply(*at),
                text: text.clone(),
                height: height * t.scale(),
                rotation: rotation + t.angle(),
            },
            Self::Dimension {
                a,
                b,
                offset,
                aligned,
            } => Self::Dimension {
                a: t.apply(*a),
                b: t.apply(*b),
                offset: offset * t.scale() * t.determinant().signum(),
                aligned: *aligned,
            },
            Self::Hatch {
                boundary,
                pattern,
                spacing,
            } => Self::Hatch {
                boundary: boundary.iter().map(|p| t.apply(*p)).collect(),
                pattern: pattern.clone(),
                spacing: spacing * t.scale(),
            },
            Self::Insert {
                block,
                at,
                scale,
                rotation,
            } => Self::Insert {
                block: block.clone(),
                at: t.apply(*at),
                scale: scale * t.scale(),
                rotation: rotation + t.angle(),
            },
        }
    }
}

fn simple_polygon(p: &[Point]) -> bool {
    if p.iter()
        .zip(p.iter().cycle().skip(1))
        .take(p.len())
        .any(|(a, b)| a.distance(*b) < EPS)
    {
        return false;
    }
    let area: f64 = p
        .iter()
        .zip(p.iter().cycle().skip(1))
        .take(p.len())
        .map(|(a, b)| a.cross(*b))
        .sum();
    if area.abs() < EPS {
        return false;
    }
    // The editable hatch subset is convex, with one complete turn. The turn
    // check rejects self-intersecting stars whose corners share the same sign.
    let mut sign = 0.0_f64;
    let mut turn = 0.0_f64;
    for i in 0..p.len() {
        let a = p[(i + 1) % p.len()] - p[i];
        let b = p[(i + 2) % p.len()] - p[(i + 1) % p.len()];
        let cross = a.cross(b);
        turn += cross.atan2(a.dot(b));
        if cross.abs() > EPS {
            if sign != 0.0 && sign.signum() != cross.signum() {
                return false;
            }
            sign = cross;
        }
    }
    (turn.abs() - std::f64::consts::TAU).abs() < 1e-6
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Entity {
    pub id: u64,
    pub layer: String,
    #[serde(flatten)]
    pub shape: Shape,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Layer {
    pub name: String,
    pub color: [f32; 4],
    pub visible: bool,
    pub locked: bool,
}
impl Layer {
    pub fn new(name: &str, color: [f32; 4]) -> Self {
        Self {
            name: name.into(),
            color,
            visible: true,
            locked: false,
        }
    }
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Document {
    pub format_version: u32,
    pub units: String,
    pub current_layer: String,
    pub layers: Vec<Layer>,
    pub entities: BTreeMap<u64, Entity>,
    pub blocks: BTreeMap<String, Vec<Shape>>,
    pub next_id: u64,
}
impl Default for Document {
    fn default() -> Self {
        Self {
            format_version: 1,
            units: "mm".into(),
            current_layer: "0".into(),
            layers: vec![Layer::new("0", [0.80, 0.85, 0.90, 1.0])],
            entities: BTreeMap::new(),
            blocks: BTreeMap::new(),
            next_id: 1,
        }
    }
}
impl Document {
    pub fn layer(&self, name: &str) -> Option<&Layer> {
        self.layers.iter().find(|l| l.name == name)
    }
    pub fn insert(&mut self, shape: Shape) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        self.entities.insert(
            id,
            Entity {
                id,
                layer: self.current_layer.clone(),
                shape,
            },
        );
        id
    }
    pub fn validate(&self) -> Result<(), String> {
        if self.format_version != 1 {
            return Err(format!(
                "Unsupported native document version {}",
                self.format_version
            ));
        }
        if !["mm", "cm", "m", "in", "ft"].contains(&self.units.as_str()) {
            return Err("Unsupported drawing units".into());
        }
        if self.layers.is_empty()
            || self.layers.len() > 10_000
            || self.entities.len() > 1_000_000
            || self.blocks.len() > 10_000
        {
            return Err("Document exceeds supported limits".into());
        }
        let names: HashSet<_> = self.layers.iter().map(|l| &l.name).collect();
        if names.len() != self.layers.len()
            || self.layer(&self.current_layer).is_none()
            || self.layer("0").is_none()
            || self.layers.iter().any(|l| {
                l.name.is_empty()
                    || l.name.len() > 255
                    || l.color
                        .iter()
                        .any(|c| !c.is_finite() || !(0.0..=1.0).contains(c))
            })
        {
            return Err("Invalid layers".into());
        }
        for (id, e) in &self.entities {
            if *id != e.id
                || *id == 0
                || *id >= self.next_id
                || *id > 9_007_199_254_740_991
                || self.layer(&e.layer).is_none()
            {
                return Err("Invalid entity identity or layer".into());
            }
            e.shape.validate()?;
            self.validate_reference(&e.shape, &mut Vec::new())?;
        }
        for (name, shapes) in &self.blocks {
            if name.is_empty() || shapes.len() > 100_000 {
                return Err("Invalid block definition".into());
            }
            for shape in shapes {
                shape.validate()?;
                self.validate_reference(shape, &mut vec![name.as_str()])?;
            }
        }
        Ok(())
    }
    fn validate_reference<'a>(
        &'a self,
        shape: &'a Shape,
        stack: &mut Vec<&'a str>,
    ) -> Result<(), String> {
        if let Shape::Insert { block, .. } = shape {
            if stack.len() >= 16 || stack.contains(&block.as_str()) {
                return Err("Recursive or excessively nested block".into());
            }
            let shapes = self
                .blocks
                .get(block)
                .ok_or_else(|| format!("Missing block: {block}"))?;
            stack.push(block);
            for s in shapes {
                self.validate_reference(s, stack)?;
            }
            stack.pop();
        }
        Ok(())
    }
}
