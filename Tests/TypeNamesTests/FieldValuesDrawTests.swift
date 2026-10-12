import CanvasRPC
@_spi(Host) import Canvas
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Titles
import Types

// A note's values in `canvas draw` (`FieldValuesPlugin`, Types): `fieldValues: {…}` joins what the
// note holds, member by member at every depth, so a statement names only what it changes. Over memos, which
// are types and instances as a note is.

@MainActor private func values(of title: String, in editor: CanvasEditor) -> JSONObject? {
    editor.shape(called: title)?[FieldValuesProperty.self]?.values
}

@MainActor private func dids(_ result: JSON) -> [String] {
    result["changes"]?.arrayValue?.compactMap { $0["did"]?.stringValue } ?? []
}

private let orderSchema = #"""
{"type": "object", "properties": {"status": {"type": "string"}, "tags": {"type": "array", "items": {"type": "string"}},
 "shipping": {"type": "object", "properties": {"street": {"type": "string"}, "city": {"type": "string"}}}}}
"""#

@MainActor let fieldValuesDrawTests = Suite("Values in canvas draw", [
    test("the merge alone: members set one by one at every depth, a list replaced whole, null clearing the member it is written at") {
        let held: JSONValue = ["a": ["b": ["c": 1, "d": 2], "e": 3], "list": [1, 2], "keep": "k"]
        func merged(_ written: JSONValue, _ over: JSONValue? = held) -> JSONValue { FieldValuesMerge.merged(written, into: over) }
        expectEqual(merged(["a": ["b": ["c": 9]]]), ["a": ["b": ["c": 9, "d": 2], "e": 3], "list": [1, 2], "keep": "k"], "three deep, the rest kept")
        expectEqual(merged(["list": [3]]), ["a": ["b": ["c": 1, "d": 2], "e": 3], "list": [3], "keep": "k"], "a list is replaced whole")
        expectEqual(merged(["a": ["b": ["c": .null]]]), ["a": ["b": ["d": 2], "e": 3], "list": [1, 2], "keep": "k"], "null clears the member")
        expectEqual(merged(["keep": .null, "list": .null]).objectValue?.keys.sorted(), ["a"])
        expectEqual(merged(.null), .null, "null alone is the whole property off")
        expectEqual(merged(["a": 1]), ["a": 1, "list": [1, 2], "keep": "k"], "a scalar over an object replaces it")
        expectEqual(merged(["list": ["x": 1]]).objectValue?["list"], ["x": 1], "an object over a list replaces it")
        expectEqual(merged(["a": ["new": 1]], ["a": 5]), ["a": ["new": 1]], "an object over a scalar held is joined with nothing")
        expectEqual(merged(["a": ["x": .null, "y": 1]], nil), ["a": ["y": 1]], "a null where nothing is held clears nothing and is never stored")
        expectEqual(merged(["a": ["x": .null]], nil), ["a": [:]], "an object left empty is the prune's to take")
        expectEqual(merged(["a": 1], nil), ["a": 1], "a new shape's is joined with nothing")
        expectEqual(FieldValues.pruned(merged(["a": ["x": .null]], nil)), nil)
        expectEqual(merged([:]), held, "an empty object changes nothing")
        expectEqual(merged(["a": ["unit": .null]], ["a": "12 Main St"]), ["a": "12 Main St"], "clearing a member under a scalar clears nothing")
        expectEqual(merged(["a": ["b": ["c": .null]]], ["a": ["b": [1]]]), ["a": ["b": [1]]], "nor under a list, at any depth")
        expectEqual(merged(["a": [:]], ["a": 5]), ["a": 5], "an empty object over a scalar sets nothing")
        expectEqual(merged(["a": ["unit": .null, "y": 1]], ["a": "12 Main St"]), ["a": ["y": 1]], "one with a member to set still replaces it")
    },

    test("a statement names only what it changes: the rest stays, at any depth; null clears; a script run again is unchanged") {
        let editor = try typeNamesEditor()
        editor.addType("Order", schema: orderSchema)
        _ = try drawn(#"memo "O1" is: "Order" fieldValues: {"status": "paid", "tags": ["a", "b"], "shipping": {"street": "High St", "city": "Leeds"}}"#, on: editor)
        let result = try drawn(#"memo "O1" fieldValues: {"shipping": {"city": "York"}, "tags": ["c"]}"#, on: editor)
        expectEqual(dids(result), ["updated"])
        expectEqual(values(of: "O1", in: editor), ["status": "paid", "tags": ["c"], "shipping": ["street": "High St", "city": "York"]],
                    "the street is kept, the list replaced whole")
        expectEqual(dids(try drawn(#"memo "O1" fieldValues: {"shipping": {"city": "York"}, "tags": ["c"]}"#, on: editor)), ["unchanged"])
        _ = try drawn(#"memo "O1" fieldValues: {"status": null}"#, on: editor)
        expectEqual(values(of: "O1", in: editor)?["status"], nil, "null clears the member")
        _ = try drawn(#"memo "O1" fieldValues: {"shipping": {"street": null, "city": null}}"#, on: editor)
        expectEqual(values(of: "O1", in: editor), ["tags": ["c"]], "an object left empty is pruned")
        _ = try drawn(#"memo "O1" fieldValues: null"#, on: editor)
        expectEqual(editor.shape(called: "O1")?[FieldValuesProperty.self], nil, "null takes every value off")
    },

    test("a join that comes to nothing is one update, then unchanged; over nothing it is no change at all") {
        let editor = try typeNamesEditor()
        editor.addType("Order", schema: orderSchema)
        _ = try drawn(#"memo "O1" is: "Order" fieldValues: {"shipping": {"city": "Leeds"}}"#, on: editor)
        let first = try drawn(#"memo "O1" fieldValues: {"shipping": {"city": null}}"#, on: editor)
        expectEqual(dids(first), ["updated"])
        expectEqual(editor.shape(called: "O1")?[FieldValuesProperty.self], nil, "no fieldValues are left")
        expectEqual(dids(try drawn(#"memo "O1" fieldValues: {"shipping": {"city": null}}"#, on: editor)), ["unchanged"])
        // A new note, an object with a null inside: nothing is stored.
        _ = try drawn(#"memo "O2" is: "Order" fieldValues: {"status": "paid", "shipping": {"city": null}}"#, on: editor)
        expectEqual(values(of: "O2", in: editor), ["status": "paid"])
    },

    test("clearing a member under a value held as text keeps the value, as the one writer does: unchanged") {
        let editor = try typeNamesEditor()
        editor.addType("Order", schema: orderSchema)
        _ = try drawn(#"memo "O1" is: "Order" fieldValues: {"status": "paid", "shipping": "12 Main St"}"#, on: editor)
        let result = try drawn(#"memo "O1" fieldValues: {"shipping": {"unit": null}}"#, on: editor)
        expectEqual(dids(result), ["unchanged"])
        expectEqual(values(of: "O1", in: editor), ["status": "paid", "shipping": "12 Main St"], "the street is kept")
        let shape = try require(editor.shape(called: "O1"))
        let written = shape[FieldValuesProperty.self]?.setting(nil, at: FieldPath(field: "shipping").key("unit"))
        expectEqual(written?.values, values(of: "O1", in: editor), "the writer's rule says the same")
    },

    test("a dry run reports what a run does, writes nothing, and a type and its notes drawn in one script are placed and checked the same in both") {
        let editor = try typeNamesEditor()
        let script = """
        memo "Thing" schema: "{\\"type\\": \\"object\\", \\"properties\\": {\\"count\\": {\\"type\\": \\"integer\\", \\"minimum\\": 1}, \\"label\\": {\\"type\\": \\"string\\"}}}"
        memo "T1" below "Thing" is: "Thing" fieldValues: {"count": 0}
        """
        let dry = try drawn(script, on: editor, dryRun: true)
        expect(editor.shape(called: "Thing") == nil, "a dry run drew nothing")
        let real = try drawn(script, on: editor)
        func rowOf(_ result: JSON, _ title: String) -> JSON? { result["changes"]?.arrayValue?.first { $0["title"]?.stringValue == title } }
        expectEqual(rowOf(dry, "T1")?["at"], rowOf(real, "T1")?["at"], "the note's size is the same in a dry run")
        func messages(_ result: JSON) -> [String] { result["warnings"]?.arrayValue?.compactMap { $0["message"]?.stringValue } ?? [] }
        expect(messages(dry).contains { $0.contains("at least 1") }, "\(messages(dry))")
        expectEqual(messages(dry), messages(real), "the same warnings in both")
        expectEqual(values(of: "T1", in: editor), ["count": 0])
    },

    test("a note with no type keeps its values and joins them too") {
        let editor = try typeNamesEditor()
        _ = try drawn(#"memo "A" fieldValues: {"x": 1}"#, on: editor)
        expectEqual(values(of: "A", in: editor), ["x": 1], "no types, no check: the values are kept")
        _ = try drawn(#"memo "A" fieldValues: {"y": 2}"#, on: editor)
        expectEqual(values(of: "A", in: editor), ["x": 1, "y": 2])
    },

    test("a row carries what its note still needs and what is wrong, by field and path; a wrong value is also an error warning, a needed one no warning") {
        let editor = try typeNamesEditor()
        editor.addType("Order", schema: #"""
        {"type": "object", "properties": {"customer": {"type": "string"}, "status": {"enum": ["draft", "paid"]},
         "lineItems": {"type": "array", "items": {"type": "object", "properties": {"product": {"type": "string"}, "quantity": {"type": "integer", "minimum": 1}}, "required": ["product"]}}},
         "required": ["customer"]}
        """#)
        let result = try drawn(#"memo "O1" is: "Order" fieldValues: {"status": "gone", "lineItems": [{"product": "Mug", "quantity": 0}, {"quantity": 2}]}"#, on: editor)
        let problems = try require(result["changes"]?.arrayValue?.first?["problems"]?.arrayValue)
        let said = problems.map { "\($0["class"]?.stringValue ?? "") \($0["field"]?.stringValue ?? "-") \($0["path"]?.stringValue ?? "-")" }
        expect(said.contains("needed customer /customer") && said.contains("wrong status /status") && said.contains("wrong lineItems /lineItems/0/quantity"), "\(said)")
        expectEqual(problems.first { $0["field"] == "customer" }?["message"], "customer is needed")
        let messages = (result["warnings"]?.arrayValue ?? []).compactMap { $0["message"]?.stringValue }
        expect(messages.contains { $0.hasPrefix(#""O1": status"#) }, "the wrong value is a warning: \(messages)")
        expect(!messages.contains { $0.contains("customer") }, "a needed field is no warning: \(messages)")
        let errors = (result["warnings"]?.arrayValue ?? []).filter { $0["severity"] == "error" }
        expectEqual(errors.compactMap { $0["attribute"]?.stringValue }.sorted(), ["lineItems", "status"], "an error, on the field's key")
        // Restated whole: nothing written, the problems still listed.
        let again = try drawn(#"memo "O1""#, on: editor)
        expectEqual(dids(again), ["unchanged"])
        expectEqual(again["changes"]?.arrayValue?.first?["problems"]?.arrayValue?.count, problems.count, "an unchanged row says what is left")
        // Nothing left: no member at all, and no types: none either.
        _ = try drawn(#"memo "O2" is: "Order" fieldValues: {"customer": "c"}"#, on: editor)
        let clean = try drawn(#"memo "O2""#, on: editor)
        expectEqual(clean["changes"]?.arrayValue?.first?["problems"], nil)
        let plain = try drawn(#"memo "Plain""#, on: editor)
        expectEqual(plain["changes"]?.arrayValue?.first?["problems"], nil)
    },

    test("a member no field of the note's types names is kept and warned about: at the top, in a group, in a list's item, by the types' titles; once, for a shape the run changed") {
        let editor = try typeNamesEditor()
        editor.addType("Order", schema: #"""
        {"type": "object", "properties": {"status": {"type": "string"}, "shipping": {"type": "object", "properties": {"city": {"type": "string"}}},
         "lineItems": {"type": "array", "items": {"type": "object", "properties": {"product": {"type": "string"}}}}}}
        """#)
        editor.addType("Gift", schema: #"{"type": "object", "properties": {"wrap": {"type": "string"}}}"#)
        func unnamed(_ result: JSON) -> [String] {
            (result["warnings"]?.arrayValue ?? []).filter { $0["attribute"] == "fieldValues" }.compactMap { $0["message"]?.stringValue }
        }
        let top = try drawn(#"memo "O1" is: "Order" fieldValues: {"emial": "x", "status": "paid"}"#, on: editor)
        expectEqual(unnamed(top), [#""O1": "emial" isn't a field of Order"#])
        expectEqual(values(of: "O1", in: editor), ["emial": "x", "status": "paid"], "kept")
        let nested = try drawn(#"memo "O1" fieldValues: {"shipping": {"zip": "LS1", "city": "Leeds"}, "lineItems": [{"product": "Mug", "sku": "m"}]}"#, on: editor)
        expectEqual(unnamed(nested), [#""O1": "sku" isn't a field of line items"#, #""O1": "zip" isn't a field of shipping"#])
        let several = try drawn(#"memo "O3" is: ["Order", "Gift"] fieldValues: {"emial": "x"}"#, on: editor)
        expectEqual(unnamed(several), [#""O3": "emial" isn't a field of Order or Gift"#])
        expectEqual(unnamed(try drawn(#"memo "O3" fieldValues: {"emial": "x"}"#, on: editor)), [], "restated, unchanged: nothing written, nothing said again")
        let cleared = try drawn(#"memo "O3" fieldValues: {"emial": null}"#, on: editor)
        expectEqual(unnamed(cleared), [], "a member written null clears: never warned about")
        expectEqual(values(of: "O3", in: editor), nil)
        let none = try drawn(#"memo "Free" fieldValues: {"x": 1}"#, on: editor)
        expectEqual(unnamed(none), [#""Free": fieldValues: it has no type, so no member is a field"#])
        // A shape of a type that is gone: kept and not checked.
        let ghost = ShapeID()
        editor.transact { transaction in
            var record = AnyShapeRecord(ShapeRecord(Memo(frame: CGRect(x: 600, y: 600, width: 240, height: 52))))
            record[TitleProperty.self] = "Haunted"
            record[IsAProperty.self] = [TypeLink(ghost)]
            transaction.insert(record)
        }
        expectEqual(unnamed(try drawn(#"memo "Haunted" fieldValues: {"anything": 1}"#, on: editor)), [], "while a type is gone no key is called unnamed")
    },

    // MARK: @[Title] is a pointer

    test("a string that is exactly @[Title], at the top, in a group and in a list, becomes the token of the shape called so; one drawn in the same script is no problem and no warning, in a run and a dry run") {
        let editor = try typeNamesEditor()
        let person = editor.addType("Person", schema: #"{"type": "object", "properties": {"name": {"type": "string"}}}"#)
        editor.addType("Order", schema: pointerOrderSchema(person))
        let script = """
        memo "Ann Lee" is: "Person" fieldValues: {"name": "Ann"}
        memo "Bo" below "Ann Lee" is: "Person"
        memo "O1" below "Bo" is: "Order" fieldValues: {"customer": "@[Ann Lee]", "contact": {"owner": "@[Bo]"}, "cc": ["@[Bo]", "@[Ann Lee]"]}
        """
        let dry = try drawn(script, on: editor, dryRun: true)
        expect(editor.shape(called: "O1") == nil, "a dry run drew nothing")
        let real = try drawn(script, on: editor)
        let ann = try require(editor.shape(called: "Ann Lee")), bo = try require(editor.shape(called: "Bo"))
        @MainActor func token(_ shape: AnyShapeRecord) -> JSONValue { .string(MentionToken.write(shape.id, label: editor.registry.title(of: shape) ?? "")) }
        expectEqual(values(of: "O1", in: editor), ["customer": token(ann), "contact": ["owner": token(bo)], "cc": .array([token(bo), token(ann)])])
        for (name, result) in [("run", real), ("dry run", dry)] {
            let row = result["changes"]?.arrayValue?.first { $0["title"] == "O1" }
            expectEqual(row?["problems"], nil, "no problem in a \(name)")
            let said = (result["warnings"]?.arrayValue ?? []).compactMap { $0["message"]?.stringValue }
            expect(said.isEmpty, "no warning in a \(name): \(said)")
        }
    },

    test("a whole token is kept as written, a backslash before @[Title] writes it as text, @[ among other text is text") {
        let editor = try typeNamesEditor()
        let person = editor.addType("Person", schema: #"{"type": "object", "properties": {"name": {"type": "string"}}}"#)
        editor.addType("Order", schema: pointerOrderSchema(person))
        _ = try drawn(#"memo "Ann Lee" is: "Person""#, on: editor)
        let ann = try require(editor.shape(called: "Ann Lee"))
        let whole = MentionToken.write(ann.id, label: "Ann Lee")
        let script = "memo \"O1\" is: \"Order\" fieldValues: {\"customer\": \"\(whole)\", \"note\": \"\\\\@[Ann Lee]\", \"memo\": \"see @[Nobody] soon\", \"also\": \"@[Ann Lee] and @[Bo]\"}"
        _ = try drawn(script, on: editor)
        let held = try require(values(of: "O1", in: editor))
        expectEqual(held["customer"], .string(whole), "a whole token, as written")
        expectEqual(held["note"], "@[Ann Lee]", "the backslash is dropped, the text kept")
        expectEqual(held["memo"], "see @[Nobody] soon", "text around is text, and no title is looked up")
        expectEqual(held["also"], "@[Ann Lee] and @[Bo]")
        expectEqual(dids(try drawn(script, on: editor)), ["unchanged"], "run again, nothing changes")
    },

    test("a blank @[], a title nobody has and a title two shapes share are refused as a mention in a text is, and nothing is committed") {
        let editor = try typeNamesEditor()
        let person = editor.addType("Person", schema: #"{"type": "object", "properties": {"name": {"type": "string"}}}"#)
        editor.addType("Order", schema: pointerOrderSchema(person))
        _ = try drawn(#"memo "Ann Lee" is: "Person""#, on: editor)
        for y in [300, 400] as [CGFloat] {
            var twin = AnyShapeRecord(ShapeRecord(Memo(frame: CGRect(x: 600, y: y, width: 240, height: 52))))
            twin[TitleProperty.self] = "Twin"
            editor.transact { $0.insert(twin) }
        }
        let before = editor.document.shapes.count
        @MainActor func refusal(_ value: String) throws -> JSON {
            try refused(#"memo "New" below "Ann Lee" is: "Order" fieldValues: {"customer": "\#(value)"}"#, on: editor)
        }
        let blank = try refusal("@[]")
        expectEqual(blank["reason"], "invalid_value")
        expectEqual(blank["message"]?.stringValue?.contains("\"New\": fieldValues: @[] is a mention with no title in it"), true, "\(blank)")
        let unknown = try refusal("@[Ann Lea]")
        expectEqual(unknown["reason"], "unknown_title")
        expect(unknown["hint"]?.stringValue?.contains("Ann Lee") == true, "did you mean: \(unknown)")
        expect(unknown["hint"]?.stringValue?.contains(#"to write @[ as text, write \\@["#) == true, "\(unknown)")
        let twin = try refusal("@[Twin]")
        expectEqual(twin["reason"], "ambiguous_title")
        expectEqual(editor.document.shapes.count, before, "nothing committed")
        expect(editor.shape(called: "New") == nil)
    },

    test("a pointer to a note that isn't of the field's type is wrong, in problems and as an error, and one to a note not in the file is warned about as a mention is") {
        let editor = try typeNamesEditor()
        let person = editor.addType("Person", schema: #"{"type": "object", "properties": {"name": {"type": "string"}}}"#)
        editor.addType("Order", schema: pointerOrderSchema(person))
        _ = try drawn("memo \"Ann Lee\" is: \"Person\"\nmemo \"Plain\" below \"Ann Lee\"", on: editor)
        let result = try drawn(#"memo "O1" below "Plain" is: "Order" fieldValues: {"customer": "@[Plain]"}"#, on: editor)
        let problems = try require(result["changes"]?.arrayValue?.first?["problems"]?.arrayValue)
        expectEqual(problems.map { $0["class"]?.stringValue }, ["wrong"])
        expectEqual(problems.first?["field"], "customer")
        expectEqual(problems.first?["path"], "/customer")
        let errors = (result["warnings"]?.arrayValue ?? []).filter { $0["severity"] == "error" }
        expectEqual(errors.compactMap { $0["attribute"]?.stringValue }, ["customer"], "an error, on the field's key")
        // The same field pointing at a note of the type is clean.
        let fine = try drawn(#"memo "O1" fieldValues: {"customer": "@[Ann Lee]"}"#, on: editor)
        expectEqual(fine["changes"]?.arrayValue?.first?["problems"], nil)
        // A token of a shape that is not in the file: said, as a mention's is.
        let gone = MentionToken.write(ShapeID(), label: "Ghost")
        let missing = try drawn("memo \"O2\" below \"O1\" is: \"Order\" fieldValues: {\"customer\": \"\(gone)\"}", on: editor)
        let said = (missing["warnings"]?.arrayValue ?? []).compactMap { $0["message"]?.stringValue }
        expect(said.contains { $0.contains("fieldValues names shapes that aren't in the file") }, "\(said)")
    },

    test("a type restated in the script with a field made required gives a restated note the new problem in the same run, and a note the script doesn't name is left as it was") {
        let editor = try typeNamesEditor()
        let order = editor.addType("Order", schema: #"{"type": "object", "properties": {"status": {"type": "string"}}}"#)
        _ = try drawn(#"memo "O1" is: "Order" fieldValues: {"status": "paid"}"#, on: editor)
        _ = try drawn(#"memo "O2" is: "Order" fieldValues: {"status": "paid"}"#, on: editor)
        let schema = scripted(#"{"type": "object", "properties": {"status": {"type": "string"}, "due": {"type": "string"}}, "required": ["due"]}"#)
        let result = try drawn("memo \"Order\" schema: \"\(schema)\"\nmemo \"O1\" fieldValues: {\"status\": \"paid\"}", on: editor)
        let rows = result["changes"]?.arrayValue ?? []
        expectEqual(rows.first { $0["title"] == "O1" }?["problems"]?.arrayValue?.compactMap { $0["message"]?.stringValue }, ["due is needed"], "the new rule, in this run")
        expectEqual(rows.count, 2, "O2 is not named: no row")
        _ = order
    },
])

private func scripted(_ text: String) -> String { text.replacingOccurrences(of: "\"", with: "\\\"") }

/// An Order of pointers at `person`: one, one inside a group, and a list of them.
private func pointerOrderSchema(_ person: ShapeID) -> String {
    let link = String(decoding: (try? JSONEncoder().encode(JSONValue.object(FieldKind.pointerSchema(to: person)))) ?? Data(), as: UTF8.self)
    return #"{"type": "object", "properties": {"customer": \#(link), "contact": {"type": "object", "properties": {"owner": \#(link)}}, "cc": {"type": "array", "items": \#(link)}}}"#
}
