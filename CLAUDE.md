# Infinite Canvas

Native macOS infinite canvas (SwiftUI shell, AppKit canvas), built from compiled-in plugins.

## Build and test

- `./build.sh && open build/InfiniteCanvas.app`. It calls `swiftc` directly and wraps the binary in an `.app`, because SwiftPM (`swift build`) is broken with this machine's Command Line Tools. Each module is compiled with only its dependency closure on `-I`.
- `./test.sh` builds every module but the app (debug, `-D DEBUG`) and runs each test executable. `TEST_FILTER=substring ./test.sh` runs the matching tests, and fails if none match. Every `Suite` a test target declares must be passed to `runTests` in its `main.swift`; test.sh fails otherwise.
- `Package.swift` is the module graph: one target per line, each tagged `// layer:`. Its header lists the layers and what each may use (foundation, ui, horizontal, vertical, bridge, composition, app, testsupport, test). Non-test modules live in `Sources/X`, or `Examples/X` with `path:`; test modules in `Tests/X`.
- Every build.sh mode audits first; `./build.sh audit` does only that. It fails on a cycle or a forbidden layer edge; on any difference between that table and SwiftPM's own evaluation of `Package.swift`; on a module whose imports, as the compiler parses them, aren't exactly its declared dependencies; on an import inside `#if`, `canImport(<project module>)`, `@_exported`, `@_implementationOnly` or `@testable`; and on a module writing another module's `ShapeKind`, `PluginID` or `ToolID` string without depending on it. The graph (the `-I` closure plus MemberImportVisibility) keeps the core from referencing plugin types; the id check keeps any module from writing another module's kind, tool or plugin id as a literal. The editor's host API (input, cursor, drawing, delegate) is `@_spi(Host)`, and only the ui, testsupport and test layers may import it.
- `./build.sh graph`, `dot`, and `api <Module>` (a module's public interface) are for reading the graph.
- If the build fails with "this SDK is not supported by the compiler", a stale newer SDK is being picked. Prefix the command with `SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`.
- Sources compile in Swift 6 language mode. Keep them free of warnings (build.sh passes `-warnings-as-errors`).

## Architecture

Read `docs/plugin-system.md` first; it's the guide to the plugin system, with the examples.

- `Canvas` (the core) knows no particular shape or concern (its one tool is Select), and must stay that way. A concern like validity is declared by a plugin (an `ExtensionPoint` in its own module) and other plugins opt in; if the core seems to need to know about one, add a generic extension point instead.
- A plugin is a value (`CanvasPlugin`) that registers into a frozen `Registry`. A kind is its props type (`static let kind`); its behavior is a stateless `ShapeDefinition` (only `render` is required for box kinds, and `geometry` drives hit testing and outlines); more comes from capability protocols (`Editable`, `HandleProviding`, `CustomTranslation`, `PaintOrderAnchored`). Behavior intrinsic to a kind is a capability; behavior any plugin can add is an extension point. Conform to `ShapeDefinition` (and capabilities), `Tool`, `Session` and `EditorService` in an extension: only there does the compiler flag a near miss on a defaulted requirement.
- Layers: horizontals (Validation, Titles) declare extension points and import no vertical; verticals (Arrows, StickyNotes, Ellipses, Rectangles, Eraser) import no other vertical; bridges (EllipseTitles) connect them. The shipped list is `ShippedPlugins.all` in Composition.
- `CanvasEditor` is the headless brain (document, camera, selection, tools, sessions, input, drawing); `CanvasView` (CanvasUI) only turns NSEvents into editor calls and hosts the editing view. Plugins can't import CanvasUI.
- Change documents only with `editor.transact`. Tools see `Pointer` values, never `NSEvent`; timers go through `editor.scheduler`. Model positions are world units; overlay sizes (handles, outlines, hit margins) are view points, divided by `zoom` in world space.
- Arrows see other shapes only as `ConnectableShape` (a closed shape's core geometry). Keep specific shape kinds out of arrow code.
- UI constants live in each module's `@MainActor` style enum (`Style`, `ArrowStyle`, `NoteStyle`, ...). Pure geometry (Geometry, `ArrowGeometry`) is nonisolated, so its constants live on those types.

## Arrows follow tldraw

- Arrow behavior and geometry deliberately mirror tldraw's arc arrows: binding precision and timers, clipping, arrowhead gaps, handles and hint overlays. The constants come from tldraw's source.
- Check tldraw (`packages/tldraw/src/lib/shapes/arrow/`, `bindings/arrow/`, `overlays/`) before changing arrow behavior, and call out any intentional deviation.
- CompositionTests holds the app to the proof of concept (commit 804db97): an arrow transcript compared byte for byte, and renders (outlines, binding hints, handles) compared pixel for pixel. `Tests/CompositionTests/Replay.swift` drives both the POC recording and the test. The fixtures come only from the POC, via `scripts/record-poc-fixtures.sh` (re-running it must change nothing). Never regenerate them from the app to make a change pass; an intended change to arrow behavior needs an explicit note.

## Verifying UI changes

- Screen capture isn't permitted here.
- Drive a headless editor with `EditorHarness` (CanvasTesting): one clock drives event timestamps and the `ManualScheduler`, so pointer speed and the arrow timers behave. Check drawing with `renderBitmap` and `pixel`.
- For focus, key routing and the editing view, put a `CanvasView` in an unshown `NSWindow` and send it synthesized `NSEvent`s (see CompositionTests).
