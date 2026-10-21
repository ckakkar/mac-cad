use cad_core::{
    commands::Engine,
    geometry::{Bounds, Point},
    model::{Document, Shape},
};
use std::time::Instant;
fn main() {
    println!(
        "mac-cad core benchmark · {} · {}",
        std::env::consts::ARCH,
        std::env::consts::OS
    );
    for count in [10_000, 100_000] {
        let mut doc = Document::default();
        for i in 0..count {
            let p = Point::new((i % 1000) as f64 * 100.0, (i / 1000) as f64 * 100.0);
            doc.insert(Shape::Line {
                a: p,
                b: p + Point::new(80.0, 60.0),
            });
        }
        let start = Instant::now();
        let engine = Engine::new(doc).unwrap();
        let index = start.elapsed();
        let b = Bounds {
            min: Point::new(-100.0, -100.0),
            max: Point::new(100_100.0, 10_100.0),
        };
        let start = Instant::now();
        let batch = engine.batch(b, 1.0);
        let render = start.elapsed();
        let start = Instant::now();
        for i in 0..1000 {
            std::hint::black_box(
                engine.pick(Point::new((i % 1000) as f64 * 100.0 + 10.0, 7.5), 10.0),
            );
        }
        let picks = start.elapsed();
        println!("{count} LINE entities: validate+index {index:?}; full scene {render:?} ({} segments); 1000 indexed picks {picks:?}; segment storage {} bytes",batch.segments.len(),batch.segments.len()*std::mem::size_of::<cad_core::render::Segment>());
    }
    println!(
        "CPU scene timings only. This does not measure GPU frame time or total process memory."
    );
}
