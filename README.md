# MacCAD

A native, open-source 2D CAD app for Apple Silicon. Built for architectural and
interior drafting with Swift, AppKit/SwiftUI, Metal, and a Rust document engine.

**Early development.** This is a working foundation and a limited drafting tool,
not an AutoCAD replacement yet. Real-world drawing fidelity and baseline-M1 frame
rates have not been qualified. See [compatibility](docs/COMPATIBILITY.md).

## Build and run

Requires an Apple Silicon Mac, macOS 14+, Xcode Command Line Tools with a matching
macOS SDK, Rust stable, Python 3, and network access for the first dependency fetch.
Full Xcode is useful for profiling and notarization, but is not required for the
Swift Package Manager build.

```sh
make run       # build and open build/MacCAD.app
make check     # formatting, clippy, core tests, app build and integration checks
make dmg       # build/MacCAD.dmg, with a drag-to-Applications install
make bench     # 10k/100k entity CPU benchmarks
```

The first Swift build compiles system modules and can take several minutes.
Build products and module caches stay inside the checkout.

## Drawing

Use the toolbar for selection, lines, polylines, rectangles, circles, arcs, text,
aligned dimensions, rectangular hatches, move, and copy. Select **Open example
plan** in an empty document for a generated architectural sketch.

- Click to place points. Shift-click adds/removes objects from the selection.
- Type a command or alias (`LINE`, `L`, `CIRCLE`, `C`, etc.) to start a tool, then
  enter `x,y` points or `@dx,dy` relative coordinates in the command bar.
- Use full commands for numeric editing: `LINE 0,0 3000,0`, `MOVE 500,0`,
  `ROTATE 0,0 90`. The terminal button shows the command reference.
- Escape cancels an unfinished gesture. Return on the canvas finishes a polyline.
- Trackpad: two-finger pan, pinch to zoom. Mouse: wheel zoom, Option-drag pan.
- Layers have visibility and locking. Snap, ortho, polar and grid controls sit in
  the status bar. Units are explicit; changing units does not rescale geometry.
- ⌘Z / ⇧⌘Z undo/redo, ⌘A selects editable objects, ⌘0 fits the drawing.

Save editable work as `.maccad`. Native documents use AppKit coordinated saves,
autosave and recovery, backed by a versioned Rust document format. **Export DXF**
produces a DXF R2013 subset; **Export Scaled PDF** creates a single A3 sheet at a
chosen scale, warning if the drawing will be clipped.

## DXF and experimental DWG

DXF import opens a new native drawing and displays an import report. Supported
geometry includes planar lines, circles, arcs, zero-width lightweight polylines
with bulges, basic text, and static uniformly scaled block inserts. Other data may
be omitted or simplified; inspect the report and compare with the original.

Experimental DWG import uses the open-source LibreDWG `dwg2dxf` helper from
`/opt/homebrew/bin` or `/usr/local/bin`. Install LibreDWG separately to enable it:

```sh
brew install libredwg
```

The helper is optional and is not bundled in the initial app. Conversion runs in
a separate process with a timeout and imports the resulting DXF subset. **DWG
saving is not implemented.** Imported DWG/DXF source files are never native save
destinations. There is no claim of lossless exchange or AutoCAD plugin support.

## Direct distribution

MacCAD follows [Trav](https://github.com/ckakkar/trav)'s GitHub distribution model:
an app in a DMG, an Applications shortcut, and signed in-app updates. It is **not
an App Store app**. The configured stable asset name is `MacCAD.dmg` in
[GitHub Releases](https://github.com/ckakkar/mac-cad/releases). No release is
published by local builds.

CI checks pull requests and pushes to `main`. After successful CI, the release
workflow builds the exact tested commit, publishes the DMG, a signed Sparkle
update feed/archive, checksums, and corresponding source including locked Rust
dependencies. Publishing first requires the app's own update signing keys; see
[CONTRIBUTING.md](CONTRIBUTING.md). Local builds work without those secrets and
clearly indicate that the updater is unconfigured.

Without optional Apple Developer ID signing/notarization, downloads may require
**Open Anyway** in System Settings → Privacy & Security on first launch.

## Architecture and roadmap

`crates/cad-core` owns the document, double-precision geometry, commands,
transaction history, spatial index, and format adapters. `native/MacCAD` contains
the native document app and Metal canvas. A serial document queue and the C ABI in
`native/CCadCore` keep ownership explicit. Scene geometry crosses the bridge in
binary batches; the GPU receives camera-relative floats.

Next milestones: representative drawing qualification, richer editing/snapping,
reference drawings, layouts/viewports, annotation and plotting fidelity, verified
DWG writing, scripting, and 3D. Full AutoCAD-for-Mac parity remains the long-term
goal. [AGENTS.md](AGENTS.md) records project decisions and implementation rules.

## License

[GPL-3.0-or-later](LICENSE). Third-party license texts are included in built apps.
The DXF adapter uses [dxf-rs](https://github.com/ixmilia/dxf-rs), optional DWG
conversion uses [LibreDWG](https://www.gnu.org/software/libredwg/), and updates use
[Sparkle](https://sparkle-project.org/).
