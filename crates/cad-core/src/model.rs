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
    Point {
        at: Point,
    },
    Ellipse {
        center: Point,
        major: Point,
        ratio: f64,
        start: f64,
        sweep: f64,
    },
    Spline {
        degree: usize,
        control_points: Vec<Point>,
        knots: Vec<f64>,
        weights: Vec<f64>,
        closed: bool,
    },
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
    RadialDimension {
        center: Point,
        edge: Point,
        at: Point,
        diameter: bool,
    },
    Leader {
        points: Vec<Point>,
        text: String,
        height: f64,
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
            Self::Point { at } => at.finite(),
            Self::Ellipse {
                center,
                major,
                ratio,
                start,
                sweep,
            } => {
                center.finite()
                    && major.finite()
                    && positive(major.length())
                    && positive(*ratio)
                    && *ratio <= 1.0
                    && start.is_finite()
                    && sweep.is_finite()
                    && sweep.abs() > EPS
                    && sweep.abs() <= std::f64::consts::TAU + EPS
            }
            Self::Spline {
                degree,
                control_points,
                knots,
                weights,
                ..
            } => {
                *degree >= 1
                    && *degree <= 7
                    && control_points.len() > *degree
                    && control_points.len() <= 10_000
                    && knots.len() == control_points.len() + degree + 1
                    && weights.len() == control_points.len()
                    && control_points.iter().all(|p| p.finite())
                    && weights.iter().all(|w| positive(*w))
                    && knots.iter().all(|k| k.is_finite())
                    && knots.windows(2).all(|k| k[0] <= k[1])
                    && knots[*degree] < knots[control_points.len()]
            }
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
            Self::RadialDimension {
                center, edge, at, ..
            } => center.finite() && edge.finite() && at.finite() && center.distance(*edge) > EPS,
            Self::Leader {
                points,
                text,
                height,
            } => {
                points.len() >= 2
                    && points.len() <= 10_000
                    && points.iter().all(|p| p.finite())
                    && text.len() <= 65536
                    && positive(*height)
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
            Self::Point { at } => Self::Point { at: t.apply(*at) },
            Self::Ellipse {
                center,
                major,
                ratio,
                start,
                sweep,
            } => Self::Ellipse {
                center: t.apply(*center),
                major: t.apply(*center + *major) - t.apply(*center),
                ratio: *ratio,
                start: if t.determinant() < 0.0 {
                    -start
                } else {
                    *start
                },
                sweep: if t.determinant() < 0.0 {
                    -sweep
                } else {
                    *sweep
                },
            },
            Self::Spline {
                degree,
                control_points,
                knots,
                weights,
                closed,
            } => Self::Spline {
                degree: *degree,
                control_points: control_points.iter().map(|p| t.apply(*p)).collect(),
                knots: knots.clone(),
                weights: weights.clone(),
                closed: *closed,
            },
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
            Self::RadialDimension {
                center,
                edge,
                at,
                diameter,
            } => Self::RadialDimension {
                center: t.apply(*center),
                edge: t.apply(*edge),
                at: t.apply(*at),
                diameter: *diameter,
            },
            Self::Leader {
                points,
                text,
                height,
            } => Self::Leader {
                points: points.iter().map(|p| t.apply(*p)).collect(),
                text: text.clone(),
                height: height * t.scale(),
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
    #[serde(default)]
    pub style: EntityStyle,
    #[serde(flatten)]
    pub shape: Shape,
}
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct EntityStyle {
    pub color: Option<[f32; 4]>,
    pub line_type: Option<String>,
    pub line_weight: Option<f32>,
}
impl EntityStyle {
    pub fn valid(&self) -> bool {
        self.color
            .is_none_or(|c| c.iter().all(|v| v.is_finite() && (0.0..=1.0).contains(v)))
            && self
                .line_weight
                .is_none_or(|w| w.is_finite() && (0.0..=2.11).contains(&w))
            && self.line_type.as_ref().is_none_or(|s| valid_line_type(s))
    }
}
pub fn valid_line_type(s: &str) -> bool {
    ["Continuous", "Dashed", "Center", "Hidden", "Dotted"].contains(&s)
}
fn default_line_type() -> String {
    "Continuous".into()
}
fn default_line_weight() -> f32 {
    0.25
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Layer {
    pub name: String,
    pub color: [f32; 4],
    pub visible: bool,
    pub locked: bool,
    #[serde(default = "default_line_type")]
    pub line_type: String,
    #[serde(default = "default_line_weight")]
    pub line_weight: f32,
}
impl Layer {
    pub fn new(name: &str, color: [f32; 4]) -> Self {
        Self {
            name: name.into(),
            color,
            visible: true,
            locked: false,
            line_type: default_line_type(),
            line_weight: default_line_weight(),
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
            format_version: 2,
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
                style: Default::default(),
                shape,
            },
        );
        id
    }
    pub fn validate(&self) -> Result<(), String> {
        if ![1, 2].contains(&self.format_version) {
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
                    || !valid_line_type(&l.line_type)
                    || !l.line_weight.is_finite()
                    || !(0.0..=2.11).contains(&l.line_weight)
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
            if !e.style.valid() {
                return Err("Invalid entity properties".into());
            }
        }
        for (name, shapes) in &self.blocks {
            if name.is_empty() || shapes.len() > 100_000 {
                return Err("Invalid block definition".into());
            }
            for shape in shapes {
                shape.validate()?;
            }
        }
        // Memoize each block's expanded cost. A shallow branching graph can
        // otherwise expand exponentially despite a small file and depth limit.
        let mut costs = BTreeMap::new();
        for name in self.blocks.keys() {
            self.block_cost(name, &mut Vec::new(), &mut costs)?;
        }
        let mut expanded = 0usize;
        for entity in self.entities.values() {
            expanded = expanded.saturating_add(match &entity.shape {
                Shape::Insert { block, .. } => {
                    costs
                        .get(block.as_str())
                        .ok_or_else(|| format!("Missing block: {block}"))?
                        .0
                }
                _ => 1,
            });
            if expanded > 1_000_000 {
                return Err("Drawing exceeds one million expanded block objects".into());
            }
        }
        Ok(())
    }
    fn block_cost<'a>(
        &'a self,
        name: &'a str,
        stack: &mut Vec<&'a str>,
        cache: &mut BTreeMap<&'a str, (usize, usize)>,
    ) -> Result<(usize, usize), String> {
        if stack.len() >= 16 || stack.contains(&name) {
            return Err("Recursive or excessively nested block".into());
        }
        if let Some(&(cost, depth)) = cache.get(name) {
            if stack.len() + depth > 16 {
                return Err("Excessively nested block".into());
            }
            return Ok((cost, depth));
        }
        let shapes = self
            .blocks
            .get(name)
            .ok_or_else(|| format!("Missing block: {name}"))?;
        stack.push(name);
        let (mut cost, mut depth) = (0usize, 1usize);
        for shape in shapes {
            let count = if let Shape::Insert { block, .. } = shape {
                let (n, d) = self.block_cost(block, stack, cache)?;
                depth = depth.max(d + 1);
                n
            } else {
                1
            };
            cost = cost.saturating_add(count);
            if cost > 1_000_000 {
                return Err("Block exceeds one million expanded objects".into());
            }
        }
        stack.pop();
        cache.insert(name, (cost, depth));
        Ok((cost, depth))
    }
}
