@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit
import Titles
import Types
import Validation

// A type's `$title` that titles nothing is a warning on the type that wrote it, in the rule that carries its
// gone-reference warning: its note's `schema`, never an instance's.

private func schema(_ properties: String) -> String { #"{"type": "object", "properties": {\#(properties)}}"# }

@MainActor private func messages(_ editor: CanvasEditor, _ id: ShapeID) -> [String] {
    editor.issues(id).map(\.message)
}

@MainActor private func rewrite(_ editor: CanvasEditor, _ id: ShapeID, to text: String) {
    editor.transact("Edit Schema") { $0.update(id) { $0[TypeSchemaProperty.self] = SchemaText(text) } }
}

@MainActor let titleWarningTests = Suite("A `$title` that titles nothing", [
    test("each problem warns the type that wrote it, on its schema, in its own words; a working one and no `$title` say nothing") {
        let editor = try typeEditor()
        let works = editor.addType(schema(#""name": {"type": "string"}, "$title": {"x-canvas-from": "name"}"#), title: "Works")
        let none = editor.addType(schema(#""name": {"type": "string"}"#), title: "None")
        let nothing = editor.addType(schema(#""name": {"type": "string"}, "$title": {}"#), title: "Nothing")
        let missing = editor.addType(schema(#""name": {"type": "string"}, "$title": {"x-canvas-from": "nme"}"#), title: "Missing")
        let cannot = editor.addType(schema(#""address": {"type": "object", "properties": {"city": {"type": "string"}}}, "$title": {"x-canvas-from": "address"}"#), title: "Cannot")
        let yesNo = editor.addType(schema(#""done": {"type": "boolean"}, "$title": {"x-canvas-from": "done"}"#), title: "YesNo")
        let notObject = editor.addType(schema(#""name": {"type": "string"}, "$title": "name""#), title: "NotObject")
        expectEqual(messages(editor, works), [])
        expectEqual(messages(editor, none), [])
        expectEqual(messages(editor, nothing), ["“$title” names no field."])
        expectEqual(messages(editor, missing), ["“$title” names “nme”, which isn’t a field."])
        expectEqual(messages(editor, cannot), ["“$title” names “address”, which isn’t text, a number, a date or a choice."])
        expectEqual(messages(editor, yesNo), ["“$title” names “done”, which isn’t text, a number, a date or a choice."])
        expect(messages(editor, notObject).contains("“$title” names no field."), "a `$title` that is no object: \(messages(editor, notObject)) (the meta-schema says its own)")
        expectEqual(editor.issues(missing).map(\.severity), [.warning])
        expectEqual(editor.issues(missing).map(\.field), ["schema"])
        rewrite(editor, missing, to: schema(#""name": {"type": "string"}, "$title": {"x-canvas-from": "name"}"#))
        expectEqual(messages(editor, missing), [], "fixed")
        editor.undo()
        expectEqual(messages(editor, missing).count, 1, "and broken again")
    },
    test("a type with a gone reference and a bad `$title` carries both, and no instance is warned") {
        let editor = try typeEditor()
        let ghost = ShapeID()
        let holder = editor.addType(schema(#""x": {"$ref": "\#(FieldFixtures.uri(of: ghost))"}, "$title": {"x-canvas-from": "nme"}"#), title: "Holder")
        expectEqual(messages(editor, holder), ["Refers to a type that is gone.", "“$title” names “nme”, which isn’t a field."])
        let note = editor.addInstance("Ann", of: [holder])
        expectEqual(editor.issues(note), [])
    },
    test("a child that inherits a bad `$title` says nothing, and the parent does; Employee's own `$title` naming Person's field warns once Person renames it, and clears when it is put back") {
        let editor = try typeEditor()
        let base = schema(#""name": {"type": "string"}"#)
        let person = editor.addType(base + "", title: "Person")
        let employee = editor.addType(schema(#""role": {"type": "string"}, "$title": {"x-canvas-from": "name"}"#), title: "Employee", at: CGPoint(x: 400, y: 40))
        editor.addTypeLink(person, to: employee)
        expectEqual(messages(editor, employee), [], "Person's name is a field Employee has through the chain")
        rewrite(editor, person, to: schema(#""nom": {"type": "string"}"#))
        expectEqual(messages(editor, employee), ["“$title” names “name”, which isn’t a field."])
        expectEqual(messages(editor, person), [])
        rewrite(editor, person, to: base)
        expectEqual(messages(editor, employee), [], "put back")
        // A bad one Employee inherits is Person's to say.
        rewrite(editor, person, to: schema(#""name": {"type": "string"}, "$title": {"x-canvas-from": "nme"}"#))
        rewrite(editor, employee, to: schema(#""role": {"type": "string"}"#))
        expectEqual(messages(editor, person), ["“$title” names “nme”, which isn’t a field."])
        expectEqual(messages(editor, employee), [], "inherited: not its own")
    },
])
