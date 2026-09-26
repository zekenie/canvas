# Infinite Canvas

A native macOS infinite canvas. Proof of concept: panning, zooming, sticky notes.

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
| Move note | Drag it |
| Edit note | Double-click it, or select it and press Return; Escape to finish |
| Delete note | Select it and press Delete |

## Layout

- `CanvasView.swift`: the AppKit view. Handles input and draws the grid and notes through the camera transform.
- `Model.swift`: `StickyNote` and `Camera` (world ↔ view mapping, zoom around a point).
- `NoteEditor.swift`: the `NSTextView` overlay used while editing a note.
- `Style.swift`: colors and metrics.
- `InfiniteCanvasApp.swift`: SwiftUI app shell and menu commands.
