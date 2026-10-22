MacCAD 0.4.8 opens real DWG drawings far more faithfully and makes the workspace
feel like a native Mac app laid out like AutoCAD for Mac. Apple Silicon, macOS 14+.
Download MacCAD.dmg and drag the app into Applications.

**DWG and DXF drawings**

- A new DXF reader, also used for DWG files after the bundled LibreDWG converts
  them, keeps hatches (holes, stored patterns, solid fills), dimension graphics,
  leaders, block attributes, mirrored and non-uniform blocks, wide polylines,
  linetypes with LTSCALE, frozen layers and the full AutoCAD color table.
- Text uses its style's TrueType font, justification, width factor, wrapping,
  paragraph indent and stacked fractions.
- Large drawings open: a 38 MB architectural DWG with 100,957 objects and 8,630
  blocks opens in about 6 seconds on an M2.
- The import report counts everything left out (layouts, external references,
  MLEADER, OLE and image contents, extended data). The first import asks before
  opening a copy; you can turn that question off.
- Mouse wheels zoom about the cursor; trackpads pan. Large drawings zoom smoothly
  because the scene is rebuilt only when needed.

**Native workspace**

- Customizable unified toolbar, drawings as window tabs, a Tool Sets sidebar, a
  Properties/Layers inspector, Settings (⌘,) and sheets.
- AutoCAD for Mac menu order and shortcuts: ⌘1/3/4/5/6 palettes, ⌘0 Clean Screen,
  ⌘L ortho, ⌘B snap, ⌘U polar, ⇧⌘D dynamic input, ⌘P Print, ⇧⌘P Page Setup.
  Zoom Extents is View ▸ Zoom ▸ Extents or `Z` `E`.
- Crosshair and pickbox, AutoSnap markers, selection preview, grips with hot-grip
  stretching, dragged move/copy/rotate/mirror previews and a light background.
- Command line with clickable options, autocomplete, F2 history and Recent Input.
- Properties with AutoCAD names and `*VARIES*`; layer rename, delete and isolate;
  MATCHPROP; named Undo/Redo; printing through the macOS print panel.

Verification: 48 core tests, including DXF reader tests built from group codes;
native command and workflow checks; bridge, save/reopen, recovery, Metal/PDF and
bundled DWG fixture checks; and local rendering checks on private architectural
drawings. Signed update feed/archive, checksums and corresponding source are
included. The private Sparkle key stays in the owner's local macOS Keychain.

This is still a 2D drafting preview, **not a complete AutoCAD clone**. **MacCAD
cannot save DWG yet**: save as `.maccad` or export DXF, which flattens hatches and
MacCAD-drawn annotations. Imported dimensions and hatches are not associative.
Layouts/viewports, xrefs, MLEADER, tables, grip modes other than stretch, object
snap tracking, general trimming and scripting are unfinished. Compare imported
drawings with the original before relying on them. See AUTOCAD_PARITY.md and
COMPATIBILITY.md. Printing may ask for local network access to find printers.

The app is ad-hoc signed, not Apple-notarized. First launch may require Open Anyway
in System Settings → Privacy & Security. Update signatures are separate from Apple
Developer ID signing; installation on a second Mac still needs qualification.
