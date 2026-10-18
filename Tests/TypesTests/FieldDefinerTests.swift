import Canvas
import CanvasTesting
import CoreGraphics
import TestKit
import Types

// The one writer of a type's field definitions (`FieldDefiner`): its door (what it refuses), the step it names,
// what it writes, and what follows a write. The edits themselves are `fieldDefinitionTests`'.

private let ownerSchema = """
{
  "type": "object",
  "properties": {},
  "required": []
}
"""

@MainActor private func schema(_ editor: CanvasEditor, _ id: ShapeID) -> String? { editor.document[id]?[TypeSchemaProperty.self]?.text }

@MainActor private func definer(_ editor: CanvasEditor) throws -> FieldDefiner { try require(editor.fieldDefiner) }

@MainActor private func typeOf(_ editor: CanvasEditor, schema: String = TypeSchemaProperty.starter) -> ShapeID {
    editor.addType(schema, title: "Owner")
}

@MainActor let fieldDefinerTests = Suite("The field definer", [
    test("each operation is one step named for it, and undo and redo put the schema back byte for byte") {
        let editor = try typeEditor()
        let type = typeOf(editor)
        let writer = try definer(editor)
        var texts = [try require(schema(editor, type))]
        @MainActor func step(_ name: String, _ body: () -> Bool) throws {
            expect(body(), name)
            expectEqual(editor.undoHistory.undoName, name)
            texts.append(try require(schema(editor, type)))
            expect(texts.last != texts[texts.count - 2], name)
        }
        try step("Add Field") { writer.addField(named: "since", kind: .date, to: type) == "since" }
        try step("Add Field") { writer.addField(named: "primary", kind: .yesNo, to: type) == "primary" }
        try step("Add Field") { writer.addField(named: "Level", kind: .text, to: type) == "level" }
        try step("Rename Field") { writer.renameField("level", to: "Tier", in: type) }
        try step("Change Kind") { writer.changeKind(of: "level", to: .choice, in: type) }
        try step("Add Option") { writer.addOption("gold", to: "level", in: type) }
        try step("Add Option") { writer.addOption("silver", to: "level", in: type) }
        try step("Rename Option") { writer.renameOption(at: 1, to: "tin", of: "level", in: type) }
        try step("Remove Option") { writer.removeOption(at: 0, of: "level", in: type) }
        try step("Remove Field") { writer.removeField("primary", from: type) }
        let final = try require(schema(editor, type))
        for earlier in texts.dropLast().reversed() {
            editor.undo()
            expectEqual(schema(editor, type), earlier, "undo is exact")
        }
        for later in texts.dropFirst() {
            editor.redo()
            expectEqual(schema(editor, type), later)
        }
        expectEqual(schema(editor, type), final)
        expectEqual(writer.fields(of: type).map(\.key), ["since", "level"])
        expectEqual(writer.fields(of: type).map(\.name), ["since", "Tier"])
        expectEqual(writer.fields(of: type)[1].options, ["tin"])
    },
    test("a write that changes nothing makes no commit and no step, and a refused one writes nothing") {
        let editor = try typeEditor()
        let type = typeOf(editor)
        let writer = try definer(editor)
        writer.addField(named: "size", kind: .choice, to: type)
        writer.addOption("m", to: "size", in: type)
        let start = editor.revision, undoable = editor.undoHistory.undoName, text = schema(editor, type)
        @MainActor func nothing(_ what: String, _ body: () -> Bool) {
            expect(!body(), what)
            expectEqual(editor.revision, start, what)
            expectEqual(editor.undoHistory.undoName, undoable, what)
            expectEqual(schema(editor, type), text, what)
        }
        nothing("same kind") { writer.changeKind(of: "size", to: .choice, in: type) }
        nothing("same name") { writer.renameField("size", to: "size", in: type) }
        nothing("an option it has") { writer.addOption("m", to: "size", in: type) }
        nothing("an empty option") { writer.addOption(" ", to: "size", in: type) }
        nothing("an empty name") { writer.renameField("size", to: "  ", in: type) }
        nothing("a field that is not there") { writer.removeField("nope", from: type) }
        nothing("an option that is not there") { writer.removeOption(at: 4, of: "size", in: type) }
        nothing("another shape") { writer.changeKind(of: "size", to: .text, in: ShapeID()) }
        expect(writer.addField(named: "  ", kind: .text, to: type) == nil)
        expect(writer.addField(named: "?!", kind: .text, to: type) == nil)
        expectEqual(editor.revision, start)
        let note = editor.addInstance("plain", of: [])
        expect(writer.addField(named: "x", kind: .text, to: note) == nil, "a shape that is no type")
        expect(!writer.removeField("x", from: note))
    },
    test("a schema that isn't a JSON object refuses every write: nothing written, no shake, no step") {
        let log = RefusalLog()
        let editor = try typeEditor(more: [FreezingPlugin(log: log)])
        let broken = #"{"type": "object", "properties": {"a": "#
        let type = typeOf(editor, schema: broken)
        let writer = try definer(editor)
        let start = editor.revision
        expect(writer.addField(named: "since", kind: .text, to: type) == nil)
        expect(!writer.renameField("a", to: "b", in: type))
        expect(!writer.changeKind(of: "a", to: .number, in: type))
        expect(!writer.removeField("a", from: type))
        expect(!writer.addOption("x", to: "a", in: type))
        expectEqual(schema(editor, type), broken)
        expectEqual(editor.revision, start)
        expect(log.refusals.isEmpty, "a no, not a shake")
        let array = typeOf(editor, schema: "[1, 2]")
        expect(writer.addField(named: "since", kind: .text, to: array) == nil)
        expectEqual(schema(editor, array), "[1, 2]")
        expectEqual(writer.fields(of: type), [])
    },
    test("a type that can't change is refused and heard before any transaction: every operation, no step") {
        let log = RefusalLog()
        let editor = try typeEditor(more: [FreezingPlugin(log: log)])
        let type = typeOf(editor)
        let writer = try definer(editor)
        writer.addField(named: "size", kind: .choice, to: type)
        editor.freeze([type])
        let start = editor.revision, undoable = editor.undoHistory.undoName, text = schema(editor, type)
        expect(writer.addField(named: "x", kind: .text, to: type) == nil)
        expect(!writer.renameField("size", to: "Big", in: type))
        expect(!writer.changeKind(of: "size", to: .text, in: type))
        expect(!writer.removeField("size", from: type))
        expect(!writer.addOption("m", to: "size", in: type))
        expect(!writer.renameOption(at: 0, to: "x", of: "size", in: type))
        expect(!writer.removeOption(at: 0, of: "size", in: type))
        expectEqual(log.refusals.count, 7, "each is heard")
        expect(log.refusals.allSatisfy { $0 == [type] })
        expectEqual(schema(editor, type), text)
        expectEqual(editor.revision, start)
        expectEqual(editor.undoHistory.undoName, undoable)
        editor.freeze([type], false)
        expect(writer.addField(named: "x", kind: .text, to: type) == "x")
    },
    test("the write is the schema as the starter lays it out, and the field is read back as its kind by the book, the rows and the check") {
        let editor = try typeEditor()
        let type = typeOf(editor)
        let writer = try definer(editor)
        for (name, kind) in [("since", DefinedKind.date), ("primary", .yesNo), ("share", .number), ("note", .text)] {
            writer.addField(named: name, kind: kind, to: type)
        }
        writer.addField(named: "level", kind: .choice, to: type)
        writer.addOption("gold", to: "level", in: type)
        writer.addOption("tin", to: "level", in: type)
        expectEqual(schema(editor, type), """
        {
          "type": "object",
          "properties": {
            "since": {
              "type": "string",
              "format": "date"
            },
            "primary": {
              "type": "boolean"
            },
            "share": {
              "type": "number"
            },
            "note": {
              "type": "string"
            },
            "level": {
              "type": "string",
              "enum": ["gold", "tin"]
            }
          }
        }
        """)
        let instance = editor.addInstance("", of: [type])
        let book = try require(editor.fieldBook)
        let resolved = book.fields(of: try require(editor.document[instance]))
        let kinds = resolved.fields.map { book.kind(of: $0) }
        expectEqual(kinds, [.plain(.date), .plain(.yesNo), .plain(.number(integer: false)), .plain(.text),
                            .plain(.choice([FieldOption(value: .string("gold"), label: "gold"), FieldOption(value: .string("tin"), label: "tin")]))])
        expectEqual(resolved.fields.map(\.field.name), ["since", "primary", "share", "note", "level"])
        let writerOfValues = try require(editor.fieldWriter)
        writerOfValues.set("2021-05-01", at: FieldPath(field: "since"), of: instance)
        writerOfValues.set("copper", at: FieldPath(field: "level"), of: instance)
        let problems = try require(editor.fieldChecks).check(of: try require(editor.document[instance])).problems.map(\.path.pointer)
        expectEqual(problems, ["/level"], "the date stands, and a value that is no option is wrong")
    },
    test("a note that is an instance gains a row when a field is added, changes it when renamed or re-kinded, loses it when removed; undo brings them back") {
        let editor = try rowEditor()
        let type = editor.addSlipType(TypeSchemaProperty.starter, words: "An owner", title: "Owner")
        let writer = try definer(editor)
        let instance = editor.addSlip("", of: [type])
        let rows = try require(editor.rowBook)
        _ = editor.laidOut(instance)
        expectEqual(rows.rows(of: instance).count, 0)
        let height = editor.laidOut(instance)?.height
        writer.addField(named: "since", kind: .date, to: type)
        expectEqual(rows.rows(of: instance).map(\.name), ["since"])
        expect((editor.laidOut(instance)?.height ?? 0) > (height ?? 0), "the note grew a row")
        writer.addField(named: "primary", kind: .yesNo, to: type)
        writer.renameField("since", to: "Owned since", in: type)
        expectEqual(rows.rows(of: instance).map(\.name), ["Owned since", "primary"])
        expectEqual(rows.rows(of: type).map(\.name), ["Owned since", "primary"], "and the type's own note")
        writer.changeKind(of: "primary", to: .number, in: type)
        expectEqual(rows.rows(of: type).map { $0.content }.last, .kind(label: "Number", chip: nil, hasMore: false))
        writer.removeField("since", from: type)
        expectEqual(rows.rows(of: instance).map(\.name), ["primary"])
        editor.undo()
        editor.undo()
        expectEqual(rows.rows(of: instance).map(\.name), ["Owned since", "primary"], "undo brings the rows back with the schema")
        expectEqual(rows.rows(of: type).map { $0.content }.last, .kind(label: "Yes or no", chip: nil, hasMore: false))
    },
    test("TypeIndex hears each write as a change of the type, once") {
        let editor = try typeEditor()
        let type = typeOf(editor)
        let writer = try definer(editor)
        var heard: [Set<ShapeID>] = []
        try require(editor.types).onChange { heard.append($0.types) }
        writer.addField(named: "since", kind: .date, to: type)
        writer.addField(named: "since", kind: .date, to: type)
        writer.changeKind(of: "since", to: .date, in: type)
        expectEqual(heard, [[type], [type]])
    },
    test("a type with words keeps a step of its own: the write is the step, the sync's reply (scripted) is another") {
        let editor = try typeEditor()
        let type = editor.addType(TypeSchemaProperty.starter, words: "An owner of a car.", title: "Owner")
        let writer = try definer(editor)
        writer.addField(named: "since", kind: .date, to: type)
        expectEqual(editor.undoHistory.undoName, "Add Field")
        editor.undo()
        expectEqual(writer.fields(of: type), [])
    },
])
