# MacCAD

A native, open-source 2D CAD app for Apple Silicon. Swift, AppKit/SwiftUI and Metal
around a double-precision Rust document engine, with local files and offline drafting.

[**Download MacCAD.dmg**](https://github.com/ckakkar/mac-cad/releases/latest/download/MacCAD.dmg)
· Apple Silicon · macOS 14+ · [Releases](https://github.com/ckakkar/mac-cad/releases)

Open the DMG and drag MacCAD into Applications. This build is ad-hoc signed and
**not notarized**; the first launch may need **Open Anyway** in System Settings →
Privacy & Security. Updates are signed with MacCAD's own Sparkle key.

**Drafting preview.** MacCAD has useful drawing and editing tools, but does not yet
have all of AutoCAD for Mac's 2D capabilities. DWG import is experimental; DWG
saving, layouts, external references and full annotation fidelity are still missing.
See the [compatibility matrix](docs/COMPATIBILITY.md) and [AutoCAD parity audit](docs/AUTOCAD_PARITY.md) before using production drawings.

## Drawing

Each drawing opens in a native document window (and window tab) laid out like
AutoCAD for Mac: a Tool Sets sidebar, model space with an AutoCAD-style crosshair,
a command line with clickable prompt options, a status bar of drafting aids, and a
Properties/Layers inspector, under a customizable unified toolbar. The menu bar
follows AutoCAD for Mac's order and its published Mac shortcuts. Open the example
plan from an empty drawing to try it.

- Draw lines, bulged polylines, rectangles, polygons, circles, arcs, ellipses,
  control-point splines, points, text, basic dimensions, leaders and convex hatches.
- Move, copy, rotate, scale, mirror, offset, trim, extend, fillet, chamfer, join,
  break, stretch, array and explode objects, with dragged previews. Edit geometry,
  color, linetype, lineweight and layer in Properties. Changes participate in
  undo/redo, and Edit ▸ Undo names the action (“Undo Move”).
- Select objects to show grips; click a grip and pick or type a point to stretch it.
  Objects under the pickbox highlight before you click. Click adds to selection;
  Shift-click removes. Drag left to right for a window, right to left for crossing.
- Type a command anywhere over the canvas (`L`, `CIRCLE`, …) and press **Space or
  Return**; an autocomplete list appears as you type. Then click or enter `x,y`,
  `@dx,dy`, `@distance<angle` or values. Full numeric commands work too:
  `LINE 0,0 3000,0`, `ROTATE 0,0 90`.
- Object snaps show AutoCAD's marker shapes and names; choose running modes from
  the status bar Osnap menu or Drafting Settings (`DS`). F3 object snap, F7 grid,
  F8/⌘L ortho, F9/⌘B snap, F10/⌘U polar, F12/⇧⌘D dynamic input, F2 history.
- ⌘1 Tool Sets, ⌘3 command line, ⌘4 Layers, ⌘5/⌘I Properties, ⌘6 status bar,
  ⌘0 Clean Screen, ⇧⌘H all palettes, ⌘, Settings, ⌘P Print, ⇧⌘P Page Setup.
- Trackpad: two-finger pan, pinch to zoom, two-finger double-tap for extents. Mouse:
  wheel zoom, middle or Option-drag pan. `Z` `E` zooms to extents; ⌘= / ⌘− zoom.
- ⌘Z / ⇧⌘Z undo/redo; ⌘A selects editable objects; ⌘C/⌘X/⌘V copy/cut/paste
  MacCAD objects between drawings. Units are explicit; changing units does not rescale.

Modify commands accept preselection or prompt for objects after invocation.
Help ▸ Command Reference lists numeric command forms. See [USAGE.md](USAGE.md)
for examples and the limits of each editing operation.

Save editable work as `.maccad`. Version 2 documents retain geometry and properties;
version 1 documents migrate on opening. AppKit coordinates safe saves, autosave and
versions. Export DXF produces an explicitly limited R2013 subset. File ▸ Print plots
through the macOS print panel (printer or PDF) with plot area, scale, plot style and
lineweight options; File ▸ Export ▸ PDF offers A4–A0, Letter, Legal and Tabloid,
orientation, exact scale or Fit, colors or monochrome, and selection-only output.

## DXF and DWG

Open a DXF or DWG to import into a new native document. Review the import report:
unsupported objects and styling are omitted or simplified, and the original source
is never overwritten by native saves. Compare the result against the original.

The DMG **includes LibreDWG 0.14**; a separate Homebrew install is unnecessary.
DWG conversion runs in a separate process with a timeout and visible diagnostics,
then uses the same DXF subset importer. Smoke checks exercise upstream LibreDWG
line fixtures from DWG 2000, 2013 and 2018; this does not qualify arbitrary drawings.
**DWG export is not implemented.** There is no lossless exchange or plugin claim.

## Build and run

Requires Apple Silicon, macOS 14+, matching Xcode Command Line Tools, Rust stable,
Python 3 and `pkgconf` (`brew install pkgconf`). Network is needed for first fetch.
Full Xcode is useful for profiling/notarization but not required to build.

```sh
make run       # build and open build/MacCAD.app
make check     # formatting, clippy, core tests, bridge, bundle and app checks
make dmg       # package build/MacCAD.dmg
make bench     # 10k/100k entity CPU benchmarks (not GPU frame rates)
```

The first build compiles LibreDWG and Swift system modules and can take several
minutes. Sources and caches stay inside the checkout. The GPL corresponding-source
release archive includes locked Rust dependencies and the LibreDWG source tarball.

## Direct distribution

MacCAD follows [Trav](https://github.com/ckakkar/trav)'s GitHub DMG distribution
model, with signed Sparkle updates, version-specific update archives, checksums and
corresponding source. It is not a Mac App Store app. CI checks pushes and pull
requests. Release signing currently uses the owner's **local Keychain**; the private
key is not stored in GitHub. Cloud publishing is opt-in and disabled by default.
See [CONTRIBUTING.md](CONTRIBUTING.md) for release instructions.

## Architecture and roadmap

`crates/cad-core` owns documents, commands, history, geometry, spatial indexing and
exchange. `native/MacCAD` owns the native UI and Metal renderer. A serial document
queue and the C ABI in `native/CCadCore` transfer immutable geometry batches; GPU
coordinates are camera-relative floats while model geometry remains double precision.

Next: professional drawing qualification, layouts/viewports, references, associative
annotations, richer hatches/fonts, verified DWG writing and scripting. Full AutoCAD
for Mac parity remains a long-term goal. GPU frame rates on baseline M1 and actual
force-quit recovery still need qualification. [AGENTS.md](AGENTS.md) records decisions.

## License

[GPL-3.0-or-later](LICENSE). Built apps include dependency license texts. DXF uses
[dxf-rs](https://github.com/ixmilia/dxf-rs), DWG import uses
[LibreDWG](https://www.gnu.org/software/libredwg/), and updates use
[Sparkle](https://sparkle-project.org/). MacCAD is an independent project and is not
affiliated with Autodesk. AutoCAD and DWG are Autodesk trademarks.
