# Infinite Canvas

Native macOS infinite canvas (SwiftUI shell, AppKit canvas). Early prototype.

## Build

- `./build.sh && open build/InfiniteCanvas.app`. It calls `swiftc` directly and wraps the binary in an `.app`, because SwiftPM (`swift build`) is broken with this machine's Command Line Tools.
- If the build fails with "this SDK is not supported by the compiler", a stale newer SDK is being picked. Prefix the command with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.
- Sources compile in Swift 6 language mode. Keep them free of warnings.

## Architecture

- `CanvasView` draws everything itself in `draw(_:)` through `Camera` (world ↔ view coordinates). Model positions are world units; overlay sizes (handles, outlines, hit margins) are view points, divided by `camera.zoom` when drawn in world space.
- The only subview is `NoteEditor`, a scaled `NSTextView` shown over a note while it's being edited.
- Shapes are `CanvasShape` values in `CanvasView.shapes` (back to front); what else a shape can do comes from further protocols. Drawing and indicator outlines are a type switch in `CanvasView` for now.
- Arrows know shapes only through the `Connectable` protocol (`Model.swift`), and find them via `CanvasView.connectables`. Keep specific shape types (`StickyNote`, `Ellipse`) out of arrow code (`Arrow`, `ArrowGeometry`, `CanvasView+Arrows.swift`).
- UI constants live in `Style` (main-actor isolated). Pure geometry (`Geometry.swift`, `ArrowGeometry.swift`) is nonisolated, so its constants live on those types.

## Arrows follow tldraw

- Arrow behavior and geometry deliberately mirror tldraw's arc arrows: binding precision and timers, clipping, arrowhead gaps, handles and hint overlays. The constants come from tldraw's source.
- Check tldraw (`packages/tldraw/src/lib/shapes/arrow/`, `bindings/arrow/`, `overlays/`) before changing arrow behavior, and call out any intentional deviation.

## Verifying UI changes

- Screen capture isn't permitted here.
- To verify, drive `CanvasView` offscreen: put it in an unshown `NSWindow`, call its mouse handlers with synthesized `NSEvent`s (with real timestamps; pointer speed matters for arrows), and render with `cacheDisplay(in:to:)` to PNG.
- Compile every source except `InfiniteCanvasApp.swift` alongside the harness's own `main.swift`.
