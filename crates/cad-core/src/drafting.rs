//! Drafting operations shared by menus, tool palettes, scripts and numeric input.
use crate::{
    commands::{parse_number, parse_point, Engine, Settings},
    curves::{arc_through, clamped_knots, offset_polyline, polyline_edges},
    geometry::{intersection, Bounds, Point, Transform, EPS},
    model::{Document, Entity, Shape, Vertex},
    render::entity_geometry,
};
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    f64::consts::{PI, TAU},
};

impl Engine {
    pub(crate) fn drafting_dispatch(&mut self, v: &Value) -> Option<Result<Value, String>> {
        let op = v["op"].as_str()?;
        if ![
            "select_window",
            "properties",
            "measure",
            "clipboard",
            "paste",
        ]
        .contains(&op)
        {
            return None;
        }
        Some((|| match op {
            "select_window" => {
                let b: Bounds =
                    serde_json::from_value(v["bounds"].clone()).map_err(|e| e.to_string())?;
                if !b.min.finite() || !b.max.finite() || b.min.x > b.max.x || b.min.y > b.max.y {
                    return Err("Invalid selection window".into());
                }
                let crossing = v["crossing"].as_bool().unwrap_or(false);
                let hits: Vec<_> = self
                    .ids_in(b)
                    .into_iter()
                    .filter(|id| {
                        let e = &self.doc.entities[id];
                        if !self.editable(e) {
                            return false;
                        }
                        if let Some(bb) = crate::render::entity_bounds(&self.doc, e) {
                            if b.contains(bb.min) && b.contains(bb.max) {
                                return true;
                            }
                            if !crossing {
                                return false;
                            }
                            let batch = entity_geometry(&self.doc, e, 0.05);
                            if batch.labels.iter().any(|_| {
                                bb.min.x <= b.max.x
                                    && bb.max.x >= b.min.x
                                    && bb.min.y <= b.max.y
                                    && bb.max.y >= b.min.y
                            }) {
                                return true;
                            }
                            return batch.segments.iter().any(|s| {
                                segment_hits_box(Point::new(s.ax, s.ay), Point::new(s.bx, s.by), b)
                            });
                        }
                        false
                    })
                    .collect();
                if !v["extend"].as_bool().unwrap_or(false) {
                    self.selected.clear();
                }
                self.selected.extend(hits);
                Ok(self.state())
            }
            "properties" => {
                let mut after = self.selection()?;
                if v["geometry"].is_object() && after.len() != 1 {
                    return Err("Edit geometry one object at a time".into());
                }
                for e in &mut after {
                    if let Some(layer) = v["layer"].as_str() {
                        if !self
                            .doc
                            .layer(layer)
                            .is_some_and(|l| l.visible && !l.locked)
                        {
                            return Err("Destination layer must be visible and unlocked".into());
                        }
                        e.layer = layer.into();
                    }
                    if let Some(style) = v.get("style") {
                        e.style =
                            serde_json::from_value(style.clone()).map_err(|e| e.to_string())?;
                    }
                    if let Some(patch) = v["geometry"].as_object() {
                        let mut shape =
                            serde_json::to_value(&e.shape).map_err(|e| e.to_string())?;
                        for (key, value) in patch {
                            if key == "kind" || shape.get(key).is_none() {
                                return Err(format!("Unsupported property: {key}"));
                            }
                            shape[key] = value.clone();
                        }
                        e.shape = serde_json::from_value(shape).map_err(|e| e.to_string())?;
                    }
                }
                self.commit(after, Vec::new(), None)?;
                Ok(self.state())
            }
            "measure" => {
                if let Some(points) = v["points"].as_array() {
                    let points: Vec<Point> = points
                        .iter()
                        .map(|p| serde_json::from_value(p.clone()).map_err(|e| e.to_string()))
                        .collect::<Result<_, _>>()?;
                    if points.len() < 2 || points.iter().any(|p| !p.finite()) {
                        return Err("Pick at least two finite points".into());
                    }
                    let distance: f64 = points.windows(2).map(|p| p[0].distance(p[1])).sum();
                    let area = if points.len() > 2 {
                        signed_area(&points).abs()
                    } else {
                        0.0
                    };
                    return Ok(
                        json!({"length":distance,"area":area,"units":self.doc.units,"bounds":Bounds::from_points(&points)}),
                    );
                }
                let source = self.selection()?;
                let mut length = 0.0;
                let mut area = 0.0;
                for e in &source {
                    let (l, a) = metrics(&self.doc, e);
                    length += l;
                    area += a;
                }
                Ok(
                    json!({"length":length,"area":area,"count":source.len(),"units":self.doc.units,"bounds":source.iter().filter_map(|e|crate::render::entity_bounds(&self.doc,e)).reduce(|a,b|a.union(b))}),
                )
            }
            "clipboard" => {
                let entities = self.selection()?;
                let mut d = self.doc.clone();
                d.entities = entities.into_iter().map(|e| (e.id, e)).collect();
                serde_json::to_value(d).map_err(|e| e.to_string())
            }
            "paste" => {
                let source: Document =
                    serde_json::from_value(v["document"].clone()).map_err(|e| e.to_string())?;
                source.validate()?;
                let at: Point =
                    serde_json::from_value(v["at"].clone()).map_err(|e| e.to_string())?;
                if !at.finite() {
                    return Err("Invalid paste displacement".into());
                }
                let mut settings = Settings::of(&self.doc);
                let mut names = BTreeMap::new();
                for name in source.blocks.keys() {
                    let mut target = name.clone();
                    let mut n = 1;
                    while settings.blocks.contains_key(&target)
                        || names.values().any(|v| v == &target)
                    {
                        target = format!("{name}_{n}");
                        n += 1;
                    }
                    names.insert(name.clone(), target);
                }
                let remap = |s: &Shape| {
                    let mut s = s.clone();
                    if let Shape::Insert { block, .. } = &mut s {
                        *block = names.get(block).unwrap_or(block).clone();
                    }
                    s
                };
                for (name, shapes) in &source.blocks {
                    settings
                        .blocks
                        .insert(names[name].clone(), shapes.iter().map(remap).collect());
                }
                for l in &source.layers {
                    if !settings.layers.iter().any(|v| v.name == l.name) {
                        let mut l = l.clone();
                        l.locked = false;
                        l.visible = true;
                        settings.layers.push(l);
                    }
                }
                let mut after = Vec::new();
                for (i, e) in source.entities.values().enumerate() {
                    let mut e = e.clone();
                    e.id = self.doc.next_id + i as u64;
                    e.shape = remap(&e.shape).transformed(Transform::translation(at));
                    if !settings
                        .layers
                        .iter()
                        .find(|l| l.name == e.layer)
                        .is_some_and(|l| l.visible && !l.locked)
                    {
                        e.layer = self.doc.current_layer.clone();
                    }
                    after.push(e);
                }
                let ids = after.iter().map(|e| e.id).collect();
                self.commit(after, Vec::new(), Some(settings))?;
                self.selected = ids;
                Ok(self.state())
            }
            _ => unreachable!(),
        })())
    }
    pub(crate) fn drafting_command(&mut self, text: &str) -> Option<Result<(), String>> {
        let tokens: Vec<_> = text.split_whitespace().collect();
        let name = tokens.first()?.to_ascii_uppercase();
        let args = &tokens[1..];
        if ![
            "POINT",
            "PO",
            "ELLIPSE",
            "EL",
            "SPLINE",
            "SPL",
            "POLYGON",
            "POL",
            "ARC3",
            "DIMRADIUS",
            "DIMDIAMETER",
            "LEADER",
            "MLEADER",
            "MTEXT",
            "MT",
            "ARRAYRECT",
            "ARRAYPOLAR",
            "AR",
            "JOIN",
            "J",
            "BREAK",
            "BR",
            "REVERSE",
            "CLOSE",
            "OPEN",
            "STRETCH",
            "S",
            "FILLET",
            "F",
            "CHAMFER",
            "CHA",
            "OVERKILL",
            "PURGE",
            "SELECTSIMILAR",
            "LAYISO",
            "LAYUNISO",
            "LAYOFF",
            "LAYON",
            "LAYLOCK",
            "LAYUNLOCK",
            "LAYMCUR",
            "CHPROP",
            "MATCHPROP",
            "MA",
            "OFFSET",
            "O",
            "EXPLODE",
        ]
        .contains(&name.as_str())
        {
            return None;
        }
        Some((|| {
            let point = |i: usize| parse_point(args.get(i).ok_or("Missing coordinate (x,y)")?);
            let num = |i: usize| parse_number(args.get(i).ok_or("Missing numeric parameter")?);
            let shape = match name.as_str() {
                "POINT" | "PO" => Some(Shape::Point { at: point(0)? }),
                "ELLIPSE" | "EL" => {
                    let center = point(0)?;
                    Some(Shape::Ellipse {
                        center,
                        major: point(1)? - center,
                        ratio: num(2)?,
                        start: 0.0,
                        sweep: TAU,
                    })
                }
                "SPLINE" | "SPL" => {
                    let points = args
                        .iter()
                        .map(|p| parse_point(p))
                        .collect::<Result<Vec<_>, _>>()?;
                    if points.len() < 2 {
                        return Err("SPLINE needs at least two control points".into());
                    }
                    let degree = 3.min(points.len() - 1);
                    Some(Shape::Spline {
                        degree,
                        knots: clamped_knots(points.len(), degree),
                        weights: vec![1.0; points.len()],
                        control_points: points,
                        closed: false,
                    })
                }
                "POLYGON" | "POL" => {
                    let count = num(0)?;
                    if count.fract() != 0.0 || !(3.0..=1024.0).contains(&count) {
                        return Err("Polygon needs 3–1024 sides".into());
                    }
                    let center = point(1)?;
                    let radius = num(2)?;
                    if radius <= EPS {
                        return Err("Radius must be positive".into());
                    }
                    let rotation = if args.len() > 3 {
                        num(3)?.to_radians()
                    } else {
                        0.0
                    };
                    Some(Shape::Polyline {
                        closed: true,
                        vertices: (0..count as usize)
                            .map(|i| {
                                let a = rotation + TAU * i as f64 / count;
                                Vertex {
                                    point: center + Point::new(a.cos(), a.sin()) * radius,
                                    bulge: 0.0,
                                }
                            })
                            .collect(),
                    })
                }
                "ARC3" => Some(arc_through(point(0)?, point(1)?, point(2)?)?),
                "DIMRADIUS" | "DIMDIAMETER" => Some(Shape::RadialDimension {
                    center: point(0)?,
                    edge: point(1)?,
                    at: point(2)?,
                    diameter: name == "DIMDIAMETER",
                }),
                "LEADER" | "MLEADER" => {
                    if args.len() < 4 {
                        return Err("LEADER x,y x,y height text…".into());
                    }
                    Some(Shape::Leader {
                        points: vec![point(0)?, point(1)?],
                        height: num(2)?,
                        text: args[3..].join(" ").replace("\\P", "\n"),
                    })
                }
                "MTEXT" | "MT" => {
                    if args.len() < 3 {
                        return Err("MTEXT x,y height text (\\P starts a new paragraph)".into());
                    }
                    Some(Shape::Text {
                        at: point(0)?,
                        height: num(1)?,
                        rotation: 0.0,
                        text: args[2..].join(" ").replace("\\P", "\n"),
                    })
                }
                _ => None,
            };
            if let Some(s) = shape {
                self.add(vec![s])?;
                return Ok(());
            }
            match name.as_str() {
                "ARRAYRECT" | "AR" => {
                    let rows = positive_count(num(0)?)?;
                    let columns = positive_count(num(1)?)?;
                    let dx = num(2)?;
                    let dy = num(3)?;
                    if rows * columns > 10_000 {
                        return Err("Array exceeds 10k copies".into());
                    }
                    let source = self.selection()?;
                    if source.len() * rows * columns > 100_000 {
                        return Err("Array exceeds 100k generated entities".into());
                    }
                    let mut after = Vec::new();
                    for r in 0..rows {
                        for c in 0..columns {
                            if r == 0 && c == 0 {
                                continue;
                            }
                            for e in &source {
                                let mut e = e.clone();
                                e.id = self.doc.next_id + after.len() as u64;
                                e.shape = e.shape.transformed(Transform::translation(Point::new(
                                    c as f64 * dx,
                                    r as f64 * dy,
                                )));
                                after.push(e);
                            }
                        }
                    }
                    self.commit(after, vec![], None)
                }
                "ARRAYPOLAR" => {
                    let center = point(0)?;
                    let count = positive_count(num(1)?)?;
                    let total = if args.len() > 2 {
                        num(2)?.to_radians()
                    } else {
                        TAU
                    };
                    let source = self.selection()?;
                    if count * source.len() > 100_000 {
                        return Err("Array exceeds 100k entities".into());
                    }
                    let step = total
                        / if (total.abs() - TAU).abs() < EPS {
                            count as f64
                        } else {
                            (count - 1).max(1) as f64
                        };
                    let mut after = Vec::new();
                    for i in 1..count {
                        for e in &source {
                            let mut e = e.clone();
                            e.id = self.doc.next_id + after.len() as u64;
                            e.shape = e.shape.transformed(Transform::rotation(
                                center,
                                step * i as f64,
                                1.0,
                            ));
                            after.push(e);
                        }
                    }
                    self.commit(after, vec![], None)
                }
                "OFFSET" | "O" => {
                    let distance = num(0)?;
                    let mut after = self.selection()?;
                    for (i, e) in after.iter_mut().enumerate() {
                        e.id = self.doc.next_id + i as u64;
                        e.shape =
                            match &e.shape {
                                Shape::Line { a, b } => {
                                    let d = *b - *a;
                                    let n = Point::new(-d.y, d.x) * (distance / d.length());
                                    Shape::Line {
                                        a: *a + n,
                                        b: *b + n,
                                    }
                                }
                                Shape::Circle { center, radius } => Shape::Circle {
                                    center: *center,
                                    radius: radius + distance,
                                },
                                Shape::Arc {
                                    center,
                                    radius,
                                    start,
                                    sweep,
                                } => Shape::Arc {
                                    center: *center,
                                    radius: radius + distance,
                                    start: *start,
                                    sweep: *sweep,
                                },
                                Shape::Polyline { vertices, closed } => {
                                    offset_polyline(vertices, *closed, distance)?
                                }
                                _ => return Err(
                                    "Offset supports lines, circles, arcs and straight polylines"
                                        .into(),
                                ),
                            };
                    }
                    self.commit(after, vec![], None)
                }
                "REVERSE" | "CLOSE" | "OPEN" => {
                    let mut after = self.selection()?;
                    for e in &mut after {
                        match &mut e.shape {
                            Shape::Line { a, b } if name == "REVERSE" => std::mem::swap(a, b),
                            Shape::Polyline { vertices, closed } => {
                                if name == "CLOSE" {
                                    *closed = true;
                                } else if name == "OPEN" {
                                    *closed = false;
                                } else {
                                    let old = vertices.clone();
                                    let n = old.len();
                                    for i in 0..n {
                                        vertices[i].point = old[n - 1 - i].point;
                                        vertices[i].bulge = if *closed {
                                            -old[(n + n - 2 - i) % n].bulge
                                        } else if i + 1 < n {
                                            -old[n - 2 - i].bulge
                                        } else {
                                            0.0
                                        };
                                    }
                                }
                            }
                            Shape::Arc { start, sweep, .. } if name == "REVERSE" => {
                                *start += *sweep;
                                *sweep = -*sweep;
                            }
                            _ => {
                                return Err(
                                    "Operation supports lines/arcs (reverse) and polylines".into()
                                )
                            }
                        }
                    }
                    self.commit(after, vec![], None)
                }
                "JOIN" | "J" => self.join_selected(),
                "BREAK" | "BR" => {
                    let p = point(0)?;
                    let selected = self.selection()?;
                    if selected.len() != 1 {
                        return Err("Select one line to break".into());
                    }
                    let e = &selected[0];
                    let Shape::Line { a, b } = e.shape else {
                        return Err("Break currently supports lines".into());
                    };
                    let q = crate::geometry::nearest_on_segment(p, a, b);
                    if q.distance(p) > 1e-6 || q.distance(a) < EPS || q.distance(b) < EPS {
                        return Err("Break point must lie inside the selected line".into());
                    }
                    let mut first = e.clone();
                    first.shape = Shape::Line { a, b: q };
                    let mut second = e.clone();
                    second.id = self.doc.next_id;
                    second.shape = Shape::Line { a: q, b };
                    self.commit(vec![first, second], vec![], None)
                }
                "STRETCH" | "S" => {
                    let a = point(0)?;
                    let b = point(1)?;
                    let delta = point(2)?;
                    let bounds = Bounds {
                        min: Point::new(a.x.min(b.x), a.y.min(b.y)),
                        max: Point::new(a.x.max(b.x), a.y.max(b.y)),
                    };
                    let mut after = self.selection()?;
                    for e in &mut after {
                        match &mut e.shape {
                            Shape::Line { a, b } => {
                                if bounds.contains(*a) {
                                    *a = *a + delta;
                                }
                                if bounds.contains(*b) {
                                    *b = *b + delta;
                                }
                            }
                            Shape::Polyline { vertices, .. } => {
                                for v in vertices {
                                    if bounds.contains(v.point) {
                                        v.point = v.point + delta;
                                    }
                                }
                            }
                            _ => return Err("Stretch supports line/polyline vertices".into()),
                        }
                    }
                    self.commit(after, vec![], None)
                }
                "FILLET" | "F" => self.corner(num(0)?, None),
                "CHAMFER" | "CHA" => self.corner(num(0)?, Some(num(1)?)),
                "EXPLODE" => {
                    let selected = self.selection()?;
                    let mut after = Vec::new();
                    let mut remove = Vec::new();
                    for e in selected {
                        let shapes =
                            match &e.shape {
                                Shape::Polyline { vertices, closed } => {
                                    polyline_edges(vertices, *closed)
                                }
                                Shape::Insert {
                                    block,
                                    at,
                                    scale,
                                    rotation,
                                } => {
                                    let t = Transform::translation(*at).compose(
                                        Transform::rotation(Point::default(), *rotation, *scale),
                                    );
                                    self.doc.blocks[block]
                                        .iter()
                                        .map(|s| s.transformed(t))
                                        .collect()
                                }
                                Shape::Dimension { .. }
                                | Shape::RadialDimension { .. }
                                | Shape::Leader { .. }
                                | Shape::Hatch { .. } => {
                                    let b = entity_geometry(&self.doc, &e, 0.1);
                                    let mut shapes: Vec<_> = b
                                        .segments
                                        .into_iter()
                                        .map(|s| Shape::Line {
                                            a: Point::new(s.ax, s.ay),
                                            b: Point::new(s.bx, s.by),
                                        })
                                        .collect();
                                    shapes.extend(b.labels.into_iter().map(|l| Shape::Text {
                                        at: l.at,
                                        text: l.text,
                                        height: l.height,
                                        rotation: l.rotation,
                                    }));
                                    shapes
                                }
                                _ => {
                                    return Err(
                                        "Selection contains objects that cannot be exploded".into(),
                                    )
                                }
                            };
                        for shape in shapes {
                            let mut new = e.clone();
                            new.id = self.doc.next_id + after.len() as u64;
                            new.shape = shape;
                            after.push(new);
                        }
                        remove.push(e.id);
                    }
                    self.commit(after, remove, None)
                }
                "SELECTSIMILAR" => {
                    let source = self.selection()?;
                    let matches: Vec<_> = self
                        .doc
                        .entities
                        .values()
                        .filter(|e| {
                            self.editable(e)
                                && source.iter().any(|s| {
                                    s.layer == e.layer
                                        && std::mem::discriminant(&s.shape)
                                            == std::mem::discriminant(&e.shape)
                                })
                        })
                        .map(|e| e.id)
                        .collect();
                    self.selected = matches.into_iter().collect();
                    Ok(())
                }
                "LAYISO" | "LAYUNISO" | "LAYOFF" | "LAYON" | "LAYLOCK" | "LAYUNLOCK"
                | "LAYMCUR" => {
                    let mut settings = Settings::of(&self.doc);
                    let selected = if name == "LAYON" || name == "LAYUNISO" || name == "LAYUNLOCK" {
                        vec![]
                    } else {
                        self.selection()?
                    };
                    let names: Vec<_> = selected.iter().map(|e| e.layer.as_str()).collect();
                    if name == "LAYMCUR" {
                        settings.current_layer = names[0].into();
                    }
                    for l in &mut settings.layers {
                        match name.as_str() {
                            "LAYISO" => l.visible = names.contains(&l.name.as_str()),
                            "LAYON" | "LAYUNISO" => l.visible = true,
                            "LAYOFF" if names.contains(&l.name.as_str()) => l.visible = false,
                            "LAYLOCK" if names.contains(&l.name.as_str()) => l.locked = true,
                            "LAYUNLOCK" => l.locked = false,
                            _ => {}
                        }
                    }
                    self.commit(vec![], vec![], Some(settings))
                }
                "CHPROP" => {
                    let key = args
                        .first()
                        .ok_or("CHPROP layer|color|linetype|lineweight value")?
                        .to_ascii_lowercase();
                    let value = args.get(1).ok_or("Missing property value")?;
                    let mut after = self.selection()?;
                    for e in &mut after {
                        match key.as_str() {
                            "layer" => {
                                if !self
                                    .doc
                                    .layer(value)
                                    .is_some_and(|l| l.visible && !l.locked)
                                {
                                    return Err(
                                        "Destination layer is hidden, locked or missing".into()
                                    );
                                }
                                e.layer = value.to_string();
                            }
                            "linetype" => {
                                e.style.line_type = if value.eq_ignore_ascii_case("bylayer") {
                                    None
                                } else {
                                    Some(value.to_string())
                                }
                            }
                            "lineweight" => {
                                e.style.line_weight = if value.eq_ignore_ascii_case("bylayer") {
                                    None
                                } else {
                                    Some(parse_number(value)? as f32)
                                }
                            }
                            "color" => {
                                e.style.color = if value.eq_ignore_ascii_case("bylayer") {
                                    None
                                } else {
                                    Some(hex_color(value)?)
                                }
                            }
                            _ => return Err("Unknown property".into()),
                        }
                    }
                    self.commit(after, vec![], None)
                }
                "MATCHPROP" | "MA" => {
                    let id = num(0)? as u64;
                    let source = self
                        .doc
                        .entities
                        .get(&id)
                        .ok_or("Source entity not found")?
                        .clone();
                    let mut after = self.selection()?;
                    for e in &mut after {
                        e.layer = source.layer.clone();
                        e.style = source.style.clone();
                    }
                    self.commit(after, vec![], None)
                }
                "OVERKILL" => {
                    let source = self.selection()?;
                    let mut seen = Vec::new();
                    let mut remove = Vec::new();
                    for e in source {
                        if seen.iter().any(|s:&Entity|s.layer==e.layer&&s.shape==e.shape&&s.style==e.style||s.layer==e.layer&&s.style==e.style&&matches!((&s.shape,&e.shape),(Shape::Line {a,b},Shape::Line {a:c,b:d}) if a==d&&b==c)){remove.push(e.id);}else{seen.push(e);}
                    }
                    self.commit(vec![], remove, None)
                }
                "PURGE" => {
                    let mut settings = Settings::of(&self.doc);
                    let mut used = std::collections::BTreeSet::new();
                    for e in self.doc.entities.values() {
                        if let Shape::Insert { block, .. } = &e.shape {
                            used.insert(block.clone());
                        }
                    }
                    loop {
                        let before = used.len();
                        for name in used.clone() {
                            if let Some(shapes) = settings.blocks.get(&name) {
                                for s in shapes {
                                    if let Shape::Insert { block, .. } = s {
                                        used.insert(block.clone());
                                    }
                                }
                            }
                        }
                        if used.len() == before {
                            break;
                        }
                    }
                    settings.blocks.retain(|name, _| used.contains(name));
                    settings.layers.retain(|l| {
                        l.name == "0"
                            || l.name == settings.current_layer
                            || self.doc.entities.values().any(|e| e.layer == l.name)
                    });
                    self.commit(vec![], vec![], Some(settings))
                }
                _ => unreachable!(),
            }
        })())
    }
    fn join_selected(&mut self) -> Result<(), String> {
        let source = self.selection()?;
        if source.len() < 2 {
            return Err("Select at least two connected lines/polylines".into());
        }
        let mut chains = Vec::new();
        for e in &source {
            chains.push(match &e.shape {
                Shape::Line { a, b } => vec![
                    Vertex {
                        point: *a,
                        bulge: 0.0,
                    },
                    Vertex {
                        point: *b,
                        bulge: 0.0,
                    },
                ],
                Shape::Polyline {
                    vertices,
                    closed: false,
                } => vertices.clone(),
                _ => return Err("Join supports open lines/polylines".into()),
            });
        }
        let mut vertices = chains.remove(0);
        while !chains.is_empty() {
            let mut found = None;
            for (i, c) in chains.iter().enumerate() {
                let tail = vertices.last().unwrap().point;
                if tail.distance(c[0].point) < 1e-6 {
                    found = Some((i, false));
                    break;
                }
                if tail.distance(c.last().unwrap().point) < 1e-6 {
                    found = Some((i, true));
                    break;
                }
            }
            let Some((i, reverse)) = found else {
                reverse_vertices(&mut vertices);
                if chains.iter().all(|c| {
                    vertices.last().unwrap().point.distance(c[0].point) > 1e-6
                        && vertices
                            .last()
                            .unwrap()
                            .point
                            .distance(c.last().unwrap().point)
                            > 1e-6
                }) {
                    return Err("Selected objects do not form one endpoint-connected chain".into());
                }
                continue;
            };
            let mut c = chains.remove(i);
            if reverse {
                reverse_vertices(&mut c);
            }
            vertices.last_mut().unwrap().bulge = c[0].bulge;
            vertices.extend(c.into_iter().skip(1));
        }
        let closed = vertices[0].point.distance(vertices.last().unwrap().point) < 1e-6;
        if closed {
            vertices.pop();
        }
        let mut e = source[0].clone();
        e.shape = Shape::Polyline { vertices, closed };
        self.commit(vec![e], source.iter().skip(1).map(|e| e.id).collect(), None)
    }
    fn corner(&mut self, size: f64, chamfer: Option<f64>) -> Result<(), String> {
        if size < 0.0 || chamfer.is_some_and(|d| d < 0.0) {
            return Err("Corner distances must be nonnegative".into());
        }
        let source = self.selection()?;
        if source.len() != 2 {
            return Err("Select exactly two intersecting lines".into());
        }
        let line = |e: &Entity| match e.shape {
            Shape::Line { a, b } => Ok((a, b)),
            _ => Err("Corner operations require lines".to_string()),
        };
        let (a, b) = line(&source[0])?;
        let (c, d) = line(&source[1])?;
        let p = intersection(a, b, c, d).ok_or("Lines are parallel")?;
        let far = |a: Point, b: Point| if a.distance(p) > b.distance(p) { a } else { b };
        let f1 = far(a, b);
        let f2 = far(c, d);
        let u = (f1 - p) * (1.0 / f1.distance(p));
        let v = (f2 - p) * (1.0 / f2.distance(p));
        let theta = u.dot(v).clamp(-1.0, 1.0).acos();
        if theta < EPS || (PI - theta).abs() < EPS {
            return Err("Corner angle is degenerate".into());
        }
        let t1 = if chamfer.is_some() {
            size
        } else {
            size / (theta / 2.0).tan()
        };
        let t2 = chamfer.unwrap_or(t1);
        if t1 > p.distance(f1) || t2 > p.distance(f2) {
            return Err("Corner radius/distances exceed the line lengths".into());
        }
        let q1 = p + u * t1;
        let q2 = p + v * t2;
        let mut e1 = source[0].clone();
        e1.shape = Shape::Line { a: f1, b: q1 };
        let mut e2 = source[1].clone();
        e2.shape = Shape::Line { a: q2, b: f2 };
        let mut after = vec![e1, e2];
        if size > EPS {
            let shape = if chamfer.is_some() {
                Shape::Line { a: q1, b: q2 }
            } else {
                let bisector = (u + v) * (1.0 / (u + v).length());
                let center = p + bisector * (size / (theta / 2.0).sin());
                let start = (q1.y - center.y).atan2(q1.x - center.x);
                let end = (q2.y - center.y).atan2(q2.x - center.x);
                let mut sweep = (end - start).rem_euclid(TAU);
                if sweep > PI {
                    sweep -= TAU;
                }
                Shape::Arc {
                    center,
                    radius: size,
                    start,
                    sweep,
                }
            };
            let mut e = source[0].clone();
            e.id = self.doc.next_id;
            e.shape = shape;
            after.push(e);
        }
        self.commit(after, vec![], None)
    }
}
fn positive_count(n: f64) -> Result<usize, String> {
    if n.fract() != 0.0 || !(1.0..=10_000.0).contains(&n) {
        Err("Count must be an integer from 1 to 10000".into())
    } else {
        Ok(n as usize)
    }
}
fn reverse_vertices(v: &mut [Vertex]) {
    let old = v.to_vec();
    let n = v.len();
    for i in 0..n {
        v[i].point = old[n - 1 - i].point;
        v[i].bulge = if i + 1 < n {
            -old[n - 2 - i].bulge
        } else {
            0.0
        };
    }
}
fn hex_color(s: &str) -> Result<[f32; 4], String> {
    let s = s.trim_start_matches('#');
    if s.len() != 6 {
        return Err("Color must be #RRGGBB".into());
    }
    let n = u32::from_str_radix(s, 16).map_err(|_| "Invalid hexadecimal color")?;
    Ok([
        ((n >> 16) & 255) as f32 / 255.0,
        ((n >> 8) & 255) as f32 / 255.0,
        (n & 255) as f32 / 255.0,
        1.0,
    ])
}
fn signed_area(p: &[Point]) -> f64 {
    if p.len() < 3 {
        return 0.0;
    }
    let origin = p[0];
    p.iter()
        .zip(p.iter().cycle().skip(1))
        .take(p.len())
        .map(|(a, b)| (*a - origin).cross(*b - origin))
        .sum::<f64>()
        * 0.5
}
fn metrics(doc: &Document, e: &Entity) -> (f64, f64) {
    match &e.shape {
        Shape::Circle { radius, .. } => (TAU * radius, PI * radius * radius),
        Shape::Arc { radius, sweep, .. } => (radius * sweep.abs(), 0.0),
        Shape::Ellipse {
            major,
            ratio,
            sweep,
            ..
        } if (sweep.abs() - TAU).abs() < EPS => {
            let a = major.length();
            let b = a * ratio;
            let h = ((a - b) / (a + b)).powi(2);
            (
                PI * (a + b) * (1.0 + 3.0 * h / (10.0 + (4.0 - 3.0 * h).sqrt())),
                PI * a * b,
            )
        }
        Shape::Polyline { vertices, closed } => {
            let mut length = 0.0;
            let mut area = if *closed {
                signed_area(&vertices.iter().map(|v| v.point).collect::<Vec<_>>())
            } else {
                0.0
            };
            for s in polyline_edges(vertices, *closed) {
                match s {
                    Shape::Line { a, b } => length += a.distance(b),
                    Shape::Arc { radius, sweep, .. } => {
                        length += radius * sweep.abs();
                        area += 0.5 * radius * radius * (sweep - sweep.sin());
                    }
                    _ => {}
                }
            }
            (length, if *closed { area.abs() } else { 0.0 })
        }
        Shape::Hatch { boundary, .. } => (
            boundary
                .iter()
                .zip(boundary.iter().cycle().skip(1))
                .take(boundary.len())
                .map(|(a, b)| a.distance(*b))
                .sum(),
            signed_area(boundary).abs(),
        ),
        _ => {
            let b = entity_geometry(doc, e, 0.01);
            (
                b.segments
                    .iter()
                    .map(|s| (s.bx - s.ax).hypot(s.by - s.ay))
                    .sum(),
                0.0,
            )
        }
    }
}
fn segment_hits_box(a: Point, b: Point, rect: Bounds) -> bool {
    if rect.contains(a) || rect.contains(b) {
        return true;
    }
    let corners = [
        rect.min,
        Point::new(rect.max.x, rect.min.y),
        rect.max,
        Point::new(rect.min.x, rect.max.y),
    ];
    (0..4).any(|i| {
        let c = corners[i];
        let d = corners[(i + 1) % 4];
        if let Some(p) = intersection(a, b, c, d) {
            let t = (p - a).dot(b - a) / (b - a).dot(b - a);
            let u = (p - c).dot(d - c) / (d - c).dot(d - c);
            (-EPS..=1.0 + EPS).contains(&t) && (-EPS..=1.0 + EPS).contains(&u)
        } else {
            false
        }
    })
}
