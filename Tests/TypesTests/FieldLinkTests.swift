import Canvas
import CanvasTesting
import Foundation
import Mentions
import TestKit
import Titles
import Types

// A pointer's value, one mention token in a string of `fieldValues`: read as a value, named to the core
// (so a copy, a cut, a paste and a delete treat it as they do a mention) and held to the type it points at.

private let ann = FieldFixtures.annLeeID, bo = FieldFixtures.boParkID
private let customer = FieldPath(field: "customer")

@MainActor private func setValues(_ editor: CanvasEditor, _ id: ShapeID, _ values: FieldValues) {
    editor.transact("Set Values") { $0.update(id) { $0[FieldValuesProperty.self] = values } }
}

@MainActor let fieldLinkTests = Suite("Field links", [
    test("a link is read from a string that is exactly one token, and written back as the canonical one") {
        let token = link(to: ann, "Ann Lee")
        let read = try require(FieldLink(token))
        expectEqual(read.target, ann)
        expectEqual(read.stored, "Ann Lee")
        expectEqual(read.value, token)
        expectEqual(FieldLink(.string("Ann Lee")), nil, "plain text")
        expectEqual(FieldLink(.string("see " + (token.stringValue ?? ""))), nil, "words around it")
        expectEqual(FieldLink(.number(1)), nil)
        expectEqual(FieldLink(.array([token])), nil, "a list is not a link")
        let lower = JSONValue.string("@[Ann](shape:\(ann.rawValue.uuidString.lowercased()))")
        expectEqual(FieldLink(lower)?.target, ann, "an agent's lowercase id")
    },

    test("fieldValues names the shapes of its tokens at any depth, in key order, and passes over what is not exactly a token") {
        let values = FieldValues(["customer": link(to: ann, "Ann Lee"),
                                  "guests": .array([link(to: bo, "Bo Park"), link(to: ann, "Ann Lee")]),
                                  "host": ["name": link(to: bo, "Bo Park")],
                                  "lines": .array([["who": link(to: ann, "Ann Lee"), "qty": 2]]),
                                  "note": .string("Ask " + (link(to: ann, "Ann Lee").stringValue ?? "") + " first"),
                                  "plain": "Ann Lee", "count": 3, "yes": true])
        var named: [ShapeID] = []
        values.forEachNamedShape { named.append($0) }
        expectEqual(named, [ann, bo, ann, bo, ann], "customer, guests (two), host, lines: the note with words and the plain values name nothing")
        var leaves = 0
        values.forEachNamingLeaf { _ in leaves += 1 }
        expectEqual(leaves, 1, "the value is its own leaf, not mention text: Mentions' edges and warnings leave it out")
    },

    test("renaming rewrites only the tokens whose id changes, keeps the label and every other byte, and is itself when nothing changed") {
        let other = ShapeID()
        let lowercase = JSONValue.string("@[Bo](shape:\(bo.rawValue.uuidString.lowercased()))")
        let values = FieldValues(["customer": link(to: ann, "Ann Lee"), "guests": .array([lowercase, link(to: ann, "A\\nn")]), "note": "Ann"])
        let renamed = values.renamingShapes { $0 == ann ? other : nil }
        expectEqual(renamed["customer"], link(to: other, "Ann Lee"))
        expectEqual(renamed["guests"], .array([lowercase, link(to: other, "A\\nn")]), "a lowercase id of another shape stays as written")
        expectEqual(renamed["note"], "Ann")
        expectEqual(values.renamingShapes { _ in nil }, values)
        expectEqual(values.renamingShapes { $0 }, values, "an id kept is no change")
        expectEqual(values.renamingShapes { $0 == bo ? other : nil }["guests"]?.arrayValue?.first, link(to: other, "Bo"), "a lowercase id that is renamed is written canonical")
    },

    test("the registry's codec for fieldValues names shapes, and the kinds that name shapes are as they were") {
        let registry = try Registry(plugins: typePlugins())
        expect(registry.namingKinds.contains(Memo.kind))
        let editor = try fieldEditor()
        let order = editor.addInstance("", of: [FieldFixtures.orderID])
        setValues(editor, order, FieldValues(["customer": link(to: ann, "Ann Lee")]))
        let record = try require(editor.document[order])
        var named: [ShapeID] = []
        record.forEachNamingValue(in: editor.registry) { _, value in value.forEachNamedShape { named.append($0) } }
        expect(named.contains(ann), "the core finds the name through the property's codec: \(named)")
    },

    test("a copy with the target points at the target's copy, a copy without it at the original; a delete writes nothing and undo is exact") {
        let editor = try fieldEditor()
        let order = editor.addInstance("", of: [FieldFixtures.orderID])
        setValues(editor, order, FieldValues(["customer": link(to: ann, "Ann Lee"), "guests": .array([link(to: bo, "Bo Park")])]))
        let record = try require(editor.document[order])
        let annCopy = ShapeID()
        let withTarget = try require(record.remappingReferences({ $0 == ann ? annCopy : nil }, in: editor.shapeContext))
        expectEqual(withTarget[FieldValuesProperty.self]?["customer"], link(to: annCopy, "Ann Lee"), "the label kept")
        expectEqual(withTarget[FieldValuesProperty.self]?["guests"], .array([link(to: bo, "Bo Park")]), "what wasn't copied is kept")
        let without = try require(record.remappingReferences({ _ in nil }, in: editor.shapeContext))
        expectEqual(without[FieldValuesProperty.self], record[FieldValuesProperty.self])

        editor.transact("Delete") { $0.delete([ann]) }
        expectEqual(editor.document[order], record, "nothing written to the note that pointed at her")
        editor.undo()
        expectEqual(editor.document[order], record)
        expect(editor.document[ann] != nil)
    },

    test("a token in a text field names its shape too: no schema is read") {
        let editor = try fieldEditor()
        let order = editor.addInstance("", of: [FieldFixtures.orderID])
        setValues(editor, order, FieldValues(["giftNote": link(to: bo, "Bo Park")]))
        let record = try require(editor.document[order])
        let copy = try require(record.remappingReferences({ $0 == bo ? ann : nil }, in: editor.shapeContext))
        expectEqual(copy[FieldValuesProperty.self]?["giftNote"], link(to: ann, "Bo Park"))
        let kind = try require(editor.fieldBook?.fields(of: record).fields.first { $0.field.name == "giftNote" })
        expectEqual(editor.fieldBook?.kind(of: kind), .plain(.text), "its row is a text row, holding the token as stored")
    },

    test("FieldLinks admits a note whose chain reaches the type, an Employee's too, and never a type's own note or a gone type") {
        let editor = try fieldEditor()
        let index = try require(editor.types)
        let employee = editor.addInstance("", of: [FieldFixtures.employeeID], title: "Cy Doe")
        let order = editor.addInstance("", of: [FieldFixtures.orderID])
        let person = FieldFixtures.personID
        expect(FieldLinks.admits(ann, as: person, in: index))
        expect(FieldLinks.admits(employee, as: person, in: index), "an Employee is a Person")
        expect(!FieldLinks.admits(order, as: person, in: index))
        expect(!FieldLinks.admits(FieldFixtures.employeeID, as: person, in: index), "a type's own note")
        expect(!FieldLinks.admits(person, as: person, in: index))
        expect(!FieldLinks.admits(ann, as: ShapeID(), in: index), "a type that isn't one")
        expectEqual(Set(FieldLinks.targets(of: person, in: index)), [ann, bo, employee])
        expectEqual(FieldLinks.targets(of: ShapeID(), in: index), [])
        editor.transact("Delete") { $0.delete([person]) }
        expect(!FieldLinks.admits(ann, as: person, in: index), "the type is gone")
    },

    test("the pointer's schema is the three members, and reads back as a pointer to the type") {
        let schema = FieldKind.pointerSchema(to: FieldFixtures.personID)
        expectEqual(schema["type"], "string")
        expectEqual(schema["contentMediaType"], .string(FieldKind.pointerMediaType))
        expectEqual(schema["contentSchema"], ["$ref": .string(SchemaReferences.uri(of: FieldFixtures.personID))])
        expectEqual(schema.count, 3)
        expectEqual(FieldKind.pointerMediaType, "text/x-canvas-link")
        let editor = try fieldEditor()
        let json = String(decoding: try JSONEncoder().encode(JSONValue.object(schema)), as: UTF8.self)
        let type = editor.addType(#"{"type": "object", "properties": {"who": \#(json), "all": {"type": "array", "items": \#(json)}}}"#, title: "Team")
        let fields = try require(editor.fieldBook).fields(types: [type]).fields
        expectEqual(fields.map { editor.fieldBook?.kind(of: $0) }, [.pointer(FieldFixtures.personID), .pointers(FieldFixtures.personID)])
    },

    test("the book shows a pointer by the name a mention of its target shows now, the name it holds when the target is gone") {
        let editor = try fieldEditor()
        let book = try require(editor.fieldBook)
        let held = try require(FieldLink(link(to: ann, "Ann")))
        expectEqual(book.shown(held), "Ann Lee", "the live title, not the name it holds")
        expectEqual(book.resolution(of: held).isLive, true)
        editor.transact("Rename") { $0.update(ann) { $0[TitleProperty.self] = "Ann Smith" } }
        expectEqual(book.shown(held), "Ann Smith")
        editor.transact("Delete") { $0.delete([ann]) }
        expectEqual(book.shown(held), "Ann", "the stored name")
        expectEqual(book.resolution(of: held), .missing)
        expectEqual(book.shown(FieldLink(target: ann, stored: "")), "Deleted")
        let pointing = FieldLink.pointing(at: try require(editor.document[bo]), in: editor)
        expectEqual(pointing, FieldLink(target: bo, stored: "Bo Park"))
    },
])
