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
| Cancel/history/completion | Escape/Ctrl-[ / Ctrl-\ cancel; Ctrl-J/M accept/repeat; history with draft restoration; cycling Tab completion; autocomplete list with alias targets first; prompts and inputs echoed as `Command: L` history; F2 expanded history | Custom aliases, PGP/CUI configuration, fuzzy/synonym suggestions, command macros |
| Command line | Live prompt with clickable `[Option]` keywords; fixed three-line history; right-click Enter/Cancel/options or Repeat/Recent Input | Floating/transparent command line, input search options, command-line font settings |
| Prompt sequencing | Line/polyline/spline, rectangle, circle, arc, ellipse, polygon, text, basic dimensions/leader, move/copy/rotate/scale/mirror, offset, corner edits, erase, join/explode/break, arrays and static blocks | Every AutoCAD option/alternate construction, transparent commands, option menus |
| Selection | Additive clicks, Shift removal, containing (blue, solid) and crossing (green, dashed) windows, selection preview under the pickbox, All/Last/Previous, noun-first and command-first flows | Fence/lasso, polygon windows, selection cycling, QSELECT filters, subobjects/groups |
| Coordinates | Absolute Cartesian, @relative Cartesian, absolute/relative polar, #absolute prefix, direct line/polyline distance toward pointer | Architectural/fractional units, coordinate filters, UCS, FROM/tracking offsets, dynamic relative defaults |
| Dynamic input | Prompt tooltip following the crosshair, input box once typing starts, distance/angle readout along rubber bands; same command coordinator; F12 toggle | Separate editable length/angle boxes, Tab dimension locking, full pointer-input settings |
| Drawing aids | Running object snap modes (Endpoint, Midpoint, Center, Node, Quadrant, Intersection, Insertion, Perpendicular, Tangent, Nearest) with per-mode AutoSnap markers and tooltips; ortho; polar increments 5–90°; adaptive grid with major lines; grid snap; Drafting Settings sheet; F3/F7/F8/F9/F10/F12 and ⌘L/⌘B/⌘U/⇧⌘D | Object snap tracking/acquisition, one-shot snap overrides, Extension/Apparent snaps, additional polar angles, isometric drafting |
| View navigation | Trackpad pan/pinch, smart zoom (two-finger double-tap) between extents and previous view, wheel zoom, middle-button pan/double-click fit, Z Extents/Window/Previous/factor (one Previous step per gesture), PAN, viewport [–] menu | Named views, multiple tiled viewports, ViewCube/navigation bar, full ZOOM/PAN options |
| Native workspace | Unified customizable toolbar; window tabs as drawing tabs; Tool Sets sidebar with filter and collapsible groups; Properties/Layers inspector; status bar aid toggles with Osnap/Polar menus; AutoCAD for Mac menu bar order with validated items, checkmarks and named Undo/Redo; ⌘1/3/4/5/6, ⌘I, ⌘0 Clean Screen, ⇧⌘H palettes; Settings (⌘,); light/dark model space; crosshair, pickbox, aperture and grip sizes | Floating/dockable palettes, saved workspaces, Content/Reference/Project palettes, CUI customization |
| Basic geometry | Lines, zero-width bulged polylines, rectangles, circles, arcs, ellipses, points, regular polygons | XLINE/RAY, MLINE, DONUT, revision clouds; broader shape options |
| Curves | Rational B-splines, control-point construction and DXF geometry | Fit-point interpolation, SPLINEDIT/PEDIT conversion and knot editing |
| Object editing | Basic transforms with dragged previews (move/copy/rotate/mirror), line break, open/close/reverse, connected polyline join, vertex-window stretch | ALIGN/LENGTHEN, two-point BREAK, PEDIT width/arc workflows, interactive STRETCH command |
| Grips | Grips on selected objects between commands; hover/hot colors; one hot grip stretches with live preview, snaps, ortho/polar and typed absolute/relative points; Escape cools the grip; lines, polylines (vertices, straight and bulged edge midpoints), circles, arcs, ellipses, splines, text, points, inserts, dimensions, leaders, hatches | Space-cycling grip modes (MOVE/ROTATE/SCALE/MIRROR), multiple hot grips, Copy/Base options, multifunction grip menus, grips on many large objects |
| Trim/extend | Lines against one supplied infinite line | General curves, picked boundary sets, quick trim, edge/projection settings |
| Offset | Lines/circles/arcs/straight polylines, signed distance or side point; source style retained | Curved polylines/splines, through mode, self-intersection cleanup |
| Fillet/chamfer | Two intersecting lines, radius/distances | Other curves, polyline-wide edits, trim/multiple and angle options |
| Arrays | Rectangular/polar ordinary copies with prompts | Associative arrays, path arrays, per-item/context editing |
| Properties/layers | Grouped Properties with AutoCAD property names, X/Y fields, `*VARIES*`, polyline vertex stepper and read-only measurements; interactive MATCHPROP; layer palette with current/on/lock, color/linetype/lineweight, rename, delete of empty layers, isolate, search and context menus | Transparency/scales, freeze/thaw, layer states/filters, per-viewport overrides, full ByBlock behavior, quick properties |
| Groups/constraints | Not implemented | Groups, geometric/dimensional constraints, parameters/formulas |
| Static blocks | Define, insert, nested references, uniform positive scale/rotation, explode | Names with spaces in command prompts, WBLOCK, block editor, nonuniform/mirrored inserts, attributes and dynamic blocks |
| Text | Basic text, multiline content, numeric height/rotation, spaces preserved | Rich MTEXT, SHX/font/style fidelity, justification, columns, FIND, fields, spelling |
| Dimensions/leaders | Horizontal linear, aligned, radius/diameter and simple leaders; independent geometry | Associativity, vertical/rotated linear, angular/ordinate/arc length, baseline/continue, styles/tolerances, multileader styles |
| Hatches/fills | Convex polygon solid/diagonal | Concave regions/holes, pick-point boundaries, associative hatch editing, pattern libraries, gradients |
| Tables/data | Basic distance, length and area reports | TABLE, attributes/data extraction, fields, linked data and schedules |
| Units/coordinate systems | mm/cm/m/in/ft metadata, WCS top view | Architectural/engineering formats, precision conventions, named UCS and transforms |
| Layouts/paper space | Not implemented | Multiple layouts, scaled viewports, viewport clipping/locking, title blocks/templates |
| References/underlays | Not implemented | DWG xrefs, raster/PDF/DWF underlays, clipping, reload/path management |
| Plotting | Native Print (⌘P) and Page Setup (⇧⌘P) with plot area (extents/selection/display), scale, monochrome/colors and lineweights in the print panel; Export PDF sheet with paper/orientation/scale | Named page setups, plot styles CTB/STB, multi-sheet publish and layout plotting |
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
editor isolation, plus hot-grip stretch/cancel/undo, interactive MATCHPROP, Edit ▸
Undo inside LINE, named undo menu titles, prompt option parsing, autocomplete,
Circle ▸ Center, Diameter, layer rename and print rendering. Core tests independently
verify geometry, grips, undo labels, layer rename/delete/isolate and snap modes.

LINE Undo is revision-guarded: after an intervening document edit (such as a layer
change), it asks you to finish/cancel LINE before undoing other changes. It does
not undo the unrelated edit or consume pending points.

No supported row means every AutoCAD option is implemented. In particular, the
cursor field currently uses command-line coordinate rules: `x,y` is absolute,
`@x,y` is relative. It does not silently emulate AutoCAD's separate dynamic pointer
coordinate defaults. Tests and documentation must describe that distinction.

## Next implementation groups

1. Finish everyday editing: grip modes and multiple hot grips, general curve
   trim/extend, PEDIT/SPLINEDIT, construction geometry, selection cycling and
   object snap tracking.
2. Complete annotation: text/font/style fidelity, associative dimensions and leaders,
   complex hatches, tables, fields and attributes.
3. Add layouts/viewports, references/underlays, page setups and publishing.
4. Qualify file interchange and implement verified DWG writing; preserve unsupported
   records or explicitly diagnose every loss.
5. Add customization/automation and qualify large-drawing performance and recovery.

These remain real implementation tasks; they are not disabled controls or promises
that existing releases already contain them.
