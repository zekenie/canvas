import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Composition
import Connections
import CoreGraphics
import LanguageModels
import Locking
import Mentions
import Publishing
import Selection
import SlashCommands
import StickyNotes
import TestKit
import TextEditing
import Titles

// Slash commands as shipped: Titles' `/title`, Locking's `/lock` and Publishing's `/public` and `/private`, typed
// in a note's editor in the app's canvas view (Moving's `/move-to` and `/move-near` are MovingShippedTests').

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
        // On a new line it lists what the note offers: /title, then /lock, then /public, then /type, then Moving's two.
        window.pressReturn()
        window.type("/")
        let picker = try require(editing.slashCommands?.picker, "the list is open")
        expectEqual(picker.listed.map(\.name), ["title", "lock", "public", "type", "is-a", "move-to", "move-near"])
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
        expectEqual(editor.slashCommands?.commands(for: note).map(\.name), [], "a locked note offers nothing: its text, read-only, can't be typed in")

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

    test("/lock typed on a new line of an arrow's label and entered locks the arrow: the label is mention text, so it hosts commands as a note's text does; Return on any other line is a new line") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, _) = windowed(editor)
        let arrow = editor.add(Arrow(start: .free(CGPoint(x: 100, y: 300)), end: .free(CGPoint(x: 500, y: 300)), text: "keep"))
        @MainActor func text() -> String? { editor.document[arrow]?.typed(as: Arrow.self)?.props.text.plainText() }
        @MainActor func view() throws -> MentionTextView<AnyMentionable> {
            try require(window.firstResponder as? MentionTextView<AnyMentionable>, "the label's editor has the keyboard")
        }
        editor.selection = arrow
        expect(editor.beginEditing(arrow))
        let editing = try view()
        expect(editing.slashCommands != nil, "the label's editor hosts slash commands")
        editing.setSelectedRange(NSRange(location: 4, length: 0))
        window.pressReturn()
        expectEqual(text(), "keep\n", "Return is a new line")
        window.type("/")
        let picker = try require(editing.slashCommands?.picker, "the list is open")
        expectEqual(picker.listed.map(\.name), ["lock", "is-a"], "what an arrow offers: no title, nothing public, and Moving leaves it alone; it may be an instance of a type")
        window.type("lo")
        expectEqual(picker.highlightedCommand?.name, "lock")
        window.settle()
        window.pressReturn()
        window.settle()
        expect(editor.isLocked(arrow), "locked")
        expectEqual(editor.editingShapeID, nil, "editing has ended")
        expectEqual(text(), "keep\n", "the line is gone from the label, its line break is not")
        expectEqual(editor.undoHistory.undoName, "Lock")
        editor.undo()
        expect(!editor.isLocked(arrow), "Undo Lock unlocks it")
        expectEqual(editor.undoHistory.undoName, "Typing")
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

    test("/public typed on a new line of a note and entered makes it public, /private takes that back: one step each, named as the menu's items are, with editing going on") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, _) = windowed(editor)
        let note = editor.add(StickyNote(frame: noteFrame, text: "keep"))
        @MainActor func text() -> String? { editor.document[note]?.typed(as: StickyNote.self)?.props.text.plainText() }
        @MainActor func isPublic() -> Bool { editor.document[note]?[PublicProperty.self] == true }
        editor.selection = note
        expect(editor.beginEditing(note))
        let editing = try require(window.firstResponder as? MentionTextView<AnyMentionable>, "the note's editor has the keyboard")
        editing.setSelectedRange(NSRange(location: 4, length: 0))
        window.pressReturn()
        window.type("/")
        expectEqual(try require(editing.slashCommands?.picker).listed.map(\.name), ["title", "lock", "public", "type", "is-a", "move-to", "move-near"], "private: /public, not /private")
        window.type("public")
        window.pressReturn()
        window.settle()
        expect(isPublic(), "public")
        expectEqual(editor.editingShapeID, note, "editing goes on")
        expectEqual(text(), "keep\n", "the line is gone from its text")
        expectEqual(editor.undoHistory.undoName, "Make Public")
        window.type("/")
        expectEqual(try require(editing.slashCommands?.picker).listed.map(\.name), ["title", "lock", "private", "type", "is-a", "move-to", "move-near"], "public: /private, not /public")
        window.type("private")
        window.pressReturn()
        window.settle()
        expect(!isPublic(), "private again")
        expectEqual(editor.undoHistory.undoName, "Make Private")
        editor.undo()
        expect(isPublic(), "undone")
        window.pressEscape()
    },
])
