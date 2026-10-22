use crate::geometry::{Point, Transform, EPS};
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, HashSet};
use std::sync::Arc;

/// Block definitions are shared copy-on-write so undo snapshots stay cheap.
pub type Blocks = Arc<BTreeMap<String, Vec<BlockEntity>>>;

fn is_zero(v: &f64) -> bool {
    *v == 0.0
}
fn one() -> f64 {
    1.0
}
fn is_one(v: &f64) -> bool {
    *v == 1.0
}
fn yes() -> bool {
    true
}
fn is_zero_u8(v: &u8) -> bool {
    *v == 0
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Vertex {
    pub point: Point,
    #[serde(default)]
    pub bulge: f64,
    /// Segment widths, as in a wide LWPOLYLINE; zero draws a thin line.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub start_width: f64,
    #[serde(default, skip_serializing_if = "is_zero")]
    pub end_width: f64,
}
impl Vertex {
    pub fn new(point: Point, bulge: f64) -> Self {
        Self {
            point,
            bulge,
            start_width: 0.0,
            end_width: 0.0,
        }
    }
}

/// Text appearance beyond position, height and rotation. Single-line TEXT uses
/// justification; multiline text uses an attachment point and wrap width.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TextFormat {
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub style: String,
    #[serde(default = "one", skip_serializing_if = "is_one")]
    pub width_factor: f64,
    /// Obliquing angle in radians.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub oblique: f64,
    /// TEXT horizontal justification: 0 left, 1 center, 2 right, 3 aligned, 4 middle, 5 fit.
    #[serde(default, skip_serializing_if = "is_zero_u8")]
    pub halign: u8,
    /// TEXT vertical justification: 0 baseline, 1 bottom, 2 middle, 3 top.
    #[serde(default, skip_serializing_if = "is_zero_u8")]
    pub valign: u8,
    /// Second alignment point of justified TEXT; the text is placed relative to it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub align: Option<Point>,
    /// Multiline attachment 1–9 (top-left … bottom-right); 0 is single-line text.
    #[serde(default, skip_serializing_if = "is_zero_u8")]
    pub attachment: u8,
    /// Multiline wrap width; 0 disables wrapping.
    #[serde(default, skip_serializing_if = "is_zero")]
    pub wrap: f64,
    #[serde(default = "one", skip_serializing_if = "is_one")]
    pub line_spacing: f64,
}
impl Default for TextFormat {
    fn default() -> Self {
        Self {
            style: String::new(),
            width_factor: 1.0,
            oblique: 0.0,
            halign: 0,
            valign: 0,
            align: None,
            attachment: 0,
            wrap: 0.0,
            line_spacing: 1.0,
        }
    }
}
impl TextFormat {
    pub fn is_plain(&self) -> bool {
        *self == Self::default()
    }
    fn valid(&self) -> bool {
        self.width_factor.is_finite()
            && self.width_factor > EPS
            && self.width_factor <= 100.0
            && self.oblique.is_finite()
            && self.halign <= 5
            && self.valign <= 3
            && self.attachment <= 9
            && self.wrap.is_finite()
            && self.wrap >= 0.0
            && self.line_spacing.is_finite()
            && self.line_spacing > 0.0
            && self.align.is_none_or(|p| p.finite())
    }
    fn transformed(&self, t: Transform) -> Self {
        Self {
            align: self.align.map(|p| t.apply(p)),
            wrap: self.wrap * t.scale(),
            ..self.clone()
        }
    }
}

/// A block attribute value placed with its insert.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Attribute {
    pub tag: String,
    pub text: String,
    pub at: Point,
    pub height: f64,
    #[serde(default)]
    pub rotation: f64,
    #[serde(default, skip_serializing_if = "TextFormat::is_plain")]
    pub format: TextFormat,
    #[serde(default)]
    pub invisible: bool,
}

/// Dimension semantics kept with an imported dimension's graphics block.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct DimensionInfo {
    pub kind: String,
    #[serde(default)]
    pub measurement: f64,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub text: String,
    #[serde(default, skip_serializing_if = "String::is_empty")]
    pub style: String,
}

/// One family of parallel dashed lines in a hatch pattern, in drawing units.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PatternLine {
    /// Line direction in radians.
    pub angle: f64,
    pub origin: Point,
    /// Displacement between successive lines of the family.
    pub offset: Point,
    /// Positive dashes, negative gaps and zero dots; empty draws continuous lines.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub dashes: Vec<f64>,
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
        #[serde(default, skip_serializing_if = "TextFormat::is_plain")]
        format: TextFormat,
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
    /// General hatch: boundary loops with holes, filled solid or with pattern lines.
    Region {
        loops: Vec<Vec<Vertex>>,
        #[serde(default)]
        solid: bool,
        #[serde(default, skip_serializing_if = "String::is_empty")]
        pattern: String,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        lines: Vec<PatternLine>,
    },
    /// Filled triangle or quadrilateral (SOLID, TRACE, flat 3DFACE), in polygon order.
    Solid {
        points: Vec<Point>,
    },
    Insert {
        block: String,
        at: Point,
        /// X scale; also the Y scale unless `y_scale` is set. Negative mirrors.
        scale: f64,
        rotation: f64,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        y_scale: Option<f64>,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        attributes: Vec<Attribute>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        dimension: Option<DimensionInfo>,
    },
    /// Raster image frame; `u` and `v` span the full image width and height.
    Image {
        at: Point,
        u: Point,
        v: Point,
        path: String,
    },
    /// Construction line (XLINE) or ray through `at`.
    XLine {
        at: Point,
        direction: Point,
        ray: bool,
    },
}
impl Shape {
    pub fn text(at: Point, text: impl Into<String>, height: f64, rotation: f64) -> Self {
        Self::Text {
            at,
            text: text.into(),
            height,
            rotation,
            format: TextFormat::default(),
        }
    }
    pub fn insert(block: impl Into<String>, at: Point, scale: f64, rotation: f64) -> Self {
        Self::Insert {
            block: block.into(),
            at,
            scale,
            rotation,
            y_scale: None,
            attributes: Vec::new(),
            dimension: None,
        }
    }
    /// The insert placement as a transform from block to drawing coordinates.
    pub fn insert_transform(
        at: Point,
        scale: f64,
        y_scale: Option<f64>,
        rotation: f64,
    ) -> Transform {
        Transform::translation(at)
            .compose(Transform::rotation(Point::default(), rotation, 1.0))
            .compose(Transform::scale_xy(scale, y_scale.unwrap_or(scale)))
    }
    pub fn validate(&self) -> Result<(), String> {
        let positive = |v: f64| v.is_finite() && v > EPS && v <= 1e12;
        let nonzero = |v: f64| v.is_finite() && v.abs() > EPS && v.abs() <= 1e12;
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
            Self::Polyline { vertices, .. } => vertices.len() >= 2 && valid_vertices(vertices),
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
                format,
            } => {
                at.finite()
                    && positive(*height)
                    && text.len() <= 65536
                    && rotation.is_finite()
                    && format.valid()
            }
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
            Self::Region { loops, lines, .. } => {
                !loops.is_empty()
                    && loops.len() <= 10_000
                    && loops.iter().all(|l| l.len() >= 2 && valid_vertices(l))
                    && lines.len() <= 1_000
                    && lines.iter().all(|l| {
                        l.angle.is_finite()
                            && l.origin.finite()
                            && l.offset.finite()
                            && l.dashes.len() <= 64
                            && l.dashes.iter().all(|d| d.is_finite() && d.abs() <= 1e12)
                    })
            }
            Self::Solid { points } => {
                (3..=4).contains(&points.len()) && points.iter().all(|p| p.finite())
            }
            Self::Insert {
                block,
                at,
                scale,
                rotation,
                y_scale,
                attributes,
                ..
            } => {
                !block.is_empty()
                    && at.finite()
                    && nonzero(*scale)
                    && y_scale.is_none_or(nonzero)
                    && rotation.is_finite()
                    && attributes.len() <= 1_000
                    && attributes.iter().all(|a| {
                        a.at.finite()
                            && positive(a.height)
                            && a.rotation.is_finite()
                            && a.text.len() <= 65536
                            && a.format.valid()
                    })
            }
            Self::Image { at, u, v, path } => {
                at.finite()
                    && u.finite()
                    && v.finite()
                    && u.cross(*v).abs() > EPS
                    && path.len() <= 4096
            }
            Self::XLine { at, direction, .. } => {
                at.finite() && direction.finite() && direction.length() > EPS
            }
        };
        if valid {
            Ok(())
        } else {
            Err("Invalid or degenerate geometry".into())
        }
    }
    pub fn transformed(&self, t: Transform) -> Self {
        let mirror = t.determinant() < 0.0;
        let linear = |p: Point| t.apply(p) - t.apply(Point::default());
        let vertices = |vertices: &[Vertex]| -> Vec<Vertex> {
            vertices
                .iter()
                .map(|v| Vertex {
                    point: t.apply(v.point),
                    bulge: if mirror { -v.bulge } else { v.bulge },
                    start_width: v.start_width * t.scale(),
                    end_width: v.end_width * t.scale(),
                })
                .collect()
        };
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
                start: if mirror { -start } else { *start },
                sweep: if mirror { -sweep } else { *sweep },
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
            Self::Polyline {
                vertices: v,
                closed,
            } => Self::Polyline {
                vertices: vertices(v),
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
                    sweep: if mirror { -sweep } else { *sweep },
                }
            }
            Self::Text {
                at,
                text,
                height,
                rotation,
                format,
            } => Self::Text {
                at: t.apply(*at),
                text: text.clone(),
                height: height * t.scale(),
                rotation: rotation + t.angle(),
                format: format.transformed(t),
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
            Self::Region {
                loops,
                solid,
                pattern,
                lines,
            } => Self::Region {
                loops: loops.iter().map(|l| vertices(l)).collect(),
                solid: *solid,
                pattern: pattern.clone(),
                lines: lines
                    .iter()
                    .map(|l| {
                        let d = linear(Point::new(l.angle.cos(), l.angle.sin()));
                        PatternLine {
                            angle: d.y.atan2(d.x),
                            origin: t.apply(l.origin),
                            offset: linear(l.offset),
                            dashes: l.dashes.iter().map(|v| v * t.scale()).collect(),
                        }
                    })
                    .collect(),
            },
            Self::Solid { points } => Self::Solid {
                points: points.iter().map(|p| t.apply(*p)).collect(),
            },
            Self::Insert {
                block,
                at,
                scale,
                rotation,
                y_scale,
                attributes,
                dimension,
            } => {
                // A·T(at)·R(r)·S(sx,sy) = T(A at)·R(r')·S(sx',sy'); a mirror flips Y.
                let s = t.scale();
                let sy = y_scale.unwrap_or(*scale);
                let (rotation, y) = if mirror {
                    (t.angle() - rotation, -sy * s)
                } else {
                    (rotation + t.angle(), sy * s)
                };
                Self::Insert {
                    block: block.clone(),
                    at: t.apply(*at),
                    scale: scale * s,
                    rotation,
                    y_scale: if y_scale.is_some() || mirror {
                        Some(y)
                    } else {
                        None
                    },
                    attributes: attributes
                        .iter()
                        .map(|a| Attribute {
                            at: t.apply(a.at),
                            height: a.height * s,
                            rotation: a.rotation + t.angle(),
                            format: a.format.transformed(t),
                            ..a.clone()
                        })
                        .collect(),
                    dimension: dimension.clone(),
                }
            }
            Self::Image { at, u, v, path } => Self::Image {
                at: t.apply(*at),
                u: linear(*u),
                v: linear(*v),
                path: path.clone(),
            },
            Self::XLine { at, direction, ray } => Self::XLine {
                at: t.apply(*at),
                direction: linear(*direction),
                ray: *ray,
            },
        }
    }
}

fn valid_vertices(vertices: &[Vertex]) -> bool {
    vertices.len() <= 100_000
        && vertices.iter().all(|v| {
            v.point.finite()
                && v.bulge.is_finite()
                && v.bulge.abs() <= 1e6
                && v.start_width.is_finite()
                && v.end_width.is_finite()
                && v.start_width >= 0.0
                && v.end_width >= 0.0
        })
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
pub const BY_BLOCK_COLOR: u8 = 1;
pub const BY_BLOCK_LINE_TYPE: u8 = 2;
pub const BY_BLOCK_LINE_WEIGHT: u8 = 4;
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct EntityStyle {
    pub color: Option<[f32; 4]>,
    pub line_type: Option<String>,
    pub line_weight: Option<f32>,
    /// Properties taken from the enclosing block reference (ByBlock), as bit flags.
    #[serde(default, skip_serializing_if = "is_zero_u8")]
    pub by_block: u8,
    /// Per-object linetype scale (CELTSCALE).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub line_type_scale: Option<f64>,
}
impl EntityStyle {
    pub fn valid(&self) -> bool {
        self.color
            .is_none_or(|c| c.iter().all(|v| v.is_finite() && (0.0..=1.0).contains(v)))
            && self
                .line_weight
                .is_none_or(|w| w.is_finite() && (0.0..=2.11).contains(&w))
            && self.line_type.as_ref().is_none_or(|s| valid_line_type(s))
            && self
                .line_type_scale
                .is_none_or(|s| s.is_finite() && s > EPS && s <= 1e6)
            && self.by_block <= 7
    }
}
/// Built-in names plus any linetype a drawing defines; unknown names draw continuous.
pub fn valid_line_type(s: &str) -> bool {
    !s.is_empty() && s.len() <= 255 && !s.chars().any(|c| c.is_control())
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
    /// Frozen layers are hidden everywhere, including inside blocks.
    #[serde(default)]
    pub frozen: bool,
    #[serde(default = "yes")]
    pub plot: bool,
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
            frozen: false,
            plot: true,
        }
    }
    pub fn shown(&self) -> bool {
        self.visible && !self.frozen
    }
}
/// A linetype definition: positive dashes, negative gaps, zero dots (drawing units).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct LineTypeDef {
    #[serde(default)]
    pub description: String,
    pub pattern: Vec<f64>,
}
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct TextStyle {
    #[serde(default)]
    pub font: String,
    #[serde(default = "one")]
    pub width_factor: f64,
    #[serde(default)]
    pub oblique: f64,
    #[serde(default)]
    pub height: f64,
}
/// Drawing-wide display settings that travel with the drawing.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Header {
    /// Global linetype scale (LTSCALE).
    #[serde(default = "one")]
    pub ltscale: f64,
    /// Point display mode and size (PDMODE, PDSIZE).
    #[serde(default)]
    pub pdmode: i32,
    #[serde(default)]
    pub pdsize: f64,
}
impl Default for Header {
    fn default() -> Self {
        Self {
            ltscale: 1.0,
            pdmode: 0,
            pdsize: 0.0,
        }
    }
}
/// An object inside a block definition. Layer "0" and ByBlock properties take
/// the insert's values when the block is drawn.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct BlockEntity {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub layer: Option<String>,
    #[serde(default, skip_serializing_if = "is_plain_style")]
    pub style: EntityStyle,
    #[serde(flatten)]
    pub shape: Shape,
}
fn is_plain_style(s: &EntityStyle) -> bool {
    *s == EntityStyle::default()
}
impl From<Shape> for BlockEntity {
    fn from(shape: Shape) -> Self {
        Self {
            layer: None,
            style: EntityStyle::default(),
            shape,
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
    pub blocks: Blocks,
    pub next_id: u64,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub linetypes: BTreeMap<String, LineTypeDef>,
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub text_styles: BTreeMap<String, TextStyle>,
    #[serde(default)]
    pub header: Header,
}
pub const FORMAT_VERSION: u32 = 3;
impl Default for Document {
    fn default() -> Self {
        Self {
            format_version: FORMAT_VERSION,
            units: "mm".into(),
            current_layer: "0".into(),
            layers: vec![Layer::new("0", [0.80, 0.85, 0.90, 1.0])],
            entities: BTreeMap::new(),
            blocks: Arc::default(),
            next_id: 1,
            linetypes: BTreeMap::new(),
            text_styles: BTreeMap::new(),
            header: Header::default(),
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
        if ![1, 2, 3].contains(&self.format_version) {
            return Err(format!(
                "Unsupported native document version {}",
                self.format_version
            ));
        }
        if !["mm", "cm", "m", "in", "ft"].contains(&self.units.as_str()) {
            return Err("Unsupported drawing units".into());
        }
        if self.layers.is_empty()
            || self.layers.len() > 100_000
            || self.entities.len() > 5_000_000
            || self.blocks.len() > 200_000
            || self.linetypes.len() > 10_000
            || self.text_styles.len() > 10_000
        {
            return Err("Document exceeds supported limits".into());
        }
        if !self.header.ltscale.is_finite()
            || self.header.ltscale <= 0.0
            || !self.header.pdsize.is_finite()
        {
            return Err("Invalid drawing header".into());
        }
        if self.linetypes.iter().any(|(name, l)| {
            !valid_line_type(name)
                || l.pattern.len() > 64
                || l.pattern.iter().any(|v| !v.is_finite() || v.abs() > 1e12)
        }) || self.text_styles.values().any(|s| {
            !s.width_factor.is_finite()
                || s.width_factor <= 0.0
                || !s.oblique.is_finite()
                || !s.height.is_finite()
        }) {
            return Err("Invalid linetype or text style".into());
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
        for (name, entities) in self.blocks.iter() {
            if name.is_empty() || entities.len() > 2_000_000 {
                return Err("Invalid block definition".into());
            }
            for e in entities {
                e.shape.validate()?;
                if !e.style.valid() || e.layer.as_ref().is_some_and(|l| l.len() > 255) {
                    return Err("Invalid block entity properties".into());
                }
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
            if expanded > MAX_EXPANDED {
                return Err("Drawing exceeds 50 million expanded block objects".into());
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
        if stack.len() >= 32 || stack.contains(&name) {
            return Err("Recursive or excessively nested block".into());
        }
        if let Some(&(cost, depth)) = cache.get(name) {
            if stack.len() + depth > 32 {
                return Err("Excessively nested block".into());
            }
            return Ok((cost, depth));
        }
        let entities = self
            .blocks
            .get(name)
            .ok_or_else(|| format!("Missing block: {name}"))?;
        stack.push(name);
        let (mut cost, mut depth) = (0usize, 1usize);
        for e in entities {
            let count = if let Shape::Insert { block, .. } = &e.shape {
                let (n, d) = self.block_cost(block, stack, cache)?;
                depth = depth.max(d + 1);
                n
            } else {
                1
            };
            cost = cost.saturating_add(count);
            if cost > MAX_EXPANDED {
                return Err("Block exceeds 50 million expanded objects".into());
            }
        }
        stack.pop();
        cache.insert(name, (cost, depth));
        Ok((cost, depth))
    }
}
impl Document {
    /// Entities produced by exploding one block reference. Objects on layer "0"
    /// or with ByBlock properties take the reference's layer and properties.
    pub fn explode_insert(&self, insert: &Entity, first_id: u64) -> Result<Vec<Entity>, String> {
        let Shape::Insert {
            block,
            at,
            scale,
            rotation,
            y_scale,
            attributes,
            ..
        } = &insert.shape
        else {
            return Err("Not a block reference".into());
        };
        let entities = self
            .blocks
            .get(block)
            .ok_or_else(|| format!("Missing block: {block}"))?;
        let t = Shape::insert_transform(*at, *scale, *y_scale, *rotation);
        let mut out = Vec::new();
        for e in entities {
            let layer = match e.layer.as_deref() {
                Some(l) if l != "0" && self.layer(l).is_some() => l.to_string(),
                _ => insert.layer.clone(),
            };
            let style = if e.style == EntityStyle::default() {
                insert.style.clone()
            } else {
                let mut s = e.style.clone();
                if s.by_block & BY_BLOCK_COLOR != 0 {
                    s.color = insert.style.color;
                }
                if s.by_block & BY_BLOCK_LINE_TYPE != 0 {
                    s.line_type = insert.style.line_type.clone();
                }
                if s.by_block & BY_BLOCK_LINE_WEIGHT != 0 {
                    s.line_weight = insert.style.line_weight;
                }
                s.by_block = 0;
                s
            };
            out.push(Entity {
                id: first_id + out.len() as u64,
                layer,
                style,
                shape: e.shape.transformed(t),
            });
        }
        for a in attributes.iter().filter(|a| !a.invisible) {
            out.push(Entity {
                id: first_id + out.len() as u64,
                layer: insert.layer.clone(),
                style: insert.style.clone(),
                shape: Shape::Text {
                    at: a.at,
                    text: a.text.clone(),
                    height: a.height,
                    rotation: a.rotation,
                    format: a.format.clone(),
                },
            });
        }
        Ok(out)
    }
}
/// Guard against pathological block graphs while admitting large real drawings.
pub const MAX_EXPANDED: usize = 50_000_000;
