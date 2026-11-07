import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Clipboard
import Geometry
import Mentions
import Selection
import StickyNotes
import TestKit

// Edit › Paste as Note (⌥⇧⌘V) in the app's window, over the nested file, on a pasteboard of the test's own: the chord reaches
// Clipboard's command through the canvas, and StickyNotes' plain reader makes the note, put down by Draw as one step.

@MainActor let pasteAsNoteShippedTests = Suite("Paste as Note, shipped", [
    test("⌥⇧⌘V puts the pasteboard's text down as one note beside the selected shape, selected, and one Undo takes it; Redo brings back the same") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let w = try NestedWindow(pasteboard: pasteboard)
        defer { w.board.close() }
        let note = w.nest.notes(on: 1).0
        w.editor.selection = note
        w.window.makeFirstResponder(w.canvas)
        pasteboard.clearContents()
        pasteboard.setString("Ship the kit @[not a mention", forType: .string)
        expect(!w.editor.canPaste, "⌘V reads no prose: only a recognizing reader pastes")
        expect(w.editor.canPasteAsNote)
        let before = w.editor.document
        expect(w.window.performKeyEquivalent(with: w.window.keyEvent("v", code: 9, modifiers: [.command, .option, .shift])), "the canvas's shortcut takes it")
        let made = w.editor.shapes(since: before)
        expectEqual(made.count, 1, "one note")
        let pasted = try require(made.first)
        let text = try require(pasted.typed(as: StickyNote.self)?.props.text)
        expectEqual(text.plainText(), "Ship the kit @[not a mention", "its words as they were")
        expectEqual(text.mentioned, [], "nothing in it is a mention")
        let anchor = try require(w.editor.document[note]?.box), box = try require(pasted.box)
        expect(!box.intersects(anchor), "beside the selected shape, not on it")
        expectEqual(w.editor.selectedShapeIDs, [pasted.id])
        expectEqual(w.editor.undoHistory.undoName, "Paste as Note")
        let landed = w.editor.document
        w.editor.undo()
        expectEqual(w.editor.document, before, "one Undo takes it")
        w.editor.redo()
        expectEqual(w.editor.document, landed, "and Redo brings back the same")
    },
    test("the menu item is the chord's, and is off with nothing a plain reader reads") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let w = try NestedWindow(pasteboard: pasteboard)
        defer { w.board.close() }
        w.window.makeFirstResponder(w.canvas)
        let edit = try require(BoardMenus.make(appName: "Infinite Canvas", registry: w.editor.registry).main.item(withTitle: "Edit")?.submenu)
        let item = try require(edit.item(withTitle: "Paste as Note"))
        item.target = w.controller
        expectEqual(KeyboardShortcutSection.key(of: item), "⌥⇧⌘V")
        pasteboard.clearContents()
        expect(!w.controller.validateMenuItem(item), "an empty pasteboard")
        pasteboard.clearContents()
        pasteboard.setString("words", forType: .string)
        expect(w.controller.validateMenuItem(item))
        let before = w.editor.document
        w.controller.runCommand(item)
        expectEqual(w.editor.shapes(since: before).count, 1)
    },
])
