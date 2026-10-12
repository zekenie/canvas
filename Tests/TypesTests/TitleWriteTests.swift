@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Titles
import Types
import Validation

// A note's title written from the field that titles it: by the writer (a row, the card, the panel), once by
// `/is-a`, never by anything else; and what the titles' own rules say of a copy.

private let person = FieldFixtures.namedPersonID, employee = FieldFixtures.namedEmployeeID
private let name = FieldPath(field: "name"), email = FieldPath(field: "email")

/// Person (titled by its name) and Employee, a Person.
@MainActor private func namedEditor(more: [any CanvasPlugin] = []) throws -> CanvasEditor {
    let editor = try typeEditor(more: more)
    editor.addFieldTypes([FieldFixtures.namedPerson, FieldFixtures.namedEmployee])
    editor.addTypeLink(person, to: employee)
    return editor
}

@MainActor private func values(_ editor: CanvasEditor, _ id: ShapeID) -> FieldValues? { editor.document[id]?[FieldValuesProperty.self] }

@MainActor private func type(_ text: String, into id: ShapeID, of editor: CanvasEditor, at path: FieldPath = name) throws {
    try require(editor.fieldWriter).setTyped(text, as: .text, at: path, of: id)
}

/// A typeable kind that holds no title (as an arrow does).
private struct Bare: BoxShapeProps {
    static let kind: ShapeKind = "bare"
    static let properties = Properties<Bare>(title: "Bare") {
        Property("frame", \.frame).required()
        Property("text", \.text)
    }
    var frame = CGRect(x: 0, y: 0, width: 100, height: 40)
    var text: MentionText = ""
    init() {}
}

@MainActor private struct BareDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Bare>, in context: RenderContext) {}
}

private struct BarePlugin: CanvasPlugin {
    var id: PluginID { "bare" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(BareDefinition()) { bare in
            bare.typeWords(\.text, drawnIn: { _ in nil })
            bare.typeable()
        }
    }
}

@MainActor let titleWriteTests = Suite("A title written from its field", [
    test("a note with no title takes the value as it is typed, and three typed writes are one step that one undo takes back whole") {
        let editor = try namedEditor()
        let ann = editor.addNote(of: [person])
        let start = editor.revision
        for typed in ["A", "An", "Ann"] {
            try type(typed, into: ann, of: editor)
            expectEqual(editor.title(ann), typed)
        }
        expectEqual(editor.revision, start + 3)
        expectEqual(editor.undoHistory.undoName, "Change Name")
        editor.undo()
        expectEqual(editor.title(ann), nil)
        expectEqual(values(editor, ann), nil, "the title and the value are one step")
        editor.redo()
        expectEqual(editor.title(ann), "Ann")
        expectEqual(values(editor, ann)?["name"], "Ann")
    },
    test("a title that matches the old value follows it; clearing the value or growing it past 80 takes it off, and it comes back at 80") {
        let editor = try namedEditor()
        let ann = editor.addNote(of: [person])
        try type("Ann", into: ann, of: editor)
        try type("Anna", into: ann, of: editor)
        expectEqual(editor.title(ann), "Anna")
        try type("", into: ann, of: editor)
        expectEqual(editor.title(ann), nil, "a cleared value takes it off")
        expectEqual(values(editor, ann), nil)
        try type(String(repeating: "a", count: 80), into: ann, of: editor)
        expectEqual(editor.title(ann)?.count, 80)
        try type(String(repeating: "a", count: 81), into: ann, of: editor)
        expectEqual(editor.title(ann), nil, "81 characters")
        expectEqual(values(editor, ann)?["name"], .string(String(repeating: "a", count: 81)), "the value is kept as typed")
        try type(String(repeating: "a", count: 80), into: ann, of: editor)
        expectEqual(editor.title(ann)?.count, 80, "back to 80: written again")
    },
    test("a title set by hand is untouched, whatever is written; so is a title when another field is written") {
        let editor = try namedEditor()
        let boss = editor.addInstance("", of: [person], title: "The Boss")
        try type("Ann", into: boss, of: editor)
        expectEqual(editor.title(boss), "The Boss")
        try type("", into: boss, of: editor)
        expectEqual(editor.title(boss), "The Boss", "a cleared value too")
        let ann = editor.addNote(of: [person])
        try type("Ann", into: ann, of: editor)
        try type("ann@example.com", into: ann, of: editor, at: email)
        expectEqual(editor.title(ann), "Ann", "a write to email titles and un-titles nothing")
        let bo = editor.addNote(of: [person])
        try type("bo@example.com", into: bo, of: editor, at: email)
        expectEqual(editor.title(bo), nil, "a write to email never titles")
        try type("Bo", into: bo, of: editor)
        expectEqual(editor.title(bo), "Bo")
    },
    test("a title that was Ann's name by hand and is renamed in the panel stops following; typing the name to match makes it follow again") {
        let editor = try namedEditor()
        let ann = editor.addNote(of: [person])
        try type("Ann", into: ann, of: editor)
        editor.transact("Rename") { $0.update(ann) { $0[TitleProperty.self] = "Annie" } }
        try type("Anna", into: ann, of: editor)
        expectEqual(editor.title(ann), "Annie")
        editor.transact("Rename") { $0.update(ann) { $0[TitleProperty.self] = "Anna" } }
        try type("Annabel", into: ann, of: editor)
        expectEqual(editor.title(ann), "Annabel", "a hand title equal to the value is a copy, and follows")
    },
    test("an Employee is titled through Person's `$title`; one that writes its own title field uses that") {
        let editor = try namedEditor()
        let bo = editor.addNote(of: [employee])
        try type("Bo Park", into: bo, of: editor)
        expectEqual(editor.title(bo), "Bo Park")
        editor.transact("Own") { $0.update(employee) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"role": {"type": "string"}, "$title": {"x-canvas-from": "role"}}}"#) } }
        let cy = editor.addNote(of: [employee])
        try type("Cy", into: cy, of: editor)
        expectEqual(editor.title(cy), nil, "Employee's own `$title` names role")
        try type("Cook", into: cy, of: editor, at: FieldPath(field: "role"))
        expectEqual(editor.title(cy), "Cook")
    },
    test("a type with a bad `$title` titles nothing, and a kind that holds no title, a type's own note and a shape that isn't one are left alone") {
        let editor = try namedEditor(more: [BarePlugin()])
        let broken = editor.addType(#"{"type": "object", "properties": {"nme": {"type": "string"}, "$title": {"x-canvas-from": "name"}}}"#, title: "Broken")
        let note = editor.addNote(of: [broken])
        try type("x", into: note, of: editor, at: FieldPath(field: "nme"))
        expectEqual(editor.title(note), nil)
        let bare = ShapeID()
        editor.transact { $0.insert(ShapeRecord(id: bare, Bare())) }
        editor.addTypeLink(person, to: bare)
        try type("Ann", into: bare, of: editor)
        expectEqual(values(editor, bare)?["name"], "Ann", "the value is written")
        expectEqual(editor.document[bare]?[TitleProperty.self], nil, "a kind with no title is never given one")
        try type("Ann", into: employee, of: editor)
        expectEqual(editor.title(employee), "Employee", "Employee's type note holds Person in its `is`: not titled")
        try type("Ann", into: person, of: editor)
        expectEqual(editor.title(person), "Person")
    },
    test("a read-only shape shakes and nothing is written, the title included; a write with a card's key joins the held step, title in it") {
        let log = RefusalLog()
        let editor = try namedEditor(more: [FreezingPlugin(log: log)])
        let ann = editor.addNote(of: [person])
        try type("Ann", into: ann, of: editor)
        editor.freeze([ann])
        let writer = try require(editor.fieldWriter)
        expect(!writer.setTyped("Anna", as: .text, at: name, of: ann))
        expectEqual(editor.title(ann), "Ann")
        editor.freeze([ann], false)
        let bo = editor.addNote(of: [person])
        writer.set("Bo", at: name, of: bo, step: .card(key: 1))
        writer.set("bo@example.com", at: email, of: bo, step: .card(key: 1))
        expectEqual(editor.title(bo), "Bo")
        editor.undo()
        expectEqual(editor.title(bo), nil, "one held step: the value and the title go together")
        expectEqual(values(editor, bo), nil)
    },
    test("renaming a pair and removing an unnamed value change no title, and a run of writes resolves nothing again") {
        let editor = try namedEditor()
        let ann = editor.addNote(of: [person], ["name": "Ann"])
        let book = try require(editor.fieldBook)
        let titled = editor.addNote(of: [person])
        try type("A", into: titled, of: editor)
        let resolutions = book.resolutionsMade
        for typed in ["An", "Ann", "Anne", "Anna"] { try type(typed, into: titled, of: editor) }
        expectEqual(book.resolutionsMade, resolutions, "the source is kept with the list")
        expectEqual(editor.title(titled), "Anna")
        let writer = try require(editor.fieldWriter)
        editor.transact { $0.update(titled) { $0[FieldValuesProperty.self] = FieldValues(["name": "Anna", "ghost": "boo"]) } }
        expect(writer.removeUnnamed("ghost", of: titled))
        expectEqual(editor.title(titled), "Anna")
        expectEqual(editor.title(ann), nil, "values set another way title nothing")
    },
])

/// A note on another board, and the Person it is made of on the root.
@MainActor private func onAnotherBoard(values: JSONObject, title: String? = nil) throws -> (editor: CanvasEditor, note: ShapeID) {
    let pocket = ShapeID(), note = ShapeID()
    var inside = instanceRecord("", of: [], title: title, id: note)
    inside[FieldValuesProperty.self] = FieldValues(values)
    let types = [FieldFixtures.namedPerson, FieldFixtures.namedEmployee].map { typeRecord($0.schema, words: $0.words, title: $0.title, id: $0.id) }
    let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))] + types),
                          children: [pocket: CanvasDocument(shapes: [inside])])
    return (try typeEditor(file: file, more: [PocketsPlugin()]), note)
}

@MainActor let isATitleTests = Suite("A note given a type is titled once", [
    test("`/is-a` on a note that holds the value and no title titles it in the step Add Type, and undo takes both back") {
        let editor = try namedEditor()
        let ann = editor.addInstance("Ann", of: [])
        editor.setFieldValues(["name": "Ann Lee"], of: ann)
        let line = try IsALine(on: ann, in: editor)
        line.type("/is-a Person")
        line.returnKey()
        expectEqual(editor.typesOf(ann), [person])
        expectEqual(editor.title(ann), "Ann Lee")
        expectEqual(editor.undoHistory.undoName, "Add Type")
        editor.undo()
        expectEqual(editor.typesOf(ann), [])
        expectEqual(editor.title(ann), nil)
    },
    test("a note with a title is left alone, whatever it is; a note with no value stays untitled; one holding a value too long is untitled") {
        let editor = try namedEditor()
        let held = editor.addInstance("", of: [], title: "Mine")
        editor.setFieldValues(["name": "Ann"], of: held)
        let empty = editor.addInstance("", of: [], at: CGPoint(x: 400, y: 400))
        let long = editor.addInstance("", of: [], at: CGPoint(x: 800, y: 400))
        editor.setFieldValues(["name": .string(String(repeating: "a", count: 81))], of: long)
        editor.addTypeLink(person, to: [held, empty, long])
        expectEqual(editor.title(held), "Mine")
        expectEqual(editor.title(empty), nil)
        expectEqual(editor.title(long), nil)
    },
    test("two notes in one step are both titled in it; a type built on Person gives Person's field; a note on another board is titled too") {
        let editor = try namedEditor()
        let a = editor.addInstance("", of: [], at: CGPoint(x: 40, y: 400)), b = editor.addInstance("", of: [], at: CGPoint(x: 400, y: 400))
        editor.setFieldValues(["name": "Ann"], of: a)
        editor.setFieldValues(["name": "Bo"], of: b)
        editor.addTypeLink(employee, to: [a, b])
        expectEqual([editor.title(a), editor.title(b)], ["Ann", "Bo"])
        editor.undo()
        expectEqual([editor.title(a), editor.title(b)], [nil, nil], "one step")
        let far = try onAnotherBoard(values: ["name": "Cy"])
        far.editor.addTypeLink(person, to: far.note)
        expectEqual(far.editor.file.record(far.note)?[TitleProperty.self], "Cy")
    },
    test("the title stays when the type goes, and a type with no `$title` titles nothing; a type's own note is never titled") {
        let editor = try namedEditor()
        let ann = editor.addInstance("", of: [])
        editor.setFieldValues(["name": "Ann"], of: ann)
        editor.addTypeLink(person, to: ann)
        expectEqual(editor.title(ann), "Ann")
        editor.removeTypeLink(person, from: ann)
        expectEqual(editor.title(ann), "Ann", "Remove Type writes `is` alone")
        let plain = editor.addType(FieldFixtures.person.schema, title: "Plain")
        let bo = editor.addInstance("", of: [], at: CGPoint(x: 400, y: 400))
        editor.setFieldValues(["name": "Bo"], of: bo)
        editor.addTypeLink(plain, to: bo)
        expectEqual(editor.title(bo), nil)
        let other = editor.addType(FieldFixtures.person.schema, title: "Other")
        editor.setFieldValues(["name": "Cy"], of: other)
        editor.transact { $0.update(other) { $0[TitleProperty.self] = nil } }
        editor.addTypeLink(person, to: other)
        expectEqual(editor.title(other), nil, "a type's own note")
    },
])

@MainActor let titleDuplicateTests = Suite("A title copied from a field is a title", [
    test("two Persons given one name both warn, a duplicate does, and renaming one clears both") {
        let editor = try namedEditor(more: [TitleValidationPlugin()])
        let ann = editor.addNote(of: [person]), other = editor.addNote(of: [person])
        try type("Ann Lee", into: ann, of: editor)
        expectEqual(editor.issues(ann), [])
        try type("Ann Lee", into: other, of: editor)
        let words = "“Ann Lee” is another shape’s title too."
        expectEqual(editor.issues(ann).map(\.message), [words])
        expectEqual(editor.issues(other).map(\.message), [words])
        expectEqual(editor.issues(ann).map(\.field), ["title"])
        // A copy carries its title and its value (what a paste or a duplicate makes), and warns as any title does.
        let copy = editor.addInstance("", of: [person], title: "Ann Lee", at: CGPoint(x: 800, y: 400))
        editor.setFieldValues(["name": "Ann Lee"], of: copy)
        expectEqual(editor.issues(copy).map(\.message), [words])
        try type("Ann Lees", into: other, of: editor)
        expectEqual(editor.issues(other), [])
        expectEqual(editor.issues(ann).map(\.message), [words], "the copy still shares it")
        editor.transact { $0.delete([copy]) }
        expectEqual(editor.issues(ann), [])
    },
])
