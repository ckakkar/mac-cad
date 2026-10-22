use cad_core::{
    commands::Engine,
    curves::{clamped_knots, spline_point},
    exchange::{export_dxf, import_dxf},
    geometry::{Point, EPS},
    model::{Document, Shape},
    render::entity_geometry,
};
use serde_json::{json, Value};
fn run(e: &mut Engine, text: &str) {
    e.command(text)
        .unwrap_or_else(|err| panic!("{text}: {err}"));
}
fn select(e: &mut Engine, ids: &[u64]) {
    e.dispatch(json!({"op":"select","ids":ids})).unwrap();
}

#[test]
fn spline_basis_and_rational_quarter_circle() {
    let p = [
        Point::new(1.0, 0.0),
        Point::new(1.0, 1.0),
        Point::new(0.0, 1.0),
    ];
    let knots = clamped_knots(3, 2);
    let w = [1.0, 0.5_f64.sqrt(), 1.0];
    assert_eq!(spline_point(2, &p, &knots, &w, 0.0), p[0]);
    assert_eq!(spline_point(2, &p, &knots, &w, 1.0), p[2]);
    let midpoint = spline_point(2, &p, &knots, &w, 0.5);
    assert!((midpoint.length() - 1.0).abs() < 1e-12);
    assert!((midpoint.x - midpoint.y).abs() < 1e-12);
}
#[test]
fn added_shapes_have_geometry_and_undo() {
    let mut e = Engine::default();
    for c in [
        "ELLIPSE 0,0 1000,0 0.5",
        "SPLINE 0,0 1000,1000 2000,0",
        "POLYGON 6 0,0 500",
        "POINT 100,200",
        "ARC3 0,0 500,500 1000,0",
        "DIMRADIUS 0,0 1000,0 1300,200",
        "LEADER 0,0 100,100 30 Note",
    ] {
        run(&mut e, c);
    }
    assert_eq!(e.doc.entities.len(), 7);
    for entity in e.doc.entities.values() {
        let b = entity_geometry(&e.doc, entity, 0.1);
        assert!(!b.segments.is_empty() || !b.labels.is_empty());
    }
    run(&mut e, "UNDO");
    assert_eq!(e.doc.entities.len(), 6);
    run(&mut e, "REDO");
    assert_eq!(e.doc.entities.len(), 7);
}
#[test]
fn arrays_are_one_transaction() {
    let mut e = Engine::default();
    run(&mut e, "LINE 0,0 10,0");
    select(&mut e, &[1]);
    run(&mut e, "ARRAYRECT 2 3 100 200");
    assert_eq!(e.doc.entities.len(), 6);
    run(&mut e, "UNDO");
    assert_eq!(e.doc.entities.len(), 1);
    run(&mut e, "REDO");
    assert_eq!(e.doc.entities.len(), 6);
    select(&mut e, &[1]);
    run(&mut e, "ARRAYPOLAR 0,0 4 360");
    assert_eq!(e.doc.entities.len(), 9);
    let before = e.doc.clone();
    assert!(e.command("ARRAYRECT 1000 1000 1 1").is_err());
    assert_eq!(e.doc, before);
}
#[test]
fn join_reversed_bulged_edges_without_changing_curve() {
    let mut e = Engine::default();
    run(&mut e, "LINE 0,0 1,0");
    run(&mut e, "PLINE 2,1:0.414213562373095 1,0");
    select(&mut e, &[1, 2]);
    run(&mut e, "JOIN");
    let Shape::Polyline { vertices, closed } = &e.doc.entities[&1].shape else {
        panic!()
    };
    assert!(!closed);
    assert_eq!(vertices[0].point, Point::new(0.0, 0.0));
    assert!((vertices[1].bulge + 0.414213562373095).abs() < 1e-12);
    select(&mut e, &[1]);
    run(&mut e, "REVERSE");
    let Shape::Polyline { vertices, .. } = &e.doc.entities[&1].shape else {
        panic!()
    };
    assert!((vertices[0].bulge - 0.414213562373095).abs() < 1e-12);
    run(&mut e, "EXPLODE");
    assert_eq!(e.doc.entities.len(), 2);
    assert!(e
        .doc
        .entities
        .values()
        .any(|e| matches!(e.shape, Shape::Arc { .. })));
}
#[test]
fn break_stretch_and_offset_preserve_valid_shapes() {
    let mut e = Engine::default();
    run(&mut e, "LINE 0,0 100,0");
    select(&mut e, &[1]);
    run(&mut e, "BREAK 50,0");
    assert_eq!(e.doc.entities.len(), 2);
    run(&mut e, "STRETCH -1,-1 1,1 -10,0");
    assert_eq!(
        e.doc.entities[&1].shape,
        Shape::Line {
            a: Point::new(-10.0, 0.0),
            b: Point::new(50.0, 0.0)
        }
    );
    run(&mut e, "RECT 0,0 100,100");
    let id = e.doc.next_id - 1;
    select(&mut e, &[id]);
    run(&mut e, "OFFSET 10");
    assert!(matches!(
        e.doc.entities.values().last().unwrap().shape,
        Shape::Polyline { closed: true, .. }
    ));
}
#[test]
fn fillet_is_tangent_and_chamfer_uses_both_distances() {
    let mut e = Engine::default();
    run(&mut e, "LINE 0,0 100,0");
    run(&mut e, "LINE 0,0 0,100");
    select(&mut e, &[1, 2]);
    run(&mut e, "FILLET 10");
    let Shape::Arc {
        center,
        radius,
        start,
        sweep,
    } = e.doc.entities[&3].shape
    else {
        panic!()
    };
    assert!(center.distance(Point::new(10.0, 10.0)) < 1e-9);
    assert_eq!(radius, 10.0);
    let a = center + Point::new(start.cos(), start.sin()) * radius;
    let end = start + sweep;
    let b = center + Point::new(end.cos(), end.sin()) * radius;
    assert!(a.distance(Point::new(10.0, 0.0)) < 1e-9 || b.distance(Point::new(10.0, 0.0)) < 1e-9);
    run(&mut e, "UNDO");
    select(&mut e, &[1, 2]);
    run(&mut e, "CHAMFER 10 20");
    assert_eq!(e.doc.entities.len(), 3);
    assert!(e.doc.entities.values().any(|e|matches!(e.shape,Shape::Line {a,b} if a.distance(Point::new(10.0,0.0))<EPS && b.distance(Point::new(0.0,20.0))<EPS)));
}
#[test]
fn invalid_corner_and_property_edits_are_atomic() {
    let mut e = Engine::default();
    run(&mut e, "LINE 0,0 100,0");
    run(&mut e, "LINE 0,0 0,100");
    select(&mut e, &[1, 2]);
    let before = e.doc.clone();
    assert!(e.command("FILLET 1000").is_err());
    assert_eq!(e.doc, before);
    assert!(e
        .dispatch(json!({"op":"properties","geometry":{"a":{"x":5,"y":5}}}))
        .is_err());
    assert_eq!(e.doc, before);
    select(&mut e, &[1]);
    assert!(e
        .dispatch(json!({"op":"properties","style":{"line_weight":-1}}))
        .is_err());
    assert_eq!(e.doc, before);
}
#[test]
fn window_vs_crossing_selection_and_locking() {
    let mut e = Engine::default();
    run(&mut e, "LINE -10,0 10,0");
    let bounds = json!({"min":{"x":-2,"y":-2},"max":{"x":2,"y":2}});
    e.dispatch(json!({"op":"select_window","bounds":bounds,"crossing":false}))
        .unwrap();
    assert!(e.selected.is_empty());
    e.dispatch(json!({"op":"select_window","bounds":bounds,"crossing":true}))
        .unwrap();
    assert_eq!(e.selected.len(), 1);
    e.dispatch(json!({"op":"layer","name":"0","locked":true}))
        .unwrap();
    e.dispatch(json!({"op":"select_window","bounds":bounds,"crossing":true}))
        .unwrap();
    assert!(e.selected.is_empty());
}
#[test]
fn line_circle_intersections_and_arc_snaps_are_exact() {
    let mut e = Engine::default();
    run(&mut e, "LINE -20,3 20,3");
    run(&mut e, "CIRCLE 0,0 5");
    let result = e.precise_snap(Point::new(4.01, 3.01), 0.1, None);
    assert_eq!(result["kind"], "intersection");
    let p: Point = serde_json::from_value(result["point"].clone()).unwrap();
    assert!(p.distance(Point::new(4.0, 3.0)) < 1e-9);
    let mut e = Engine::default();
    run(&mut e, "ARC 0,0 10 10 20");
    let result = e.snap(Point::new(10.0, 0.0), 0.1);
    assert_eq!(result["kind"], "none");
    let angle = 10.0_f64.to_radians();
    let endpoint = Point::new(angle.cos() * 10.0, angle.sin() * 10.0);
    assert_eq!(e.snap(endpoint, 0.1)["kind"], "endpoint");
}
#[test]
fn perpendicular_and_tangent_object_snaps() {
    let mut e = Engine::default();
    run(&mut e, "LINE -20,0 20,0");
    let r = e.precise_snap(Point::new(2.02, 0.01), 0.1, Some(Point::new(2.0, 10.0)));
    assert_eq!(r["kind"], "perpendicular");
    let mut e = Engine::default();
    run(&mut e, "CIRCLE 0,0 5");
    let base = Point::new(10.0, 0.0);
    let theta = (0.5_f64).acos();
    let tangent = Point::new(5.0 * theta.cos(), 5.0 * theta.sin());
    let r = e.precise_snap(tangent, 0.1, Some(base));
    assert_eq!(r["kind"], "tangent");
}
#[test]
fn area_includes_bulged_polyline_segment() {
    let mut e = Engine::default();
    run(&mut e, "PLINE -1,0:1 1,0 close");
    select(&mut e, &[1]);
    let r = e.dispatch(json!({"op":"measure"})).unwrap();
    assert!((r["area"].as_f64().unwrap() - std::f64::consts::PI / 2.0).abs() < 1e-9);
}
#[test]
fn clipboard_remaps_colliding_block_names() {
    let mut e = Engine::default();
    run(&mut e, "LINE 0,0 100,0");
    select(&mut e, &[1]);
    run(&mut e, "BLOCK wall 0,0");
    e.dispatch(json!({"op":"select_all"})).unwrap();
    let clipboard = e.dispatch(json!({"op":"clipboard"})).unwrap();
    e.dispatch(json!({"op":"paste","document":clipboard,"at":{"x":10,"y":20}}))
        .unwrap();
    assert!(e.doc.blocks.contains_key("wall_1"));
    assert_eq!(e.doc.entities.len(), 2);
    run(&mut e, "UNDO");
    assert!(!e.doc.blocks.contains_key("wall_1"));
}
#[test]
fn native_v1_migrates_to_v2_with_default_properties() {
    let mut value = serde_json::to_value(Document::default()).unwrap();
    value["format_version"] = json!(1);
    for layer in value["layers"].as_array_mut().unwrap() {
        layer.as_object_mut().unwrap().remove("line_type");
        layer.as_object_mut().unwrap().remove("line_weight");
    }
    let mut e = Engine::default();
    e.dispatch(json!({"op":"load","document":value})).unwrap();
    assert_eq!(e.doc.format_version, 2);
    assert_eq!(e.doc.layers[0].line_type, "Continuous");
}
#[test]
fn new_geometry_dxf_round_trip() {
    let mut e = Engine::default();
    for c in [
        "ELLIPSE 0,0 1000,0 0.5",
        "SPLINE 0,0 100,100 200,100 300,0",
        "POINT 10,20",
        "MTEXT 0,0 100 First\\PSecond",
    ] {
        run(&mut e, c);
    }
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("new.dxf");
    export_dxf(&e.doc, &path).unwrap();
    let (actual, _) = import_dxf(&path).unwrap();
    assert_eq!(actual.entities.len(), 4);
    for (a, b) in e.doc.entities.values().zip(actual.entities.values()) {
        let a = serde_json::to_value(&a.shape).unwrap();
        let b = serde_json::to_value(&b.shape).unwrap();
        assert_near(&a, &b);
    }
}

#[test]
fn styles_round_trip_and_plot_batches_omit_selection_highlights() {
    let mut e = Engine::default();
    e.dispatch(json!({"op":"layer","name":"0","line_type":"Center","line_weight":0.7}))
        .unwrap();
    run(&mut e, "LINE 0,0 1000,0");
    select(&mut e, &[1]);
    run(&mut e, "CHPROP color #FF8800");
    run(&mut e, "CHPROP lineweight 0.5");
    run(&mut e, "CHPROP linetype Dashed");
    let bounds = cad_core::geometry::Bounds {
        min: Point::new(-1.0, -1.0),
        max: Point::new(1001.0, 1.0),
    };
    let visual = e.batch(bounds, 0.1);
    let plot = e.batch_mode(bounds, 0.1, false);
    assert!(plot.segments.len() > 1);
    assert_eq!(plot.segments[0].line_weight, 0.5);
    assert_eq!(visual.segments[0].color, [0.29, 0.67, 1.0, 1.0]);
    assert_ne!(plot.segments[0].color, visual.segments[0].color);
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("styles.dxf");
    export_dxf(&e.doc, &path).unwrap();
    let (actual, _) = import_dxf(&path).unwrap();
    assert_eq!(actual.entities[&1].style, e.doc.entities[&1].style);
    assert_eq!(actual.layers[0].line_type, "Center");
    assert_eq!(actual.layers[0].line_weight, 0.7);
    let drawing = dxf::Drawing::load_file(path).unwrap();
    let dashed = drawing.line_types().find(|l| l.name == "DASHED").unwrap();
    assert_eq!(dashed.dash_dot_space_lengths, vec![240.0, -100.0]);
}

#[test]
fn unlock_all_works_without_a_selection() {
    let mut e = Engine::default();
    e.dispatch(json!({"op":"layer","name":"0","locked":true}))
        .unwrap();
    run(&mut e, "LAYUNLOCK");
    assert!(!e.doc.layers[0].locked);
}

#[test]
fn dxf_preview_is_optional_and_default_layer_is_unique() {
    let mut e = Engine::default();
    run(&mut e, "LINE 0,0 10,20");
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("preview.dxf");
    export_dxf(&e.doc, &path).unwrap();
    let drawing = dxf::Drawing::load_file(&path).unwrap();
    assert_eq!(drawing.layers().filter(|l| l.name == "0").count(), 1);
    let text = std::fs::read_to_string(&path).unwrap();
    let preview = "  0\nSECTION\n  2\nTHUMBNAILIMAGE\n 90\n4\n310\nDEADBEEF\n  0\nENDSEC\n";
    let eof = text
        .rfind("  0\r\nEOF")
        .or_else(|| text.rfind("  0\nEOF"))
        .unwrap();
    let with_preview = format!("{}{}{}", &text[..eof], preview, &text[eof..])
        .replace("AcDbLine\r\n", "AcDbLine\r\n421\r\n3258135347\r\n");
    assert!(with_preview.contains("3258135347"));
    std::fs::write(&path, with_preview).unwrap();
    let (actual, warnings) = import_dxf(&path).unwrap();
    assert_eq!(actual.entities[&1].shape, e.doc.entities[&1].shape);
    assert!(warnings
        .iter()
        .any(|w| w.contains("preview thumbnail omitted")));
    std::fs::write(
        &path,
        format!(
            "{}{}",
            &text[..eof],
            preview.trim_end_matches("  0\nENDSEC\n")
        ),
    )
    .unwrap();
    assert!(import_dxf(&path).is_err());
}

#[test]
fn compact_block_expansion_is_bounded() {
    let mut d = Document::default();
    let blocks = std::sync::Arc::make_mut(&mut d.blocks);
    blocks.insert(
        "leaf".into(),
        vec![Shape::Line {
            a: Point::new(0.0, 0.0),
            b: Point::new(1.0, 0.0),
        }
        .into()],
    );
    let mut previous = "leaf".to_string();
    // Ten levels of ten references expand to ten billion objects.
    for i in 0..10 {
        let name = format!("branch{i}");
        let child = Shape::insert(previous, Point::new(0.0, 0.0), 1.0, 0.0);
        blocks.insert(name.clone(), vec![child.into(); 10]);
        previous = name;
    }
    d.insert(Shape::insert(previous, Point::new(0.0, 0.0), 1.0, 0.0));
    assert!(d.validate().unwrap_err().contains("million expanded"));
}
fn assert_near(a: &Value, b: &Value) {
    match (a, b) {
        (Value::Number(a), Value::Number(b)) => {
            assert!((a.as_f64().unwrap() - b.as_f64().unwrap()).abs() < 1e-8)
        }
        (Value::Array(a), Value::Array(b)) => {
            assert_eq!(a.len(), b.len());
            for (a, b) in a.iter().zip(b) {
                assert_near(a, b)
            }
        }
        (Value::Object(a), Value::Object(b)) => {
            assert_eq!(a.len(), b.len());
            for (k, v) in a {
                assert_near(v, &b[k])
            }
        }
        _ => assert_eq!(a, b),
    }
}

#[test]
fn command_selection_add_remove_and_invalid_mode_are_atomic() {
    let mut e = Engine::default();
    run(&mut e, "LINE 0,0 10,0");
    run(&mut e, "LINE 0,20 10,20");
    for y in [0, 20, 0] {
        e.dispatch(json!({"op":"pick","point":{"x":5,"y":y},"tolerance":1,"mode":"add"}))
            .unwrap();
    }
    assert_eq!(e.selected.len(), 2);
    e.dispatch(json!({"op":"pick","point":{"x":5,"y":0},"tolerance":1,"mode":"remove"}))
        .unwrap();
    assert_eq!(e.selected.iter().copied().collect::<Vec<_>>(), vec![2]);
    let before = e.selected.clone();
    assert!(e
        .dispatch(json!({"op":"pick","point":{"x":5,"y":0},"tolerance":1,"mode":"bad"}))
        .is_err());
    assert_eq!(before, e.selected);
    e.dispatch(json!({"op":"select_window","bounds":{"min":{"x":0,"y":0},"max":{"x":10,"y":20}},"mode":"remove"})).unwrap();
    assert!(e.selected.is_empty());
    e.dispatch(json!({"op":"select_last"})).unwrap();
    assert!(e.selected.contains(&2));
}

#[test]
fn circle_constructions_offset_side_and_mirror_delete_are_validated() {
    let mut e = Engine::default();
    run(&mut e, "CIRCLE2 -10,0 10,0");
    run(&mut e, "CIRCLE3 1,0 0,1 -1,0");
    assert!(matches!(
        e.doc.entities[&1].shape,
        Shape::Circle { radius: 10.0, .. }
    ));
    assert!(matches!(
        e.doc.entities[&2].shape,
        Shape::Circle { radius: 1.0, .. }
    ));
    let before = e.doc.clone();
    assert!(e.command("CIRCLE3 0,0 1,0 2,0").is_err());
    assert_eq!(e.doc, before);
    select(&mut e, &[1]);
    run(&mut e, "OFFSET 2 0,0");
    assert!(matches!(
        e.doc.entities[&3].shape,
        Shape::Circle { radius: 8.0, .. }
    ));
    run(&mut e, "LINE 1,0 2,0");
    select(&mut e, &[4]);
    run(&mut e, "OFFSET 5 0,-10");
    assert!(matches!(e.doc.entities[&5].shape,Shape::Line{a,..} if a.y == -5.0));
    select(&mut e, &[4]);
    run(&mut e, "MIRROR 0,0 0,1 delete");
    assert_eq!(e.doc.entities.len(), 5);
    assert!(matches!(e.doc.entities[&4].shape,Shape::Line{a,..} if a.x == -1.0));
    run(&mut e, "UNDO");
    assert!(matches!(e.doc.entities[&4].shape,Shape::Line{a,..} if a.x == 1.0));
    let before_guard = e.doc.clone();
    let revision = e.revision;
    assert!(e
        .dispatch(json!({"op":"undo_if_revision","revision":revision+1}))
        .is_err());
    assert_eq!(e.doc, before_guard);
    assert_eq!(e.revision, revision);
    e.dispatch(json!({"op":"undo_if_revision","revision":revision}))
        .unwrap();
    assert_ne!(e.revision, revision);
}
