use cad_core::{
    commands::Engine,
    exchange::{export_dxf, import_dxf},
    geometry::{bulge_arc, Bounds, Point, Transform},
    model::{Document, Shape},
};
use serde_json::json;

fn command(e: &mut Engine, s: &str) {
    e.command(s).unwrap();
}
#[test]
fn draw_edit_undo_save_reopen() {
    let mut e = Engine::default();
    command(&mut e, "LINE 0,0 3000,0");
    e.dispatch(json!({"op":"select_all"})).unwrap();
    command(&mut e, "MOVE 500,100");
    let moved = e.doc.entities.clone();
    command(&mut e, "UNDO");
    assert_ne!(e.doc.entities, moved);
    command(&mut e, "REDO");
    assert_eq!(e.doc.entities, moved);
    let data = e.dispatch(json!({"op":"serialize"})).unwrap();
    let mut reopened = Engine::default();
    reopened
        .dispatch(json!({"op":"load","document":data}))
        .unwrap();
    assert_eq!(e.doc, reopened.doc);
}
#[test]
fn rejected_geometry_does_not_commit() {
    let mut e = Engine::default();
    command(&mut e, "LINE 0,0 10,0");
    let before = e.doc.clone();
    for c in [
        "CIRCLE 0,0 -1",
        "LINE NaN,0 1,1",
        "LINE 0,0 0,0",
        "SCALE 0,0 -2",
        "POLYLINE 0,0",
        "ARC 0,0 20 0 900",
    ] {
        assert!(e.command(c).is_err(), "{c}");
        assert_eq!(e.doc, before);
    }
}
#[test]
fn units_and_layers_are_undoable_and_validated() {
    let mut e = Engine::default();
    command(&mut e, "UNITS m");
    assert_eq!(e.doc.units, "m");
    command(&mut e, "UNDO");
    assert_eq!(e.doc.units, "mm");
    assert!(e.command("UNITS bananas").is_err());
    assert_eq!(e.doc.units, "mm");
    e.dispatch(json!({"op":"layer","name":"Walls","create":true}))
        .unwrap();
    command(&mut e, "LINE 0,0 2,3");
    e.dispatch(json!({"op":"layer","name":"Walls","locked":true}))
        .unwrap();
    assert!(e.command("LINE 0,0 1,1").is_err());
    assert_eq!(e.pick(Point::new(1.0, 1.5), 0.1), None);
    let before = e.doc.clone();
    assert!(e
        .dispatch(json!({"op":"layer","name":"","create":true}))
        .is_err());
    assert_eq!(e.doc, before);
}
#[test]
fn redo_branch_and_dirty_revision() {
    let mut e = Engine::default();
    command(&mut e, "LINE 0,0 1,1");
    e.dispatch(json!({"op":"saved","revision":e.revision}))
        .unwrap();
    assert_eq!(e.state()["dirty"], false);
    command(&mut e, "CIRCLE 0,0 5");
    assert_eq!(e.state()["dirty"], true);
    command(&mut e, "UNDO");
    assert_eq!(e.state()["dirty"], false);
    command(&mut e, "CIRCLE 0,0 10");
    assert!(e.command("REDO").is_err());
}
#[test]
fn transform_and_block_semantics() {
    let mut e = Engine::default();
    command(&mut e, "LINE 10,10 20,10");
    e.dispatch(json!({"op":"select_all"})).unwrap();
    command(&mut e, "BLOCK wall 10,10");
    assert_eq!(e.doc.entities.len(), 1);
    assert_eq!(e.doc.blocks.len(), 1);
    command(&mut e, "INSERT wall 100,100 2 90");
    let b = e.bounds().unwrap();
    assert!((b.max.y - 120.0).abs() < 1e-8);
    e.dispatch(json!({"op":"select_all"})).unwrap();
    command(&mut e, "EXPLODE");
    assert!(e
        .doc
        .entities
        .values()
        .all(|e| matches!(e.shape, Shape::Line { .. })));
    command(&mut e, "UNDO");
    assert!(e
        .doc
        .entities
        .values()
        .all(|e| matches!(e.shape, Shape::Insert { .. })));
}
#[test]
fn trim_extend_and_offsets() {
    let mut e = Engine::default();
    command(&mut e, "LINE -10,0 10,0");
    e.dispatch(json!({"op":"select_all"})).unwrap();
    command(&mut e, "TRIM 0,-10 0,10 -5,0");
    assert_eq!(
        e.doc.entities[&1].shape,
        Shape::Line {
            a: Point::new(0.0, 0.0),
            b: Point::new(10.0, 0.0)
        }
    );
    command(&mut e, "EXTEND -5,-10 -5,10 -1,0");
    assert_eq!(
        e.doc.entities[&1].shape,
        Shape::Line {
            a: Point::new(-5.0, 0.0),
            b: Point::new(10.0, 0.0)
        }
    );
    command(&mut e, "OFFSET 2");
    assert_eq!(e.doc.entities.len(), 2);
}
#[test]
fn indexed_picking_and_snapping_at_large_coordinates() {
    let mut e = Engine::default();
    command(&mut e, "LINE 1000000000,1000000000 1000000001,1000000000");
    assert_eq!(e.pick(Point::new(1e9 + 0.5, 1e9), 0.01), Some(1));
    let s = e.snap(Point::new(1e9 + 0.001, 1e9), 0.01);
    assert_eq!(s["kind"], "endpoint");
    assert_eq!(s["point"]["x"], 1e9);
    let batch = e.batch(
        Bounds {
            min: Point::new(0.0, 0.0),
            max: Point::new(100.0, 100.0),
        },
        0.1,
    );
    assert!(batch.segments.is_empty());
}
#[test]
fn bulge_and_mirror_preserve_arc_geometry() {
    let (center, r, _, sweep) =
        bulge_arc(Point::new(-1.0, 0.0), Point::new(1.0, 0.0), 1.0).unwrap();
    assert!(center.distance(Point::default()) < 1e-9);
    assert!((r - 1.0).abs() < 1e-9);
    assert!((sweep - std::f64::consts::PI).abs() < 1e-9);
    let arc = Shape::Arc {
        center: Point::new(2.0, 3.0),
        radius: 5.0,
        start: 0.0,
        sweep: 1.0,
    };
    let mirrored =
        arc.transformed(Transform::mirror(Point::default(), Point::new(0.0, 1.0)).unwrap());
    if let Shape::Arc { center, sweep, .. } = mirrored {
        assert_eq!(center, Point::new(-2.0, 3.0));
        assert_eq!(sweep, -1.0);
    } else {
        panic!();
    }
}
#[test]
fn malformed_native_and_recursive_blocks_are_rejected() {
    let mut e = Engine::default();
    let before = e.doc.clone();
    let mut invalid = serde_json::to_value(&e.doc).unwrap();
    invalid["format_version"] = json!(99);
    assert!(e.dispatch(json!({"op":"load","document":invalid})).is_err());
    assert_eq!(e.doc, before);
    let mut d = Document::default();
    d.blocks.insert(
        "loop".into(),
        vec![Shape::Insert {
            block: "loop".into(),
            at: Point::default(),
            scale: 1.0,
            rotation: 0.0,
        }],
    );
    assert!(Engine::new(d).is_err());
}
#[test]
fn dxf_geometry_units_layers_blocks_round_trip() {
    let mut e = Engine::default();
    command(&mut e, "UNITS m");
    e.dispatch(json!({"op":"layer","name":"Walls","create":true}))
        .unwrap();
    for c in [
        "LINE 0,0 10,0",
        "CIRCLE 5,5 2",
        "ARC 0,0 2 10 90",
        "PLINE 0,0 2,0:0.414213562373095 2,2 close",
        "TEXT 1,1 0.15 Room",
    ] {
        command(&mut e, c);
    }
    e.dispatch(json!({"op":"select","ids":[1]})).unwrap();
    command(&mut e, "BLOCK wall 0,0");
    command(&mut e, "INSERT wall 5,5 2 45");
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("drawing.dxf");
    export_dxf(&e.doc, &path).unwrap();
    let (doc, warnings) = import_dxf(&path).unwrap();
    assert!(!warnings.is_empty());
    assert_eq!(doc.units, "m");
    assert_eq!(doc.entities.len(), e.doc.entities.len());
    assert_eq!(doc.blocks, e.doc.blocks);
    let shapes: Vec<_> = e.doc.entities.values().map(|e| &e.shape).collect();
    let actual: Vec<_> = doc.entities.values().map(|e| &e.shape).collect();
    // dxf-rs emits decimal floating point with finite precision. Compare the
    // exchange representation to 1e-9; native round trips above stay exact.
    assert_json_near(
        &serde_json::to_value(actual).unwrap(),
        &serde_json::to_value(shapes).unwrap(),
    );
}

fn assert_json_near(a: &serde_json::Value, b: &serde_json::Value) {
    match (a, b) {
        (serde_json::Value::Number(a), serde_json::Value::Number(b)) => {
            assert!((a.as_f64().unwrap() - b.as_f64().unwrap()).abs() < 1e-9)
        }
        (serde_json::Value::Array(a), serde_json::Value::Array(b)) => {
            assert_eq!(a.len(), b.len());
            for (a, b) in a.iter().zip(b) {
                assert_json_near(a, b);
            }
        }
        (serde_json::Value::Object(a), serde_json::Value::Object(b)) => {
            assert_eq!(a.len(), b.len());
            for (k, a) in a {
                assert_json_near(a, &b[k]);
            }
        }
        _ => assert_eq!(a, b),
    }
}
#[test]
fn dxf_export_never_truncates_invalid_destination() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("original.dwg");
    std::fs::write(&path, b"original").unwrap();
    assert!(export_dxf(&Document::default(), &path).is_err());
    assert_eq!(std::fs::read(&path).unwrap(), b"original");
    let bad = dir.path().join("bad.dxf");
    std::fs::write(&bad, b"this is not DXF").unwrap();
    assert!(import_dxf(&bad).is_err());
}
#[test]
fn ffi_contains_errors_and_owns_batches() {
    use cad_core::ffi::*;
    use std::ffi::{CStr, CString};
    unsafe {
        let h = cad_create();
        for request in [
            "not json",
            r#"{"op":"command","text":"LINE 0,0 10,0"}"#,
            r#"{"op":"command","text":"CIRCLE 0,0 -2"}"#,
        ] {
            let s = CString::new(request).unwrap();
            let result = cad_request(h, s.as_ptr());
            let value: serde_json::Value =
                serde_json::from_str(CStr::from_ptr(result).to_str().unwrap()).unwrap();
            assert_eq!(value["ok"], request.contains("LINE"));
            cad_string_free(result);
        }
        let b = cad_render(h, -1.0, -1.0, 20.0, 20.0, 0.1);
        assert!(!b.is_null());
        let mut count = 0;
        let segments = cad_batch_segments(b, &mut count);
        assert_eq!(count, 1);
        assert_eq!((*segments).bx, 10.0);
        cad_batch_free(b);
        cad_destroy(h);
    }
}
