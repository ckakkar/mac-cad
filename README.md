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
See the [compatibility matrix](docs/COMPATIBILITY.md) before using production drawings.

## Drawing

The workspace combines native document windows and menus with grouped Draw,
Modify and Annotation tools, a Metal canvas, a command bar and a properties/layers
inspector. Open the example plan from an empty document to try it.

- Draw lines, bulged polylines, rectangles, polygons, circles, arcs, ellipses,
  control-point splines, points, text, basic dimensions, leaders and convex hatches.
- Move, copy, rotate, scale, mirror, offset, trim, extend, fillet, chamfer, join,
  break, stretch, array and explode objects. Edit geometry, color, linetype,
  lineweight and layer in Properties. Changes participate in undo/redo.
- Click to select; Shift-click adds/removes. Drag left to right for a containing
  window, or right to left for crossing selection. Hidden/locked objects are excluded.
- Enter a tool name (`LINE`, `CIRCLE`, etc.), then click or enter `x,y` coordinates,
  `@dx,dy` relative coordinates, or supported scalar values. Full numeric commands
  work too: `LINE 0,0 3000,0`, `ROTATE 0,0 90`.
- Up/Down recalls command history; Tab completes names. Escape cancels a gesture;
  Return finishes a polyline/spline. ⌘3 toggles history, ⌘5 toggles Properties.
- Trackpad: two-finger pan, pinch to zoom. Mouse: wheel zoom, Option-drag pan.
  ⌘0 fits the drawing. F3 toggles snaps; F8 toggles ortho.
- ⌘Z / ⇧⌘Z undo/redo; ⌘A selects editable objects; ⌘C/⌘X/⌘V copy/cut/paste
  MacCAD objects between drawings. Units are explicit; changing units does not rescale.

The question-mark button opens the command reference. See [USAGE.md](USAGE.md)
for examples and the limits of each editing operation.

Save editable work as `.maccad`. Version 2 documents retain geometry and properties;
version 1 documents migrate on opening. AppKit coordinates safe saves and autosave.
Export DXF produces an explicitly limited R2013 subset. Export Scaled PDF offers
A4–A0, Letter, Legal and Tabloid, orientation, exact scale or Fit, drawing colors or
monochrome, and optional selection-only output with plotted lineweights.

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
