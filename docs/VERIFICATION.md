# 0.4 verification record

Local environment: Apple M2, 16 GiB RAM, macOS 27.0.1, Command Line Tools only (no
Xcode), arm64 release builds.

`make check` passes Rust formatting and clippy with warnings denied, 48 core tests,
Swift/C/Rust draw/select/move/undo/redo/save/reopen, and packaged app verification
(plist, arm64, nested signatures, linkage and license notices). App integration
exercises coordinated NSDocument save/reopen, recovery payloads, worker queues,
binary geometry, Metal pipeline compilation, PDF generation, the print plot view
and bundled LibreDWG imports of upstream 2000/2013/2018 `Line.dwg` fixtures.
Native saves and recovery files are written and read by the Rust core, and a
native save to a `.dwg` path is refused.

DXF reader tests (`tests/dxf_import.rs`) build drawings from group codes and
check: hatch pattern lines that touch boundary corners stay inside and have the
exact expected length; MTEXT paragraph indent; TEXT justification points; stacked
fractions; block base points, entity layers and ByBlock inheritance; mirrored,
non-uniform inserts with attributes; frozen layers; dimension graphics blocks;
reported paper-space and unsupported objects; DXF export of attribute values and
anonymous dimension blocks.

Local checks on private drawings that are not committed (on Apple M2, 16 GB):
a 38 MB AutoCAD 2004-format farmhouse plan converts in 4.8 s, and the 184 MB DXF
is read in 0.6 s (100,957 model-space objects, 8,630 blocks, 118 layers). Building
the full-extents scene takes 0.25 s (2.1 million segments, 259k fill triangles).
A native save is 94 MB, serializes in 0.12 s and reads back exactly. Snapshot
renders of the ground-floor sheet were inspected for hatch clipping, text
placement and dimension graphics; they were not yet compared side by side with
AutoCAD. A 419 KB street-lighting library (40 references to 64 blocks) renders
completely.

New core tests cover grip points and stretch edits for lines, circles, arcs and
straight/bulged polyline segments; grip commits, invalid/locked refusals and undo;
grip previews; named undo/redo steps; hover picking without selection changes;
running object snap mode filtering; and layer rename/delete/isolate with undo.

CommandSmoke executes the command field editor and prompted sequences listed for
0.3, plus hot-grip relative stretch, Escape cooling a grip, interactive MATCHPROP,
Edit ▸ Undo inside LINE, menu validation titles (“Undo Circle”) and disabled Copy,
prompt option parsing, autocomplete ranking, Circle ▸ Center, Diameter and layer
rename.

The native workspace was also driven with synthesized pointer and keyboard events
and inspected in screenshots: toolbar layout and validation, Tool Sets, crosshair
and pickbox, selection preview, window selection with `*VARIES*`, grips and live
hot-grip preview, Endpoint/Midpoint AutoSnap markers, rubber-band distance/angle,
autocomplete, F2 history, context menu, Layers and Properties tabs, Settings,
Drafting Settings, the print panel's Plot accessory and preview, light model space
and window tabs. VoiceOver, keyboard-only navigation of every control, multiple
displays and printing to physical printers were not qualified.

## CPU benchmark (0.2 geometry/render baseline)

One local release-mode run of `make bench`, generated LINE-only fixtures, single
Rust process; validation/index and full-scene construction timed separately.
Picking performs 1,000 indexed queries. Buffer size is segment bytes only.

| Entities | Validate/index | Full scene | 1,000 picks | Segment buffer |
| ---: | ---: | ---: | ---: | ---: |
| 10,000 | 1.44 ms | 0.95 ms | 0.34 ms | 640,000 bytes |
| 100,000 | 19.08 ms | 12.99 ms | 0.38 ms | 6,400,000 bytes |

These are individual CPU measurements, not a statistical benchmark, GPU frame
rate, end-to-end interaction latency or total process memory. They do not qualify
baseline-M1 performance or complex curved/annotated drawings.

## Not established by these checks

Professional DWG/DXF appearance fidelity, lossless round trips, full AutoCAD 2D
parity, actual force-quit recovery, a second-Mac signed update installation,
Gatekeeper first download, baseline-M1 60 fps, and the frame-time cost of 4× MSAA
and the pointer-driven CoreGraphics overlay on large drawings. See COMPATIBILITY.md.
