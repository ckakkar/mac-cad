# mac-cad agent guide

## Product direction

Build an open-source CAD application that feels native to macOS and is optimized
for Apple Silicon. The initial audience is architects and interior designers.
Full AutoCAD-for-Mac functionality is a long-term roadmap, not a claim about the
current app or the first alpha. Implement original code and an original interface;
use documented formats and observable behavior to establish compatibility.

Agreed initial defaults:

- Apple Silicon only, macOS 14 or newer.
- Swift with AppKit/SwiftUI for the native interface; Metal for the canvas.
- Rust for documents, geometry, indexing, commands, undo/redo, and file adapters.
- Fully open-source dependencies. Project license: GPL-3.0-or-later, accommodating
  LibreDWG. Include dependency licenses when distributing binaries.
- Local documents and offline drafting. No account or cloud requirement.
- Direct GitHub downloads, **not the Mac App Store**.

## Architecture and implementation

- Keep the Rust document authoritative. Do not create a second editable document
  model in Swift. Swift may hold immutable presentation snapshots.
- Toolbar actions, gestures, and typed CAD commands must use the same Rust command
  engine. Commands must validate before committing, be cancellable, and participate
  in undo/redo. Failed commands must leave the document and history unchanged.
- Keep model coordinates double precision. Use camera-relative coordinates before
  converting to GPU floats. Do not round document geometry to display precision.
- Use a narrow C ABI with explicit allocation ownership, matching free functions,
  documented lifetimes, and panic containment. No per-entity FFI calls per frame.
- Serialize access to each document. Keep parsing and expensive scene preparation
  off the UI thread. Batch rendering, cull by viewport, use spatial indexes for
  picking/snapping, and invalidate only what changed where practical.
- Use native document windows, menus and shortcuts, file dialogs, toolbars, layer
  and property inspectors, accessibility labels, and system appearance support.
  Keep a command bar, familiar aliases, and precise numeric entry alongside them.
- Prefer focused modules over a single growing application or engine source file.
  Keep build scripts reproducible and dependencies pinned with lockfiles.

## AutoCAD-for-Mac interaction target

The owner explicitly wants familiar AutoCAD-for-Mac 2D features and workflows.
Maintain `docs/AUTOCAD_PARITY.md` as a truthful behavior/feature inventory. Do not
call the application a complete clone or declare full parity while gaps remain.

- Space and Return accept command inputs and repeat the previous command when
  idle. Annotation text must retain spaces; other native text fields must keep
  normal macOS editing behavior.
- Support prompted, cancellable command sessions, both preselection and selection
  after invocation, exact numeric/relative/polar input, context-specific options,
  defaults, history and completion. Route toolbar/menu/keyboard paths consistently.
- Command sessions contain transient prompts and points only; Rust owns committed
  geometry, document selection, validation, file semantics and undo/redo.
- Serially process input and selection changes. Validate before advancing prompts;
  failed operations keep their current prompt and leave committed geometry intact.
- Verify actual native field editors and command sequences, not only isolated
  handlers. Use Autodesk's public Mac documentation as the behavior reference.

## Milestones

1. Foundation: native app, Rust workspace, bridge, licensing, build scripts, CI.
2. Working slice: draw a line by pointer or numeric command, select/move it,
   undo/redo, save, close, and reopen.
3. Drafting alpha: lines, polylines with bulges, circles, arcs, rectangles, text;
   move/copy/rotate/scale/mirror/trim/extend/offset/erase; units, snapping, ortho/polar
   aids, layers, static blocks, linear/aligned dimensions, basic hatches, and
   single-sheet scaled PDF output. Include tested DXF exchange and experimental
   DWG import diagnostics.
4. Later: external references, multiple layouts/viewports, richer annotations and
   plotting, dynamic blocks, verified DWG export, scripting, and 3D. Maintain a
   feature/compatibility matrix rather than assuming these are already supported.

An incomplete milestone must be described as incomplete. Do not present scaffolded
adapters, disabled controls, synthetic benchmarks, or untested imports as working
professional CAD capabilities.

## Documents and interoperability

- Use a versioned native format, atomic saves, and recoverable autosave data.
- Alpha exchange baseline: a documented DXF R2013 subset using `dxf-rs` behind an
  adapter, plus experimental DWG import through a separate LibreDWG adapter.
- Never overwrite an imported DWG or imply lossless DWG round trips. DWG writing
  is outside the alpha. Save imported work as a native document or export DXF.
- Report unsupported objects, styles, layouts, fonts, and other losses visibly.
  Make lossy import/export a deliberate user choice; do not silently drop content.
- Validate untrusted native/DXF/DWG input, file versions, IDs, references, units,
  finite coordinates, geometric degeneracy, recursive blocks, and resource limits.
- Keep original geometry separate from tessellated display data. Test precision,
  bulges, transforms, text, blocks, dimensions, layers, and units independently of
  screenshots. Unsupported features must be listed in the compatibility matrix.
- Do not commit proprietary drawings or extracted Autodesk code/assets. Use
  generated fixtures or drawings with documented redistribution permission.
- REA is optional for specific behavior investigations, not a runtime CAD engine.

## Distribution: follow `ckakkar/trav`

The reference is `https://github.com/ckakkar/trav`; a local checkout may be available
at `../trav`. Read its current release workflow when working on distribution.
Follow its user-facing model while retaining this app's native Swift stack:

- A stable `MacCAD.dmg` asset on GitHub Releases; drag the app into Applications.
- Run CI on pushes to `main`; version releases monotonically from the release
  line plus the commit count, and release the exact tested SHA.
- The owner chose to keep the private Sparkle key local in macOS Keychain account
  `xyz.ckakkar.maccad`. Sign releases locally with that account. Do not export,
  transfer, or add it to GitHub secrets without new explicit authorization. The
  public key in `config/SparklePublicKey` belongs to MacCAD. Cloud publishing is
  opt-in through `MACCAD_CLOUD_RELEASES=true` and is currently disabled.
- In-app update checks, release notes, signed update artifacts, and an HTTPS feed.
  Use a maintained native updater such as Sparkle rather than a homegrown installer.
- Update signatures are separate from Apple code signing. Never disable signature
  verification or ship a placeholder signing key as a functioning updater.
- Apple Developer ID signing and notarization can be optional, as in Trav.
  Ad-hoc builds must accurately document the first-launch Gatekeeper experience.
- Local builds must work without release secrets. Document required release
  configuration and fail clearly when publication prerequisites are missing.
- Do not read/reuse Trav's private signing keys, copy secrets, or modify Trav.
  Do not publish releases or change repository secrets unless explicitly requested.

## Verification and handoff

- Run Rust formatting checks, clippy with warnings denied, and relevant core tests.
- Build the Swift app and packaged bundle on macOS; lint the plist and verify the
  bundle's architecture, linkage, and code signature. Record any unavailable check.
- Test the complete draw/edit/undo/save/reopen flow across the actual C bridge.
  Exercise command cancellation, malformed inputs, failed saves, and crash recovery.
- Test native and supported DXF round trips by comparing geometry/properties and
  rendered appearance. DWG needs representative, legally shareable fixtures.
- Benchmark 10k and 100k entity drawings, with fixture contents, hardware, timing,
  and memory methodology recorded. The target is responsive editing and 60 fps
  pan/zoom for the 100k fixture on baseline M1; never infer it from core timings alone.
- Keep README, contributor/build instructions, compatibility matrix, and changelog
  consistent with delivered behavior. Report what changed, what passed, and what
  remains experimental or unverified. Do not commit or push without being asked.
