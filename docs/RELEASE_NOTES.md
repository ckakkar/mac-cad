MacCAD 0.3 adds familiar command-driven drafting workflows. Apple Silicon, macOS 14+.
Download MacCAD.dmg and drag the app into Applications.

- Space/Return starts commands, accepts prompted values and repeats the previous
  command when idle. Annotation text retains spaces; normal native text fields
  retain macOS editing behavior.
- Select objects before or after starting modify commands. Additive selection,
  Shift removal and All/Last/Previous selection prompts.
- Continuing LINE with Close/Undo, absolute/relative Cartesian and polar entry,
  direct distances, circle 2P/3P/diameter and polygon construction options.
- Editable cursor input, sequential text height/rotation/content, transforms,
  offset side, line corner edits, erase/join/explode/break, arrays and static blocks.
- Contextual prompts/defaults, serialized input, invalid-input recovery, history,
  cycling completion, CAD control/function keys, palette toggles and view commands.
- ZOOM Extents/Window/Previous/factor, PAN, middle-button navigation and a right-click
  Enter/Repeat menu.

Verification: 32 core tests; native command-field/workflow checks plus existing
bridge, save/reopen, recovery-payload, Metal/PDF and bundled DWG fixture checks.
Signed update feed/archive, checksums and corresponding source are included. The
private Sparkle signing key stays in the owner's local macOS Keychain.

This is still a 2D drafting preview, **not a complete AutoCAD clone**. General curve
trimming, grips, rich annotations, complex hatches, layouts/viewports, xrefs,
DWG export and scripting are unfinished. Command option coverage is partial; see
AUTOCAD_PARITY.md and COMPATIBILITY.md in the repository. DWG import remains
experimental and exchange is lossy. Cursor input currently uses command-line
coordinate rules: use @ explicitly for relative values.

The app is ad-hoc signed, not Apple-notarized. First launch may require Open Anyway
in System Settings → Privacy & Security. Update signatures are separate from Apple
Developer ID signing; installation on a second Mac still needs qualification.
