use cad_core::{
    commands::Engine,
    geometry::Point,
    grips::{grips, stretch},
    model::{Shape, Vertex},
};
use serde_json::{json, Value};
fn run(e: &mut Engine, text: &str) {
    e.command(text)
        .unwrap_or_else(|err| panic!("{text}: {err}"));
}
fn op(e: &mut Engine, v: Value) -> Value {
    e.dispatch(v).unwrap_or_else(|err| panic!("{err}"))
}
fn close(a: Point, b: Point) -> bool {
    a.distance(b) < 1e-9
}

#[test]
fn line_and_circle_grips_stretch_and_move() {
    let line = Shape::Line {
        a: Point::new(0.0, 0.0),
        b: Point::new(10.0, 0.0),
    };
    let g = grips(&line);
    assert_eq!(g.len(), 3);
    assert!(close(g[2].point, Point::new(5.0, 0.0)));
    assert_eq!(
        stretch(&line, 1, Point::new(10.0, 5.0)).unwrap(),
        Shape::Line {
            a: Point::new(0.0, 0.0),
            b: Point::new(10.0, 5.0)
        }
    );
    assert_eq!(
        stretch(&line, 2, Point::new(5.0, 3.0)).unwrap(),
        Shape::Line {
            a: Point::new(0.0, 3.0),
            b: Point::new(10.0, 3.0)
        }
    );
    // Collapsing a line onto its other endpoint is refused.
    assert!(stretch(&line, 0, Point::new(10.0, 0.0)).is_err());
    let circle = Shape::Circle {
        center: Point::new(1.0, 1.0),
        radius: 2.0,
    };
    let g = grips(&circle);
    assert_eq!(g.len(), 5);
    assert!(close(g[2].point, Point::new(1.0, 3.0)));
    assert_eq!(
        stretch(&circle, 1, Point::new(6.0, 1.0)).unwrap(),
        Shape::Circle {
            center: Point::new(1.0, 1.0),
            radius: 5.0
        }
    );
}
#[test]
fn arc_midpoint_and_polyline_bulge_grips_reshape_curves() {
    let arc = Shape::Arc {
        center: Point::new(0.0, 0.0),
        radius: 1.0,
        start: 0.0,
        sweep: std::f64::consts::PI,
    };
    let g = grips(&arc);
    assert!(close(g[2].point, Point::new(0.0, 1.0)));
    let Shape::Arc { radius, center, .. } = stretch(&arc, 2, Point::new(0.0, 2.0)).unwrap() else {
        panic!("arc expected")
    };
    // The arc through (1,0), (0,2) and (-1,0) has center (0,0.75) and radius 1.25.
    assert!((radius - 1.25).abs() < 1e-9 && close(center, Point::new(0.0, 0.75)));
    let pline = Shape::Polyline {
        vertices: vec![
            Vertex {
                point: Point::new(0.0, 0.0),
                bulge: 0.0,
            },
            Vertex {
                point: Point::new(2.0, 0.0),
                bulge: 0.0,
            },
        ],
        closed: false,
    };
    // Vertex grips first, then edge midpoints.
    assert_eq!(grips(&pline).len(), 3);
    let Shape::Polyline { vertices, .. } = stretch(&pline, 2, Point::new(1.0, 1.0)).unwrap() else {
        panic!("polyline expected")
    };
    assert!(close(vertices[0].point, Point::new(0.0, 1.0)) && vertices[0].bulge == 0.0);
    let mut curved = pline.clone();
    if let Shape::Polyline { vertices, .. } = &mut curved {
        vertices[0].bulge = 1.0;
    }
    let mid = grips(&curved)[2].point;
    assert!(close(mid, Point::new(1.0, -1.0)));
    let Shape::Polyline { vertices, .. } = stretch(&curved, 2, Point::new(1.0, 1.0)).unwrap()
    else {
        panic!("polyline expected")
    };
    assert!((vertices[0].bulge + 1.0).abs() < 1e-9);
}
#[test]
fn grip_edits_commit_with_undo_and_refuse_invalid_or_locked_objects() {
    let mut e = Engine::default();
    run(&mut e, "LINE 0,0 10,0");
    op(&mut e, json!({"op":"select","ids":[1]}));
    let state = op(&mut e, json!({"op":"state"}));
    assert_eq!(state["grips"].as_array().unwrap().len(), 3);
    let state = op(
        &mut e,
        json!({"op":"grip","id":1,"index":1,"point":{"x":10.0,"y":10.0}}),
    );
    assert_eq!(state["undo_label"], "Grip Edit");
    assert_eq!(state["selected"], json!([1]));
    let before = e.doc.clone();
    assert!(e
        .dispatch(json!({"op":"grip","id":1,"index":0,"point":{"x":10.0,"y":10.0}}))
        .is_err());
    assert!(e
        .dispatch(json!({"op":"grip","id":1,"index":7,"point":{"x":1.0,"y":1.0}}))
        .is_err());
    assert_eq!(e.doc, before);
    run(&mut e, "UNDO");
    assert_eq!(
        e.doc.entities[&1].shape,
        Shape::Line {
            a: Point::new(0.0, 0.0),
            b: Point::new(10.0, 0.0)
        }
    );
    op(&mut e, json!({"op":"layer","name":"0","locked":true}));
    assert!(e
        .dispatch(json!({"op":"grip","id":1,"index":0,"point":{"x":1.0,"y":1.0}}))
        .is_err());
}
#[test]
fn undo_and_redo_steps_carry_command_names() {
    let mut e = Engine::default();
    let state = op(&mut e, json!({"op":"command","text":"CIRCLE 0,0 10"}));
    assert_eq!(state["undo_label"], "Circle");
    op(&mut e, json!({"op":"select_all"}));
    let state = op(&mut e, json!({"op":"command","text":"MOVE 5,0"}));
    assert_eq!(state["undo_label"], "Move");
    let state = op(&mut e, json!({"op":"command","text":"UNDO"}));
    assert_eq!(state["undo_label"], "Circle");
    assert_eq!(state["redo_label"], "Move");
    let state = op(&mut e, json!({"op":"layer","name":"Walls","create":true}));
    assert_eq!(state["undo_label"], "Layer Change");
    assert_eq!(state["redo_label"], Value::Null);
}
#[test]
fn layers_rename_with_their_objects_and_delete_only_when_empty() {
    let mut e = Engine::default();
    op(&mut e, json!({"op":"layer","name":"Walls","create":true}));
    run(&mut e, "LINE 0,0 10,0");
    op(&mut e, json!({"op":"layer","name":"Doors","create":true}));
    op(&mut e, json!({"op":"layer","name":"Walls","current":true}));
    let state = op(
        &mut e,
        json!({"op":"layer","name":"Walls","rename":"A-WALL"}),
    );
    assert_eq!(state["current_layer"], "A-WALL");
    assert_eq!(e.doc.entities[&1].layer, "A-WALL");
    for bad in ["0", "Doors", "a/b", "  "] {
        assert!(e
            .dispatch(json!({"op":"layer","name":"A-WALL","rename":bad}))
            .is_err());
    }
    assert!(e
        .dispatch(json!({"op":"layer","name":"0","rename":"Base"}))
        .is_err());
    assert!(e
        .dispatch(json!({"op":"layer","name":"A-WALL","delete":true}))
        .is_err());
    op(&mut e, json!({"op":"layer","name":"Doors","delete":true}));
    assert!(e.doc.layer("Doors").is_none());
    run(&mut e, "UNDO");
    assert!(e.doc.layer("Doors").is_some());
    run(&mut e, "UNDO");
    assert_eq!(e.doc.entities[&1].layer, "Walls");
    assert_eq!(e.doc.current_layer, "Walls");
}
#[test]
fn hover_does_not_change_selection_and_snap_modes_filter_candidates() {
    let mut e = Engine::default();
    run(&mut e, "LINE 0,0 100,0");
    let hit = op(
        &mut e,
        json!({"op":"hover","point":{"x":40.0,"y":1.0},"tolerance":2.0}),
    );
    assert_eq!(hit["id"], 1);
    assert!(e.selected.is_empty());
    let miss = op(
        &mut e,
        json!({"op":"hover","point":{"x":40.0,"y":10.0},"tolerance":2.0}),
    );
    assert_eq!(miss["id"], Value::Null);
    let near_mid = json!({"x":49.0,"y":0.5});
    let all = op(
        &mut e,
        json!({"op":"snap","point":near_mid,"tolerance":5.0}),
    );
    assert_eq!(all["kind"], "midpoint");
    let endpoints = op(
        &mut e,
        json!({"op":"snap","point":near_mid,"tolerance":5.0,"modes":["endpoint"]}),
    );
    assert_eq!(endpoints["kind"], "none");
    let nearest = op(
        &mut e,
        json!({"op":"snap","point":near_mid,"tolerance":5.0,"modes":["nearest"]}),
    );
    assert_eq!(nearest["kind"], "nearest");
}
#[test]
fn grip_previews_and_layer_isolation_do_not_disturb_other_state() {
    let mut e = Engine::default();
    run(&mut e, "CIRCLE 0,0 10");
    op(&mut e, json!({"op":"layer","name":"Walls","create":true}));
    let before = e.doc.clone();
    let preview = op(
        &mut e,
        json!({"op":"grip_preview","id":1,"index":1,"point":{"x":20.0,"y":0.0},"tolerance":0.5}),
    );
    let segments = preview["segments"].as_array().unwrap();
    assert!(!segments.is_empty() && segments.len().is_multiple_of(4));
    let far = segments
        .iter()
        .filter_map(|v| v.as_f64())
        .fold(0.0_f64, |m, v| m.max(v.abs()));
    assert!((far - 20.0).abs() < 1e-6);
    assert_eq!(e.doc, before);
    let bad = op(
        &mut e,
        json!({"op":"grip_preview","id":1,"index":1,"point":{"x":0.0,"y":0.0},"tolerance":0.5}),
    );
    assert_eq!(bad["segments"], json!([]));
    op(&mut e, json!({"op":"layer","name":"Walls","isolate":true}));
    assert!(!e.doc.layer("0").unwrap().visible && e.doc.layer("Walls").unwrap().visible);
    assert_eq!(e.doc.current_layer, "Walls");
    run(&mut e, "UNDO");
    assert!(e.doc.layer("0").unwrap().visible);
}
