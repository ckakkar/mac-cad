//! Generate redistributable release QA drawings; contains no customer data.
use cad_core::{commands::Engine, exchange::export_dxf};
use serde_json::json;
use std::path::PathBuf;
fn main() -> Result<(), String> {
    let root = PathBuf::from(
        std::env::args()
            .nth(1)
            .unwrap_or_else(|| "build/fixtures".into()),
    );
    std::fs::create_dir_all(&root).map_err(|e| e.to_string())?;
    let mut e = Engine::default();
    e.dispatch(json!({"op":"layer","name":"Architecture","create":true}))?;
    e.dispatch(
        json!({"op":"layer","name":"Architecture","color":[0.82,0.87,0.93,1.0],"line_weight":0.35}),
    )?;
    for c in [
        "RECT 0,0 8000,6000",
        "RECT 200,200 7800,5800",
        "LINE 5000,200 5000,5800",
        "LINE 5200,200 5200,5800",
        "LINE 200,3500 5000,3500",
        "LINE 200,3700 5000,3700",
    ] {
        e.command(c)?;
    }
    e.dispatch(json!({"op":"layer","name":"Openings","create":true}))?;
    e.dispatch(json!({"op":"layer","name":"Openings","color":[0.95,0.65,0.3,1.0]}))?;
    for c in [
        "ARC 1800,200 900 0 90",
        "LINE 1800,200 1800,1100",
        "RECT 700,5750 2300,5850",
        "RECT 5700,5750 7200,5850",
        "ELLIPSE 2600,1800 3400,1800 0.55",
        "CIRCLE 6500,3000 700",
    ] {
        e.command(c)?;
    }
    e.dispatch(json!({"op":"layer","name":"Annotation","create":true}))?;
    e.dispatch(
        json!({"op":"layer","name":"Annotation","color":[0.4,0.78,0.7,1.0],"line_weight":0.13}),
    )?;
    for c in [
        "TEXT 1300,2800 180 LIVING / DINING",
        "TEXT 900,4500 180 KITCHEN",
        "TEXT 5700,4700 180 BEDROOM",
        "DIM 0,0 8000,0 -650",
        "DIMALIGNED 8000,0 8000,6000 -650",
        "SPLINE 1000,1400 1800,2200 3200,2200 4000,1400",
        "POLYGON 6 6500,3000 400",
        "LEADER 2300,5800 3000,6600 150 Double glazing",
    ] {
        e.command(c)?;
    }
    std::fs::write(
        root.join("Architecture.maccad"),
        serde_json::to_vec_pretty(&e.doc).map_err(|e| e.to_string())?,
    )
    .map_err(|e| e.to_string())?;
    let warnings = export_dxf(&e.doc, &root.join("Architecture.dxf"))?;
    for warning in warnings {
        println!("{warning}");
    }
    println!(
        "Generated {} entities in {}",
        e.doc.entities.len(),
        root.display()
    );
    Ok(())
}
