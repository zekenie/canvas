import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Composition
import CoreGraphics
import LanguageModels
import Locking
import Mentions
import Selection
import SlashCommands
import StickyNotes
import TestKit
import TextEditing
import Titles

// Slash commands as shipped: the two that ship, Titles' `/title` and Locking's `/lock`, typed in a
// note's editor in the app's canvas view.

private let noteFrame = CGRect(x: 100, y: 100, width: 200, height: 200)

@MainActor let slashCommandsShippedTests = Suite("Slash commands, as shipped", [
    test("/lock typed on a new line of a note and entered locks it: editing ends, the line is gone from its text, Undo is Undo Lock, and the step before is the typing") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, _) = windowed(editor)
        let note = editor.add(StickyNote(frame: noteFrame, text: "keep"))
        @MainActor func text() -> String? { editor.document[note]?.typed(as: StickyNote.self)?.props.text.plainText() }
        @MainActor func view() throws -> MentionTextView<AnyMentionable> {
            try require(window.firstResponder as? MentionTextView<AnyMentionable>, "the note's editor has the keyboard")
        }
        editor.selection = note
        expect(editor.beginEditing(note))
        var editing = try view()
        expect(editing.slashCommands != nil, "the note's editor hosts slash commands")
        editing.setSelectedRange(NSRange(location: 4, length: 0))

        // Mid-line a slash is a slash.
        window.type("/")
        expect(editing.slashCommands?.picker == nil, "mid-line")
        window.pressDelete()
        // On a new line it lists what the note offers: /title, then /lock.
        window.pressReturn()
        window.type("/")
        let picker = try require(editing.slashCommands?.picker, "the list is open")
        expectEqual(picker.listed.map(\.name), ["title", "lock"])
        expect(editing.caretListWindow === editing.slashCommands?.window)
        expect(editing.holdsKeys)
        window.type("lo")
        expectEqual(picker.highlightedCommand?.name, "lock")
        window.settle()
        window.pressReturn()
        window.settle()

        expect(editor.isLocked(note), "locked")
        expectEqual(editor.editingShapeID, nil, "editing has ended")
        expectEqual(text(), "keep\n", "the line is gone from its text, its line break is not")
        expect(editing.slashCommands?.picker == nil)
        expectEqual(editor.undoHistory.undoName, "Lock")
        expectEqual(editor.slashCommands?.commands(for: note).map(\.name), ["title"], "a locked note offers /title alone, which its text, read-only, can't type")

        editor.undo()
        expect(!editor.isLocked(note), "Undo Lock unlocks it")
        expectEqual(text(), "keep\n")
        expectEqual(editor.undoHistory.undoName, "Typing", "the step before it is the typing")
        editor.undo()
        expectEqual(text(), "keep")
        expectEqual(editor.undoHistory.undoName, nil)
        editor.redo()
        editor.redo()
        expect(editor.isLocked(note))

        // Unlocked and edited again, the command is offered again; a command line that isn't one stays text.
        editor.unlock([note])
        expect(editor.beginEditing(note))
        editing = try view()
        editing.setSelectedRange(NSRange(location: editing.textStorage?.length ?? 0, length: 0))
        window.type("/lock now")
        window.pressReturn()
        expect(!editor.isLocked(note), "/lock takes no arguments")
        expect(editing.string.hasSuffix("/lock now\n"))
        window.pressEscape()
        editor.undo()
    },

    test("/title Groceries typed on a new line of a note and entered names it: editing goes on, the line is gone from its text, Undo is Undo Title, and the step before is the typing; /title alone is a new line") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, _) = windowed(editor)
        let note = editor.add(StickyNote(frame: noteFrame, text: "keep"))
        @MainActor func text() -> String? { editor.document[note]?.typed(as: StickyNote.self)?.props.text.plainText() }
        @MainActor func title() -> String? { editor.document[note]?[TitleProperty.self] }
        @MainActor func view() throws -> MentionTextView<AnyMentionable> {
            try require(window.firstResponder as? MentionTextView<AnyMentionable>, "the note's editor has the keyboard")
        }
        editor.selection = note
        expect(editor.beginEditing(note))
        var editing = try view()
        editing.setSelectedRange(NSRange(location: 4, length: 0))
        window.pressReturn()
        window.type("/title Groceries")
        window.pressReturn()
        window.settle()

        expectEqual(title(), "Groceries", "named")
        expectEqual(editor.editingShapeID, note, "editing goes on")
        expectEqual(text(), "keep\n", "the line is gone from its text, its line break is not")
        expect(editing.slashCommands?.picker == nil)
        expectEqual(editor.undoHistory.undoName, "Title")

        editor.undo()
        expectEqual(title(), nil, "Undo Title takes the name away")
        expectEqual(text(), "keep\n")
        expectEqual(editor.undoHistory.undoName, "Typing", "the step before it is the typing")
        editor.undo()
        expectEqual(text(), "keep")
        expectEqual(editor.undoHistory.undoName, nil)
        editor.redo()
        editor.redo()
        expectEqual(title(), "Groceries")

        // With nothing after its name the command isn't entered: the line stays text, and Return is a new line.
        expect(editor.beginEditing(note))
        editing = try view()
        editing.setSelectedRange(NSRange(location: editing.textStorage?.length ?? 0, length: 0))
        window.type("/title ")
        window.pressReturn()
        expectEqual(title(), "Groceries", "it names nothing")
        expect(editing.string.hasSuffix("/title \n"))
        window.pressEscape()
    },
])
