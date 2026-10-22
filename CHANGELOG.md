# Changelog

## 0.4.8 — DWG drawings

- Replace the DXF importer with MacCAD's own reader, written from the DXF
  reference. DWG files still convert through the bundled LibreDWG first. It reads
  hatches (any boundary, holes, stored patterns, solid fill), dimension graphics,
  leaders, block attributes, MINSERT, mirrored and non-uniform inserts, block
  entity layers with ByBlock/layer-0 inheritance, wide polylines, 2D solids,
  construction lines, image/OLE frames, object coordinate systems, layer
  frozen/plot flags, drawing linetypes with LTSCALE, PDMODE points, text styles and
  the full 256-color ACI table. The import report counts every omitted object type.
- Draw text with its style's TrueType family, cap-height sizing, TEXT
  justification (including Aligned/Fit), width factor and obliquing, and MTEXT
  attachment, wrapping, line spacing, paragraph indent and stacked fractions.
- Raise import limits for real drawings (1 GiB DWG, 4 GiB DXF, 5 million objects)
  and give LibreDWG five minutes. Summarize its decoding problems by kind.
- Save and open `.maccad` files in the Rust core (format version 3) so large
  drawings never cross the bridge as one JSON value; float values round-trip
  exactly.
- The import confirmation can be turned off with “Don’t ask again”.
- Mouse wheels zoom about the cursor (1.2× per notch, Settings can reverse it),
  and trackpad gestures pan. The canvas redraws its cached scene while zooming
  and rebuilds it only when the view leaves it or curves need finer detail.
- DXF export writes block entity layers and styles, polyline widths, text style
  and MTEXT attachment, drawing linetypes, anonymous block flags and attribute
  values (as text); lineweight ByLayer is no longer written as 0.00 mm.
- Fix hatch pattern lines that touched a boundary corner drawing outside it.
- Add `MacCAD --render-snapshot <drawing> <out.pdf> [window]` for rendering checks
  without the user interface.

## 0.4 — Native workspace

- Rebuild each drawing window around native AppKit structure: a customizable
  unified toolbar, window tabs as drawing tabs, a Tool Sets sidebar and a
  Properties/Layers inspector in an `NSSplitViewController`, and sheets instead of
  app-modal alerts. Command errors go to the command line with a beep. Drawings
  dropped onto model space open like Dock drops.
- Reorganize the menu bar in AutoCAD for Mac's order (Insert, Format, Tools, Draw,
  Dimension, Modify…) with validated items, checkmarks, named Undo/Redo, Open
  Recent, Duplicate/Rename/Move To/Revert, Page Setup/Print, Services and Window
  tab items. Align shortcuts with Autodesk's Mac list (⌘0 Clean Screen, ⌘I, ⌘L,
  ⌘B, ⌘U, ⇧⌘D, ⇧⌘H, ⌘,, ⌥⌘W); zoom extents moves to View ▸ Zoom and `Z E`.
- Draw AutoCAD's crosshair and pickbox, per-mode AutoSnap markers and tooltips,
  selection preview, grips, dragged move/copy/rotate/mirror previews, tool-specific
  rubber bands, distance/angle readouts and the UCS icon. Add 4× MSAA lines, an
  adaptive grid with major lines, a light model-space option and clipped text.
- Add grip stretching in the Rust engine for every drawable type, with live
  previews, typed points, snaps and undo. Add named undo steps, hover picking,
  running object snap modes, and layer rename/delete/isolate.
- Command line: clickable prompt options, autocomplete with descriptions, echoed
  history, F2 floating history, Recent Input and context-sensitive right-click.
  Interactive MATCHPROP; Edit ▸ Undo inside LINE removes the last segment.
- Properties use AutoCAD property names, X/Y fields, `*VARIES*`, polyline vertex
  stepping and measurements. Status bar aids gain Osnap/Polar menus.
- Add Settings (⌘,), Drafting Settings (`DS`) and Drawing Units (`UN`) sheets,
  native Print with a Plot accessory (area, scale, style, lineweights) and an
  Export PDF save sheet with paper and scale options.
- Convert the editor to Observation so pointer motion updates only the coordinate
  readout. Verified by 39 core tests and new native workflow integration checks.

This is still a 2D drafting preview, not a complete AutoCAD for Mac clone.

## 0.3 — Command workflows

- Space/Return starts commands, accepts prompts and repeats the previous command;
  annotation spaces and standard native text editing remain intact.
- Add serialized transient command sessions shared by tools, menus and keyboard:
  selection after invocation, defaults/options, line Close/Undo and command history.
- Add editable cursor input, absolute/relative polar coordinates, circle 2P/3P and
  diameter input, three-point arc default, ellipse axis construction and polygon
  inscribed/circumscribed prompts.
- Add prompted text height/rotation/content; move/copy/rotate/scale/mirror,
  offset-side, corner edits, erase, join/explode/break, arrays and static blocks.
- Make selection additive with Shift removal; support All/Last/Previous prompts,
  cycling completion, CAD control shortcuts, view/palette toggles, grid snap,
  ZOOM options, PAN and a right-click Enter/Repeat menu.
- Verify keyboard/command sequences through the real native field editor and Rust
  core, plus 32 core tests and existing app/bundle/DWG integration checks.
- Add an explicit AutoCAD-for-Mac parity audit; major 2D capabilities remain missing.

## 0.2 — Drafting preview

- Rework the workspace around grouped tools, native Draw/Dimension/Modify menus,
  editable properties, searchable layers and command history/completion.
- Add ellipses, rational control-point splines, points, polygons, three-point arcs,
  multiline text, radial/diameter dimensions and simple leaders.
- Add fillet/chamfer for lines, rectangular/polar arrays, connected polyline join,
  line break, vertex stretch, reverse/open/close, expanded offsets and cleanup.
- Add window/crossing selection, cross-document clipboard, geometry/style edits,
  layer colors/linetypes/weights and screen/plot lineweight rendering.
- Add analytic line/circle/arc intersections and base-relative perpendicular/tangent
  snaps; correct arc endpoints/quadrants and expand curve snap coverage.
- Add single-sheet PDF paper/orientation, Fit/exact scale, color/monochrome and
  selection-only plotting; remove selection highlights from plot output.
- Expand DXF with ellipse/spline/point, legacy polylines, simplified MTEXT and basic
  dimensions. Avoid duplicate layer 0, tolerate preview thumbnails and unsigned
  color metadata, and retain explicit loss reports.
- Bundle a pinned, statically linked LibreDWG 0.14 import helper and its source and
  licenses; exercise upstream DWG 2000/2013/2018 line fixtures.
- Migrate native version 1 to version 2 with default entity/layer properties; bound
  compact block expansion and avoid worker-queue destruction deadlocks.
- Configure the real MacCAD Sparkle public key, local Keychain release signing,
  source-revision metadata, corresponding-source archives and signed GitHub assets.
  Cloud publication remains disabled while the private key stays local.
- Verify 30 core tests plus native bridge, bundle, document/Metal/PDF/DWG integration.

This remains a limited 2D preview. DWG export, layouts/viewports, xrefs/images,
associative annotations, complex hatches and full AutoCAD parity are not delivered.

## 0.1 — Foundation

- Establish the Swift/AppKit/SwiftUI Apple Silicon app, Metal canvas, Rust engine,
  C bridge, safe native saves, command history, index and undo/redo.
- Add basic drawing/transforms, layers, static blocks, dimensions, convex hatches,
  DXF subset exchange, external DWG conversion and scaled A3 PDF output.
- Add CI, DMG/update packaging, benchmarks, GPL licensing and project instructions.
