import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Frames
import LanguageModels
import Locking
import Mentions
import Publishing
import References
import Selection
import ShippedTesting
import SlashCommands
import StickyNotes
import Subboards
import TestKit
import TextEditing
import Titles
import Types

// Slash commands as shipped: Titles' `/title`, Locking's `/lock` and Publishing's `/public` and `/private`, typed
// in a note's editor in the app's canvas view (Moving's `/move-to` and `/move-near` are MovingShippedTests'), and a
// thing's name typed after the `/`, which lists what the commands can do with it.

private let noteFrame = CGRect(x: 100, y: 100, width: 200, height: 200)

@MainActor let slashCommandsShippedTests = Suite("Slash commands, as shipped", [
    test("typed for a selection, as the command bar is, one shape of each shipped kind lists what it can take, in order; a locked note unlock alone; a mix counts each row's reach") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let state = try require(editor.slashCommands)
        let note = editor.add(StickyNote(frame: noteFrame, text: "Note"))
        let frame = editor.add(Frame(frame: CGRect(x: 400, y: 100, width: 400, height: 300)))
        let subboard = editor.add(Subboard(frame: CGRect(x: 900, y: 100, width: 240, height: 160)))
        let arrow = editor.add(Arrow(start: .free(CGPoint(x: 100, y: 600)), end: .free(CGPoint(x: 400, y: 600))))
        let reference = editor.add(Reference(frame: CGRect(x: 500, y: 600, width: 120, height: 32)))
        let locked = editor.add(StickyNote(frame: CGRect(x: 100, y: 800, width: 200, height: 200), text: "Locked"))
        editor.lock([locked])
        @MainActor func listed(_ ids: [ShapeID]) -> [String] { state.commands(for: .selection(ids)).map(\.name) }
        expectEqual(listed([note]), ["title", "lock", "public", "is-a", "color", "move-to", "move-near", "bring-to-front", "send-to-back", "bring-in-front-of", "send-behind"], "a note's text lists the same")
        expectEqual(listed([frame]), ["turn-into-subboard", "title", "lock", "public", "color", "move-to", "move-near", "bring-to-front", "send-to-back", "bring-in-front-of", "send-behind"], "typeable nowhere before: a frame has no text")
        expectEqual(listed([subboard]), ["title", "lock", "public", "color", "move-to", "move-near", "bring-to-front", "send-to-back", "bring-in-front-of", "send-behind"])
        expectEqual(listed([arrow]), ["lock", "is-a", "color"], "its label's list, and its color")
        expectEqual(listed([reference]), ["lock", "move-to", "move-near", "bring-to-front", "send-to-back", "bring-in-front-of", "send-behind"])
        expectEqual(listed([locked]), ["unlock"], "a locked note only what can act on it")
        let mixed = state.commands(for: .selection([note, frame, arrow])).map { "\($0.name) \($0.shapes.count) of \($0.targetCount)" }
        expectEqual(mixed, ["lock 3 of 3", "public 2 of 3", "is-a 2 of 3", "color 3 of 3", "move-to 2 of 3", "move-near 2 of 3",
                            "bring-to-front 2 of 3", "send-to-back 2 of 3", "bring-in-front-of 2 of 3", "send-behind 2 of 3", "turn-into-subboard 1 of 3",
                            "query 3 of 3"],
                    "the first shape's order, then what only later shapes offer; title, one shape's, left out; /query, about them all, last")
    },

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
        // On a new line it lists what the note offers: /title, then /lock, then /public, then /is-a, then /color, then Moving's two and Reordering's four.
        window.pressReturn()
        window.type("/")
        let picker = try require(editing.slashCommands?.picker, "the list is open")
        expectEqual(picker.listed.map(\.name), ["title", "lock", "public", "is-a", "color", "move-to", "move-near", "bring-to-front", "send-to-back", "bring-in-front-of", "send-behind"])
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
        expectEqual(picker.listed.map(\.name), ["lock", "is-a", "color"], "what an arrow offers: no title, nothing public, and Moving leaves it alone; it may be an instance of a type, and it has a color")
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
        expectEqual(try require(editing.slashCommands?.picker).listed.map(\.name), ["title", "lock", "public", "is-a", "color", "move-to", "move-near", "bring-to-front", "send-to-back", "bring-in-front-of", "send-behind"], "private: /public, not /private")
        window.type("public")
        window.pressReturn()
        window.settle()
        expect(isPublic(), "public")
        expectEqual(editor.editingShapeID, note, "editing goes on")
        expectEqual(text(), "keep\n", "the line is gone from its text")
        expectEqual(editor.undoHistory.undoName, "Make Public")
        window.type("/")
        expectEqual(try require(editing.slashCommands?.picker).listed.map(\.name), ["title", "lock", "private", "is-a", "color", "move-to", "move-near", "bring-to-front", "send-to-back", "bring-in-front-of", "send-behind"], "public: /private, not /public")
        window.type("private")
        window.pressReturn()
        window.settle()
        expect(!isPublic(), "private again")
        expectEqual(editor.undoHistory.undoName, "Make Private")
        editor.undo()
        expect(isPublic(), "undone")
        window.pressEscape()
    },

    test("/idea typed on a new line of a note lists what can be done with Idea: is-a Idea, the type, and move-near and send-behind Idea, the note; Return runs the first, and once the note is an Idea the list has the note's rows alone") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, _) = windowed(editor)
        let idea = editor.addTypeNote(TypeSchemaProperty.starter, title: "Idea", frame: CGRect(x: 900, y: 100, width: 200, height: 200))
        let note = editor.add(StickyNote(frame: noteFrame, text: "keep"))
        @MainActor func text() -> String? { editor.document[note]?.typed(as: StickyNote.self)?.props.text.plainText() }
        @MainActor func view() throws -> MentionTextView<AnyMentionable> {
            try require(window.firstResponder as? MentionTextView<AnyMentionable>, "the note's editor has the keyboard")
        }
        editor.selection = note
        expect(editor.beginEditing(note))
        let editing = try view()
        editing.setSelectedRange(NSRange(location: 4, length: 0))
        window.pressReturn()
        window.type("/idea")
        let list = try require(editing.slashCommands?.picker, "the list")
        expectEqual(list.rows.compactMap(\.item?.title), ["is-a Idea", "move-near Idea", "send-behind Idea"],
                    "the type, then the note it is, in the commands' order; not bring-in-front-of, since the note is in front already")
        window.pressReturn()
        window.settle()
        expectEqual(editor.document[note]?[IsAProperty.self]?.map(\.shape), [idea], "an Idea")
        expectEqual(editor.undoHistory.undoName, "Add Type")
        expectEqual(editor.editingShapeID, note, "editing goes on")
        expectEqual(text(), "keep\n", "the line is gone from its text")

        window.type("/idea")
        expectEqual(editing.slashCommands?.picker?.rows.compactMap(\.item?.title), ["move-near Idea", "send-behind Idea"], "a note is never twice a type")
        let before = editor.document[note]?.box
        window.pressReturn()
        window.settle()
        expect(editor.document[note]?.box != before, "moved beside Idea")
        expectEqual(editor.undoHistory.undoName, "Move")
        window.pressEscape()
    },
])
