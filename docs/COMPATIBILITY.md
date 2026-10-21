# Compatibility and release gates

This table describes the implemented subset, not AutoCAD parity. Synthetic core
tests exercise supported exchange; no professional drawing corpus is qualified.

| Capability | Current behavior |
| --- | --- |
| Native documents | Version 1 JSON `.maccad`; geometry, units, layers, static blocks; AppKit safe saves, autosave/recovery |
| Drafting | Lines, bulged polylines, rectangles, circles, arcs, basic text |
| Editing | Move/copy/rotate/uniform positive scale, mirror-copy, erase, undo/redo |
| Offset | Lines and circles only |
| Trim/extend | Lines against a supplied infinite line boundary |
| Static blocks | Create, insert, nested references, explode one level; uniform scale and rotation |
| Block limitations | Definition shapes inherit insert layer/color; mirrored inserts must be exploded first |
| Dimensions | Basic horizontal linear and aligned; no associativity or dimension styles |
| Hatches | Convex polygons, solid or diagonal; toolbar creates rectangular diagonal hatches |
| Snaps | Line endpoints/midpoints; polyline vertices; circle/arc center and quadrants; approximate points for other objects |
| Layers | Current layer, visibility, locking, colors via engine; locked/hidden objects excluded from editing |
| Units | mm, cm, m, in, ft; setting units reinterprets values without scaling geometry |
| PDF plotting | Single A3 landscape sheet, selected numeric scale, black linework, basic text/fills; clipping warning |
| DXF import | `dxf-rs`; planar LINE/CIRCLE/ARC, zero-width LWPOLYLINE/bulges, basic TEXT, static uniform positive INSERT |
| DXF export | R2013; above primitives/blocks; dimensions and hatches flattened to lines/text, solid fill lost |
| DXF layers/units | Names, visibility, approximate indexed colors and supported units; locking not exchanged |
| DXF text | Basic system-font substitution; font/justification/style fidelity not supported |
| DWG import | Experimental external LibreDWG `dwg2dxf` → DXF subset; helper installation required, not bundled |
| DWG export | Not implemented; no DWG source overwrites |
| Layouts, xrefs, dynamic blocks | Not implemented |
| Splines, complex hatches, SHX fonts | Not implemented; import diagnostics warn of losses |
| Scripting, AutoLISP/ObjectARX plugins | Not implemented |
| 3D solids/rendering | Future milestone |

## Numerical and format policy

Model geometry is f64; world coordinates are bounded to ±1e12 drawing units and
must be finite. Geometry below 1e-9 drawing units is treated as degenerate.
Display tessellation does not replace native geometry. Curves use a screen-space
tolerance, with bounded tessellation density. Very dense diagonal hatches use a
display spacing cap; native data retains the requested spacing.

DXF writes finite decimal precision; exchange tests compare supported numbers to
an absolute 1e-9 tolerance. Native round trips are exact. Negative-sweep arcs export
as equivalent counterclockwise DXF arcs, so orientation metadata is not preserved.
Import is always a new native drawing, with a warning before import and a report
afterward. Unsupported information is not retained for future re-export.

Native and exchange input limits are 128 MiB, one million top-level entities,
10k layers/blocks, and 16 nested block references. These are alpha limits, not
security guarantees against every pathological drawing. Do not publish a lossless
compatibility claim based solely on successful parsing or a plausible preview.

## Required before a professional alpha claim

- Round-trip legally shareable architecture drawings in an independent CAD app;
  inspect dimensions, bulges, blocks, units, placement and plotted output.
- Test DWG conversion across representative file versions with LibreDWG installed.
- Exercise actual crash/force-quit recovery, multiple documents and disk failures.
- Run accessibility and native UI interaction checks in both system appearances.
- Measure Metal frame times and total memory on baseline M1 at 10k/100k entities;
  the 60 fps target is not established by CPU benchmark numbers.
- Verify signed GitHub update installation, first-download Gatekeeper behavior,
  and optional Developer ID/notarization on a separate machine.
