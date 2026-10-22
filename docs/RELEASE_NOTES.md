MacCAD 0.4 makes the workspace feel like a native Mac app laid out like AutoCAD for
Mac. Apple Silicon, macOS 14+. Download MacCAD.dmg and drag the app into Applications.

- Native window structure: customizable unified toolbar, drawings as window tabs,
  a Tool Sets sidebar, a Properties/Layers inspector, Settings (⌘,) and sheets.
- AutoCAD for Mac menu order and shortcuts: ⌘1/3/4/5/6 palettes, ⌘0 Clean Screen,
  ⌘L ortho, ⌘B snap, ⌘U polar, ⇧⌘D dynamic input, ⌘P Print, ⇧⌘P Page Setup.
  Zoom Extents is now View ▸ Zoom ▸ Extents or `Z` `E` (⌘0 is Clean Screen).
- Model space: crosshair and pickbox, AutoSnap markers and tooltips, selection
  preview, grips with hot-grip stretching, dragged previews for move/copy/rotate/
  mirror, distance/angle readouts, smoother lines and a light background option.
- Command line: clickable prompt options, autocomplete, history echo, F2 history,
  Recent Input and a context menu with the current command's options.
- Properties with AutoCAD names and `*VARIES*`; layer rename, delete and isolate;
  interactive MATCHPROP; named Undo/Redo menu items.
- Print through the macOS print panel with plot area, scale and plot style options.

Verification: 39 core tests; native command-field and workflow checks including
grips, MATCHPROP, undo titles and print rendering; bridge, save/reopen, recovery,
Metal/PDF and bundled DWG fixture checks. Signed update feed/archive, checksums and
corresponding source are included. The private Sparkle key stays in the owner's
local macOS Keychain.

This is still a 2D drafting preview, **not a complete AutoCAD clone**. Grip modes
other than stretch, object snap tracking, general curve trimming, rich annotations,
complex hatches, layouts/viewports, xrefs, DWG export and scripting are unfinished.
See AUTOCAD_PARITY.md and COMPATIBILITY.md. DWG import remains experimental and
exchange is lossy. Printing may ask for local network access to find printers.

The app is ad-hoc signed, not Apple-notarized. First launch may require Open Anyway
in System Settings → Privacy & Security. Update signatures are separate from Apple
Developer ID signing; installation on a second Mac still needs qualification.
