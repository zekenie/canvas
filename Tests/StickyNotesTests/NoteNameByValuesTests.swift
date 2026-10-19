import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Foundation
import Mentions
import StickyNotes
import TestKit
import TextEditing
import Titles
import Types

// A note with no title and no words is named by its values (`FieldValues.name`, through the note's `untitled:`): its
// filled top-level plain values in key order, joined by ` · `, wherever Mentions names a shape. A note with something to
// say is named by that; a type's own note and a note with no values are still the placeholder.

@MainActor private func editorWithNotes() throws -> CanvasEditor {
    CanvasEditor(registry: try Registry(plugins: notePlugins), scheduler: ManualScheduler())
}

@MainActor
private func add(_ values: JSONObject, words: String = "", title: String? = nil, to editor: CanvasEditor, id: ShapeID = ShapeID()) -> ShapeID {
    var note = ShapeRecord(id: id, StickyNote(frame: CGRect(x: 0, y: 0, width: 200, height: 200), text: MentionText(plain: words)))
    note[TitleProperty.self] = title
    if !values.isEmpty { note[FieldValuesProperty.self] = FieldValues(values) }
    let record = AnyShapeRecord(note)
    editor.transact { $0.insert(record) }
    return id
}

@MainActor private func label(of id: ShapeID, in editor: CanvasEditor) -> MentionAppearance? {
    editor.document[id].flatMap(editor.registry.mentionAppearance)
}

@MainActor let noteNameByValuesTests = Suite("A note named by its values", [
    test("a note with values and no title or words is named by them, in key order, joined by ` · `; the first-minute Layer reads as board 1 draws it") {
        let editor = try editorWithNotes()
        let layer = add(["order": 1, "purpose": "expose foobar", "title": "foundation"], to: editor)
        let name = try require(label(of: layer, in: editor))
        expectEqual(name.label, "1 · expose foobar · foundation")
        expect(!name.isPlaceholder, "a name, not the placeholder")
        // Key order, not the order a type's rows are in: `zeta` is the first row of a type that lists it first.
        let unsorted = add(["zeta": "last", "alpha": "first", "mid": 7.5], to: editor)
        expectEqual(label(of: unsorted, in: editor)?.label, "first · 7.5 · last")
    },
    test("a ticked box is named by its field, a clear one and nested values by nothing; a long name is cut") {
        let editor = try editorWithNotes()
        let ticked = add(["urgent": true, "done": false, "address": ["city": "Oslo"], "tags": ["a", "b"]], to: editor)
        expectEqual(label(of: ticked, in: editor)?.label, "urgent")
        let nothing = add(["done": false, "address": ["city": "Oslo"]], to: editor)
        expectEqual(label(of: nothing, in: editor)?.label, "Untitled Note", "no plain value says anything")
        let long = add(["a": .string(String(repeating: "x", count: 100))], to: editor)
        let cut = try require(label(of: long, in: editor)?.label)
        expectEqual(cut.count, FieldValues.nameLength)
        expect(cut.hasSuffix("…"))
        let lines = add(["a": "first line\nsecond"], to: editor)
        expectEqual(label(of: lines, in: editor)?.label, "first line", "a value of several lines says its first")
    },
    test("a title, then the words' first line, come before the values; a type's own note and a note with none are the placeholder") {
        let editor = try editorWithNotes()
        let titled = add(["purpose": "x"], title: "Auth", to: editor)
        let worded = add(["purpose": "x"], words: "Sign in\nmore", to: editor)
        let blank = add([:], to: editor)
        let type = ShapeID()
        var schema = ShapeRecord(id: type, StickyNote(frame: CGRect(x: 300, y: 0, width: 200, height: 200), text: ""))
        schema[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
        schema[FieldValuesProperty.self] = FieldValues(["purpose": "x"])
        let record = AnyShapeRecord(schema)
        editor.transact { $0.insert(record) }
        expectEqual(label(of: titled, in: editor)?.label, "Auth")
        expectEqual(label(of: worded, in: editor)?.label, "Sign in")
        expectEqual(label(of: blank, in: editor)?.label, "Untitled Note")
        expectEqual(label(of: type, in: editor)?.label, "Untitled Note", "a type's own note is not named by values")
        expect(label(of: type, in: editor)?.isPlaceholder == true)
    },
    test("it is a named note wherever Mentions names one: `@` offers it, a typed query finds it by its values, and a value edited renames it") {
        let editor = try editorWithNotes()
        let layer = add(["order": 1, "purpose": "expose foobar", "title": "foundation"], to: editor)
        let blank = add([:], to: editor)
        let mentions = try require(editor.mentions)
        let anchor = add([:], title: "Anchor", to: editor)
        let listed = mentions.candidates(matching: "", in: AnyMentionable.self, for: anchor)
        expect(listed.all.contains { $0.id == layer }, "an empty query lists it")
        expect(!listed.all.contains { $0.id == blank }, "a note with nothing in it is still left out of `@`")
        let found = mentions.candidates(matching: "foobar", in: AnyMentionable.self, for: nil)
        expectEqual(found.all.map(\.id), [layer])
        expectEqual(found.all.first?.appearance.label, "1 · expose foobar · foundation")
        editor.transact { $0.update(layer) { $0[FieldValuesProperty.self] = FieldValues(["order": 2, "purpose": "stream"]) } }
        expectEqual(mentions.candidates(matching: "foobar", in: AnyMentionable.self, for: nil).all.map(\.id), [])
        expectEqual(mentions.candidates(matching: "stream", in: AnyMentionable.self, for: nil).all.first?.appearance.label, "2 · stream")
        expectEqual(editor.mentions?.resolve(layer), .live(try require(label(of: layer, in: editor))))
    },
])
