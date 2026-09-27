# Infinite Canvas

A native macOS infinite canvas: a small core, with everything on it (selecting, sticky notes,
ellipses, arrows modeled on tldraw's, task cards, validation, checklists, a detail panel) added by
plugins.
The plugin system is a port, in Swift, of the one in data-canvas. Start with
[docs/plugin-system.md](docs/plugin-system.md).

## Build, test, run

```sh
./build.sh && open build/InfiniteCanvas.app
./test.sh
```

`build.sh` calls `swiftc` directly, so it only needs the Command Line Tools (and `jq`, which macOS
includes from 15 on). It builds each module separately, in the order `Package.swift` declares, and
refuses to build if the code and the manifest disagree. `./build.sh graph` prints the module graph,
and `./build.sh audit` checks it without compiling.

## Boards

Each board is a file (`.canvasboard`, JSON) in its own window: File › New, Open, Open Recent, and Save,
as in any Mac document app. Boards save themselves as you work, and File › Revert To goes back to
earlier versions. The first launch opens the welcome board; Help › Welcome Board opens it again.
A board remembers, on each Mac, where you left its view.

## Controls

| Action | How |
| --- | --- |
| Pan | Two-finger scroll, or H (the hand tool) and drag; a fling slides on. V or Escape goes back to select |
| Zoom | Pinch, ⌘-scroll, or ⌘= / ⌘- / ⌘0 |
| New note | Double-click empty space, or N (the note tool) and click |
| New ellipse | O, then click; keep dragging to place it |
| New task | T, then click; edit it in the detail panel |
| New rectangle | R, then click (an example plugin) |
| Draw a line | L, then drag; Escape takes back the line being drawn (an example plugin) |
| Erase | E, then click or drag across shapes (an example plugin) |
| Select | Click a shape, or drag across empty space to select what the marquee touches (⌘: only what it encloses; ⇧: add to the selection) |
| Add to or remove from the selection | ⇧-click (or ⌘-click) a shape |
| Select all | ⌘A |
| Move shapes | Drag a shape. With several selected, drag any of them, or the space between them, to move them all; Escape puts them back |
| Edit a note | Double-click it, or select it and press Return; Escape to finish |
| Edit a shape's details | Select it; the detail panel on the right edits it. Escape gives the keyboard back to the canvas |
| Show or hide the detail panel | ⌃⌘I, or the Details button in the toolbar |
| Add a checklist to a note or task | The panel's Checklist tab: + adds an item, − or Delete removes the selected one |
| Delete shapes or arrows | Select them and press Delete |
| Arrow tool | A (V or Escape to go back to select) |
| Draw an arrow | Drag from one shape to another with the arrow tool. Arriving quickly aims at a shape's center; arriving slowly, or pausing inside the shape, aims at that exact spot |
| Aim into a shape | Hold ⌥ while drawing or dragging an end: the arrow runs all the way to the spot |
| Don't attach | Hold ⌘ while drawing or dragging an end |
| Snap angle | Hold ⇧ while dragging an end (15° steps) |
| Re-aim an end | Select the arrow and drag its end handle |
| Bend | Select the arrow and drag its middle handle |
| Toggle an arrowhead | Double-click an end handle |

An empty note (no text, no checklist) gets an orange outline (the validation plugin), and says why at the foot of the
detail panel (the validation-details bridge). A note with a checklist shows a done/total chip.
Hovering an ellipse shows its title (the titles example).

## Layout

```
Package.swift           the module graph: one line per module, with its layer
Sources/
  Geometry/             vector math, arcs, Camera
  Canvas/               the core: model, plugin registry, editor, the hand tool, drawing
  CanvasUI/             the AppKit view, the SwiftUI toolbar, and CanvasFocus
  Selection/            the selection horizontal: the select tool, marquee, handles, Delete and ⌘A
  Arrows/               arrows (a port of tldraw's arrow geometry and binding)
  StickyNotes/          sticky notes, with in-place editing
  Ellipses/             ellipses
  TaskCards/            task cards, edited only in the detail panel
  Validation/           the validation horizontal: rules, engine, outline
  DetailPanel/          the detail panel horizontal: tabs, sections, bindings, the inspector view
  ContextMenus/         the context menu horizontal: right-click items, groups, the selection's menu
  Checklists/           a horizontal any kind opts into: a checklist, its panel tab, menu items, a chip
  ValidationDetails/    a bridge between two horizontals: validation issues in the panel's footer
  Composition/          the shipped plugin list, and the welcome board
  InfiniteCanvas/       the SwiftUI app
Examples/               the smallest plugin for each pattern
  Rectangles/           a vertical: a kind, how it draws, a tool
  Polylines/            a shape without a frame: its own geometry, hit test and translation
  Eraser/               a tool with no shape, and a session
  Titles/               a horizontal: an extension point, sugar, an overlay
  EllipseTitles/        a bridge: opts ellipses into titles without either knowing
  Reordering/           menu items for every kind with a capability: the Arrange submenu
Tests/                  test executables (the core, each plugin with logic of its own, the examples,
                        the shipped app) and their support libraries, on a small macro-free kit
scripts/                re-records the proof of concept's behavior, which the tests hold the app to
```
