# Infinite Canvas

A native macOS infinite canvas: a small core, with everything on it (sticky notes, ellipses,
arrows modeled on tldraw's, validation) added by plugins. The plugin system is a port, in Swift, of
the one in data-canvas. Start with [docs/plugin-system.md](docs/plugin-system.md).

## Build, test, run

```sh
./build.sh && open build/InfiniteCanvas.app
./test.sh
```

`build.sh` calls `swiftc` directly, so it only needs the Command Line Tools (and `jq`, which macOS
includes from 15 on). It builds each module separately, in the order `Package.swift` declares, and
refuses to build if the code and the manifest disagree. `./build.sh graph` prints the module graph,
and `./build.sh audit` checks it without compiling.

## Controls

| Action | How |
| --- | --- |
| Pan | Two-finger scroll, or drag the background |
| Zoom | Pinch, ⌘-scroll, or ⌘= / ⌘- / ⌘0 |
| New note | Double-click empty space, or N (the note tool) and click |
| New ellipse | O, then click; keep dragging to place it |
| New rectangle | R, then click (an example plugin) |
| Erase | E, then click or drag across shapes (an example plugin) |
| Move a shape | Drag it |
| Edit a note | Double-click it, or select it and press Return; Escape to finish |
| Delete a shape or arrow | Select it and press Delete |
| Arrow tool | A (V or Escape to go back to select) |
| Draw an arrow | Drag from one shape to another with the arrow tool. Arriving quickly aims at a shape's center; arriving slowly, or pausing inside the shape, aims at that exact spot |
| Aim into a shape | Hold ⌥ while drawing or dragging an end: the arrow runs all the way to the spot |
| Don't attach | Hold ⌘ while drawing or dragging an end |
| Snap angle | Hold ⇧ while dragging an end (15° steps) |
| Re-aim an end | Select the arrow and drag its end handle |
| Bend | Select the arrow and drag its middle handle |
| Toggle an arrowhead | Double-click an end handle |

An empty note gets an orange outline (the validation plugin). Hovering an ellipse shows its title
(the titles example).

## Layout

```
Package.swift           the module graph: one line per module, with its layer
Sources/
  Geometry/             vector math, arcs, Camera
  Canvas/               the core: model, plugin registry, editor, tools, drawing
  CanvasUI/             the AppKit view and the SwiftUI toolbar
  Arrows/               arrows (a port of tldraw's arrow geometry and binding)
  StickyNotes/          sticky notes, with in-place editing
  Ellipses/             ellipses
  Validation/           the validation horizontal: rules, engine, outline
  Composition/          the shipped plugin list, and the welcome board
  InfiniteCanvas/       the SwiftUI app
Examples/               the smallest plugin for each pattern
  Rectangles/           a vertical: a kind, how it draws, a tool
  Eraser/               a tool with no shape, and a session
  Titles/               a horizontal: an extension point, sugar, an overlay
  EllipseTitles/        a bridge: opts ellipses into titles without either knowing
Tests/                  test executables (the core, each plugin with logic of its own, the examples,
                        the shipped app) and their support libraries, on a small macro-free kit
scripts/                re-records the proof of concept's behavior, which the tests hold the app to
```
