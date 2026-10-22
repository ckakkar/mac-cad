# Drafting in MacCAD

Use the example plan in an empty document to try tools. Geometry uses the current
drawing units; `UNITS mm` changes interpretation, without rescaling objects.

## Command entry

Click a drawing tool or enter its name to start a gesture. Click points on the
canvas, or enter coordinates (`1000,500`), relative coordinates (`@500,0`), and
supported scalar values such as a circle radius. Escape cancels; Return finishes
polylines/splines. Up/Down recalls commands, Tab completes names. Full commands:

```text
LINE 0,0 3000,0
RECT 0,0 8000,6000
PLINE 0,0 1000,0:0.414213562373095 1000,1000 close
CIRCLE 4000,3000 600
ARC 0,0 1000 0 90
ARC3 0,0 500,500 1000,0
ELLIPSE 0,0 2000,0 0.5
SPLINE 0,0 1000,2000 2000,2000 3000,0
POLYGON 6 0,0 1000
POINT 0,0
TEXT 1000,1000 150 Living room
MTEXT 0,0 150 First line\PSecond line
DIM 0,0 8000,0 -500
DIMALIGNED 0,0 1000,1000 200
DIMRADIUS 0,0 1000,0 1400,400
DIMDIAMETER 0,0 1000,0 1400,400
LEADER 0,0 500,500 150 Note
HATCH diagonal 100 0,0 2000,0 2000,1000 0,1000
```

Angles are degrees. ELLIPSE takes center, major-axis endpoint, minor/major ratio.
SPLINE uses control points rather than passing through fit points. PLINE's optional
`:bulge` belongs to the edge starting at that vertex. Hatches require convex
boundaries and support `solid` or `diagonal`.

## Select and edit

Click adds objects; Shift-click removes them. Drag left-to-right for objects entirely inside
the window; drag right-to-left for crossing objects. Use Properties to edit shape
parameters, layer and style. ⌘A selects visible unlocked objects. ⌘C/⌘X/⌘V copies,
cuts and pastes MacCAD objects between documents; pasted objects shift by 150 units.

Full numeric commands below use the current selection. Bare command names
can also prompt for selection after invocation:

```text
MOVE 500,0
COPY 1000,0
ROTATE 0,0 90
SCALE 0,0 2
MIRROR 0,0 0,1000
OFFSET 200
FILLET 200
CHAMFER 100 200
ARRAYRECT 2 3 1000 1000
ARRAYPOLAR 0,0 6 360
JOIN
BREAK 500,0
STRETCH 0,0 1000,1000 100,0
REVERSE
CLOSE
OPEN
ERASE
```

OFFSET uses signed distance and supports lines, circles, arcs and straight
polylines. FILLET/CHAMFER operate on two intersecting lines. JOIN connects open
lines/polylines, preserving bulges; BREAK splits one line at the supplied point.
STRETCH moves selected line/polyline vertices inside its window by the final vector.
Arrays create ordinary editable copies. MIRROR keeps the originals.

`TRIM 0,0 0,1000 -100,0` and `EXTEND 0,0 0,1000 -100,0` operate on selected lines
against the infinite boundary defined by the first two points, using the final
point to choose the trim side/extend end. General curve trimming is not available.

`BLOCK door 0,0` makes a static block from the selection relative to a base point;
`INSERT door 2000,0 1 90` inserts it at scale 1 and 90 degrees. `EXPLODE` converts
supported compound objects into simpler geometry. Nested definition shapes inherit
insertion properties.

`CHPROP color #FF8800`, `CHPROP linetype Dashed`, `CHPROP lineweight 0.5` and
`CHPROP layer Walls` set selection properties. `MATCHPROP 1` uses an existing object
ID as the style source. `SELECTSIMILAR` matches selected shape types and layers.
`OVERKILL` removes exact duplicates; `PURGE` removes unused blocks/layers.
`AREA` / `LIST` reports selection length/area; curves can use sampled approximations.

## Layers, drawing aids and files

The inspector creates/selects layers and controls visibility, locking, color,
linetype and weight. `LAYISO` isolates selected objects' layers; `LAYUNISO` currently
shows all layers rather than restoring a previous isolation state. `LAYON`,
`LAYOFF`, `LAYLOCK`, `LAYUNLOCK` and `LAYMCUR` are also available.

F3 toggles object snaps and F8 toggles ortho; polar and grid controls sit below
the canvas. Analytic intersection/perpendicular/tangent snaps apply to lines,
circles and arcs. ⌘0 fits the drawing. Use two-finger pan/pinch or wheel zoom and
Option-drag pan.

Save as `.maccad` for editable native geometry. Open DXF/DWG to import a new native
drawing and review all warnings. Exporting DXF flattens some annotations/fills;
DWG writing is unavailable. Export Scaled PDF lets you choose paper, orientation,
scale or Fit, color and selection-only output. Plot at actual size when printing
an exact-scale PDF; printer Fit-to-page changes its scale.

See [COMPATIBILITY.md](docs/COMPATIBILITY.md) for detailed exchange and tool limits.

## Familiar command workflow (0.3)

**Space and Return are equivalent at CAD command prompts.** With no active command
and an empty input they restart the last command; they do not replay its previous
coordinates. Space stays a literal space in annotation text prompts and ordinary
property/file-dialog text fields. Paste a full numeric command to use the compact
syntax above. Option-Space can insert a literal separator while editing a command.

For example, enter these responses, pressing Space or Return after each row:

```text
L
0,0
@3000<0
@2000<90
C
```

This draws two continuing line segments and closes to the starting point. During
LINE, PLINE and SPLINE, `U` removes the last segment/point; `C` closes LINE/PLINE.
Blank input finishes the current path. Escape (also Ctrl-[ / Ctrl-\) cancels the
unfinished part and clears selection; already committed LINE segments remain.
LINE Undo refuses to cross an intervening document edit, such as a layer change;
finish/cancel LINE before undoing those changes.

Start `M`, pick objects or enter `A` (All), confirm selection with Return/Space,
then enter a base point and a second point. Preselecting objects also works. Click
selection is additive; Shift removes objects. `L` (Last) and `P` (Previous) are
selection options, interpreted in that prompt's context.

```text
M
A
<Return>
0,0
@500,250
```

In coordinates, `x,y` and `#x,y` are absolute; `@dx,dy` is relative to the preceding
point. `@distance<angle` is relative polar, while `distance<angle` is polar from
world origin. A single distance during LINE/PLINE follows the current pointer
direction, respecting ortho/polar aids. The cursor input currently uses these same
command-line rules; it does not assume relative coordinates without `@`.

Other prompted sequences:

- `C` → center → radius; `D` at the radius prompt switches to diameter. `2P`/`3P`
  at the first prompt constructs a circle through diameter endpoints/three points.
- `A` → three points. `C` at the first prompt switches to center/start/end.
- `EL` → major-axis endpoints → minor radius/point. `C` first uses center/axis endpoint.
- `POL` → side count → center → `I`/`C` → radius/point.
- `T` → insertion → height → rotation → text. Space inserts text; Return completes.
  `MT` skips the rotation prompt and accepts `\P` paragraph breaks.
- `RO`/`SC` → selection if needed → base point → angle/factor.
- `MI` → selection → two axis points → erase originals Yes/No (default No).
- `O` → offset distance → selection if needed → side point(s) → Return to finish.
- `F`/`CHA` → radius/distances → selection if needed → Return. These still support
  two intersecting lines, not all AutoCAD corner-edit options.
- `E`, `J`, `X` → selection if needed → Return to erase/join/explode.
- `BR` → selected line → break point. This is a single-point split.
- `AR` → selection → rows → columns → column spacing → row spacing.
- `ARRAYPOLAR` → selection → center → item count → fill angle.
- `B` → selection → new block name → base point.
- `I` → existing block name → insertion → scale → rotation.
  Current block-name prompts require one word; blocks/arrays remain static.

`Z` → `E`, `W` or `P` zooms to extents, a two-point window, or the previous view.
`ZOOM 2X` doubles zoom. `P` starts drag-to-pan; Return/Space ends it. Middle-drag
pans; double middle-click fits. Right-click opens an Enter/Repeat, Cancel, Undo menu.

Up/Down cycles input history and restores your draft when returning to the newest
entry. Tab/Shift-Tab cycles command completions. Ctrl-J / Ctrl-M also accepts/repeats.
F2 controls history, F3 object snaps, F7 grid display, F8 ortho, F9 grid snap, F10
polar and F12 cursor input. `SNAP 100` sets grid-snap spacing; GRID/SNAP/OSNAP/ORTHO/
POLAR/DYNMODE accept ON/OFF (this is a small settings subset, not full system-variable
compatibility). Cmd-1/3/4/5/6 toggles tools/command window/layers/properties/status;
Cmd-R regenerates and Cmd-+/− zooms. Fn may be needed for function keys on Mac.

The [parity audit](docs/AUTOCAD_PARITY.md) lists missing AutoCAD behaviors and
features; this workflow update does not establish full product parity.
