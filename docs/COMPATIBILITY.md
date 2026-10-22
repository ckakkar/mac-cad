# Compatibility and release gates

This describes implemented behavior, not AutoCAD parity. See the detailed
[behavior/feature audit](AUTOCAD_PARITY.md). Generated tests and three
upstream DWG line fixtures exercise the subset; no professional corpus is qualified.

| Capability | Current behavior |
| --- | --- |
| Native documents | Version 2 JSON `.maccad`; version 1 migrates; geometry, entity properties, units, layers, static blocks; coordinated saves and autosave |
| Command workflow | Space/Return accept/repeat, prompted selection and values, Close/Undo, relative/polar input, editable cursor input, history/completion; option coverage is partial |
| Drafting | Lines, zero-width bulged polylines, rectangles, regular polygons, circles, center/start/sweep and three-point arcs, points, ellipses |
| Splines | Rational B-spline evaluation/import; SPLINE creates clamped control-point curves, not fit-point interpolation |
| Selection | Additive click/Shift removal, containing/crossing windows, All/Last/Previous prompts, select all/similar; hidden/locked layers excluded |
| Transforms | Move/copy/rotate, uniform positive scale, mirror-copy, erase, undo/redo |
| Offset | Lines, circles, arcs and straight polylines; signed distance, source properties retained; no curved polyline or self-intersection cleanup |
| Trim/extend | Lines against a supplied infinite line boundary; not general curve/boundary trimming |
| Fillet/chamfer | Two intersecting lines, numeric radius or distances; not arbitrary curves or entire polylines |
| Join/break/stretch | Join connected open lines/polylines with bulges; break one line at a point; stretch line/polyline vertices within a window |
| Arrays | Rectangular and polar copies; not associative arrays |
| Cleanup | OVERKILL removes exact duplicate shapes on the same layer/style; PURGE removes unused blocks/layers |
| Static blocks | Create, uniform positive insert/rotation, nested references, explode; definition shapes inherit insertion properties |
| Clipboard | MacCAD objects between native windows; no external CAD clipboard or embedded OLE support |
| Text | Basic system-font text and multiline text; MTEXT formatting simplified; no SHX, tables, fields or rich text editor |
| Dimensions/leaders | Basic horizontal linear, aligned, radius/diameter, simple leader; no associativity, styles or tolerances |
| Hatches | Convex polygon, solid or diagonal; no holes, associative boundaries or hatch library; no solid DONUT tool |
| Snaps | End/mid/center/quadrant; analytic line/circle/arc intersections; nearest, perpendicular and tangent with base point; ellipse quadrants and spline ends; no general spline intersections |
| Layers/properties | Visibility, locking, colors, Continuous/Dashed/Center/Hidden, lineweight; editable entity geometry/styles; LAYUNISO currently shows all layers |
| Units | mm, cm, m, in, ft; changing units reinterprets values, without geometry rescaling |
| Plotting | Single-sheet PDF: A4–A0, Letter/Legal/Tabloid, orientation, Fit/exact scale, color/monochrome, selection-only, lineweights; clipping confirmation |
| DXF import | Planar LINE/CIRCLE/ARC/POINT/ELLIPSE/SPLINE, zero-width LWPOLYLINE and legacy POLYLINE, TEXT, simplified MTEXT, basic dimensions, static uniform INSERT |
| DXF export | R2013 primitives/blocks; ellipses/splines retained; dimensions, leaders and hatches flatten to lines/text; solid hatch fill lost |
| DXF styles | Approximate indexed layer colors, entity true color, supported linetypes/weights, units; layer locking not exchanged; unknown patterns simplified |
| DWG import | Experimental bundled LibreDWG 0.14 → DXF subset, 30-second conversion limit, warnings surfaced; upstream 2000/2013/2018 Line.dwg smoke checks |
| DWG export | Not implemented; no DWG source overwrites or lossless round-trip claim |
| Layouts/viewports, xrefs, images | Not implemented; paper-space entities omitted; no retained passthrough data |
| Dynamic blocks, constraints | Not implemented |
| Scripting, AutoLISP/ObjectARX | Not implemented |
| 3D solids/rendering | Future milestone |

## Numerical and format policy

Model geometry is f64, finite and bounded to ±1e12 drawing units. Geometry below
1e-9 units is treated as degenerate. Display tessellation does not replace native
geometry. Curves have bounded tessellation; dense diagonal hatches use a display
spacing cap while retaining requested native spacing. Spline length/area and
window tests on curves use tessellated approximations.

Native round trips preserve values exactly. Supported DXF tests compare geometry
to absolute 1e-9 or 1e-8 tolerances, depending on the curve. Negative-sweep arcs and
ellipses may export with equivalent counterclockwise orientation. ASCII DXF preview
thumbnails are omitted with a notice; unsigned spellings of 32-bit color metadata
are normalized to the same signed bit pattern accepted by the decoder. Binary DXF
is passed through to dxf-rs; unsupported binary previews can still cause an error.

Import opens a new native drawing, warns before proceeding and reports losses.
Unsupported information is not retained for re-export. Fonts, justification,
annotation styles, custom objects, application data and block attributes are not
preserved. Upstream conversion warnings may describe losses before DXF import.

Input limits: 128 MiB, one million top-level/expanded block objects, 10k layers and
blocks, 16 nested block references. Compact exponential block expansions are
rejected. Limits are guardrails, not a guarantee against every pathological file.

## Remaining qualification work

- Round-trip redistributable architectural drawings in an independent CAD app;
  inspect dimensions, curves, blocks, units, placement and plotted output.
- Expand DWG fixtures beyond simple upstream line drawings and compare appearance.
- Exercise actual force-quit recovery, multiple documents and disk failures.
- Complete accessibility checks and both system appearances across supported macOS.
- Measure Metal frame times and total memory on baseline M1 at 10k/100k entities;
  CPU benchmark numbers do not establish a 60 fps target.
- Validate a signed update installation/relaunch on a second Mac, first-download
  Gatekeeper behavior and optional Developer ID/notarization.
