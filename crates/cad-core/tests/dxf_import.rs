//! DXF reader checks on generated drawings: each test writes the group codes a
//! CAD program would and compares the imported geometry, not a screenshot.
use cad_core::{
    dxfread::parse,
    exchange::export_dxf,
    geometry::Point,
    model::{Document, Shape},
    render::entity_batch,
};

/// A complete DXF file: optional tables, then the given block and entity records.
fn dxf(tables: &str, blocks: &str, entities: &str) -> String {
    let mut s = String::from("0\nSECTION\n2\nHEADER\n9\n$INSUNITS\n70\n4\n0\nENDSEC\n");
    s += &format!("0\nSECTION\n2\nTABLES\n{tables}0\nENDSEC\n");
    s += &format!("0\nSECTION\n2\nBLOCKS\n{blocks}0\nENDSEC\n");
    s += &format!("0\nSECTION\n2\nENTITIES\n{entities}0\nENDSEC\n0\nEOF\n");
    s
}
fn only(doc: &Document) -> &Shape {
    assert_eq!(doc.entities.len(), 1, "{:?}", doc.entities);
    &doc.entities.values().next().unwrap().shape
}
fn near(a: f64, b: f64) -> bool {
    (a - b).abs() < 1e-9
}

#[test]
fn hatch_pattern_lines_touching_corners_stay_inside() {
    // A 10×10 square with 45° lines whose family touches two corners exactly.
    let hatch = "0\nHATCH\n8\n0\n10\n0\n20\n0\n30\n0\n2\nANSI31\n70\n0\n71\n0\n91\n1\n\
                 92\n2\n72\n0\n73\n1\n93\n4\n10\n0\n20\n0\n10\n10\n20\n0\n10\n10\n20\n10\n10\n0\n20\n10\n97\n0\n\
                 75\n0\n76\n1\n52\n0\n41\n1\n77\n0\n78\n1\n53\n45\n43\n0\n44\n0\n45\n-1\n46\n1\n79\n0\n98\n0\n";
    let (doc, _) = parse(&dxf("", "", hatch)).unwrap();
    let entity = doc.entities.values().next().unwrap();
    assert!(matches!(entity.shape, Shape::Region { solid: false, .. }));
    let batch = entity_batch(&doc, entity, 1e-3);
    let mut length = 0.0;
    for s in &batch.segments {
        for v in [s.ax, s.ay, s.bx, s.by] {
            assert!(
                (-1e-9..=10.0 + 1e-9).contains(&v),
                "pattern line outside boundary: {s:?}"
            );
        }
        length += Point::new(s.ax, s.ay).distance(Point::new(s.bx, s.by));
    }
    // Lines y = x + 2k for k = -4..4 cross the square with length (10 - |2k|)√2.
    let expected: f64 = (-4i32..=4)
        .map(|k| (10.0 - (2 * k).abs() as f64) * 2f64.sqrt())
        .sum();
    // Only pattern lines are drawn; a hatch has no outline of its own.
    assert!((length - expected).abs() < 1e-6, "{length} vs {expected}");
}

#[test]
fn mtext_paragraph_indent_moves_the_text() {
    let mtext =
        "0\nMTEXT\n8\n0\n10\n-1000\n20\n50\n40\n2.5\n41\n2000\n71\n1\n1\n\\pi1010;{\\LTitle}\n";
    let (doc, _) = parse(&dxf("", "", mtext)).unwrap();
    let Shape::Text {
        at, text, format, ..
    } = only(&doc)
    else {
        panic!()
    };
    assert_eq!(text, "Title");
    assert!(near(at.x, 10.0) && near(at.y, 50.0), "{at:?}");
    assert_eq!(format.attachment, 1);
    assert!(near(format.wrap, 990.0));
}

#[test]
fn text_justification_and_stacked_fractions() {
    // Middle-center TEXT keeps its alignment point; MTEXT stacks read as fractions.
    let text = "0\nTEXT\n8\n0\n10\n0\n20\n0\n40\n3\n1\nRoom\n72\n1\n11\n5\n21\n7\n73\n2\n\
                0\nMTEXT\n8\n0\n10\n0\n20\n0\n40\n1\n1\nRISER = 7\\S1/4;\"\n";
    let (doc, _) = parse(&dxf("", "", text)).unwrap();
    let shapes: Vec<_> = doc.entities.values().map(|e| &e.shape).collect();
    let Shape::Text { format, .. } = shapes[0] else {
        panic!()
    };
    assert_eq!((format.halign, format.valign), (1, 2));
    assert_eq!(format.align, Some(Point::new(5.0, 7.0)));
    let Shape::Text { text, .. } = shapes[1] else {
        panic!()
    };
    assert_eq!(text, "RISER = 7 1/4\"");
}

#[test]
fn inserts_keep_attributes_mirroring_and_block_layers() {
    let tables = "0\nTABLE\n2\nLAYER\n0\nLAYER\n2\nFurniture\n70\n0\n62\n3\n6\nCONTINUOUS\n0\nLAYER\n2\nHidden\n70\n1\n62\n1\n6\nCONTINUOUS\n0\nENDTAB\n";
    let blocks = "0\nBLOCK\n8\n0\n2\nCHAIR\n70\n2\n10\n1\n20\n1\n\
                  0\nLINE\n8\nFurniture\n10\n1\n20\n1\n11\n3\n21\n1\n\
                  0\nLINE\n8\n0\n62\n0\n10\n1\n20\n1\n11\n1\n21\n2\n0\nENDBLK\n";
    let insert =
        "0\nINSERT\n8\nFurniture\n66\n1\n2\nCHAIR\n10\n100\n20\n200\n41\n-2\n42\n3\n50\n0\n\
                  0\nATTRIB\n8\n0\n10\n100\n20\n195\n40\n1\n1\nOak\n2\nMATERIAL\n70\n0\n0\nSEQEND\n\
                  0\nLINE\n8\nHidden\n10\n0\n20\n0\n11\n1\n21\n1\n";
    let (doc, _) = parse(&dxf(tables, blocks, insert)).unwrap();
    let layer = doc.layer("Hidden").unwrap();
    assert!(layer.frozen && !layer.shown());
    let block = &doc.blocks["CHAIR"];
    // The block base point (1,1) moves to the origin; layer 0 contents inherit.
    let Shape::Line { a, b } = block[0].shape else {
        panic!()
    };
    assert_eq!((a, b), (Point::new(0.0, 0.0), Point::new(2.0, 0.0)));
    assert_eq!(block[0].layer.as_deref(), Some("Furniture"));
    assert_eq!(block[1].layer, None);
    let insert = doc
        .entities
        .values()
        .find(|e| matches!(e.shape, Shape::Insert { .. }))
        .unwrap();
    let Shape::Insert {
        scale,
        y_scale,
        attributes,
        ..
    } = &insert.shape
    else {
        panic!()
    };
    assert_eq!((*scale, *y_scale), (-2.0, Some(3.0)));
    assert_eq!(
        (attributes[0].tag.as_str(), attributes[0].text.as_str()),
        ("MATERIAL", "Oak")
    );
    // The mirrored block line runs from the insertion point toward -x.
    let batch = entity_batch(&doc, insert, 1e-3);
    let s = batch
        .segments
        .iter()
        .find(|s| near(s.ay, 200.0) && near(s.by, 200.0))
        .unwrap();
    assert!(
        near(s.ax.min(s.bx), 96.0) && near(s.ax.max(s.bx), 100.0),
        "{s:?}"
    );
}

#[test]
fn dimensions_reference_their_graphics_block() {
    let blocks = "0\nBLOCK\n8\n0\n2\n*D1\n70\n1\n10\n0\n20\n0\n0\nLINE\n8\n0\n10\n0\n20\n0\n11\n5\n21\n0\n0\nENDBLK\n";
    let dimension = "0\nDIMENSION\n8\n0\n2\n*D1\n3\nArch\n10\n0\n20\n1\n70\n32\n42\n5\n1\n<>\n";
    let (doc, _) = parse(&dxf("", blocks, dimension)).unwrap();
    let Shape::Insert {
        block,
        dimension: Some(info),
        ..
    } = only(&doc)
    else {
        panic!()
    };
    assert_eq!(block, "*D1");
    assert_eq!(
        (info.kind.as_str(), info.measurement, info.style.as_str()),
        ("rotated", 5.0, "Arch")
    );
}

#[test]
fn unsupported_objects_are_reported_not_dropped_silently() {
    let entities = "0\nMLEADER\n8\n0\n0\nLINE\n8\n0\n67\n1\n10\n0\n20\n0\n11\n1\n21\n0\n0\nLINE\n8\n0\n10\n0\n20\n0\n11\n0\n21\n0\n";
    let (doc, warnings) = parse(&dxf("", "", entities)).unwrap();
    assert!(
        warnings.iter().any(|w| w.contains("MLEADER")),
        "{warnings:?}"
    );
    assert!(
        warnings.iter().any(|w| w.contains("paper-space")),
        "{warnings:?}"
    );
    // A zero-length line is drawn as a dot, as AutoCAD does.
    assert!(matches!(only(&doc), Shape::Point { .. }));
}

#[test]
fn export_keeps_attribute_text_and_anonymous_dimension_blocks() {
    let blocks = "0\nBLOCK\n8\n0\n2\n*D1\n70\n1\n10\n0\n20\n0\n0\nLINE\n8\n0\n10\n0\n20\n0\n11\n5\n21\n0\n0\nENDBLK\n\
                  0\nBLOCK\n8\n0\n2\nTAG\n70\n2\n10\n0\n20\n0\n0\nCIRCLE\n8\n0\n10\n0\n20\n0\n40\n1\n0\nENDBLK\n";
    let entities = "0\nDIMENSION\n8\n0\n2\n*D1\n10\n0\n20\n1\n70\n32\n42\n5\n\
                    0\nINSERT\n8\n0\n66\n1\n2\nTAG\n10\n10\n20\n10\n0\nATTRIB\n8\n0\n10\n12\n20\n10\n40\n1\n1\nA-101\n2\nNUMBER\n70\n0\n0\nSEQEND\n";
    let (doc, _) = parse(&dxf("", blocks, entities)).unwrap();
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("out.dxf");
    let warnings = export_dxf(&doc, &path).unwrap();
    assert!(
        warnings.iter().any(|w| w.contains("attribute")),
        "{warnings:?}"
    );
    let drawing = dxf::Drawing::load_file(&path).unwrap();
    assert!(drawing
        .blocks()
        .any(|b| b.name == "*D1" && b.is_anonymous()));
    let (back, _) = cad_core::exchange::import_dxf(&path).unwrap();
    assert!(back
        .entities
        .values()
        .any(|e| matches!(&e.shape, Shape::Text { text, .. } if text == "A-101")));
    assert!(back
        .entities
        .values()
        .any(|e| matches!(&e.shape, Shape::Insert { block, .. } if block == "*D1")));
}
