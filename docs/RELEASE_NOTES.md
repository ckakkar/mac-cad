MacCAD is an open-source, native 2D drafting preview for Apple Silicon and macOS 14+.
Download **MacCAD.dmg**, open it and drag the app into Applications.

- New workspace with grouped tools, editable object properties, searchable layers,
  command history, completion and native drawing/editing menus.
- Ellipses, splines, polygons, points, multiline text, radial dimensions and leaders.
- Window/crossing selection, fillet/chamfer, arrays, join/break/stretch, expanded
  offsets, cross-document clipboard and improved object snapping.
- Entity/layer colors, linetypes and lineweights; configurable PDF paper, scale,
  orientation, color and selection-only output.
- Bundled LibreDWG import: no separate Homebrew install needed. Expanded DXF subset
  and visible conversion/import reports. Native version 1 files migrate to version 2.
- Signed Sparkle updates, checksums and complete corresponding source. The private
  update-signing key remains in the owner's local Keychain.

**Limits:** this release does not provide all AutoCAD for Mac 2D capabilities.
DWG saving, layouts, external references, dynamic blocks, associative annotations,
rich hatch/font fidelity and scripting are not implemented. DWG import remains
experimental and DXF exchange is lossy; review reports and compare with originals.
See the repository compatibility matrix before production use.

**Verification:** 30 Rust tests and native Swift/C/Rust bridge, bundle/signature,
NSDocument save/reopen, recovery-payload, Metal/PDF checks, plus bundled import of
upstream LibreDWG 2000/2013/2018 line fixtures. Professional corpus fidelity,
force-quit recovery and baseline-M1 frame rates remain unqualified.

**First launch:** this build is ad-hoc signed, not Apple-notarized. macOS may require
Open Anyway in System Settings → Privacy & Security. Sparkle update signatures
are separate from Apple Developer ID signing.
