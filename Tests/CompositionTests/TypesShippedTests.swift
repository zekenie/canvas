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
import LanguageModels
import Mentions
import Publishing
import Selection
import SlashCommands
import StickyNotes
import TestKit
import Titles
import Types

// Types as shipped: a note made a type with `/type`, typed in its editor in the app's canvas view;
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
    test("/type typed on a line of a note makes it a type in one step, Make Type, public, editing going on; done with it, the model writes its schema and names it") {
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
        window.type("/ty")
        expectEqual(view.slashCommands?.picker?.highlightedCommand?.name, "type")
        window.pressReturn()
        window.settle()
        expectEqual(editor.document[note]?[TypeSchemaProperty.self]?.text, TypeSchemaProperty.starter)
        expectEqual(editor.document[note]?[PublicProperty.self], true, "a type starts public")
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
        window.type("/is")
        expectEqual(editing.slashCommands?.picker?.highlightedCommand?.name, "is-a")
        window.press("\t", code: 48)
        window.type("@")
        let picker = try require(editing.picker, "the @ picker, on the line of a command that takes a type")
        expectEqual(picker.rows.compactMap(\.candidate?.id), [person], "a type, not Zeke or the note itself")
        window.pressReturn()
        window.pressReturn()
        window.settle()
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
        window.type("@")
        expectEqual(try require(label.picker).rows.compactMap(\.candidate?.id), [person])
        window.pressReturn()
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
    test("canvas draw writes is: as a JSON list of ids, one undo step; a query finds the instances by the is-a edge, and the type by its schema") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        try configureBoards(pasteboard: pasteboard)
        let board = newBoard()
        defer { board.close() }
        let server = try startCommandServer(boards: [board], frontmost: board)
        defer { server.stop() }
        let order = scripted(#"{"type": "object", "properties": {"id": {"type": "string"}}}"#)
        let made = try canvas(server, ["draw", #"sticky-note "Order" text: "An order" schema: "\#(order)""#])
        expectEqual(made.status, 0, made.error)
        let type = try require(board.editor.document.shapes.first)
        let steps = board.editor.undoHistory.undoName
        let drawn = try canvas(server, ["draw", #"sticky-note "Order 7" is: ["\#(type.id)"]"#])
        expectEqual(drawn.status, 0, drawn.error)
        let instance = try require(board.editor.document.shapes.first { $0.id != type.id })
        expectEqual(instance[IsAProperty.self]?.map(\.shape), [type.id])
        expect(board.editor.undoHistory.undoName != nil && steps != nil)
        board.editor.undo()
        expectEqual(board.editor.document.shapes.map(\.id), [type.id], "one step takes the instance back")
        board.editor.redo()
        let found = try JSON(text: canvas(server, ["query", "--brief", #":edge-to("Order", is-a)"#]).output)
        expectEqual(found["count"], 1)
        let types = try JSON(text: canvas(server, ["query", "--brief", "sticky-note[schema]"]).output)
        expectEqual(types["count"], 1)
    },
])
