---
paths:
  - "Sources/Snapping/**"
  - "Tests/SnappingTests/**"
  - "Tests/CompositionTests/SnappingShippedTests.swift"
  - "Tests/CanvasTests/TranslationAdjusterTests.swift"
---

# Snapping

Snapping what a drag moves to the frames of the shapes in view: targets, ties, modifiers, guides and cost.

Related: [editor](editor.md), [selection](selection.md), [plugins and kinds](plugins-and-kinds.md) ([every topic](../../CLAUDE.md#map)).

In the guide, `docs/plugin-system.md`: [Snapping](../../docs/plugin-system.md#snapping).

## Architecture

- Snapping (a feature, on the core alone; `docs/plugin-system.md`, "Snapping"): what a drag moves (a `TranslatingSession`: the selection dragged, a shape just placed) snaps to the frames of the shapes in view, as one rect (the frames it moves, together, as the drag began), along each axis on its own, to the nearest within 8 view points (tldraw's `snapThreshold`) of: an edge or its middle onto another frame's (tldraw's corners and center); its middle onto the middle of the space between two neighbors, if it fits there; its far or near edge where the space between two neighbors would repeat before or after them (tldraw's bounds snapping, but spaces only between neighbors, each frame's nearest past either edge that overlaps it across the axis, within 64 frames along it, and only for what shares their stretch across by more than the threshold, so a snap along the other axis never leaves it without its guide; `SnapTargets`, pure, world units). Ties go to edges and middles, then the near edge. It lands exactly on the line (the core's translation adjuster moves each box by exactly what it says on a changed axis), and along the other axis follows the pointer exactly. Always on, unlike tldraw's (on only while ⌘ is held), once the pointer is past the drag threshold from the press, so a click's lone box moves no more than the pointer; ⌘ or ⌃ held once the drag is under way lets what moves follow the pointer exactly, at once (Keynote's ⌘; either frees an arrow's end too; at the press ⌘ on a shape starts a marquee and ⌃ is the secondary click), and ⇧, which keeps the drag to one axis (the core's), snaps and guides along that axis alone (`SnapTargets.snap(_:movedBy:within:only:)`). Kinds with a frame (`BoxShapeProps`) snap and are snapped to, locked ones too (they stay put, and aren't part of what moves); arrows and lines neither (tldraw's arrows can't be snapped to, `canSnap`). What's in view is read when the drag first snaps, again once the camera moves or a shape the drag doesn't move changes (`SnapState`, a service); no view (`viewportSize` zero, headless), nothing to snap to. Guides (`editor.snapGuides`: `.alignment`, a line through the corners and centers on it with a ✕ at each; `.spacing`, equal spaces side by side with ticks, those in a row too; tldraw's look, in its snap red) draw with the session. Reading 10,000 frames in view costs some 6 ms, each event after 0.12 ms (`./build.sh bench`).

## Testing

- For snapping, SnappingTests hold `SnapTargets` pure and drag CanvasTesting's boxes with a move tool of their own (`snapHarness`, `movePlugin(moves)`: a press starts a `TranslatingSession` from the press, the select tool's lone box, since SnappingTests can't use Selection) in a 1000 × 800 view at 100% (a test that snaps needs `viewportDidResize`: with no view nothing is in view), reading `editor.snapGuides`; a key let go counts as held until `h.wait(150)`. CanvasTests' TranslationAdjusterTests hold the core's hook with a fixture adjuster, and CompositionTests' SnappingShippedTests the shipped pieces through the select tool.
