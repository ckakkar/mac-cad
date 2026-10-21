# 0.2 verification record

Local environment: Apple M2, 16 GiB RAM, macOS 27.0.1, arm64 release builds.

`make check` passes Rust formatting and clippy with warnings denied, 30 core tests,
Swift/C/Rust draw/select/move/undo/redo/save/reopen, and packaged app verification
(plist, arm64, nested signatures, linkage and license notices). App integration
exercises coordinated NSDocument save/reopen, recovery payloads, worker queues,
binary geometry, Metal pipeline compilation, PDF generation, and bundled LibreDWG
imports of upstream 2000/2013/2018 `Line.dwg` fixtures. Original upstream fixtures
come from the pinned GNU source archive, not customer drawings.

The core tests cover rational spline evaluation, bulges, transforms, fillet
geometry, corner-edit atomicity, arrays/history, window/crossing selection,
intersection/perpendicular/tangent snaps, clipboard block-name collisions,
format migration, DXF geometry/styles/preview handling and bounded block expansion.
The native example plan and numeric ellipse entry were also exercised in the UI.

## CPU benchmark

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
Gatekeeper first download, and baseline-M1 60 fps. See COMPATIBILITY.md for gates.
