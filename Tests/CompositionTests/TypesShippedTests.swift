import Adornments
import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CanvasUI
import Clipboard
import Composition
import Connections
import CoreGraphics
import DetailPanel
import Foundation
import Frames
import LanguageModels
import Locking
import Mentions
import Publishing
import Selection
import SlashCommands
import StickyNotes
import TestKit
import Titles
import Types

// Types as shipped: a note made a type with `/is-a type`, typed in its editor in the app's canvas view;
// its words and its schema kept in step by the model; a mention of another type, a `$ref` to it;
// copied with the type it refers to; and drawn by an agent with `schema:`.

/// What the model writes for a pet, its title first, as the prompt asks.
private let petAnswer = """
{
  "title": "Pet",
  "type": "object",
  "properties": {
    "name": {
      "type": "string"
    }
  }
}
"""

@MainActor let typesShippedTests = Suite("Types, as shipped", [
    test("/is-a type typed on a line of a note makes it a type in one step, Make Type, not public, editing going on; done with it, the model writes its schema and names it") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let model = ScriptedLanguageModel(), scheduler = ManualScheduler()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: scheduler, pasteboard: pasteboard, model: model)
        let (window, _) = windowed(editor)
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "a pet in my household"))
        editor.selection = note
        expect(editor.beginEditing(note))
        let view = try require(window.firstResponder as? MentionTextView<AnyMentionable>, "the note's editor has the keyboard")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        window.pressReturn()
        window.type("/is-a ")
        expectEqual(view.slashCommands?.choices?.listed.map(\.title), ["Type"], "no types in the file: only Type")
        expectEqual(view.slashCommands?.choices?.highlightedChoice?.title, "Type")
        window.type("type")
        expectEqual(view.slashCommands?.choices?.listed.map(\.title), ["Type"], "titled so: no New type “Type”")
        window.pressReturn()
        window.settle()
        expectEqual(editor.document[note]?[TypeSchemaProperty.self]?.text, TypeSchemaProperty.starter)
        expectEqual(editor.document[note]?[PublicProperty.self], nil, "a type does not start public")
        expectEqual(editor.undoHistory.undoName, "Make Type")
        expectEqual(editor.editingShapeID, note, "editing goes on")
        expect(editor.types?.isType(note) == true)
        expectEqual(model.requests.count, 0, "nothing asked while it's typed into")
        // Done with it: its words are ahead of the starter, so the model is asked for the schema.
        model.queue(petAnswer)
        editor.endEditing()
        scheduler.advance(by: .zero)
        spinRunLoop(until: { editor.typeSync?.status(of: note) == .idle && model.requests.count == 1 })
        expectEqual(model.lastRequest?.messages, [.user("<prompt>\na pet in my household\n</prompt>\n\n<schema>\n\(TypeSchemaProperty.starter)\n</schema>")])
        let schema = try require(editor.document[note]?[TypeSchemaProperty.self]?.text)
        expect(!schema.contains("\"title\""), "its name is the note's: \(schema)")
        expectEqual(editor.document[note]?[TitleProperty.self], "Pet", "an untitled note named by the model's title")
        expectEqual(editor.undoHistory.undoName, "Update Schema")
        // Its panel has the Schema tab.
        let layout = try require(editor.detailPanel?.layout(for: try require(editor.document[note])))
        expect(layout.tabs.map(\.title).contains("Schema"))
    },
    test("/is-a type typed on a note whose words are a JSON object: the schema is the words, the make asks the model nothing, and ending the editing asks once, for the words") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let model = ScriptedLanguageModel(), scheduler = ManualScheduler()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: scheduler, pasteboard: pasteboard, model: model)
        let (window, _) = windowed(editor)
        let json = #"{"type": "object", "properties": {"name": {"type": "string"}}}"#
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: #"{"type": "object", "properties": {"name": {"type": "string"}}}"#))
        editor.selection = note
        expect(editor.beginEditing(note))
        let view = try require(window.firstResponder as? MentionTextView<AnyMentionable>, "the note's editor has the keyboard")
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        window.pressReturn()
        window.type("/is-a ")
        window.pressReturn()
        window.settle()
        // The view has committed the line's removal before the command read the words: else they would not parse.
        expectEqual(editor.document[note]?[TypeSchemaProperty.self]?.text, json, "the words are the schema")
        expectEqual(editor.undoHistory.undoName, "Make Type")
        expect(editor.types?.isType(note) == true)
        expectEqual(model.requests.count, 0, "the make asks nothing")
        model.queue("a thing with a name")
        editor.endEditing()
        scheduler.advance(by: .zero)
        spinRunLoop(until: { editor.typeSync?.status(of: note) == .idle && model.requests.count == 1 })
        expectEqual(model.requests.count, 1, "one request, for the words")
    },
    test("a type made public by hand is public, and a type still: /public on it, Remove Type leaves it public and undo brings the type back, /private takes public away") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "a pet in my household"))
        editor.makeType(note)
        expectEqual(editor.document[note]?[PublicProperty.self], nil, "a type does not start public")
        let state = try require(editor.slashCommands)
        expect(state.commands(for: note).map(\.name).contains("public"), "/public is offered on a type")
        expect(state.run("public", on: note, with: SlashArguments("")))
        expectEqual(editor.document[note]?[PublicProperty.self], true)
        expect(editor.types?.isType(note) == true)
        editor.removeType(note)
        expectEqual(editor.document[note]?[PublicProperty.self], true, "Remove Type leaves whether it is public")
        editor.undo()
        expect(editor.types?.isType(note) == true)
        expect(state.run("private", on: note, with: SlashArguments("")))
        expectEqual(editor.document[note]?[PublicProperty.self], nil)
        expect(editor.types?.isType(note) == true)
    },
    test("Is a ▸ sits in a shape's menu right after Lock, with no line between; an arrow's has it with the types and no Type, a frame's none; a locked note reads Unlock, Is a") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, canvas) = windowed(editor)
        _ = editor.addTypeNote(TypeSchemaProperty.starter, title: "Person", frame: CGRect(x: 500, y: 100, width: 200, height: 200))
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Ann"))
        let arrow = editor.add(Arrow(start: .free(CGPoint(x: 40, y: 500)), end: .free(CGPoint(x: 340, y: 500))))
        let frame = editor.add(Frame(frame: CGRect(x: 40, y: 560, width: 300, height: 200)), title: "Group")
        @MainActor func outline(at point: CGPoint, _ time: TimeInterval) -> [String] {
            canvas.menu(for: window.mouse(.rightMouseDown, at: point, time: time))?.outline ?? ["no menu"]
        }
        let noteMenu = outline(at: CGPoint(x: 200, y: 200), 1)
        let lock = try require(noteMenu.firstIndex(of: "Lock"))
        expectEqual(Array(noteMenu[lock...].prefix(6)), ["Lock", "Is a ▸", "  Type", "  —", "  Person", "—"], "\(noteMenu)")
        let arrowMenu = outline(at: CGPoint(x: 190, y: 500), 2)
        expect(arrowMenu.contains("Is a ▸") && arrowMenu.contains("  Person") && !arrowMenu.contains("  Type"), "\(arrowMenu)")
        let frameMenu = outline(at: CGPoint(x: 200, y: 700), 3)
        expect(!frameMenu.contains("Is a ▸"), "\(frameMenu)")
        _ = (arrow, frame)
        editor.lock([note])
        let locked = outline(at: CGPoint(x: 200, y: 200), 4)
        let unlock = try require(locked.firstIndex(of: "Unlock"))
        expectEqual(locked[unlock + 1], "Is a ▸", "\(locked)")
    },
    test("@ typed on /is-a's line is a letter: no picker, and the choice list stays") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, _) = windowed(editor)
        let note = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Ann"))
        editor.selection = note
        expect(editor.beginEditing(note))
        let view = try require(window.firstResponder as? MentionTextView<AnyMentionable>)
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        window.pressReturn()
        window.type("/is-a ")
        window.type("@")
        expect(view.picker == nil, "no mention picker")
        expect(view.string.hasSuffix("/is-a @"))
        expect(view.slashCommands?.choices != nil, "the choice list stays")
    },
    test("a mention of another type in a type's words is a $ref to it in the schema the model writes; a mention of a note that isn't a type stays words") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let model = ScriptedLanguageModel(), scheduler = ManualScheduler()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: scheduler, pasteboard: pasteboard, model: model)
        let address = editor.addTypeNote(#"{"type": "object", "properties": {"street": {"type": "string"}}}"#, text: "An address: its street",
                                         title: "Address", frame: CGRect(x: 400, y: 100, width: 200, height: 200))
        let zeke = editor.add(StickyNote(frame: CGRect(x: 700, y: 100, width: 200, height: 200), text: "Owner"), title: "Zeke")
        let house = editor.addTypeNote(TypeSchemaProperty.starter, title: "House")
        editor.transact("Typing") { $0.update(house, as: StickyNote.self) {
            $0.props.text = MentionText([.text("A house: its "), .mention(address, label: "Address"), .text(", as "), .mention(zeke, label: "Zeke"), .text(" says")])
        } }
        model.queue(#"{"type": "object", "properties": {"address": {"$ref": "@Address"}}}"#)
        try require(editor.typeSync).commit(house)
        spinRunLoop(until: { model.requests.count == 1 && editor.typeSync?.status(of: house) == .idle })
        let message = try require(model.lastRequest?.messages.first?.text)
        expect(message.hasPrefix("<schemas>\n@Address\n</schemas>"), message)
        expect(message.contains("A house: its @Address, as Zeke says"), message)
        expect(message.contains(#""title": "House""#), "the type's name, for the model: \(message)")
        expectEqual(editor.schemaText(house), #"{"type": "object", "properties": {"address": {"$ref": "\#(SchemaReferences.uri(of: address))"}}}"#)
        expectEqual(editor.mentions?.mentioners(of: address), [house])
    },
    test("a type copied with the type it refers to refers to the copy, in its schema and its words; copied alone, to the original") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let address = editor.addTypeNote(#"{"type": "object", "properties": {"city": {"type": "string"}}}"#, title: "Address",
                                         frame: CGRect(x: 400, y: 0, width: 200, height: 200))
        let uri = SchemaReferences.uri(of: address)
        let house = editor.addTypeNote("{\"type\": \"object\", \"properties\": {\"address\": {\"$ref\": \"\(uri)\"}}}",
                                       text: MentionText([.text("A house at its "), .mention(address, label: "Address")]), title: "House")
        editor.selectedShapeIDs = [address, house]
        editor.perform(.copy)
        let before = editor.document
        editor.perform(.paste)
        let byOriginal = Dictionary(uniqueKeysWithValues: editor.shapes(since: before).map { ($0.copiedFrom!, $0.id) })
        let copyOfAddress = try require(byOriginal[address])
        let copied = try require(editor.document[try require(byOriginal[house])])
        expectEqual(SchemaReferences.refs(in: try require(copied[TypeSchemaProperty.self]?.text)).map(\.shape), [copyOfAddress])
        expectEqual(copied.typed(as: StickyNote.self)?.props.text.mentioned, [copyOfAddress])
        expect(editor.types?.isType(copied.id) == true, "a copy of a type is a type")
        editor.selectedShapeIDs = [house]
        editor.perform(.copy)
        let again = editor.document
        editor.perform(.paste)
        let alone = try require(editor.shapes(since: again).first)
        expectEqual(SchemaReferences.refs(in: try require(alone[TypeSchemaProperty.self]?.text)).map(\.shape), [address])
        expectEqual(alone.typed(as: StickyNote.self)?.props.text.mentioned, [address])
    },
    test("canvas draw makes a type with schema:, named by its title; a $ref to a shape not in the file is warned of; the model isn't asked") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let order = scripted(#"{"type": "object", "properties": {"id": {"type": "string"}}}"#)
        let result = try canvas(server, ["draw", #"sticky-note "Order" text: "An order: its id" schema: "\#(order)""#])
        expectEqual(result.status, 0, result.error)
        let type = try require(board.editor.document.shapes.first)
        expectEqual(type[TypeSchemaProperty.self]?.text, #"{"type": "object", "properties": {"id": {"type": "string"}}}"#)
        expectEqual(board.editor.registry.title(of: type), "Order")
        expect(board.editor.types?.isType(type.id) == true)
        expectEqual(board.editor.typeSync?.status(of: type.id), .idle, "what an agent wrote is in step")
        // Found by a query, as a note with a schema.
        let found = try JSON(text: canvas(server, ["query", "--brief", "sticky-note[schema]"]).output)
        expectEqual(found["count"], 1)
        // A $ref to a shape that isn't in the file: drawn, and warned of.
        let gone = ShapeID()
        let dangling = scripted(#"{"type": "object", "properties": {"a": {"$ref": "\#(SchemaReferences.uri(of: gone))"}}}"#)
        let warned = try canvas(server, ["draw", #"sticky-note "Line" schema: "\#(dangling)""#])
        expectEqual(warned.status, 0, warned.error)
        let warnings = try JSON(text: warned.output)["warnings"]?.arrayValue ?? []
        expect(warnings.contains { $0["attribute"] == "schema" && $0["message"]?.stringValue?.contains(gone.description) == true }, warned.output)
    },

    test("/is-a typed on a line of a note and a type picked make it an instance in one step, Add Type, editing going on and the line gone; its chip sits above it, and the arrow's label does the same") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, _) = windowed(editor)
        let person = editor.addTypeNote(TypeSchemaProperty.starter, title: "Person", frame: CGRect(x: 500, y: 100, width: 200, height: 200))
        let zeke = editor.add(StickyNote(frame: CGRect(x: 500, y: 400, width: 200, height: 200), text: "Owner"), title: "Zeke")
        let ann = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Ann"))
        @MainActor func view() throws -> MentionTextView<AnyMentionable> {
            try require(window.firstResponder as? MentionTextView<AnyMentionable>, "the editor has the keyboard")
        }
        editor.selection = ann
        expect(editor.beginEditing(ann))
        let editing = try view()
        editing.setSelectedRange(NSRange(location: editing.textStorage?.length ?? 0, length: 0))
        window.pressReturn()
        window.type("/is-a ")
        let rows = try require(editing.slashCommands?.choices, "the choices")
        expectEqual(rows.listed.map(\.title), ["Type", "Person"], "no Zeke (not a type), and not Ann herself")
        expectEqual(rows.highlightedChoice?.title, "Person", "the first type")
        window.type("per")
        expectEqual(rows.listed.map(\.title), ["Person", "New type “Per”"], "the match, then the new type, last")
        expectEqual(rows.highlightedChoice?.title, "Person", "the match is the highlighted row: Return picks it")
        window.pressReturn()
        expectEqual(editor.document[ann]?[IsAProperty.self]?.map(\.shape), [person])
        expectEqual(editor.editingShapeID, ann, "editing goes on")
        expectEqual(editor.document[ann]?.typed(as: StickyNote.self)?.props.text.plainText(), "Ann\n", "the line is gone from its text, the line break is not")
        expectEqual(editor.undoHistory.undoName, "Add Type")
        expectEqual(editor.types?.instances(of: person), [ann])
        window.pressEscape()
        let chips = editor.adornmentFrames(of: ann).filter { $0.adornment == .of(TypeChips.self) }
        expectEqual(chips.map { $0.label.text ?? "" }, ["Person"])
        expect(chips[0].rect.maxY <= 100, "above the note")
        editor.undo()
        expectEqual(editor.document[ann]?[IsAProperty.self], nil)
        expect(zeke != person)

        // The arrow's label: the same command, the same step, the chip above the label.
        let arrow = editor.add(Arrow(start: .free(CGPoint(x: 100, y: 700)), end: .free(CGPoint(x: 500, y: 700)), text: "keep"))
        editor.selection = arrow
        expect(editor.beginEditing(arrow))
        let label = try view()
        label.setSelectedRange(NSRange(location: 4, length: 0))
        window.pressReturn()
        window.type("/is-a ")
        expectEqual(try require(label.slashCommands?.choices).listed.map(\.title), ["Person"], "no Type row on a label")
        window.pressReturn()
        window.settle()
        expectEqual(editor.document[arrow]?[IsAProperty.self]?.map(\.shape), [person])
        expectEqual(editor.document[arrow]?.typed(as: Arrow.self)?.props.text.plainText(), "keep\n")
        expectEqual(editor.undoHistory.undoName, "Add Type")
        window.pressEscape()
        let labelFrame = try require(editor.arrowLabelFrame(of: arrow))
        let arrowChips = editor.adornmentFrames(of: arrow).filter { $0.adornment == .of(TypeChips.self) }
        expectEqual(arrowChips.map { $0.label.text ?? "" }, ["Person"])
        expect(arrowChips[0].rect.maxY <= labelFrame.minY, "above the label")
    },
    test("/is-a company typed on a note offers New type “Company”; Return puts a white type note beside it, in editing, and links the note: one step, New Type; undo takes both, then the typing") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let model = ScriptedLanguageModel(), scheduler = ManualScheduler()
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: scheduler, pasteboard: pasteboard, model: model)
        let (window, _) = windowed(editor)
        let ann = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Ann"))
        editor.selection = ann
        expect(editor.beginEditing(ann))
        let editing = try require(window.firstResponder as? MentionTextView<AnyMentionable>, "the editor has the keyboard")
        editing.setSelectedRange(NSRange(location: editing.textStorage?.length ?? 0, length: 0))
        window.pressReturn()
        window.type("/is-a company")
        let rows = try require(editing.slashCommands?.choices, "the choices")
        expectEqual(rows.listed.map(\.title), ["New type “Company”"], "nothing matches: the one row")
        expectEqual(rows.highlightedChoice?.title, "New type “Company”")
        window.pressReturn()
        window.settle()
        let made = try require(editor.document.shapes.map(\.id).first { $0 != ann }, "the new note")
        expectEqual(editor.document[made]?[TitleProperty.self], "Company")
        expectEqual(editor.document[made]?[TypeSchemaProperty.self]?.text, TypeSchemaProperty.starter)
        expectEqual(editor.document[made]?[PublicProperty.self], nil, "not public")
        expectEqual(editor.document[made]?.typed(as: StickyNote.self)?.props.text.plainText(), "", "no words yet")
        expectEqual(editor.document[ann]?[IsAProperty.self]?.map(\.shape), [made])
        expectEqual(editor.document[ann]?.typed(as: StickyNote.self)?.props.text.plainText(), "Ann\n", "the line is gone from its text")
        expectEqual(editor.selectedShapeIDs, [made])
        expectEqual(editor.editingShapeID, made, "the new note is edited, and the owner's editing has ended")
        let beside = try require(editor.document[made]?.box), annBox = try require(editor.document[ann]?.box)
        expect(beside.minX >= annBox.maxX && !beside.intersects(annBox), "right of it: \(beside) beside \(annBox)")
        expectEqual(model.requests.count, 0, "an empty type asks nothing")
        // The owner's chip is the type's.
        let chips = editor.adornmentFrames(of: ann).filter { $0.adornment == .of(TypeChips.self) }
        expectEqual(chips.map { $0.label.text ?? "" }, ["Company"])
        // Words typed into the new note before its editing ends are in the one step.
        window.type("a firm")
        editor.endEditing()
        expectEqual(editor.undoHistory.undoName, "New Type")
        editor.undo()
        expectEqual(editor.document[made], nil, "the note goes")
        expectEqual(editor.document[ann]?[IsAProperty.self], nil, "and the link")
        expectEqual(editor.undoHistory.undoName, "Typing", "then the owner's own editing")
    },
    test("/is-a co typed on a note with a Company type in the file lists Company and then New type “Co”; Return picks Company, and the last row puts a type called Co beside the note: one step, New Type") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, _) = windowed(editor)
        let company = editor.addTypeNote(TypeSchemaProperty.starter, title: "Company", frame: CGRect(x: 500, y: 100, width: 200, height: 200))
        let ann = editor.add(StickyNote(frame: CGRect(x: 100, y: 100, width: 200, height: 200), text: "Ann"))
        let bo = editor.add(StickyNote(frame: CGRect(x: 100, y: 400, width: 200, height: 200), text: "Bo"))
        @MainActor func list(_ note: ShapeID) throws -> SlashChoicePicker {
            editor.selection = note
            expect(editor.beginEditing(note))
            let editing = try require(window.firstResponder as? MentionTextView<AnyMentionable>, "the editor has the keyboard")
            editing.setSelectedRange(NSRange(location: editing.textStorage?.length ?? 0, length: 0))
            window.pressReturn()
            window.type("/is-a co")
            return try require(editing.slashCommands?.choices, "the choices")
        }
        let first = try list(ann)
        expectEqual(first.listed.map(\.title), ["Company", "New type “Co”"])
        expectEqual(first.highlightedChoice?.title, "Company", "the best match, so Return picks it")
        window.pressReturn()
        window.settle()
        expectEqual(editor.document[ann]?[IsAProperty.self]?.map(\.shape), [company])
        expectEqual(editor.document.shapes.count, 3, "no new note")
        expectEqual(editor.undoHistory.undoName, "Add Type")
        window.pressEscape()

        let second = try list(bo)
        expectEqual(second.listed.map(\.title), ["Company", "New type “Co”"])
        window.press("\u{F701}", code: 125)
        expectEqual(second.highlightedChoice?.title, "New type “Co”")
        window.pressReturn()
        window.settle()
        let made = try require(editor.document[bo]?[IsAProperty.self]?.first?.shape)
        expect(made != company)
        expectEqual(editor.document[made]?[TitleProperty.self], "Co")
        expectEqual(editor.document[made]?[TypeSchemaProperty.self]?.text, TypeSchemaProperty.starter)
        expectEqual(editor.document[company]?[TitleProperty.self], "Company", "Company is as it was")
        expectEqual(editor.document[bo]?.typed(as: StickyNote.self)?.props.text.plainText(), "Bo\n", "the line is gone from its text")
        expectEqual(editor.editingShapeID, made, "the new note is edited")
        expectEqual(editor.undoHistory.undoName, "New Type")
        window.pressEscape()
    },
    test("New type from an arrow's label puts a note beside the arrow; in a frame the new note is in the frame") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let (window, _) = windowed(editor)
        @MainActor func view() throws -> MentionTextView<AnyMentionable> {
            try require(window.firstResponder as? MentionTextView<AnyMentionable>, "the editor has the keyboard")
        }
        let arrow = editor.add(Arrow(start: .free(CGPoint(x: 100, y: 700)), end: .free(CGPoint(x: 500, y: 700)), text: "keep"))
        editor.selection = arrow
        expect(editor.beginEditing(arrow))
        let label = try view()
        label.setSelectedRange(NSRange(location: 4, length: 0))
        window.pressReturn()
        window.type("/is-a vendor")
        expectEqual(try require(label.slashCommands?.choices).listed.map(\.title), ["New type “Vendor”"])
        window.pressReturn()
        window.settle()
        let made = try require(editor.document.shapes.map(\.id).first { $0 != arrow })
        expectEqual(editor.document[made]?.kind, StickyNote.kind, "a note")
        expectEqual(editor.document[arrow]?[IsAProperty.self]?.map(\.shape), [made])
        expect(editor.editingShapeID != arrow, "the label's editing has ended")
        expectEqual(editor.undoHistory.undoName, "New Type")

        // In a frame, where it falls inside.
        let hold = editor.add(Frame(frame: CGRect(x: 1000, y: 100, width: 900, height: 500)), title: "Group")
        let inner = editor.add(StickyNote(frame: CGRect(x: 1040, y: 160, width: 200, height: 200), text: "Eve"))
        editor.put([inner], in: hold)
        editor.selection = inner
        expect(editor.beginEditing(inner))
        let editing = try view()
        editing.setSelectedRange(NSRange(location: editing.textStorage?.length ?? 0, length: 0))
        window.pressReturn()
        window.type("/is-a guest")
        window.pressReturn()
        window.settle()
        let guest = try require(editor.document[inner]?[IsAProperty.self]?.first?.shape)
        expectEqual(editor.file.record(guest)?.container, hold, "in the frame")
    },
    test("New type beside a note in a locked frame puts nothing down: no note, no link, no step") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let ann = editor.add(StickyNote(frame: CGRect(x: 140, y: 140, width: 200, height: 200), text: "Ann"))
        let hold = editor.add(Frame(frame: CGRect(x: 100, y: 100, width: 900, height: 500)), title: "Locked")
        editor.put([ann], in: hold)
        editor.lock([hold])
        let before = editor.document.shapes.count
        let steps = editor.undoHistory.undoName
        expectEqual(editor.newType(named: "Company", besides: ann), nil)
        expectEqual(editor.document.shapes.count, before, "nothing placed")
        expectEqual(editor.document[ann]?[IsAProperty.self], nil, "no link")
        expectEqual(editor.undoHistory.undoName, steps, "no step")
    },
    test("a copy of an instance copied with its type is an instance of the copy, copied alone of the original; the is-a edge and the index follow, and a query finds the instances by their edge") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), pasteboard: pasteboard, model: ScriptedLanguageModel())
        let person = editor.addTypeNote(TypeSchemaProperty.starter, title: "Person", frame: CGRect(x: 400, y: 0, width: 200, height: 200))
        let ann = editor.add(StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: "Ann"))
        editor.addTypeLink(person, to: ann)
        expectEqual(editor.types?.instances(of: person), [ann])
        editor.selectedShapeIDs = [person, ann]
        editor.perform(.copy)
        let before = editor.document
        editor.perform(.paste)
        let byOriginal = Dictionary(uniqueKeysWithValues: editor.shapes(since: before).map { ($0.copiedFrom!, $0.id) })
        let copyOfPerson = try require(byOriginal[person]), copyOfAnn = try require(byOriginal[ann])
        expectEqual(editor.document[copyOfAnn]?[IsAProperty.self]?.map(\.shape), [copyOfPerson])
        editor.selectedShapeIDs = [ann]
        editor.perform(.copy)
        let again = editor.document
        editor.perform(.paste)
        let alone = try require(editor.shapes(since: again).first)
        expectEqual(alone[IsAProperty.self]?.map(\.shape), [person])
        expectEqual(editor.types?.instances(of: person), [ann, alone.id])
        expectEqual(editor.types?.instances(of: copyOfPerson), [copyOfAnn])
    },
])
