import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import LanguageModels
import Mentions
import Selection
import SlashCommands
import TestKit
import Titles
import Topology
import Types

// New type from `/is-a`: for what was typed, when no row is titled so, one row last, `New type “X”` (the only
// row where nothing matches), and a pick puts a note titled X beside the shape, with the starter schema, and
// links the shape to it: one step. The shipped tests hold the editing a placed note begins (a memo isn't
// edited when placed).

/// A box that can hold `is` but cannot be a type, so a new type beside it is of another kind.
private struct NewChit: BoxShapeProps {
    static let kind: ShapeKind = "new-chit"
    static let properties = Properties<NewChit>(title: "Chit") {
        Property("frame", \.frame).required()
        Property("text", \.text)
    }
    var frame = CGRect(x: 600, y: 600, width: 100, height: 40)
    var text: MentionText = ""
    init() {}
}

@MainActor private struct NewChitDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<NewChit>, in context: RenderContext) {}
}

private struct NewChitsPlugin: CanvasPlugin {
    var id: PluginID { "new-chits" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(NewChitDefinition()) { chit in
            chit.typeWords(\.text, drawnIn: { _ in nil })
            chit.typeable()
        }
    }
}

@MainActor private func isA(_ editor: CanvasEditor, on id: ShapeID) throws -> OfferedSlashCommand {
    try require(try require(editor.slashCommands).commands(for: id).first { $0.name == "is-a" }, "/is-a is offered")
}

@MainActor private func newRow(_ typed: String, on id: ShapeID, in editor: CanvasEditor) throws -> SlashChoice? {
    try isA(editor, on: id).choice(otherwise: typed)
}

/// Picks the row nothing matching offers, as a list does.
@MainActor @discardableResult private func pickNew(_ typed: String, on id: ShapeID, in editor: CanvasEditor) throws -> Bool {
    let row = try require(try newRow(typed, on: id, in: editor), "a row for \(typed)")
    return try require(editor.slashCommands).run(try isA(editor, on: id), on: id, choosing: row)
}

/// Every shape but the ones `known` names.
@MainActor private func added(to editor: CanvasEditor, since known: Set<ShapeID>) -> [ShapeID] {
    editor.document.shapes.map(\.id).filter { !known.contains($0) }
}

@MainActor let newTypeTests = Suite("New type", [
    test("the row is made from what was typed: capitalized, spaces folded, in typographic quotes, with its own step") {
        let editor = try typeEditor()
        let ann = editor.add(memo("Ann"))
        let row = try require(try newRow("company", on: ann, in: editor))
        expectEqual(row.title, "New type “Company”")
        expectEqual(row.step, "New Type")
        expectEqual(try newRow("  purchase   order ", on: ann, in: editor)?.title, "New type “Purchase order”")
        expectEqual(try newRow("USA today", on: ann, in: editor)?.title, "New type “USA today”", "the rest as typed")
        expectEqual(try newRow("", on: ann, in: editor), nil, "nothing typed")
        expectEqual(try newRow("   ", on: ann, in: editor), nil)
        expectEqual(try newRow(String(repeating: "a", count: 80), on: ann, in: editor)?.title.contains("“"), true)
        expectEqual(try newRow(String(repeating: "a", count: 81), on: ann, in: editor), nil, "a title's limit is 80")
    },
    test("with a Company type in the file, /is-a co lists Company and then New type “Co”, the match highlighted; the last makes a type called Co") {
        let editor = try typeEditor()
        let company = editor.addType(TypeSchemaProperty.starter, title: "Company")
        let ann = editor.add(memo("Ann"))
        let line = try IsALine(on: ann, in: editor)
        line.type("/is-a co")
        expectEqual(line.titles, ["Company", "New type “Co”"])
        expectEqual(line.highlighted, "Company", "Return picks the match, never the new row by accident")
        line.down()
        expectEqual(line.highlighted, "New type “Co”")
        line.returnKey()
        let made = try require(added(to: editor, since: [ann, company]).first)
        expectEqual(editor.title(made), "Co")
        expectEqual(editor.schema(made), TypeSchemaProperty.starter)
        expectEqual(editor.typesOf(ann), [made], "a Co and not a Company")
        expectEqual(editor.title(company), "Company")
        expectEqual(editor.undoHistory.undoName, "New Type")
    },
    test("Return on /is-a co picks Company, the highlighted match, and makes nothing") {
        let editor = try typeEditor()
        let company = editor.addType(TypeSchemaProperty.starter, title: "Company")
        let ann = editor.add(memo("Ann"))
        let line = try IsALine(on: ann, in: editor)
        line.type("/is-a co")
        line.returnKey()
        expectEqual(editor.typesOf(ann), [company])
        expectEqual(added(to: editor, since: [ann, company]), [])
        expectEqual(editor.undoHistory.undoName, "Add Type")
    },
    test("a type titled what was typed leaves the new type out, case aside and spaces folded; a title it only starts has it last") {
        let editor = try typeEditor()
        _ = editor.addType(TypeSchemaProperty.starter, title: "Company")
        _ = editor.addType(TypeSchemaProperty.starter, title: "Purchase Order")
        let ann = editor.add(memo("Ann"))
        @MainActor func titles(_ typed: String) throws -> [String] {
            let line = try IsALine(on: ann, in: editor)
            line.type("/is-a " + typed)
            return line.titles
        }
        expectEqual(try titles("company"), ["Company"])
        expectEqual(try titles("COMPANY"), ["Company"])
        expectEqual(try titles("purchase   order"), ["Purchase Order"])
        expectEqual(try titles("compan"), ["Company", "New type “Compan”"])
        expectEqual(try titles("purchase"), ["Purchase Order", "New type “Purchase”"])
        expectEqual(try titles("vendor"), ["New type “Vendor”"], "nothing matches: the only row")
        expectEqual(try titles(""), ["Type", "Relationship Type", "Company", "Purchase Order"], "nothing typed: none")
    },
    test("nothing offers it where no kind can be a type, or none has a tool to place one") {
        let bare = try typeEditor()
        let plugins = typePlugins().filter { $0.id != "memos" }
        let unplaced = CanvasEditor(registry: try Registry(plugins: plugins + [MemosPlugin(placing: false)]), file: CanvasFile(root: CanvasDocument()),
                                    scheduler: ManualScheduler())
        let ann = unplaced.add(memo("Ann"))
        expectEqual(try newRow("company", on: ann, in: unplaced), nil, "a memo with no tool has no placement")
        let placed = bare.add(memo("Ann"))
        expect(try newRow("company", on: placed, in: bare) != nil)
    },
    test("the pick is one step, New Type: a titled note with the starter schema, not public, and the link; undo takes both, redo brings them") {
        let editor = try typeEditor()
        let ann = editor.add(memo("Ann"))
        let known: Set<ShapeID> = [ann]
        try pickNew("company", on: ann, in: editor)
        let made = try require(added(to: editor, since: known).first)
        expectEqual(editor.title(made), "Company")
        expectEqual(editor.schema(made), TypeSchemaProperty.starter)
        expectEqual(editor.words(made), "")
        expectEqual(editor.typesOf(ann), [made])
        expectEqual(editor.selectedShapeIDs, [made])
        expectEqual(editor.undoHistory.undoName, "New Type")
        editor.undo()
        expectEqual(added(to: editor, since: known), [])
        expectEqual(editor.typesOf(ann), [])
        expectEqual(editor.words(ann), "Ann")
        editor.redo()
        expectEqual(editor.typesOf(ann), [made])
        expectEqual(editor.title(made), "Company")
        expectEqual(editor.undoHistory.undoName, "New Type")
    },
    test("it lands beside the shape without overlapping it: on its right when that is free, below when the right is taken") {
        let editor = try typeEditor()
        let ann = editor.add(memo("Ann", at: CGPoint(x: 40, y: 40)))
        let at = try require(editor.document[ann]?.box)
        try pickNew("company", on: ann, in: editor)
        let first = try require(added(to: editor, since: [ann]).first)
        let box = try require(editor.document[first]?.box)
        expect(!box.intersects(at))
        expect(box.minX >= at.maxX, "right of it: \(box) beside \(at)")
        // The right is taken: the next lands elsewhere, still clear of all three.
        let ben = editor.add(memo("Ben", at: CGPoint(x: 40, y: 300)))
        let wall = editor.add(memo("wall", at: CGPoint(x: 300, y: 300)))
        let second = try require(editor.newType(named: "Order", besides: ben))
        let other = try require(editor.document[second]?.box)
        for id in [ben, wall, first] { expect(!other.intersects(try require(editor.document[id]?.box)), "clear of \(id)") }
    },
    test("the kind is the shape's own when it can be a type; the new note is not public") {
        let editor = try typeEditor()
        let ann = editor.add(memo("Ann"))
        let made = try require(editor.newType(named: "Pet", besides: ann))
        expectEqual(editor.document[made]?.kind, Memo.kind)
        expect(editor.document[made]?[IsAProperty.self] == nil)
    },
    test("a read-only board takes nothing: no note, no link, no step, and the board's owner is refused") {
        let pocket = ShapeID(), ann = ShapeID()
        var frozen = AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))
        frozen[Frozen.self] = true
        let annRecord = ShapeRecord(id: ann, memo("Ann"))
        let file = CanvasFile(root: CanvasDocument(shapes: [frozen]), children: [pocket: CanvasDocument(shapes: [AnyShapeRecord(annRecord)])])
        let log = RefusalLog()
        let editor = try typeEditor(file: file, more: [PocketsPlugin(), FreezingPlugin(log: log)])
        expect(editor.showBoard(BoardID(owner: pocket)))
        expect(editor.isBoardReadOnly)
        let steps = editor.undoHistory.undoName
        expectEqual(editor.newType(named: "Company", besides: ann), nil)
        expectEqual(editor.document.shapes.count, 1)
        expectEqual(editor.typesOf(ann), [])
        expectEqual(editor.undoHistory.undoName, steps, "no step")
        expect(log.refusals.contains { $0.contains(pocket) }, "the board's owner shakes")
    },
    test("a shape on a board that is not the one shown gets nothing") {
        let pocket = ShapeID(), far = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 600, width: 100, height: 100))))]),
                              children: [pocket: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: far, memo("Far")))])])
        let editor = try typeEditor(file: file, more: [PocketsPlugin()])
        expectEqual(editor.newType(named: "Company", besides: far), nil)
        expectEqual(editor.document.shapes.count, 1)
    },
    test("a shape that cannot be a type gets a note of the first kind that can") {
        let editor = try typeEditor(more: [NewChitsPlugin()])
        let chit = editor.add(NewChit())
        let made = try require(editor.newType(named: "Thing", besides: chit))
        expectEqual(editor.document[made]?.kind, Memo.kind)
        expectEqual(editor.typesOf(chit), [made])
    },
    test("a type made for another plugin's words (an endpoint's body): no owner an instance of it, nothing edited or selected, put down settled beside them; one step, New Type") {
        let editor = try typeEditor()
        let ann = editor.add(memo("Ann"))
        editor.undoHistory.seal()
        let made = try require(editor.newType(named: "Problem", besides: [ann], givingType: false, editing: false))
        expectEqual(editor.document[made]?[TitleProperty.self], "Problem")
        expect(editor.types?.isType(made) == true, "a type")
        expectEqual(editor.typesOf(ann), [], "the owner is no instance of it")
        expectEqual(editor.editingShapeID, nil, "nothing edited")
        expect(!editor.selectedShapeIDs.contains(made), "nothing selected")
        let box = try require(editor.document[made]?.box)
        expect(!box.intersects(try require(editor.document[ann]?.box)), "beside it, clear of it")
        expectEqual(editor.undoHistory.undoName, "New Type")
        editor.undo()
        expect(editor.document[made] == nil, "one step")
    },
    test("a type made settled beside shapes with no side of them in view lands at the nearest clear spot in view, so it's seen") {
        let editor = try typeEditor()
        editor.viewportDidResize(to: CGSize(width: 1200, height: 700))
        // Two owners at opposite corners: every side of the box around them is past the view's edges.
        let ann = editor.add(memo("Ann", at: CGPoint(x: 20, y: 40)))
        let ben = editor.add(memo("Ben", at: CGPoint(x: 900, y: 560)))
        let made = try require(editor.newType(named: "Problem", besides: [ann, ben], givingType: false, editing: false))
        let box = try require(editor.document[made]?.box)
        expect(CGRect(x: 0, y: 0, width: 1200, height: 700).contains(box), "in view: \(box)")
        expect(box.minY - 27 >= 0, "its title's row in view too")
    },
    test("a type's chip by its id, for another plugin: its name now in its color; a shape that is no type, or none, the words in a dashed pill") {
        let editor = try typeEditor()
        let ann = editor.add(memo("Ann"))
        let made = try require(editor.newType(named: "Refund", besides: ann))
        let types = try require(editor.types)
        let chip = TypeChips.label(forType: made, named: "Refunds", in: types)
        expectEqual(chip.text, "Refund", "its name now, not the words")
        expect(!chip.isMissing && chip.tint == TypeChips.tint(of: made, in: types))
        expect(TypeChips.label(forType: made, named: "", in: types, onPaper: true).tint != nil)
        let none = TypeChips.label(forType: nil, named: "Problem", in: types)
        expectEqual(none.text, "Problem")
        expect(none.isMissing, "dashed")
        expect(TypeChips.label(forType: ann, named: "Ann", in: types).isMissing, "a shape that is no type")
        expectEqual(types.types(named: " Refund "), [made], "found by its name, folded")
        expectEqual(types.types(named: "Nothing"), [])
    },
    test("a new type made empty asks the model nothing; words typed after it are read as for any type") {
        let model = ScriptedLanguageModel(), scheduler = ManualScheduler()
        let editor = try typeEditor(scheduler: scheduler, model: model)
        let ann = editor.add(memo("Ann"))
        let made = try require(editor.newType(named: "Company", besides: ann))
        scheduler.advance(by: .seconds(10))
        expectEqual(model.requests.count, 0, "no words, no fields: nothing to read")
        expectEqual(editor.schema(made), TypeSchemaProperty.starter)
    },
])
