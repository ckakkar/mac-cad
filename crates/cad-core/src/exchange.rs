//! Explicitly limited 2D exchange adapter. Native files preserve editing semantics;
//! DXF export flattens annotations/hatches and reports that conversion to callers.
use crate::{
    dxfread::aci,
    geometry::Point,
    model::{Document, Entity, EntityStyle, Shape},
    render::entity_geometry,
};
use dxf::{
    entities::{self, EntityType},
    enums::{AcadVersion, Units},
    Drawing,
};
use std::{collections::BTreeSet, io::Write, path::Path};

fn dpoint(p: Point) -> dxf::Point {
    dxf::Point::new(p.x, p.y, 0.0)
}
/// Reads DXF with MacCAD's own reader; see `dxfread`.
pub fn import_dxf(path: &Path) -> Result<(Document, Vec<String>), String> {
    crate::dxfread::read(path)
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
                    starting_width: v.start_width,
                    ending_width: v.end_width,
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
            format,
        } if text.contains('\n') || format.attachment > 0 => EntityType::MText(entities::MText {
            insertion_point: dpoint(*at),
            text: text.replace('\n', "\\P"),
            initial_text_height: *height,
            rotation_angle: *rotation,
            reference_rectangle_width: format.wrap,
            attachment_point: match format.attachment {
                2 => dxf::enums::AttachmentPoint::TopCenter,
                3 => dxf::enums::AttachmentPoint::TopRight,
                4 => dxf::enums::AttachmentPoint::MiddleLeft,
                5 => dxf::enums::AttachmentPoint::MiddleCenter,
                6 => dxf::enums::AttachmentPoint::MiddleRight,
                7 => dxf::enums::AttachmentPoint::BottomLeft,
                8 => dxf::enums::AttachmentPoint::BottomCenter,
                9 => dxf::enums::AttachmentPoint::BottomRight,
                _ => dxf::enums::AttachmentPoint::TopLeft,
            },
            text_style_name: if format.style.is_empty() {
                "STANDARD".into()
            } else {
                format.style.clone()
            },
            ..Default::default()
        }),
        Shape::Text {
            at,
            text,
            height,
            rotation,
            format,
        } => EntityType::Text(entities::Text {
            location: dpoint(*at),
            value: text.clone(),
            text_height: *height,
            rotation: rotation.to_degrees(),
            relative_x_scale_factor: format.width_factor,
            oblique_angle: format.oblique.to_degrees(),
            text_style_name: if format.style.is_empty() {
                "STANDARD".into()
            } else {
                format.style.clone()
            },
            ..Default::default()
        }),
        Shape::Insert {
            block,
            at,
            scale,
            rotation,
            y_scale,
            ..
        } => EntityType::Insert(entities::Insert {
            name: block.clone(),
            location: dpoint(*at),
            x_scale_factor: *scale,
            y_scale_factor: y_scale.unwrap_or(*scale),
            z_scale_factor: scale.abs(),
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
        // -1 is ByLayer; dxf-rs otherwise defaults to an explicit 0.00 mm.
        e.common.lineweight_enum_value =
            style.line_weight.map_or(-1, |w| (w * 100.0).round() as i16);
        drawing.add_entity(e);
        // Attribute values travel as text beside the reference, which keeps
        // them visible without ATTDEF/ATTRIB support in the writer.
        if let Shape::Insert { attributes, .. } = s {
            let visible: Vec<_> = attributes.iter().filter(|a| !a.invisible).collect();
            if !attributes.is_empty() {
                warnings.insert("Block attribute values exported as plain text; tags and editing are not retained.".into());
            }
            for a in visible {
                let text = Shape::Text {
                    at: a.at,
                    text: a.text.clone(),
                    height: a.height,
                    rotation: a.rotation,
                    format: a.format.clone(),
                };
                export_shape(doc, drawing, &text, layer, style, warnings);
            }
        }
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
            if let Some(mut e) = to_entity(&Shape::text(
                label.at,
                label.text,
                label.height,
                label.rotation,
            )) {
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
        if doc.linetypes.keys().any(|k| k.eq_ignore_ascii_case(name)) {
            continue;
        }
        drawing.add_line_type(dxf::tables::LineType {
            name: name.into(),
            description: format!("MacCAD {name}"),
            element_count: pattern.len() as i32,
            total_pattern_length: pattern.iter().map(|v| v.abs()).sum(),
            dash_dot_space_lengths: pattern,
            ..Default::default()
        });
    }
    for (name, def) in &doc.linetypes {
        drawing.add_line_type(dxf::tables::LineType {
            name: name.clone(),
            description: def.description.clone(),
            element_count: def.pattern.len() as i32,
            total_pattern_length: def.pattern.iter().map(|v| v.abs()).sum(),
            dash_dot_space_lengths: def.pattern.clone(),
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
    for (name, block_entities) in doc.blocks.iter() {
        let mut holder = Drawing::new();
        for e in block_entities {
            export_shape(
                doc,
                &mut holder,
                &e.shape,
                e.layer.as_deref().unwrap_or("0"),
                &e.style,
                &mut warnings,
            );
        }
        let mut block = dxf::Block {
            name: name.clone(),
            entities: holder.entities().cloned().collect(),
            ..Default::default()
        };
        // Dimension and other generated blocks (*D1, *U2) are anonymous.
        block.set_is_anonymous(name.starts_with('*'));
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
