# Infinite Canvas

A native macOS infinite canvas. Proof of concept: panning, zooming, sticky notes, ellipses, and
arrows that bind to them (modeled on tldraw's arrows).

## Build and run

```sh
./build.sh && open build/InfiniteCanvas.app
```

`build.sh` calls `swiftc` directly, so it only needs the Command Line Tools. With Xcode you can
also open `Package.swift` and run from there.

## Controls

| Action | How |
| --- | --- |
| Pan | Two-finger scroll, or drag the background |
| Zoom | Pinch, ⌘-scroll, or ⌘= / ⌘- / ⌘0 |
| New note | Double-click empty space |
| New ellipse | O (or the toolbar), then click; keep dragging to place it |
| Move a note or ellipse | Drag it |
| Edit note | Double-click it, or select it and press Return; Escape to finish |
| Delete a shape or arrow | Select it and press Delete |
| Arrow tool | A (V or Escape to go back to select), or the toolbar |
| Draw an arrow | Drag from one shape to another with the arrow tool. Arriving quickly aims at a shape's center; arriving slowly, or pausing inside the shape, aims at that exact spot |
| Aim into a shape | Hold ⌥ while drawing or dragging an end: the arrow runs all the way to the spot |
| Don't attach | Hold ⌘ while drawing or dragging an end |
| Snap angle | Hold ⇧ while dragging an end (15° steps) |
| Re-aim an end | Select the arrow and drag its end handle |
| Bend | Select the arrow and drag its middle handle |
| Toggle an arrowhead | Double-click an end handle |

## Layout

- `CanvasView.swift`: the AppKit view. Handles input and draws the grid, shapes, and selection through the camera transform.
- `CanvasView+Arrows.swift`: arrow interaction (binding to connectable shapes, precise/exact aiming, bending, moving) and arrow overlays.
- `ArrowGeometry.swift`: resolves an arrow against the shapes it's bound to: where it's clipped, the gap before arrowheads, arcs. A port of tldraw's arrow geometry.
- `Geometry.swift`: vector math, arcs, and line/arc–polygon intersections.
- `Model.swift`: `CanvasShape`, `Connectable` (all arrows know about a shape), `StickyNote`, `Ellipse`, `Arrow` and its bindings, and `Camera` (world ↔ view mapping, zoom around a point).
- `NoteEditor.swift`: the `NSTextView` overlay used while editing a note.
- `Style.swift`: colors and metrics.
- `InfiniteCanvasApp.swift`: SwiftUI app shell and menu commands.
