@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import LanguageModels
import TestKit
import Titles
import Types
import Validation

// The title from a field, as pure rules: which field titles a note (`TitleSource`, over the chain), and
// what a title does when a value changes (`FieldTitling`).

private struct Shelf: ChainCatalog {
    var nodes: [ShapeID: ChainNode] = [:]
    func node(_ id: ShapeID) -> ChainNode? { nodes[id] }
}

private typealias Catalog = [(ShapeID, String, [ShapeID])]

private let person = ShapeID(), employee = ShapeID(), manager = ShapeID()

private func schema(_ properties: String) -> String { #"{"type": "object", "properties": {\#(properties)}}"# }

/// The types as a shelf: each a schema text and the types it builds on.
@MainActor private func shelf(_ types: Catalog) throws -> Shelf {
    var shelf = Shelf()
    for (id, text, parents) in types { shelf.nodes[id] = ChainNode(level: try require(ChainLevel(schema: text)), parents: parents) }
    return shelf
}

private let namePerson = schema(#""name": {"type": "string"}, "email": {"type": "string"}, "$title": {"x-canvas-from": "name"}"#)
private let plainEmployee = schema(#""role": {"type": "string"}"#)

/// What a type whose only field is `field` and whose `$title` is `directive` gives.
@MainActor private func source(of field: String, directive: String = #"{"x-canvas-from": "f"}"#) throws -> TitleSource? {
    let text = schema(#""f": \#(field), "$title": \#(directive)"#)
    return TitleSource.of(Chain.resolve(types: [person], in: try shelf([(person, text, [])])))
}

@MainActor private func resolved(_ types: [ShapeID], _ catalog: Catalog) throws -> Resolved {
    Chain.resolve(types: types, in: try shelf(catalog))
}

@MainActor let titleSourceTests = Suite("The field that titles", [
    test("a type's `$title` names the field, and it reaches a type built on it; the more specific type's wins whole") {
        let types: Catalog = [(person, namePerson, []), (employee, plainEmployee, [person])]
        expectEqual(TitleSource.of(try resolved([person], types)), TitleSource(key: "name", kind: .text, type: person))
        expectEqual(TitleSource.of(try resolved([employee], types)), TitleSource(key: "name", kind: .text, type: person), "Person's reaches Employee")
        let own: Catalog = [(person, namePerson, []), (employee, schema(#""role": {"type": "string"}, "$title": {"x-canvas-from": "role"}"#), [person])]
        expectEqual(TitleSource.of(try resolved([employee], own))?.key, "role", "its own wins")
        expectEqual(TitleSource.of(try resolved([person], own))?.key, "name")
        let restated: Catalog = [(person, namePerson, []), (employee, schema(#""$title": {"x-canvas-from": "email"}"#), [person])]
        expectEqual(TitleSource.of(try resolved([employee], restated)), TitleSource(key: "email", kind: .text, type: employee), "a field only Person defines, through the chain")
        let deeper: Catalog = [(person, namePerson, []), (employee, plainEmployee, [person]), (manager, schema(#""reports": {"type": "integer"}"#), [employee])]
        expectEqual(TitleSource.of(try resolved([manager], deeper))?.type, person)
        expectEqual(TitleSource.of(try resolved([], types)), nil)
        expectEqual(TitleSource.of(Resolved()), nil)
    },
    test("text, a number, a date, a date-time and a choice title; a yes or no, a list, a group, pairs and an either do not") {
        expectEqual(try source(of: #"{"type": "string"}"#)?.kind, .text)
        expectEqual(try source(of: #"{"type": "integer"}"#)?.kind, .number(integer: true))
        expectEqual(try source(of: #"{"type": "number"}"#)?.kind, .number(integer: false))
        expectEqual(try source(of: #"{"type": "string", "format": "date"}"#)?.kind, .date)
        expectEqual(try source(of: #"{"type": "string", "format": "date-time"}"#)?.kind, .dateTime)
        let choice = try source(of: #"{"enum": ["a", "b"]}"#)
        expectEqual(choice?.kind, .choice([FieldOption(value: .string("a"), label: "a"), FieldOption(value: .string("b"), label: "b")]))
        expectEqual(try source(of: #"{"type": "boolean"}"#), nil)
        let link = "{\"type\": \"string\", \"contentMediaType\": \"text/x-canvas-link\", \"contentSchema\": {\"$ref\": \"\(FieldFixtures.uri(of: FieldFixtures.personID))\"}}"
        expectEqual(try source(of: link)?.kind, .text, "a schema that was a pointer is text")
        expectEqual(try source(of: #"{"type": "array", "items": {"type": "string"}}"#), nil, "a list")
        expectEqual(try source(of: #"{"type": "object", "properties": {"x": {"type": "string"}}}"#), nil, "a group")
        expectEqual(try source(of: #"{"$ref": "\#(FieldFixtures.uri(of: FieldFixtures.addressID))"}"#), nil, "another type's fields")
        expectEqual(try source(of: #"{"type": "object", "additionalProperties": {"type": "string"}}"#), nil, "pairs")
        expectEqual(try source(of: #"{"anyOf": [{"type": "string"}, {"type": "number"}]}"#), nil, "an either, even of two plain kinds")
        expectEqual(try source(of: "{}"), nil, "what no control suits")
        expect(TitleSource.titles(.plain(.yesNo)) == nil && TitleSource.titles(.group) == nil && TitleSource.titles(.plain(.text)) == .text)
    },
    test("a `$title` that is no object, names nothing or no field, or a field that can't title, titles nothing and says why for the type that wrote it") {
        let cases: [(String, TitleSourceProblem)] = [
            (#"{"x-canvas-from": "nme"}"#, .noField("nme")),
            ("{}", .namesNothing),
            (#"{"x-canvas-from": 5}"#, .namesNothing),
            (#"{"x-canvas-from": ["f"]}"#, .namesNothing),
            ("5", .namesNothing),
            (#""f""#, .namesNothing),
            ("[]", .namesNothing),
        ]
        for (directive, problem) in cases {
            let text = schema(#""f": {"type": "string"}, "$title": \#(directive)"#)
            let types: Catalog = [(person, text, []), (employee, plainEmployee, [person])]
            expectEqual(TitleSource.of(try resolved([person], types)), nil, directive)
            expectEqual(TitleSource.problem(try resolved([person], types), writtenBy: person), problem, directive)
            expectEqual(TitleSource.problem(try resolved([employee], types), writtenBy: employee), nil, "a child that inherits it says nothing: \(directive)")
            expectEqual(TitleSource.problem(try resolved([employee], types), writtenBy: person), problem, "it is the type that wrote it's: \(directive)")
        }
        let list = schema(#""tags": {"type": "array", "items": {"type": "string"}}, "$title": {"x-canvas-from": "tags"}"#)
        expectEqual(TitleSource.problem(try resolved([person], [(person, list, [])]), writtenBy: person), .cannotTitle("tags"))
        expectEqual(TitleSource.problem(try resolved([person], [(person, namePerson, [])]), writtenBy: person), nil, "one that works has none")
        expectEqual(TitleSource.problem(try resolved([employee], [(person, namePerson, []), (employee, plainEmployee, [person])]), writtenBy: employee), nil, "one that wrote none")
        expectEqual(TitleSource.problem(Resolved(), writtenBy: person), nil)
    },
    test("a name only a rule or `patternProperties` gives is no field; a `$title` in a group is that group's member, never a directive") {
        let rule = #"{"type": "object", "properties": {"$title": {"x-canvas-from": "name"}}, "allOf": [{"properties": {"name": {"type": "string"}}}], "patternProperties": {"^n": {"type": "string"}}}"#
        expectEqual(TitleSource.of(try resolved([person], [(person, rule, [])])), nil)
        expectEqual(TitleSource.problem(try resolved([person], [(person, rule, [])]), writtenBy: person), .noField("name"))
        let group = schema(#""name": {"type": "string"}, "address": {"type": "object", "properties": {"$title": {"x-canvas-from": "name"}, "city": {"type": "string"}}}"#)
        expectEqual(TitleSource.of(try resolved([person], [(person, group, [])])), nil)
        expectEqual(try resolved([person], [(person, group, [])]).directives, [], "a group's is a member of the group")
    },
    test("a more specific type that restates the field as something that can't title leaves its notes untitled, and warns nobody") {
        let types: Catalog = [(person, namePerson, []), (employee, schema(#""name": {"type": "boolean"}"#), [person])]
        expectEqual(TitleSource.of(try resolved([employee], types)), nil)
        expectEqual(TitleSource.problem(try resolved([employee], types), writtenBy: employee), nil)
        expectEqual(TitleSource.problem(try resolved([person], types), writtenBy: person), nil)
    },
    test("a directive is a root `properties` key that starts `$` with more after it; a field's key never does") {
        expectEqual(SchemaDirectives.name("$title"), "title")
        expectEqual(SchemaDirectives.name("$"), nil)
        expectEqual(SchemaDirectives.name("title"), nil)
        expectEqual(SchemaDirectives.name("a$b"), nil)
        expect(SchemaDirectives.isField("title") && SchemaDirectives.isField("a$b") && SchemaDirectives.isField(""))
        expect(!SchemaDirectives.isField("$title") && !SchemaDirectives.isField("$"))
    },
    test("the book answers by the list, once for each, and not for a type's own note, whose `is` is what it builds on") {
        let editor = try typeEditor()
        let person = editor.addType(FieldFixtures.namedPerson.schema, title: "Person")
        let employee = editor.addType(FieldFixtures.namedEmployee.schema, title: "Employee")
        editor.addTypeLink(person, to: employee)
        let ann = editor.addInstance("Ann", of: [person]), bo = editor.addInstance("Bo", of: [employee])
        let book = try require(editor.fieldBook)
        let wanted = TitleSource(key: "name", kind: .text, type: person)
        expectEqual(book.titleSource(of: try require(editor.document[ann])), wanted)
        expectEqual(book.titleSource(of: try require(editor.document[bo])), wanted, "Person's, through Employee")
        expectEqual(book.titleSource(types: [employee]), wanted)
        expectEqual(book.titleSource(of: try require(editor.document[employee])), nil, "Employee's type note holds Person in its `is`")
        expectEqual(book.titleSource(of: try require(editor.document[person])), nil)
        expectEqual(book.titleSource(of: instanceRecord("Plain", of: [])), nil, "no types")
        let before = book.resolutionsMade
        for _ in 0..<5 { _ = book.titleSource(types: [employee]); _ = book.titleSource(of: try require(editor.document[bo])) }
        expectEqual(book.resolutionsMade, before, "kept")
        let plain = editor.addType(FieldFixtures.person.schema, title: "Plain")
        expectEqual(book.titleSource(types: [plain]), nil)
        editor.transact("Write") { $0.update(person) { $0[TypeSchemaProperty.self] = SchemaText(FieldFixtures.person.schema) } }
        expectEqual(book.titleSource(types: [employee]), nil, "answered again when the type changes")
        editor.undo()
        expectEqual(book.titleSource(types: [employee]), wanted)
    },
])

private let en = Locale(identifier: "en_US_POSIX")
private let name = TitleSource(key: "name", kind: .text, type: person)

private func values(_ members: JSONObject) -> FieldValues { FieldValues(members) }
private func said(_ text: String) -> FieldValues { values(["name": .string(text)]) }

@MainActor let fieldTitlingTests = Suite("A title from a field", [
    test("a value shows as its row shows it, on one line; a list or an object under the key is none") {
        expectEqual(FieldTitling.shown(said("Ann Lee"), name, locale: en), "Ann Lee")
        expectEqual(FieldTitling.shown(said("Ann\nLee  Jr"), name, locale: en), "Ann Lee Jr", "a line break folds to a space")
        expectEqual(FieldTitling.shown(said("   "), name, locale: en), nil, "blank is none")
        expectEqual(FieldTitling.shown(FieldValues(), name, locale: en), nil)
        expectEqual(FieldTitling.shown(values(["name": .array([.string("a")])]), name, locale: en), nil)
        expectEqual(FieldTitling.shown(values(["name": .object(["a": .string("b")])]), name, locale: en), nil)
        expectEqual(FieldTitling.shown(values(["other": .string("a")]), name, locale: en), nil)
        let date = TitleSource(key: "due", kind: .date, type: person)
        expectEqual(FieldTitling.shown(values(["due": .string("2026-03-03")]), date, locale: en), "Mar 3, 2026")
        let number = TitleSource(key: "n", kind: .number(integer: false), type: person)
        expectEqual(FieldTitling.shown(values(["n": .number(9.5)]), number, locale: en), "9.5")
        expectEqual(FieldTitling.shown(values(["n": .number(12)]), number, locale: en), "12")
        let choice = TitleSource(key: "status", kind: .choice([FieldOption(value: .string("paid"), label: "Paid")]), type: person)
        expectEqual(FieldTitling.shown(values(["status": .string("paid")]), choice, locale: en), "Paid")
    },
    test("a title fits at 80 code points and not at 81, counted as the schema counts them") {
        expect(FieldTitling.fits(String(repeating: "a", count: 80)))
        expect(!FieldTitling.fits(String(repeating: "a", count: 81)))
        expect(FieldTitling.fits(String(repeating: "e\u{301}", count: 40)), "40 letters with an accent are 40 characters and 80 code points")
        expect(!FieldTitling.fits(String(repeating: "e\u{301}", count: 41)), "41 are 82 code points")
        expect(FieldTitling.fits(""))
    },
    test("with no title, the new value is written") {
        expectEqual(FieldTitling.retitle(held: nil, old: FieldValues(), new: said("Ann"), name, locale: en), .some("Ann"))
        expectEqual(FieldTitling.retitle(held: nil, old: said("A"), new: said("An"), name, locale: en), .some("An"), "an untitled note with an old value is titled at the next change")
        expectEqual(FieldTitling.retitle(held: nil, old: said("Ann"), new: FieldValues(), name, locale: en), nil, "nothing to write")
        expectEqual(FieldTitling.retitle(held: nil, old: FieldValues(), new: said(String(repeating: "a", count: 81)), name, locale: en), nil, "too long to be a title")
    },
    test("a title that still matched the old value follows it, and is taken off when the value clears or passes 80") {
        expectEqual(FieldTitling.retitle(held: "A", old: said("A"), new: said("An"), name, locale: en), .some("An"))
        expectEqual(FieldTitling.retitle(held: "Ann", old: said("Ann"), new: FieldValues(), name, locale: en), .some(nil), "a cleared value takes it off")
        expectEqual(FieldTitling.retitle(held: "Ann", old: said("Ann"), new: said("  "), name, locale: en), .some(nil), "a blank one too")
        let long = String(repeating: "a", count: 81)
        expectEqual(FieldTitling.retitle(held: "Ann", old: said("Ann"), new: said(long), name, locale: en), .some(nil), "past 80")
        expectEqual(FieldTitling.retitle(held: nil, old: said(long), new: said(String(repeating: "a", count: 80)), name, locale: en), .some(String(repeating: "a", count: 80)), "back to 80: written again")
        let ann = said("Ann\nLee")
        expectEqual(FieldTitling.retitle(held: "Ann Lee", old: ann, new: said("Ann Lee Jr"), name, locale: en), .some("Ann Lee Jr"), "matches as shown, folded")
    },
    test("a title set by hand is left alone, and so is one when the field's own value did not change") {
        expectEqual(FieldTitling.retitle(held: "Annie", old: said("Ann"), new: said("Anna"), name, locale: en), nil)
        expectEqual(FieldTitling.retitle(held: "Annie", old: said("Ann"), new: FieldValues(), name, locale: en), nil)
        expectEqual(FieldTitling.retitle(held: "Annie", old: FieldValues(), new: said("Ann"), name, locale: en), nil, "held with no value before: by hand")
        expectEqual(FieldTitling.retitle(held: nil, old: said("Ann"), new: said("Ann"), name, locale: en), nil, "the field did not change")
        let email: (FieldValues) -> FieldValues = { values(["name": $0.values["name"] ?? .null, "email": .string("a@b.c")]) }
        expectEqual(FieldTitling.retitle(held: nil, old: said("Ann"), new: email(said("Ann")), name, locale: en), nil, "a write to email never titles")
        expectEqual(FieldTitling.retitle(held: "Ann", old: said("Ann"), new: email(said("Ann")), name, locale: en), nil)
        expectEqual(FieldTitling.retitle(held: nil, old: FieldValues(), new: values(["email": .string("a@b.c")]), name, locale: en), nil)
    },
    test("the first title of a note is the value it holds, if that fits") {
        expectEqual(FieldTitling.firstTitle(values: said("Ann"), name, locale: en), "Ann")
        expectEqual(FieldTitling.firstTitle(values: FieldValues(), name, locale: en), nil)
        expectEqual(FieldTitling.firstTitle(values: said(String(repeating: "a", count: 81)), name, locale: en), nil)
        expectEqual(FieldTitling.firstTitle(values: said(" Ann\nLee "), name, locale: en), "Ann Lee")
    },
])

private let titleOnly = #"{"type": "object", "properties": {"$title": {"x-canvas-from": "name"}}}"#

@MainActor let schemaDirectiveTests = Suite("A `$title` is no field", [
    test("the document's fields skip a `$` key of properties, so \"N fields\" and an empty type don't count it; a pattern is still one") {
        let document = SchemaDocument(FieldFixtures.namedPerson.schema)
        expectEqual(document.fields.map(\.name), ["name", "email"])
        expectEqual(SchemaDocument(titleOnly).fields.count, 0)
        expectEqual(SchemaDocument(#"{"properties": {"a": {}, "$title": {}, "$": {}}, "patternProperties": {"^$x": {}}}"#).fields.map(\.name), ["a", "^$x"])
        expectEqual(SchemaDocument(#"{"properties": {"g": {"properties": {"$title": {}, "x": {}}}}}"#).fields.first?.fields.map(\.name), ["$title", "x"], "inside a group it is a member of the group")
    },
    test("a type holding only `$title` and words was never answered: nothing syncs by itself, and a commit asks for the schema") {
        let loaded = typeRecord(titleOnly, words: "a person, titled by its name", at: .zero)
        let b = try SyncBench(document: CanvasDocument(shapes: [loaded]))
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 0)
        b.sync(loaded.id, answer: petSchema)
        expectEqual(b.model.lastRequest?.system, SchemaPrompts.system(.toSchema), "its words are ahead, as a type with no fields' are")
    },
    test("`required` naming `$title` warns, as one naming no property does; a type with a working `$title` has no issue") {
        let editor = try typeEditor()
        let works = editor.addType(FieldFixtures.namedPerson.schema, title: "Person")
        expectEqual(editor.issues(works), [])
        let bad = editor.addType(#"{"type": "object", "properties": {"name": {"type": "string"}, "$title": {"x-canvas-from": "name"}}, "required": ["$title", "name"]}"#,
                                 at: CGPoint(x: 400, y: 40))
        expectEqual(editor.issues(bad).map(\.message), ["“$title” is required, but isn’t a property."])
        expectEqual(editor.issues(bad).map(\.severity), [.warning])
        let nested = editor.addType(#"{"properties": {"g": {"properties": {"$title": {}}, "required": ["$title"]}}}"#, at: CGPoint(x: 800, y: 40))
        expectEqual(editor.issues(nested), [], "in a group a `$` key is a property")
    },
    test("a link to `/properties/$title` is dropped and one to `/properties/name` is kept") {
        let text = FieldFixtures.namedPerson.schema
        let pointers = ["/properties/name", "/properties/$title", "/properties/$title/x-canvas-from", "/properties/email", "/required"].compactMap { JSONPointer($0) }
        let located = SchemaTarget.locate(pointers, in: text)
        expectEqual(located.map { $0 != nil }, [true, false, false, true, true])
        let nested = SchemaTarget.locate([JSONPointer(tokens: ["properties", "g", "properties", "$title"])].compactMap { $0 }, in: #"{"properties": {"g": {"properties": {"$title": {}}}}}"#)
        expectEqual(nested.map { $0 != nil }, [true], "only the root's `properties` is the type's")
    },
    test("an instance of a type with `$title` is clean; a `$title` member of its values is no field's, so never wrong; no row") {
        let editor = try fieldEditor()
        editor.addFieldTypes([FieldFixtures.namedPerson])
        let id = FieldFixtures.namedPersonID
        let ann = editor.addNote(of: [id], ["name": "Ann"])
        expectEqual(editor.fullCheck(of: ann), .clean)
        let stray = editor.addNote(of: [id], ["name": "Ann", "$title": "x"])
        expectEqual(editor.fullCheck(of: stray), .clean)
        let book = try require(editor.fieldBook)
        expectEqual(book.field(at: FieldPath(field: "$title"), types: [id]) == nil, true)
        let resolved = book.fields(types: [id])
        expectEqual(resolved.fields.map(\.field.name), ["name", "email"])
        expectEqual(RowList(resolved, own: [id]).all.map(\.field.name), ["name", "email"])
        expectEqual(resolved.schema["properties"]?.objectValue?.keys.sorted(), ["email", "name"], "the schema the check validates has no directive")
    },
])
