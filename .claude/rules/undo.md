---
paths:
  - "Sources/Canvas/Editor/UndoHistory.swift"
  - "Sources/Canvas/Editor/CanvasEditor+Undo.swift"
  - "Sources/Canvas/Model/DocumentDelta.swift"
  - "Sources/CanvasUI/BoardWindow.swift"
  - "Tests/CanvasTests/Undo*.swift"
  - "Tests/CanvasTests/DocumentDeltaTests.swift"
  - "Tests/CanvasTests/WritesAcrossBoardsTests.swift"
  - "Tests/CompositionTests/Undo*.swift"
  - "Tests/CanvasUITests/BoardWindowTests.swift"
---

# Undo

The core's undo: steps, groups and coalescing, `DocumentDelta`, one history across a file's boards, and testing it.

Related: [editor](editor.md), [boards in a file](boards-in-a-file.md), [boards on disk](boards-on-disk.md), [selection](selection.md), [editing](editing.md) ([every topic](../../CLAUDE.md#map)).

In the guide, `docs/plugin-system.md`: [Undo](../../docs/plugin-system.md#undo).

## Architecture

- Undo (the core's, `editor.undoHistory`, `docs/plugin-system.md` "Undo") records every commit into steps, tldraw's model, not `NSUndoManager`'s: a step is an action (a press to its release, a key on the canvas with its repeats while it's held, until it's let go (`editor.keyUp`, `keysReleased`) or anything else happens, so a held arrow key's nudges are one step, a command, `undoHistory.group("Name") { … }`; nested, the outermost counts), an editing session (with the action that began it: placing a note and typing is one step), a run of `transact(coalescing: key)` commits at no action's depth (a panel field typed into, until another commit, an action or `undoHistory.seal()`), or else one commit. A step that ends where it began, or whose changes were all refused, is dropped; opening one clears redo. It's named by its outermost group, else its first named transaction (`transact("Move")`), else, for an editing session, what its kind's `Editable.editingStepName` says, else "Typing". `editor.undo()`/`redo()` (`canUndo`, `canRedo`: not while a session runs) end editing, close the open step, and apply its `DocumentDelta` (each touched record before and after, exact: keys, meta, added and kept values, opaque records) as an ordinary commit with an exact `ChangeSet`, below the read-only rule (undoing Lock unlocks, no shake), never through a transaction (so no service may transact in `documentDidChange`); `UndoParticipant` services get back their snapshot (Selection's selection: undoing Delete reselects); the camera never moves (a board shown for a step has the camera it was left with). The core claims `.undo`/`.redo`, Keyboard gives them ⌘Z/⇧⌘Z. A file has one history, whatever board is shown: a step is made on the board shown (`DocumentDelta.board`; a switch closes the one under way and is no step, nor is entering or leaving a board), and undoing or redoing one from another board shows its board first (`showBoard`), then applies it there, its selection with it. A step holds every other board it reached whole, before and after (`DocumentDelta.boards`, and `unreadableBoards`): the boards a deletion took under a shape, a paste brought (`insert(_:contents:)`), a move took shapes onto or settled them on (`move(_:to:)`, `settle(_:on:)`, the root too), a write changed shapes on (`transaction.update(_:on:_:)`, `translate(_:by:on:)`: a `willDelete` handler that takes back, on other boards, what the deleted shape gave does it in the delete's own step, so one undo, and one redo, put every board back exactly and services hear each one's change), or Delete Hidden Shapes deleted from (`ChangeSet.boardsChanged`), so undoing a deletion brings back every board under the shape with every id, and undoing a paste takes its boards out; each board a step changes gets a new revision, so nothing kept of it is taken back stale. `DocumentDelta` is the one before/after type and `CanvasEditor.apply(_:restoring:)` the one place a step is applied. `replaceFile` (and `replaceDocument`) clears the history.

- A row typed in a note that is one (Types' rows editor) commits through the field writer, `transact(name, coalescing: FieldRunKey)`, which is no editing view's commit: it ends the words' `Typing` step (the editing session's step) and opens a run named for the field (`Change Email`), which Tab to another row, `seal()` (a click, the keyboard changing owner) or any other commit ends; the next word typed opens another `Typing` step. So words, a row, words are three steps, and typing in one row is one. Typing a value in and deleting it all nets to nothing (no step); ⌘Z with the caret in a row is the field's own text undo first, as in the words.

## Testing

- CanvasTests' `WritesAcrossBoardsTests` hold a `willDelete` handler's writes on other boards in the delete's step (one undo and one redo, round trips with `BoardCodec` bytes, what services hear, a board shown before, a board that goes with the delete, read-only), and any transaction's.
- For undo, `h.editor.undo()`/`redo()` and `undoHistory.undoName` headlessly, `undoHistory.seal()` between panel writes where a user would click elsewhere; compare round trips with `==` and `BoardCodec` bytes. Change counts are synchronous (no run-loop spin for `isDocumentEdited`). For Edit › Undo, use a `BoardWindow` with `window.editor` set: `validateMenuItem` for the title, `window.undo(nil)` to run it (CanvasUITests' BoardWindowTests, CompositionTests' UndoTests).
