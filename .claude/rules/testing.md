---
paths:
  - "Tests/**"
---

# Testing

Writing tests: the headless harness, views in unshown windows, and the board documents a test must close. Each subsystem's own test guidance is in the Testing section of its topic file (listed at the end).

Related: [build](build.md), [drawing](drawing.md), [editing](editing.md), [undo](undo.md) ([every topic](../../CLAUDE.md#map)).

In the guide, `docs/plugin-system.md`: [Testing plugins](../../docs/plugin-system.md#testing-plugins).

## Verifying UI changes

- Screen capture isn't permitted here. Benchmarks and most tests draw into bitmaps, while the app's `CanvasView.draw` records a display list (AppKit's context isn't a bitmap: its `bitsPerComponent` is 0) that Core Animation renders on the GPU while the window is on screen and the display awake (headless, or with the display asleep, it replays it on the CPU), so what a drawing change costs on screen is seen only in the app on screen, and a clip of many rects is the known trap (the dot grid's, some 400 ms a frame, is why it clips only into a bitmap).
- Drive a headless editor with `EditorHarness` (CanvasTesting), with `KeyboardPlugin()` and `SelectionPlugin()` first in its plugins when the test presses, drags or selects as a user does (without Selection the default tool is Hand, and without Keyboard no key does anything). `EditorHarness(plugins:file:)` starts on a file of boards (with `PocketsPlugin()` for a kind that owns them), and `h.enter(owner)` shows the board a shape owns; `openingPockets()` (in SelectionTests, TableOfContentsTests and CompositionTests) makes pockets open onto their boards (`registrar.opens(Pocket.self, …)`). `h.key("v")` presses a key on the canvas (with what `h.hold` holds); CanvasTesting's fixture tools have no keys, so pick them with `h.editor.setTool`. One clock drives event timestamps and the `ManualScheduler`, so pointer speed, the arrow timers and the hand tool's slide (inertia) behave. Check drawing with `renderBitmap`, `pixel` and `changedPixels`.
- For focus, key routing and the editing view, put a `CanvasView` in an unshown `NSWindow` and send it synthesized `NSEvent`s (see CompositionTests).
- Each test runs in an autorelease pool of its own (TestKit's `runAsTest`, which `runTests` runs each test with), as the app handles each event in one, so what a test lets go is gone as it ends: its windows, their views and what those scheduled (a panel's keyboard handed back a turn later, `reclaimSoon`) never act in a later test. A closure a test hands a view (a panel's `onExit`) captures the test's own objects weakly, since the view may call it a turn after the test let them go; and a window a test closes is `isReleasedWhenClosed = false`, which ARC needs, else it's released once too often when the pool drains. DetailPanelTests' "a panel let go by its test goes with it" holds the pool.
- A test closes the `BoardDocument`s it edits (`defer { board.close() }`). AppKit autosaves an edited document 15 s after its last change (or after the last event sent through `NSApp`, if later), in whatever test is running then, and a test's board has no file type, so one given a `fileURL` throws "inTypeName is nil" and ends the run, only when the run is slow enough to get there (under load). After each test (`runTests(_:afterEach:)`), CompositionTests' `closeBoardsLeftOpen` fails one that left a board open with changes, and closes every board it left open (`BoardDocument.unclosed`, debug builds).

## Each subsystem's tests

These topic files have a Testing section of their own: [editing](editing.md), [undo](undo.md), [drawing](drawing.md), [text editing](text-editing.md), [fuzzy matching](fuzzy-matching.md), [detail panel](detail-panel.md), [table of contents](table-of-contents.md), [adornments](adornments.md), [context menus](context-menus.md), [slash commands](slash-commands.md), [topology](topology.md), [find](find.md), [clipboard](clipboard.md), [publishing](publishing.md), [connections](connections.md), [mentions](mentions.md), [boards](boards.md), [jump to](jump-to.md), [neighbors](neighbors.md), [snapping](snapping.md), [transform](transform.md), [command line](command-line.md), [queries](queries.md), [digest](digest.md), [Quick Look](quick-look.md).
