//! Explicitly limited 2D exchange adapter. Native files preserve editing semantics;
//! DXF export flattens annotations/hatches and reports that conversion to callers.
use crate::{
    geometry::{Point, Transform, EPS},
    model::{Document, Entity, Layer, Shape, Vertex},
    render::entity_batch,
};
use dxf::{
    entities::{self, EntityType},
    enums::{AcadVersion, Units},
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
    let drawing = Drawing::load_file(path).map_err(|e| format!("DXF parse failed: {e}"))?;
    let mut doc = Document::default();
    let mut warnings = BTreeSet::new();
    warnings.insert("DXF subset import: layouts, custom objects, external references, fonts, styles, entity colors/linetypes/lineweights, attributes and application data are not preserved. Review against the original drawing.".to_string());
    // Header units are assigned below; no geometry rescaling is performed.
    doc.units=match drawing.header.default_drawing_units {Units::Millimeters=>"mm",Units::Centimeters=>"cm",Units::Meters=>"m",Units::Inches=>"in",Units::Feet=>"ft",_=>{warnings.insert("Missing/unsupported units interpreted as millimeters; verify UNITS before plotting.".into());"mm"}}.into();
    for l in drawing.layers() {
        if l.name == "0" {
            doc.layers[0].visible = l.is_layer_on;
            continue;
        }
        if !l.name.is_empty() && doc.layer(&l.name).is_none() {
            doc.layers.push(Layer {
                name: l.name.clone(),
                color: aci(l.color.index().unwrap_or(7)),
                visible: l.is_layer_on,
                locked: false,
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
                doc.insert(shape);
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

fn to_entity(s: &Shape) -> Option<entities::Entity> {
    let specific = match s {
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
    warnings: &mut BTreeSet<String>,
) {
    if let Some(mut e) = to_entity(s) {
        e.common.layer = layer.into();
        drawing.add_entity(e);
    } else {
        warnings.insert("Dimensions and hatches exported as visible lines/text; their editing semantics and solid fills are not retained.".into());
        let batch = entity_batch(
            doc,
            &Entity {
                id: 0,
                layer: layer.into(),
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
        drawing.add_layer(dxf::tables::Layer {
            name: l.name.clone(),
            color: dxf::Color::from_index(index),
            is_layer_on: l.visible,
            ..Default::default()
        });
    }
    for (name, shapes) in &doc.blocks {
        let mut holder = Drawing::new();
        for s in shapes {
            export_shape(doc, &mut holder, s, "0", &mut warnings);
        }
        let block = dxf::Block {
            name: name.clone(),
            entities: holder.entities().cloned().collect(),
            ..Default::default()
        };
        drawing.add_block(block);
    }
    for e in doc.entities.values() {
        export_shape(doc, &mut drawing, &e.shape, &e.layer, &mut warnings);
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
