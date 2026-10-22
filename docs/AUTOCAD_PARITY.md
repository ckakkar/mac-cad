# AutoCAD for Mac 2D parity audit

The product target is familiar AutoCAD-for-Mac drafting behavior, implemented with
original open-source code and native macOS controls. **Full parity is not achieved.**
This inventory is a development and verification checklist, not a completeness
claim. A command name alone does not establish all its options or file semantics.

Reference behavior: Autodesk's [Mac shortcut guide](https://www.autodesk.com/asean/shortcuts/autocad-for-mac),
[command entry](https://help.autodesk.com/cloudhelp/2026/ENU/AutoCAD-LT-MAC/files/GUID-3C87A58F-1980-451D-A9D3-32327FA63D81.htm),
[command completion and repetition](https://help.autodesk.com/cloudhelp/2022/ENU/AutoCAD-MAC-Core/files/GUID-4F12A276-E19C-434C-B0E7-DF6C30B1D324.htm),
and [dynamic input](https://help.autodesk.com/cloudhelp/2026/ENU/AutoCAD-MAC-Core/files/GUID-3EBD4C17-F0A5-49FA-B131-4AABE2E727DB.htm).
References guide observable behavior; Autodesk code, branding and assets are not
part of MacCAD. Verify each option independently before promoting a partial row.

| Area | MacCAD status | Remaining work |
| --- | --- | --- |
| Space/Return | Command inputs and canvas accept both; idle repeats the last command; text prompts keep literal spaces | Additional command-specific defaults/options |
| Cancel/history/completion | Escape/Ctrl-[ / Ctrl-\ cancel; Ctrl-J/M accept/repeat; history with draft restoration; cycling Tab completion | Custom aliases, PGP/CUI configuration, fuzzy suggestions, command macros |
| Prompt sequencing | Line/polyline/spline, rectangle, circle, arc, ellipse, polygon, text, basic dimensions/leader, move/copy/rotate/scale/mirror, offset, corner edits, erase, join/explode/break, arrays and static blocks | Every AutoCAD option/alternate construction, transparent commands, option menus |
| Selection | Additive clicks, Shift removal, containing/crossing windows, All/Last/Previous in selection prompts, noun-first and command-first flows | Fence/lasso, polygon windows, selection cycling, filters, subobjects/groups |
| Coordinates | Absolute Cartesian, @relative Cartesian, absolute/relative polar, #absolute prefix, direct line/polyline distance toward pointer | Architectural/fractional units, coordinate filters, UCS, FROM/tracking offsets, dynamic relative defaults |
| Dynamic input | Editable cursor field and prompts sharing the command coordinator; F12 toggle | Separate editable length/angle boxes, Tab dimension locking, full pointer-input settings |
| Drawing aids | Object snaps, ortho, fixed 45° polar, grid and configurable grid snap; F2/F3/F7/F8/F9/F10/F12 | Tracking/acquisition, one-shot snap overrides, user polar angles, isometric drafting |
| View navigation | Trackpad pan/pinch, wheel zoom, middle-button pan/double-click fit, Z Extents/Window/Previous/factor, PAN | Named views, multiple tiled viewports, full ZOOM/PAN options |
| Native workspace | Documents/tabs, tool sets, command area, layers/properties, status, Cmd-1/3/4/5/6, native menus | Dockable/floating palettes, workspace customization and preferences |
| Basic geometry | Lines, zero-width bulged polylines, rectangles, circles, arcs, ellipses, points, regular polygons | XLINE/RAY, MLINE, DONUT, revision clouds; broader shape options |
| Curves | Rational B-splines, control-point construction and DXF geometry | Fit-point interpolation, SPLINEDIT/PEDIT conversion and knot editing |
| Object editing | Basic transforms, line break, open/close/reverse, connected polyline join, vertex-window stretch | Grip stretch/multifunction grips, ALIGN/LENGTHEN, two-point BREAK, PEDIT width/arc workflows |
| Trim/extend | Lines against one supplied infinite line | General curves, picked boundary sets, quick trim, edge/projection settings |
| Offset | Lines/circles/arcs/straight polylines, signed distance or side point; source style retained | Curved polylines/splines, through mode, self-intersection cleanup |
| Fillet/chamfer | Two intersecting lines, radius/distances | Other curves, polyline-wide edits, trim/multiple and angle options |
| Arrays | Rectangular/polar ordinary copies with prompts | Associative arrays, path arrays, per-item/context editing |
| Properties/layers | Geometry and colors/line types/weights; layer visibility/locking/search/current | Transparency/scales, freeze/thaw, layer states/filters, per-viewport overrides, full ByBlock behavior |
| Groups/constraints | Not implemented | Groups, geometric/dimensional constraints, parameters/formulas |
| Static blocks | Define, insert, nested references, uniform positive scale/rotation, explode | Names with spaces in command prompts, WBLOCK, block editor, nonuniform/mirrored inserts, attributes and dynamic blocks |
| Text | Basic text, multiline content, numeric height/rotation, spaces preserved | Rich MTEXT, SHX/font/style fidelity, justification, columns, FIND, fields, spelling |
| Dimensions/leaders | Horizontal linear, aligned, radius/diameter and simple leaders; independent geometry | Associativity, vertical/rotated linear, angular/ordinate/arc length, baseline/continue, styles/tolerances, multileader styles |
| Hatches/fills | Convex polygon solid/diagonal | Concave regions/holes, pick-point boundaries, associative hatch editing, pattern libraries, gradients |
| Tables/data | Basic distance, length and area reports | TABLE, attributes/data extraction, fields, linked data and schedules |
| Units/coordinate systems | mm/cm/m/in/ft metadata, WCS top view | Architectural/engineering formats, precision conventions, named UCS and transforms |
| Layouts/paper space | Not implemented | Multiple layouts, scaled viewports, viewport clipping/locking, title blocks/templates |
| References/underlays | Not implemented | DWG xrefs, raster/PDF/DWF underlays, clipping, reload/path management |
| Plotting | Single-sheet PDF sizes/orientation/fit/exact scale/color/selection/lineweights | Page setups, printer configuration, plot styles CTB/STB, multi-sheet publish and layout plotting |
| Native save/recovery | Versioned native saves, autosave, recovery-payload integration checks | Actual crash/force-quit qualification, disk-failure corpus |
| DWG | Experimental bundled LibreDWG import to supported subset | Verified full-fidelity read/write across representative versions; no DWG export today |
| DXF | Planar subset with visible losses | Full object/style/layout fidelity, proxy/unknown object retention and independent corpus qualification |
| Drawing maintenance | Exact duplicate removal and unused native block/layer purge | DWG AUDIT/RECOVER, standards checking, broader OVERKILL/PURGE semantics |
| Automation | Shared Rust command engine and internal JSON/C ABI | AutoLISP, user scripting, public plugin API and compatible automation |
| Performance | Batched Metal drawing and spatial indexing; CPU line-fixture measurements | Baseline-M1 frame-time/memory qualification and large professional drawings |
| Distribution | Public DMG, locally signed Sparkle feed/archive, checksums/source | Second-Mac update installation qualification; optional Apple notarization |

## Verification policy

Native workflow integration checks execute real Rust commands through the shipping
Swift coordinator. They cover Space/Return/repeat, command-first selection,
line Undo/Close, relative/polar coordinates, circle options, invalid-input recovery,
annotation spaces/rotation, polygon, tool interruption, zoom, offset side, arrays,
blocks/insert, join/explode/break, cancellation, function keys, completion and field
editor isolation. Core tests independently verify geometry and selection behavior.

No supported row means every AutoCAD option is implemented. In particular, the
cursor field currently uses command-line coordinate rules: `x,y` is absolute,
`@x,y` is relative. It does not silently emulate AutoCAD's separate dynamic pointer
coordinate defaults. Tests and documentation must describe that distinction.

## Next implementation groups

1. Finish everyday editing: grips, general curve trim/extend, PEDIT/SPLINEDIT,
   construction geometry, selection cycling and snap/tracking options.
2. Complete annotation: text/font/style fidelity, associative dimensions and leaders,
   complex hatches, tables, fields and attributes.
3. Add layouts/viewports, references/underlays, page setups and publishing.
4. Qualify file interchange and implement verified DWG writing; preserve unsupported
   records or explicitly diagnose every loss.
5. Add customization/automation and qualify large-drawing performance and recovery.

These remain real implementation tasks; they are not disabled controls or promises
that existing releases already contain them.
