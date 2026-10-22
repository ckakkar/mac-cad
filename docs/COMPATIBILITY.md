# Compatibility and release gates

This describes implemented behavior, not AutoCAD parity. See the detailed
[behavior/feature audit](AUTOCAD_PARITY.md). Generated tests, three upstream DWG
line fixtures and local checks on two private architectural drawings exercise
the importer; no redistributable professional corpus is qualified yet.

| Capability | Current behavior |
| --- | --- |
| Native documents | Version 3 JSON `.maccad`; versions 1–2 migrate; geometry, entity properties, units, layers, linetype and text-style tables, blocks with per-entity layers/properties, attributes; coordinated saves and autosave written by the Rust core |
| Command workflow | Space/Return accept/repeat, prompted selection and values, clickable prompt options, autocomplete, Close/Undo, relative/polar input, dynamic input beside the crosshair, history/completion; option coverage is partial |
| Native workspace | Unified customizable toolbar, drawing tabs, Tool Sets sidebar, Properties/Layers inspector, status bar aids, AutoCAD for Mac menu order and shortcuts, Settings and Drafting Settings; no floating palettes or saved workspaces |
| Drafting | Lines, zero-width bulged polylines, rectangles, regular polygons, circles, center/start/sweep and three-point arcs, points, ellipses |
| Splines | Rational B-spline evaluation/import; SPLINE creates clamped control-point curves, not fit-point interpolation |
| Selection | Additive click/Shift removal, containing/crossing windows, selection preview, All/Last/Previous prompts, select all/similar; hidden/locked layers excluded |
| Grips | One hot grip at a time stretches supported objects with preview, snaps and typed points, through undoable engine edits; no grip MOVE/ROTATE/SCALE/MIRROR modes or multiple hot grips |
| Transforms | Move/copy/rotate, uniform positive scale, mirror-copy, erase, undo/redo |
| Offset | Lines, circles, arcs and straight polylines; signed distance, source properties retained; no curved polyline or self-intersection cleanup |
| Trim/extend | Lines against a supplied infinite line boundary; not general curve/boundary trimming |
| Fillet/chamfer | Two intersecting lines, numeric radius or distances; not arbitrary curves or entire polylines |
| Join/break/stretch | Join connected open lines/polylines with bulges; break one line at a point; stretch line/polyline vertices within a window |
| Arrays | Rectangular and polar copies; not associative arrays |
| Cleanup | OVERKILL removes exact duplicate shapes on the same layer/style; PURGE removes unused blocks/layers |
| Static blocks | Create, insert, nested references, explode. Imported references keep non-uniform and mirrored scale, MINSERT grids and attributes; block contents keep their own layers, with ByBlock and layer-0 inheritance; anonymous blocks retained. No block editor, attribute editing or dynamic blocks |
| Clipboard | MacCAD objects between native windows; no external CAD clipboard or embedded OLE support |
| Text | TEXT justification (including Aligned/Fit), width factor and obliquing; MTEXT attachment, wrapping width, line spacing and first-paragraph indent; TrueType style fonts by family name; SHX fonts substitute a system sans; inline MTEXT formatting (fonts, colors, stacking) simplified to plain text; no tables, fields or rich text editor |
| Dimensions/leaders | Drawing: basic horizontal linear, aligned, radius/diameter, simple leader. Imported DIMENSIONs show their stored graphics block and keep type, measurement, override text and style name; they are not associative and are not regenerated after edits. LEADER arrows use the dimension style arrow size; MLEADER is not imported |
| Hatches | Drawing: convex polygon, solid or diagonal. Imported HATCH keeps polyline and line/arc/ellipse/spline edge loops with holes (even-odd), solid fill and the stored pattern line definitions; gradients show as solid fill; not associative; no hatch editing or pattern library |
| Snaps | Selectable running modes: end/mid/center/node/quadrant/insertion; analytic line/circle/arc intersections; nearest, perpendicular and tangent with base point; ellipse quadrants and spline ends; per-mode markers; no tracking, overrides or general spline intersections |
| Layers/properties | Visibility, locking, colors, Continuous/Dashed/Center/Hidden, lineweight; rename, delete empty layers, isolate one layer; editable entity geometry/styles with `*VARIES*`; interactive MATCHPROP; LAYUNISO currently shows all layers |
| Units | mm, cm, m, in, ft; changing units reinterprets values, without geometry rescaling |
| Plotting | Native Print/Page Setup with extents/selection/display area, Fit or 1:N scale, monochrome/colors, lineweights; Export PDF: A4–A0, Letter/Legal/Tabloid, orientation, Fit/exact scale, selection-only; white objects plot black; no plot style tables |
| DXF import | MacCAD's own ASCII DXF reader (UTF-8 or Latin-1): LINE, POINT, CIRCLE, ARC, ELLIPSE, SPLINE, LWPOLYLINE/POLYLINE with bulges and widths, TEXT, MTEXT, ATTDEF/ATTRIB, INSERT/MINSERT, DIMENSION, LEADER, HATCH, SOLID/TRACE, 3DFACE outlines, IMAGE and OLE frames (no pixels), XLINE/RAY; object coordinate systems projected to plan; layer on/off/frozen/locked/plot flags, linetype patterns, LTSCALE, PDMODE, text styles. Not imported: paper space and layouts, viewports, xrefs, MLEADER, WIPEOUT, tables beyond their graphics, ACIS solids, meshes, extended data and dictionaries; each omission is counted in the import report. Binary DXF is rejected |
| DXF export | R2013 primitives and blocks (anonymous blocks flagged) with layers, linetype tables, block entity layers/styles, polyline widths, text style/width/MTEXT attachment. Imported dimensions export as references to their graphics block; attribute values export as plain text. Dimensions and leaders drawn in MacCAD, hatches, solids, images and construction lines flatten to lines/text. Every loss is reported in a warning |
| DXF styles | Full 256-entry AutoCAD Color Index table, entity true color, ByBlock/ByLayer color/linetype/lineweight, drawing-defined linetypes with per-object scale, units; layer locking not exported |
| DWG import | Experimental: bundled LibreDWG 0.14 converts DWG to DXF, then MacCAD's reader imports it; 1 GiB file and 5-minute conversion limits; LibreDWG decoding problems are counted in the import report. Objects LibreDWG cannot decode are missing or changed. Checks: upstream 2000/2013/2018 Line.dwg, plus a private 38 MB AutoCAD 2004-format architectural drawing (100,957 model-space objects, 8,630 blocks) opened in about 6 s on M2 |
| DWG export | Not implemented; no DWG source overwrites or lossless round-trip claim |
| Layouts/viewports, xrefs, images | Not implemented; paper-space entities omitted and counted; raster images and OLE objects show as frames; no retained passthrough data |
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
thumbnails are omitted with a notice. Binary DXF is rejected with a message;
files that end before their EOF marker are rejected rather than partly opened.

Import opens a new native drawing (the first import asks; the confirmation can be
turned off) and reports losses. Unsupported information is not retained for
re-export: layouts, extended data, dictionaries, custom objects, dimension
associativity and inline MTEXT formatting are dropped. LibreDWG conversion
problems are summarized in the report.

Input limits: 4 GiB DXF, 1 GiB DWG, 2 GiB native file; 5 million top-level
objects, 200,000 blocks, 2 million objects per block, 50 million expanded block
objects, 32 nested block levels. Compact exponential block expansions are
rejected. Limits are guardrails, not a guarantee against every pathological file.

## Remaining qualification work

- Round-trip redistributable architectural drawings in an independent CAD app;
  inspect dimensions, curves, blocks, units, placement and plotted output.
- Expand DWG fixtures beyond simple upstream line drawings with redistributable
  architectural files, and compare their appearance side by side with AutoCAD.
  Hatch pattern clipping, text placement and dimension graphics have been checked
  against the source data, not against AutoCAD screenshots.
- Exercise actual force-quit recovery, multiple documents and disk failures.
- Complete accessibility checks and both system appearances across supported macOS.
- Measure Metal frame times and total memory on baseline M1 at 10k/100k entities;
  CPU benchmark numbers do not establish a 60 fps target.
- Validate a signed update installation/relaunch on a second Mac, first-download
  Gatekeeper behavior and optional Developer ID/notarization.
