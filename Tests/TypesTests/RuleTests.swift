@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Types
import Validation

// A type's rules: its schema's text read as JSON Schema, Validation's issues on the shape, in the
// words its panel shows them in.

@MainActor let ruleTests = Suite("A type's rules", [
    test("not JSON is an error at its line and column; a root that isn't an object is an error") {
        let editor = try typeEditor()
        let broken = editor.addType(#"{"type": "object", "properties": {"#)
        expectEqual(editor.issues(broken).map(\.message), ["Invalid JSON: expected a property name at line 1, column 35."])
        expectEqual(editor.issues(broken).map(\.severity), [.error])
        let array = editor.addType("[1, 2]", at: CGPoint(x: 400, y: 40))
        expectEqual(editor.issues(array).map(\.message), ["A schema must be a JSON object."])
    },
    test("required naming no property warns, as does a type that isn't JSON Schema's, where it is; the seven, lists of them, and no type don't") {
        let editor = try typeEditor()
        let id = editor.addType(#"{"properties": {"a": {"type": "ninteger"}, "b": {"type": ["string", "null"]}, "c": {}}, "required": ["fax", "a"]}"#)
        expectEqual(editor.issues(id).map(\.message), ["“fax” is required, but isn’t a property.", "“ninteger” in a isn’t a JSON Schema type."])
        expectEqual(editor.issues(id).map(\.severity), [.warning, .warning])
        for type in ["string", "number", "integer", "boolean", "object", "array", "null"] {
            let fine = editor.addType(#"{"properties": {"a": {"type": "\#(type)"}}}"#, at: CGPoint(x: 400, y: 40))
            expectEqual(editor.issues(fine), [], type)
        }
    },
    test("what else JSON Schema's meta-schema refuses warns, in its sentences; a type is said once, by the rule of its own") {
        let editor = try typeEditor()
        let id = editor.addType(#"{"properties": {"age": {"type": "integer", "minimum": "zero"}, "tags": {"type": "array", "minItems": -1}}}"#)
        let messages = editor.issues(id).map(\.message)
        expectEqual(messages.count, 2, "\(messages)")
        expect(messages.allSatisfy { $0.hasSuffix(".") && $0.first?.isUppercase == true }, "sentences: \(messages)")
        expectEqual(editor.issues(id).map(\.severity), [.warning, .warning])
        let typo = editor.addType(#"{"properties": {"a": {"type": "strin"}}}"#, at: CGPoint(x: 400, y: 40))
        expectEqual(editor.issues(typo).map(\.message), ["“strin” in a isn’t a JSON Schema type."], "said once")
    },
    test("at most 20 warnings, however many names a schema gets wrong") {
        let editor = try typeEditor()
        let fields = (0..<30).map { "\"f\($0)\": {\"type\": \"bad\($0)\", \"minLength\": -1}" }.joined(separator: ", ")
        let id = editor.addType("{\"properties\": {\(fields)}}")
        expectEqual(editor.issues(id).count, 20)
    },
    test("an edit to the schema is checked again: fixing the JSON clears its error; a shape that stops being a type has none") {
        let editor = try typeEditor()
        let id = editor.addType(#"{"type": "object", "properties": {"#)
        expectEqual(editor.issues(id).count, 1)
        editor.transact { $0.update(id) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {}}"#) } }
        expectEqual(editor.issues(id), [])
        editor.transact { $0.update(id) { $0[TypeSchemaProperty.self] = SchemaText("[") } }
        expectEqual(editor.issues(id).count, 1)
        editor.removeType(id)
        expectEqual(editor.issues(id), [])
    },
    test("reading schemas: drawing types reads none, and a write reads only the type written") {
        let editor = try typeEditor()
        var ids: [ShapeID] = []
        for n in 0..<30 {
            ids.append(editor.addType(#"{"type": "object", "properties": {"f\#(n)": {}}}"#, words: "a thing \(n)",
                                      at: CGPoint(x: CGFloat(n % 6) * 260, y: CGFloat(n / 6) * 120)))
        }
        _ = renderBitmap(editor, size: CGSize(width: 1600, height: 700))
        let read = TypesPlugin.schemasRead
        _ = renderBitmap(editor, size: CGSize(width: 1600, height: 700))
        expectEqual(TypesPlugin.schemasRead, read, "a frame reads no schema")
        editor.transact { $0.update(ids[0]) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"g": {}}}"#) } }
        _ = renderBitmap(editor, size: CGSize(width: 1600, height: 700))
        expectEqual(TypesPlugin.schemasRead, read + 1, "only the one written")
    },
])

@MainActor let wordsTests = Suite("A type's words", [
    test("a kind's words are read and written through what it hands Types: a write fits the shape as the kind fits it") {
        let editor = try typeEditor()
        let id = editor.addType(TypeSchemaProperty.starter, words: "a pet")
        let words = try require(editor.registry.typeWords(of: Memo.kind))
        let record = try require(editor.document[id])
        expectEqual(words.words(record), "a pet")
        expectEqual(words.placement(record)?.box, MemoStyle.textBox(of: try require(record.box)))
        let long = MentionText(plain: String(repeating: "a pet in my household, ", count: 12))
        editor.transact { words.write(&$0, id, long) }
        expectEqual(editor.words(id), long)
        expect(try require(editor.document[id]?.box).height > MemoStyle.emptyHeight, "fitted")
        expect(editor.registry.canBeType(Memo.kind))
        expect(editor.registry.typeWords(of: "nothing") == nil)
    },
])
