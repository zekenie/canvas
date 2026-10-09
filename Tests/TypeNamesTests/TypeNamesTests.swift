import Automation
import CanvasRPC
@_spi(Host) import Canvas
import CoreGraphics
import Foundation
import Publishing
import TestKit
import Titles
import Types

// `canvas draw` naming types, in DrawLexicon: `is: "Person"` names the type by its title, as the rest
// of a script names shapes, and a shape given a schema is a type that is public. Over memos, which
// are types and instances as a note is, and slabs, which are neither.

@MainActor private func types(of title: String, in editor: CanvasEditor) throws -> [ShapeID]? {
    try require(editor.shape(called: title)?[IsAProperty.self]).map(\.shape)
}

@MainActor let typeNamesTests = Suite("Types in canvas draw", [
    test("is: names a type by its title: the shape keeps its id, in one step, and a quoted title is a list of one") {
        let editor = try typeNamesEditor()
        let person = editor.addType("Person")
        let steps = editor.undoHistory.undoName
        let result = try drawn(#"memo "Ann" is: "Person""#, on: editor)
        expectEqual(result["changes"]?.arrayValue?.compactMap { $0["did"]?.stringValue }, ["created"])
        expectEqual(try types(of: "Ann", in: editor), [person])
        expectEqual(editor.undoHistory.undoName == steps, false, "a step of its own")
        editor.undo()
        expect(editor.shape(called: "Ann") == nil, "one undo takes the whole script back")
        expect(editor.shape(called: "Person") != nil)
    },

    test("several are a JSON list, in the order written; restated, the same list is no change") {
        let editor = try typeNamesEditor()
        let person = editor.addType("Person"), employee = editor.addType("Employee card")
        _ = try drawn(#"memo "Ann" is: ["Person", "Employee card"]"#, on: editor)
        expectEqual(try types(of: "Ann", in: editor), [person, employee])
        let again = try drawn(#"memo "Ann" is: ["Person", "Employee card"]"#, on: editor)
        expectEqual(again["changes"]?.arrayValue?.compactMap { $0["did"]?.stringValue }, ["unchanged"])
        _ = try drawn(#"memo "Ann" is: ["Employee card", "Person"]"#, on: editor)
        expectEqual(try types(of: "Ann", in: editor), [employee, person], "the order is the person's to say: a later one wins")
        _ = try drawn(#"memo "Ann" is: null"#, on: editor)
        expectEqual(editor.shape(called: "Ann")?[IsAProperty.self], nil)
    },

    test("a shape that is no type is refused, saying so; a title nobody has is unknown, with the types like it") {
        let editor = try typeNamesEditor()
        editor.addType("Person")
        _ = try drawn(#"memo "Plain""#, on: editor)
        _ = try drawn(#"slab "Block""#, on: editor)
        for title in ["Plain", "Block"] {
            let error = try refused(#"memo "Ann" is: "\#(title)""#, on: editor)
            expectEqual(error["reason"], "invalid_value")
            let kind = title == "Plain" ? "memo" : "slab"
            expectEqual(error["message"]?.stringValue, #""Ann": is: "\#(title)" is a \#(kind), which isn't a type or a shape"#, title)
        }
        let typo = try refused(#"memo "Ann" is: "Persn""#, on: editor)
        expectEqual(typo["reason"], "unknown_title")
        expect(typo["hint"]?.stringValue?.contains(#""Person""#) == true, "\(typo["hint"] ?? "")")
        expect(typo["hint"]?.stringValue?.contains("Plain") == false, "a guess is a type")
        expect(editor.shape(called: "Ann") == nil, "nothing drawn")
    },

    test("a type drawn in the same script is named by an instance before and after it; its schema is what makes it one") {
        let editor = try typeNamesEditor()
        _ = try drawn(#"""
        memo "Ann" is: "Person"
        memo "Person" schema: "{\"type\":\"object\"}" right of "Ann"
        """#, on: editor)
        let person = try require(editor.shape(called: "Person"))
        expectEqual(try types(of: "Ann", in: editor), [person.id])
        // Without a schema in the script, a memo drawn there is no type.
        let error = try refused(#"""
        memo "Bob" is: "Thing"
        memo "Thing" right of "Bob"
        """#, on: editor)
        expectEqual(error["reason"], "invalid_value")
    },

    test("a type on another board is found as any title in the file is; two with one title are ambiguous") {
        let editor = try typeNamesEditor()
        editor.addType("Person")
        editor.addType("Person")
        let error = try refused(#"memo "Ann" is: "Person""#, on: editor)
        expectEqual(error["reason"], "ambiguous_title")
    },

    test("a shape given a schema by draw is public in the same step, as /type makes one; public: false is its own say, and a type already one keeps it") {
        let editor = try typeNamesEditor()
        let steps = editor.undoHistory.undoName
        let result = try drawn(#"memo "Person" schema: "{\"type\":\"object\"}""#, on: editor)
        expectEqual(result["changes"]?.arrayValue?.compactMap { $0["did"]?.stringValue }, ["created"])
        let person = try require(editor.shape(called: "Person"))
        expect(person[TypeSchemaProperty.self] != nil)
        expectEqual(person[PublicProperty.self], true)
        expect(editor.undoHistory.undoName != steps)
        editor.undo()
        expect(editor.shape(called: "Person") == nil, "one step, schema and public together")

        _ = try drawn(#"memo "Quiet" schema: "{\"type\":\"object\"}" public: false"#, on: editor)
        expectEqual(editor.shape(called: "Quiet")?[PublicProperty.self], false, "said private, so it is")

        // A note already a type, made private by the person, stays private when restated with a new schema.
        let quiet = try require(editor.shape(called: "Quiet")).id
        _ = try drawn(#"memo "Quiet" schema: "{\"type\":\"object\",\"properties\":{\"a\":{\"type\":\"string\"}}}""#, on: editor)
        expectEqual(editor.document[quiet]?[PublicProperty.self], false)

        // A memo that was no type becomes a public one when given a schema.
        _ = try drawn(#"memo "Plain""#, on: editor)
        expectEqual(editor.shape(called: "Plain")?[PublicProperty.self], nil)
        _ = try drawn(#"memo "Plain" schema: "{\"type\":\"object\"}""#, on: editor)
        expectEqual(editor.shape(called: "Plain")?[PublicProperty.self], true)
        // And without a schema, nothing is public.
        _ = try drawn(#"memo "Ann""#, on: editor)
        expectEqual(editor.shape(called: "Ann")?[PublicProperty.self], nil)
    },

    test("a plain memo restated with a schema and public: false is a private type, though it was private already") {
        let editor = try typeNamesEditor()
        _ = try drawn(#"memo "Plain""#, on: editor)
        _ = try drawn(#"memo "Plain" schema: "{\"type\":\"object\"}" public: false"#, on: editor)
        let plain = try require(editor.shape(called: "Plain"))
        expect(plain[TypeSchemaProperty.self] != nil)
        expect(plain[PublicProperty.self] != true, "said private, so it is not made public")
    },

    test("a type is not its own type; one drawn with its types in the same script is, and undo and redo keep the script whole") {
        let editor = try typeNamesEditor()
        let person = editor.addType("Person")
        let error = try refused(#"memo "Ann" schema: "{\"type\":\"object\"}" is: "Ann""#, on: editor)
        expectEqual(error["reason"], "invalid_value")
        expect(error["message"]?.stringValue?.contains("can't be its own type") == true, "\(error["message"] ?? "")")
        expect(editor.shape(called: "Ann") == nil, "nothing drawn")
        _ = try drawn(#"memo "Ann" schema: "{\"type\":\"object\"}" is: "Person""#, on: editor)
        let ann = try require(editor.shape(called: "Ann")).id
        expectEqual(editor.document[ann]?[IsAProperty.self]?.map(\.shape), [person])
        expectEqual(editor.document[ann]?[PublicProperty.self], true)
        editor.undo()
        expect(editor.shape(called: "Ann") == nil)
        editor.redo()
        expectEqual(editor.document[ann]?[IsAProperty.self]?.map(\.shape), [person], "redo brings back the list and the type together")
        expectEqual(editor.document[ann]?[PublicProperty.self], true)
    },

    test("without the plugin an `is:` of text is refused as a value that isn't a list of ids; canvas kinds says what is takes") {
        let editor = try typeNamesEditor(typeNames: false)
        editor.addType("Person")
        let error = try refused(#"memo "Ann" is: "Person""#, on: editor)
        expectEqual(error["reason"], "invalid_value")
        let on = try typeNamesEditor()
        let kinds = try run(["kinds"], on: on).get()
        let memo = try require(kinds.arrayValue?.first { $0["kind"] == "memo" })
        expectEqual(memo["attributes"]?["is"], "JSON [text] (<Title> of a type or shape)")
        expectEqual(memo["attributes"]?["schema"]?.stringValue?.hasPrefix("text") ?? false, true)
    },
])
