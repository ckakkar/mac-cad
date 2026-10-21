//! Explicitly limited 2D exchange adapter. Native files preserve editing semantics;
//! DXF export flattens annotations/hatches and reports that conversion to callers.
use crate::{
    geometry::{Point, Transform, EPS},
    model::{Document, Entity, EntityStyle, Layer, Shape, Vertex},
    render::entity_geometry,
};
use dxf::{
    entities::{self, EntityType},
    enums::{AcadVersion, DimensionType, Units},
    Drawing,
};
use std::{collections::BTreeSet, io::Write, path::Path};

fn point(p: &dxf::Point) -> Result<Point, String> {
    if p.z.abs() > EPS {
        return Err("non-planar geometry".into());
    }
    let p = Point::new(p.x, p.y);
    if p.finite() {
        Ok(p)
    } else {
        Err("invalid coordinates".into())
    }
}
fn dpoint(p: Point) -> dxf::Point {
    dxf::Point::new(p.x, p.y, 0.0)
}
fn planar(v: &dxf::Vector) -> bool {
    v.x.abs() < EPS && v.y.abs() < EPS && (v.z - 1.0).abs() < EPS
}
fn from_entity(e: &entities::Entity) -> Result<Shape, String> {
    if e.common.is_in_paper_space {
        return Err("paper-space entity".into());
    }
    if e.common.elevation.abs() > EPS {
        return Err("nonzero elevation".into());
    }
    let s = match &e.specific {
        EntityType::ModelPoint(p) if planar(&p.extrusion_direction) => Shape::Point {
            at: point(&p.location)?,
        },
        EntityType::Ellipse(s) if planar(&s.normal) && s.major_axis.z.abs() < EPS => {
            Shape::Ellipse {
                center: point(&s.center)?,
                major: Point::new(s.major_axis.x, s.major_axis.y),
                ratio: s.minor_axis_ratio,
                start: s.start_parameter,
                sweep: s.end_parameter - s.start_parameter,
            }
        }
        EntityType::Spline(s) if s.degree_of_curve >= 1 && s.degree_of_curve <= 7 => {
            Shape::Spline {
                degree: s.degree_of_curve as usize,
                control_points: s
                    .control_points
                    .iter()
                    .map(point)
                    .collect::<Result<_, _>>()?,
                knots: s.knot_values.clone(),
                weights: if s.weight_values.is_empty() {
                    vec![1.0; s.control_points.len()]
                } else {
                    s.weight_values.clone()
                },
                closed: s.flags & 1 != 0,
            }
        }
        EntityType::Polyline(p)
            if planar(&p.normal)
                && p.flags & (8 | 16 | 64) == 0
                && p.thickness.abs() < EPS
                && p.default_starting_width.abs() < EPS
                && p.default_ending_width.abs() < EPS =>
        {
            Shape::Polyline {
                vertices: p
                    .vertices()
                    .map(|v| {
                        Ok(Vertex {
                            point: point(&v.location)?,
                            bulge: v.bulge,
                        })
                    })
                    .collect::<Result<_, String>>()?,
                closed: p.flags & 1 != 0,
            }
        }
        EntityType::MText(t) if planar(&t.extrusion_direction) => Shape::Text {
            at: point(&t.insertion_point)?,
            text: plain_mtext(&(t.extended_text.join("") + &t.text)),
            height: t.initial_text_height,
            rotation: t.rotation_angle,
        },
        EntityType::RotatedDimension(d)
            if planar(&d.dimension_base.normal)
                && (d.dimension_base.dimension_type == DimensionType::Aligned
                    || d.rotation_angle.abs() < EPS) =>
        {
            let a = point(&d.definition_point_2)?;
            let b = point(&d.definition_point_3)?;
            let def = point(&d.dimension_base.definition_point_1)?;
            let aligned = d.dimension_base.dimension_type == DimensionType::Aligned;
            let delta = b - a;
            let u = if aligned {
                delta * (1.0 / delta.length().max(EPS))
            } else {
                Point::new(if b.x >= a.x { 1.0 } else { -1.0 }, 0.0)
            };
            Shape::Dimension {
                a,
                b,
                offset: (def - a).dot(Point::new(-u.y, u.x)),
                aligned,
            }
        }
        EntityType::RadialDimension(d) if planar(&d.dimension_base.normal) => {
            Shape::RadialDimension {
                center: point(&d.dimension_base.definition_point_1)?,
                edge: point(&d.definition_point_2)?,
                at: point(&d.dimension_base.text_mid_point)?,
                diameter: false,
            }
        }
        EntityType::DiameterDimension(d) if planar(&d.dimension_base.normal) => {
            let a = point(&d.dimension_base.definition_point_1)?;
            let edge = point(&d.definition_point_2)?;
            Shape::RadialDimension {
                center: (a + edge) * 0.5,
                edge,
                at: point(&d.dimension_base.text_mid_point)?,
                diameter: true,
            }
        }
        EntityType::Line(l) if planar(&l.extrusion_direction) && l.thickness.abs() < EPS => {
            Shape::Line {
                a: point(&l.p1)?,
                b: point(&l.p2)?,
            }
        }
        EntityType::Circle(c) if planar(&c.normal) && c.thickness.abs() < EPS => Shape::Circle {
            center: point(&c.center)?,
            radius: c.radius,
        },
        EntityType::Arc(a) if planar(&a.normal) && a.thickness.abs() < EPS => Shape::Arc {
            center: point(&a.center)?,
            radius: a.radius,
            start: a.start_angle.to_radians(),
            sweep: (a.end_angle - a.start_angle).rem_euclid(360.0).to_radians(),
        },
        EntityType::LwPolyline(p)
            if planar(&p.extrusion_direction)
                && p.thickness.abs() < EPS
                && p.constant_width.abs() < EPS
                && p.vertices
                    .iter()
                    .all(|v| v.starting_width.abs() < EPS && v.ending_width.abs() < EPS) =>
        {
            Shape::Polyline {
                vertices: p
                    .vertices
                    .iter()
                    .map(|v| Vertex {
                        point: Point::new(v.x, v.y),
                        bulge: v.bulge,
                    })
                    .collect(),
                closed: p.flags & 1 != 0,
            }
        }
        EntityType::Text(t) if planar(&t.normal) && t.thickness.abs() < EPS => Shape::Text {
            at: point(&t.location)?,
            text: t.value.clone(),
            height: t.text_height,
            rotation: t.rotation.to_radians(),
        },
        EntityType::Insert(i)
            if planar(&i.extrusion_direction)
                && (i.x_scale_factor - i.y_scale_factor).abs() < EPS
                && i.x_scale_factor > EPS
                && i.column_count <= 1
                && i.row_count <= 1 =>
        {
            Shape::Insert {
                block: i.name.clone(),
                at: point(&i.location)?,
                scale: i.x_scale_factor,
                rotation: i.rotation.to_radians(),
            }
        }
        _ => return Err("unsupported entity, 3D/OCS geometry, width, or insert transform".into()),
    };
    s.validate()?;
    Ok(s)
}

pub fn import_dxf(path: &Path) -> Result<(Document, Vec<String>), String> {
    if std::fs::metadata(path).map_err(|e| e.to_string())?.len() > 128 * 1024 * 1024 {
        return Err("DXF exceeds the alpha's 128 MiB import limit".into());
    }
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    let (bytes, preview_omitted) = prepare_ascii_dxf(&bytes)?;
    let drawing =
        Drawing::load(&mut bytes.as_slice()).map_err(|e| format!("DXF parse failed: {e}"))?;
    let mut doc = Document::default();
    let mut warnings = BTreeSet::new();
    if preview_omitted {
        warnings.insert(
            "Embedded DXF preview thumbnail omitted; drawing geometry is imported separately."
                .into(),
        );
    }
    warnings.insert("DXF subset import: layouts, custom objects, external references, font/annotation styles, attributes and application data are not preserved. MTEXT formatting is simplified. Review against the original drawing.".to_string());
    // Header units are assigned below; no geometry rescaling is performed.
    doc.units=match drawing.header.default_drawing_units {Units::Millimeters=>"mm",Units::Centimeters=>"cm",Units::Meters=>"m",Units::Inches=>"in",Units::Feet=>"ft",_=>{warnings.insert("Missing/unsupported units interpreted as millimeters; verify UNITS before plotting.".into());"mm"}}.into();
    for l in drawing.layers() {
        if l.name == "0" {
            doc.layers[0].color = aci(l.color.index().unwrap_or(7));
            doc.layers[0].visible = l.is_layer_on;
            doc.layers[0].line_type = canonical_line_type(&l.line_type_name).into();
            doc.layers[0].line_weight = if l.line_weight.raw_value() >= 0 {
                l.line_weight.raw_value() as f32 / 100.0
            } else {
                0.25
            };
            continue;
        }
        if !l.name.is_empty() && doc.layer(&l.name).is_none() {
            doc.layers.push(Layer {
                name: l.name.clone(),
                color: aci(l.color.index().unwrap_or(7)),
                visible: l.is_layer_on,
                locked: false,
                line_type: canonical_line_type(&l.line_type_name).into(),
                line_weight: if l.line_weight.raw_value() >= 0 {
                    l.line_weight.raw_value() as f32 / 100.0
                } else {
                    0.25
                },
            });
        }
    }
    for block in drawing.blocks() {
        if block.name.starts_with('*') {
            continue;
        }
        if block.is_xref() || !block.xref_path_name.is_empty() {
            warnings.insert(format!("External reference not imported: {}", block.name));
            continue;
        }
        let base = point(&block.base_point)?;
        let mut shapes = Vec::new();
        for e in &block.entities {
            match from_entity(e) {
                Ok(s) => shapes.push(s.transformed(Transform::translation(base * -1.0))),
                Err(w) => {
                    warnings.insert(format!("Block {}: {w}", block.name));
                }
            }
        }
        doc.blocks.insert(block.name.clone(), shapes);
    }
    let mut skipped = 0;
    for e in drawing.entities() {
        match from_entity(e) {
            Ok(shape) => {
                if doc.layer(&e.common.layer).is_none() {
                    doc.layers
                        .push(Layer::new(&e.common.layer, [0.8, 0.85, 0.9, 1.0]));
                }
                doc.current_layer = e.common.layer.clone();
                let id = doc.insert(shape);
                let color = if e.common.color_24_bit != 0 || e.common.color.is_by_entity() {
                    let n = e.common.color_24_bit as u32;
                    Some([
                        ((n >> 16) & 255) as f32 / 255.0,
                        ((n >> 8) & 255) as f32 / 255.0,
                        (n & 255) as f32 / 255.0,
                        1.0,
                    ])
                } else {
                    e.common.color.index().map(aci)
                };
                doc.entities.get_mut(&id).unwrap().style = EntityStyle {
                    color,
                    line_type: if ["BYLAYER", "BYBLOCK"]
                        .contains(&e.common.line_type_name.to_ascii_uppercase().as_str())
                    {
                        None
                    } else {
                        Some(canonical_line_type(&e.common.line_type_name).into())
                    },
                    line_weight: if e.common.lineweight_enum_value >= 0 {
                        Some(e.common.lineweight_enum_value as f32 / 100.0)
                    } else {
                        None
                    },
                };
            }
            Err(reason) => {
                skipped += 1;
                warnings.insert(reason);
            }
        }
    }
    // Missing references cannot be rendered faithfully. Diagnose and remove them;
    // cyclic graphs are rejected by Document::validate instead of being truncated.
    let known: BTreeSet<_> = doc.blocks.keys().cloned().collect();
    let missing = |s: &Shape| matches!(s,Shape::Insert {block,..} if !known.contains(block));
    doc.entities.retain(|_, e| {
        if missing(&e.shape) {
            skipped += 1;
            false
        } else {
            true
        }
    });
    for shapes in doc.blocks.values_mut() {
        shapes.retain(|s| {
            if missing(s) {
                skipped += 1;
                false
            } else {
                true
            }
        });
    }
    if skipped > 0 {
        warnings.insert(format!(
            "{skipped} entities/references omitted from this import."
        ));
    }
    doc.current_layer = "0".into();
    doc.validate()?;
    Ok((doc, warnings.into_iter().collect()))
}

/// Previews are optional metadata, not drawing entities. LibreDWG can emit PNG
/// preview data while dxf-rs assumes DIB/BMP. Skip the complete ASCII preview
/// section before decoding, preserving every other byte (including text encoding).
/// Normalize unsigned decimal spellings of 32-bit color/flag metadata to the
/// identical signed bit pattern expected by dxf-rs. Binary DXF passes unchanged.
fn prepare_ascii_dxf(bytes: &[u8]) -> Result<(Vec<u8>, bool), String> {
    if bytes.starts_with(b"AutoCAD Binary DXF") || bytes.starts_with(b"AutoCAD DXB") {
        return Ok((bytes.to_vec(), false));
    }
    fn trim(b: &[u8]) -> &[u8] {
        b.trim_ascii()
    }
    let mut lines = bytes.split_inclusive(|b| *b == b'\n');
    let mut output = Vec::with_capacity(bytes.len());
    let mut pending_section = false;
    let mut skip = false;
    let mut omitted = false;
    while let Some(code) = lines.next() {
        let Some(value) = lines.next() else {
            // Let the decoder diagnose a truncated final pair outside metadata.
            if skip {
                return Err("Unterminated DXF preview section".into());
            }
            output.extend_from_slice(code);
            break;
        };
        if pending_section {
            pending_section = false;
            if trim(code) == b"2" && trim(value) == b"THUMBNAILIMAGE" {
                skip = true;
                omitted = true;
                continue;
            }
            output.extend_from_slice(b"0\nSECTION\n");
        }
        if skip {
            if trim(code) == b"0" {
                if trim(value) != b"ENDSEC" {
                    return Err("Malformed DXF preview section".into());
                }
                skip = false;
            }
            continue;
        }
        if trim(code) == b"0" && trim(value) == b"SECTION" {
            pending_section = true;
        } else {
            output.extend_from_slice(code);
            let group = std::str::from_utf8(trim(code))
                .ok()
                .and_then(|s| s.parse::<i32>().ok());
            if matches!(group, Some(420..=429 | 440..=459)) {
                if let Some(n) = std::str::from_utf8(trim(value))
                    .ok()
                    .and_then(|s| s.parse::<u32>().ok())
                    .filter(|n| *n > i32::MAX as u32)
                {
                    output.extend_from_slice(format!("{}\n", n as i32).as_bytes());
                    continue;
                }
            }
            output.extend_from_slice(value);
        }
    }
    if skip || pending_section {
        return Err("Unterminated DXF section".into());
    }
    Ok((output, omitted))
}

fn to_entity(s: &Shape) -> Option<entities::Entity> {
    let specific = match s {
        Shape::Point { at } => EntityType::ModelPoint(entities::ModelPoint {
            location: dpoint(*at),
            ..Default::default()
        }),
        Shape::Ellipse {
            center,
            major,
            ratio,
            start,
            sweep,
        } => {
            let (a, b) = if *sweep >= 0.0 {
                (*start, *start + *sweep)
            } else {
                (*start + *sweep, *start)
            };
            EntityType::Ellipse(entities::Ellipse {
                center: dpoint(*center),
                major_axis: dxf::Vector::new(major.x, major.y, 0.0),
                minor_axis_ratio: *ratio,
                start_parameter: a,
                end_parameter: b,
                ..Default::default()
            })
        }
        Shape::Spline {
            degree,
            control_points,
            knots,
            weights,
            closed,
        } => EntityType::Spline(entities::Spline {
            degree_of_curve: *degree as i32,
            control_points: control_points.iter().map(|p| dpoint(*p)).collect(),
            knot_values: knots.clone(),
            weight_values: weights.clone(),
            flags: if *closed { 5 } else { 4 },
            ..Default::default()
        }),
        Shape::Line { a, b } => EntityType::Line(entities::Line {
            p1: dpoint(*a),
            p2: dpoint(*b),
            ..Default::default()
        }),
        Shape::Circle { center, radius } => EntityType::Circle(entities::Circle {
            center: dpoint(*center),
            radius: *radius,
            ..Default::default()
        }),
        Shape::Arc {
            center,
            radius,
            start,
            sweep,
        } => {
            let (a, b) = if *sweep >= 0.0 {
                (*start, *start + *sweep)
            } else {
                (*start + *sweep, *start)
            };
            EntityType::Arc(entities::Arc {
                center: dpoint(*center),
                radius: *radius,
                start_angle: a.to_degrees().rem_euclid(360.0),
                end_angle: b.to_degrees().rem_euclid(360.0),
                ..Default::default()
            })
        }
        Shape::Polyline { vertices, closed } => EntityType::LwPolyline(entities::LwPolyline {
            flags: if *closed { 1 } else { 0 },
            vertices: vertices
                .iter()
                .map(|v| dxf::LwPolylineVertex {
                    x: v.point.x,
                    y: v.point.y,
                    bulge: v.bulge,
                    ..Default::default()
                })
                .collect(),
            ..Default::default()
        }),
        Shape::Text {
            at,
            text,
            height,
            rotation,
        } if text.contains('\n') => EntityType::MText(entities::MText {
            insertion_point: dpoint(*at),
            text: text.replace('\n', "\\P"),
            initial_text_height: *height,
            rotation_angle: *rotation,
            ..Default::default()
        }),
        Shape::Text {
            at,
            text,
            height,
            rotation,
        } => EntityType::Text(entities::Text {
            location: dpoint(*at),
            value: text.clone(),
            text_height: *height,
            rotation: rotation.to_degrees(),
            ..Default::default()
        }),
        Shape::Insert {
            block,
            at,
            scale,
            rotation,
        } => EntityType::Insert(entities::Insert {
            name: block.clone(),
            location: dpoint(*at),
            x_scale_factor: *scale,
            y_scale_factor: *scale,
            z_scale_factor: *scale,
            rotation: rotation.to_degrees(),
            ..Default::default()
        }),
        _ => return None,
    };
    Some(entities::Entity::new(specific))
}
fn export_shape(
    doc: &Document,
    drawing: &mut Drawing,
    s: &Shape,
    layer: &str,
    style: &EntityStyle,
    warnings: &mut BTreeSet<String>,
) {
    if let Some(mut e) = to_entity(s) {
        e.common.layer = layer.into();
        if let Some(c) = style.color {
            e.common.color = dxf::Color::by_entity();
            e.common.color_24_bit = (((c[0] * 255.0).round() as i32) << 16)
                | (((c[1] * 255.0).round() as i32) << 8)
                | ((c[2] * 255.0).round() as i32);
        }
        if let Some(s) = &style.line_type {
            e.common.line_type_name = s.to_ascii_uppercase();
        }
        if let Some(w) = style.line_weight {
            e.common.lineweight_enum_value = (w * 100.0).round() as i16;
        }
        drawing.add_entity(e);
    } else {
        warnings.insert("Dimensions, leaders and hatches exported as visible lines/text; their editing semantics and solid fills are not retained.".into());
        let batch = entity_geometry(
            doc,
            &Entity {
                id: 0,
                layer: layer.into(),
                style: Default::default(),
                shape: s.clone(),
            },
            0.1,
        );
        for line in batch.segments {
            if let Some(mut e) = to_entity(&Shape::Line {
                a: Point::new(line.ax, line.ay),
                b: Point::new(line.bx, line.by),
            }) {
                e.common.layer = layer.into();
                drawing.add_entity(e);
            }
        }
        for label in batch.labels {
            if let Some(mut e) = to_entity(&Shape::Text {
                at: label.at,
                text: label.text,
                height: label.height,
                rotation: label.rotation,
            }) {
                e.common.layer = layer.into();
                drawing.add_entity(e);
            }
        }
    }
}
pub fn export_dxf(doc: &Document, path: &Path) -> Result<Vec<String>, String> {
    if !path
        .extension()
        .is_some_and(|e| e.eq_ignore_ascii_case("dxf"))
    {
        return Err("DXF export requires a .dxf destination; DWG writing is not supported".into());
    }
    doc.validate()?;
    let mut drawing = Drawing::new();
    drawing.header.version = AcadVersion::R2013;
    drawing.header.default_drawing_units = match doc.units.as_str() {
        "cm" => Units::Centimeters,
        "m" => Units::Meters,
        "in" => Units::Inches,
        "ft" => Units::Feet,
        _ => Units::Millimeters,
    };
    let mut warnings = BTreeSet::new();
    warnings.insert(
        "DXF layer colors are approximated to indexed colors; layer locking is not exported."
            .into(),
    );
    for (name, pattern) in [
        ("DASHED", vec![240.0, -100.0]),
        ("HIDDEN", vec![120.0, -60.0]),
        ("CENTER", vec![400.0, -80.0, 60.0, -80.0]),
        ("DOTTED", vec![10.0, -80.0]),
    ] {
        let unit = match doc.units.as_str() {
            "cm" => 0.1,
            "m" => 0.001,
            "in" => 1.0 / 25.4,
            "ft" => 1.0 / 304.8,
            _ => 1.0,
        };
        let pattern: Vec<f64> = pattern.into_iter().map(|v| v * unit).collect();
        drawing.add_line_type(dxf::tables::LineType {
            name: name.into(),
            description: format!("MacCAD {name}"),
            element_count: pattern.len() as i32,
            total_pattern_length: pattern.iter().map(|v| v.abs()).sum(),
            dash_dot_space_lengths: pattern,
            ..Default::default()
        });
    }
    for l in &doc.layers {
        let palette = [1, 2, 3, 4, 5, 6, 7, 8, 9];
        let index = *palette
            .iter()
            .min_by(|&&a, &&b| {
                let dist = |idx| {
                    let c = aci(idx);
                    (c[0] - l.color[0]).powi(2)
                        + (c[1] - l.color[1]).powi(2)
                        + (c[2] - l.color[2]).powi(2)
                };
                dist(a).total_cmp(&dist(b))
            })
            .unwrap();
        let layer = dxf::tables::Layer {
            name: l.name.clone(),
            color: dxf::Color::from_index(index),
            is_layer_on: l.visible,
            line_type_name: l.line_type.to_ascii_uppercase(),
            // dxf-rs exposes its raw constructor only through the public serde
            // representation. The dependency is pinned and covered by exchange tests.
            line_weight: serde_json::from_value(
                serde_json::json!({"raw_value": (l.line_weight*100.0).round() as i16}),
            )
            .map_err(|e| e.to_string())?,
            ..Default::default()
        };
        let exists = drawing.layers().any(|existing| existing.name == l.name);
        if exists {
            let existing = drawing
                .layers_mut()
                .find(|existing| existing.name == l.name)
                .unwrap();
            existing.color = layer.color;
            existing.is_layer_on = layer.is_layer_on;
            existing.line_type_name = layer.line_type_name;
            existing.line_weight = layer.line_weight;
        } else {
            drawing.add_layer(layer);
        }
    }
    for (name, shapes) in &doc.blocks {
        let mut holder = Drawing::new();
        for s in shapes {
            export_shape(
                doc,
                &mut holder,
                s,
                "0",
                &EntityStyle::default(),
                &mut warnings,
            );
        }
        let block = dxf::Block {
            name: name.clone(),
            entities: holder.entities().cloned().collect(),
            ..Default::default()
        };
        drawing.add_block(block);
    }
    for e in doc.entities.values() {
        export_shape(
            doc,
            &mut drawing,
            &e.shape,
            &e.layer,
            &e.style,
            &mut warnings,
        );
    }
    // Same-directory temporary + rename: a failed export cannot truncate a file.
    let parent = path.parent().unwrap_or(Path::new("."));
    let temp = parent.join(format!(
        ".maccad-{}-{}.tmp",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|e| e.to_string())?
            .as_nanos()
    ));
    let result = (|| {
        let mut file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temp)
            .map_err(|e| e.to_string())?;
        drawing.save(&mut file).map_err(|e| e.to_string())?;
        file.flush().map_err(|e| e.to_string())?;
        file.sync_all().map_err(|e| e.to_string())?;
        std::fs::rename(&temp, path).map_err(|e| e.to_string())
    })();
    if result.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    result?;
    Ok(warnings.into_iter().collect())
}
fn canonical_line_type(s: &str) -> &'static str {
    match s.to_ascii_uppercase().as_str() {
        "DASHED" => "Dashed",
        "HIDDEN" => "Hidden",
        "CENTER" => "Center",
        "DOTTED" => "Dotted",
        _ => "Continuous",
    }
}
fn plain_mtext(s: &str) -> String {
    let mut out = String::new();
    let mut chars = s.chars().peekable();
    while let Some(c) = chars.next() {
        match c {
            '{' | '}' => {}
            '\\' => {
                if let Some(code) = chars.next() {
                    match code {
                        'P' => out.push('\n'),
                        '\\' | '{' | '}' => out.push(code),
                        '~' => out.push(' '),
                        'L' | 'l' | 'O' | 'o' | 'K' | 'k' => {}
                        _ => {
                            while chars.peek().is_some_and(|c| *c != ';') {
                                chars.next();
                            }
                            if chars.peek() == Some(&';') {
                                chars.next();
                            }
                        }
                    }
                }
            }
            _ => out.push(c),
        }
    }
    out
}
fn aci(index: u8) -> [f32; 4] {
    match index {
        1 => [0.95, 0.25, 0.25, 1.0],
        2 => [1.0, 0.85, 0.2, 1.0],
        3 => [0.3, 0.85, 0.5, 1.0],
        4 => [0.25, 0.8, 0.9, 1.0],
        5 => [0.3, 0.5, 1.0, 1.0],
        6 => [0.8, 0.4, 0.9, 1.0],
        8 => [0.4, 0.4, 0.4, 1.0],
        9 => [0.65, 0.65, 0.65, 1.0],
        _ => [0.8, 0.85, 0.9, 1.0],
    }
}
