# Changelog

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
