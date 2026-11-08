import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Clipboard
import Geometry
import Mentions
import Selection
import Titles
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
    test("a mention's brackets in the words are escaped, whether or not they name a shape: the note's words are as they were and mention nothing") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let w = try NestedWindow(pasteboard: pasteboard)
        defer { w.board.close() }
        let (hub, _) = w.nest.notes(on: 1)
        w.editor.transact { $0.update(hub) { $0[TitleProperty.self] = "Hub" } }
        w.editor.selection = hub
        pasteboard.clearContents()
        pasteboard.setString("see @[Hub] and @[Nowhere]", forType: .string)
        let before = w.editor.document
        w.editor.pasteAsNote()
        let pasted = try require(w.editor.shapes(since: before).first, "a paste that names no shape is still a note")
        let text = try require(pasted.typed(as: StickyNote.self)?.props.text)
        expectEqual(text.plainText(), "see @[Hub] and @[Nowhere]")
        expectEqual(text.mentioned, [], "not a mention, though a shape is called Hub")
    },
    test("a small text file is a note too, its text the note's, before the file's name which Finder also puts down as text; a blank text, a file that is not text and too much text are no note") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let w = try NestedWindow(pasteboard: pasteboard)
        defer { w.board.close() }
        w.window.makeFirstResponder(w.canvas)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("paste-as-note-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("plan.txt")
        try "From a file".write(to: file, atomically: true, encoding: .utf8)
        pasteboard.clearContents()
        pasteboard.writeObjects([file as NSURL])
        pasteboard.setString("plan.txt", forType: .string)
        expect(w.editor.canPasteAsNote)
        let before = w.editor.document
        w.editor.pasteAsNote()
        let made = try require(w.editor.shapes(since: before).first)
        expectEqual(made.typed(as: StickyNote.self)?.props.text.plainText(), "From a file", "the file's text, not its name")
        // Blank words.
        pasteboard.clearContents()
        pasteboard.setString(" \n\t ", forType: .string)
        expect(!w.editor.canPasteAsNote, "whitespace is no note")
        // A file that is not UTF-8 text.
        let binary = folder.appendingPathComponent("picture.bin")
        try Data([0xFF, 0xFE, 0xC3, 0x28, 0x00, 0x80]).write(to: binary)
        pasteboard.clearContents()
        pasteboard.writeObjects([binary as NSURL])
        expect(!w.editor.canPasteAsNote, "a file that does not read as text")
        // More than a note holds: the item is dim, and nothing is made.
        pasteboard.clearContents()
        pasteboard.setString(String(repeating: "word ", count: 20_000), forType: .string)
        expect(!w.editor.canPasteAsNote, "100,000 bytes is no note")
        let revision = w.editor.revision
        w.editor.pasteAsNote()
        expectEqual(w.editor.revision, revision)
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
