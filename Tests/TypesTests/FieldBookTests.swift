@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit
import Mentions
import Titles
import Types

// The field book (`editor.fieldBook`): one resolution for each list of types, kept until a type changes,
// over the file's own index.

private func schema(_ properties: String, required: [String] = [], extra: String = "") -> String {
    let required = required.isEmpty ? "" : ", \"required\": [" + required.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    return "{\"type\": \"object\", \"properties\": {\(properties)}\(required)\(extra)}"
}

/// A person, an employee that is one, and a note that is an employee.
@MainActor private struct Staff {
    let editor: CanvasEditor
    let person: ShapeID, employee: ShapeID, ann: ShapeID
    var book: FieldBook { editor.fieldBook! }

    init() throws {
        editor = try typeEditor()
        person = editor.addType(Schemas.person, title: "Person")
        employee = editor.addType(Schemas.employee, title: "Employee")
        editor.addTypeLink(person, to: employee)
        ann = editor.addInstance("Ann", of: [employee])
    }

    func resolutions(_ body: () -> Void) -> Int {
        let before = book.resolutionsMade
        body()
        return book.resolutionsMade - before
    }
}

private enum Schemas {
    static let person = schema(#""name": {"type": "string"}, "email": {"type": "string"}"#, required: ["name"])
    static let employee = schema(#""role": {"type": "string"}, "email": {"type": "string", "format": "email"}"#)
}

@MainActor let fieldBookTests = Suite("The field book", [
    test("a list is resolved as the chain does: the rows of a note that is an Employee, Person's first") {
        let staff = try Staff()
        let resolved = staff.book.fields(of: try require(staff.editor.document[staff.ann]))
        expectEqual(resolved.order, [staff.employee, staff.person])
        expectEqual(resolved.fields.map(\.field.name), ["name", "email", "role"])
        expectEqual(resolved.fields.map(\.introducedBy), [staff.person, staff.person, staff.employee])
        expectEqual(resolved.field(named: "email")?.source, staff.employee)
        expectEqual(resolved.field(named: "email")?.field.schema["format"]?.string, "email", "Employee's, whole")
        expectEqual(resolved.field(named: "name")?.field.isRequired, true)
        expectEqual(staff.book.fields(types: [staff.employee]), resolved, "a type's own note asks for its own list: the same answer")
        expectEqual(staff.book.fields(types: []), Resolved())
        expectEqual(staff.book.fields(of: try require(staff.editor.document[staff.person])).order, [], "a type that is no instance is none")
    },
    test("one resolution for each distinct list, however many shapes hold it; the same types in another order are another list") {
        let staff = try Staff()
        let editor = staff.editor
        let many = (0..<1_000).map { instanceRecord("Note \($0)", of: [staff.employee], at: CGPoint(x: Double($0 % 40) * 300, y: 400 + Double($0 / 40) * 100)) }
        editor.transact("Add") { transaction in many.forEach { transaction.insert($0) } }
        expectEqual(staff.resolutions { for record in many { _ = staff.book.fields(of: record) } }, 1)
        let both = instanceRecord("Both", of: [staff.person, staff.employee]), reversed = instanceRecord("Both", of: [staff.employee, staff.person])
        expectEqual(staff.resolutions { _ = staff.book.fields(of: both); _ = staff.book.fields(of: both) }, 1)
        expectEqual(staff.resolutions { _ = staff.book.fields(of: reversed) }, 1, "another list")
        expectEqual(staff.book.fields(of: both).order, [staff.employee, staff.person], "Employee builds on Person: first either way")
        expectEqual(staff.book.fields(of: both).field(named: "email")?.source, staff.employee)
    },
    test("it is kept until a type comes, goes, changes its schema or changes its own types, and each moves the revision and is resolved once") {
        let staff = try Staff()
        let editor = staff.editor, list = [staff.employee]
        _ = staff.book.fields(types: list)
        @MainActor func moves(_ change: () -> Void, _ message: String) {
            let revision = staff.book.revision
            change()
            expect(staff.book.revision != revision, "\(message) moves the revision")
            expectEqual(staff.resolutions { _ = staff.book.fields(types: list); _ = staff.book.fields(types: list) }, 1, "\(message): resolved once after")
        }
        var other = ShapeID()
        moves({ other = editor.addType(schema(#""x": {"type": "string"}"#), title: "Other") }, "a type coming")
        moves({ editor.transact("Write") { $0.update(staff.person) { $0[TypeSchemaProperty.self] = SchemaText(schema(#""name": {"type": "string"}, "nick": {"type": "string"}"#)) } } }, "a schema written")
        expectEqual(staff.book.fields(types: list).fields.map(\.field.name), ["name", "nick", "role", "email"], "Person's two, then Employee's")
        moves({ editor.addTypeLink(other, to: staff.employee) }, "a type's own types")
        expectEqual(staff.book.fields(types: list).order, [staff.employee, other, staff.person], "Other was given last, so it is read first")
        moves({ editor.transact("Delete") { $0.delete([other]) } }, "a type going")
        moves({ editor.undo() }, "its coming back")
        expect(staff.book.fields(types: list).order.contains(other))
        moves({ editor.removeType(other) }, "a type no longer one")
    },
    test("it is not redone for a rename, an instance's own types, a move, or another shape's words") {
        let staff = try Staff()
        let editor = staff.editor, list = [staff.employee]
        let note = editor.add(memo("a plain note"))
        let resolved = staff.book.fields(types: list)
        let revision = staff.book.revision
        editor.transact("Rename") { $0.update(staff.employee) { $0[TitleProperty.self] = "Staff" } }
        editor.addTypeLink(staff.person, to: staff.ann)
        let beforeMove = try require(editor.types).recordsRead
        editor.transact("Move") { $0.translate([staff.ann, staff.employee], by: CGPoint(x: 5, y: 5)) }
        expectEqual(try require(editor.types).recordsRead, beforeMove, "a move reads no record")
        editor.transact("Words") { $0.update(note, as: Memo.self) { $0.props.text = "a longer plain note" } }
        expectEqual(staff.book.revision, revision)
        expectEqual(staff.resolutions { expectEqual(staff.book.fields(types: list), resolved) }, 0)
    },
    test("JSON broken mid-edit keeps the last good fields; text that was never JSON has none; undo of the edit is the earlier fields") {
        let staff = try Staff()
        let editor = staff.editor
        let list = [staff.person]
        expectEqual(staff.book.fields(types: list).fields.map(\.field.name), ["name", "email"])
        editor.transact("Type") { $0.update(staff.person) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"name": {"type": "string"}, "ag"#) } }
        expectEqual(staff.book.fields(types: list).fields.map(\.field.name), ["name", "email"], "the last good JSON's")
        editor.transact("Mend") { $0.update(staff.person) { $0[TypeSchemaProperty.self] = SchemaText(schema(#""name": {"type": "string"}, "age": {"type": "integer"}"#)) } }
        expectEqual(staff.book.fields(types: list).fields.map(\.field.name), ["name", "age"])
        editor.undo()
        editor.undo()
        expectEqual(staff.book.fields(types: list).fields.map(\.field.name), ["name", "email"], "undone: the earlier fields")
        let never = editor.addType("not json at all", title: "Never")
        let resolved = staff.book.fields(types: [never])
        expect(resolved.fields.isEmpty)
        expectEqual(resolved.order, [never], "a type with no fields is still in the chain")
        let array = editor.addType("[1, 2]", title: "Array")
        expect(staff.book.fields(types: [array]).fields.isEmpty)
    },
    test("members of a group are in the order written with its own `required`, through `#/$defs`, and a type's fields for a `$ref` to it") {
        let staff = try Staff()
        let editor = staff.editor
        let card = editor.addType(schema("""
        "address": {"type": "object", "required": ["city"], "properties": {"street": {"type": "string"}, "city": {"type": "string"}}},
        "home": {"$ref": "#/$defs/place"},
        "boss": {"$ref": "\(SchemaReferences.uri(of: staff.employee))"},
        "part": {"$ref": "\(SchemaReferences.uri(of: staff.employee))#/properties/role"},
        "gone": {"$ref": "\(SchemaReferences.uri(of: ShapeID()))"},
        "pointer": {"type": "string", "contentMediaType": "text/x-canvas-link", "contentSchema": {"$ref": "\(SchemaReferences.uri(of: staff.person))"}},
        "tags": {"type": "string"}
        """, extra: #", "$defs": {"place": {"type": "object", "properties": {"zip": {"type": "string"}, "country": {"type": "string"}}}}"#), title: "Card")
        let book = staff.book
        let resolved = book.fields(types: [card])
        @MainActor func field(_ name: String) throws -> Resolved.Field { try require(resolved.field(named: name)) }
        let address = book.members(of: try field("address"))
        expectEqual(address.map(\.field.name), ["street", "city"])
        expectEqual(address.map(\.field.isRequired), [false, true])
        expectEqual(address.map(\.source), [card, card])
        expectEqual(book.members(of: try field("home")).map(\.field.name), ["zip", "country"])
        expectEqual(book.members(of: try field("boss")).map(\.field.name), ["name", "email", "role"], "Employee's fields, Person's first")
        expectEqual(book.members(of: try field("boss")).map(\.source), [staff.person, staff.employee, staff.employee], "their own sources")
        expectEqual(book.members(of: try field("part")), [], "a part of another type gives no rows")
        expectEqual(book.members(of: try field("gone")), [], "a type that is gone gives none")
        expectEqual(book.members(of: try field("pointer")), [], "a pointer is no group")
        expectEqual(book.members(of: try field("tags")), [])
    },
    test("the item of a list is its `items` named \"\": a group's members for a list of groups, a kind for a list of text, none for none") {
        let staff = try Staff()
        let editor = staff.editor
        let order = editor.addType(schema("""
        "lines": {"type": "array", "items": {"type": "object", "properties": {"product": {"type": "string"}, "quantity": {"type": "integer"}}}},
        "tags": {"type": "array", "items": {"type": "string"}},
        "any": {"type": "array"}, "tuple": {"type": "array", "items": [{"type": "string"}]}, "pair": {"type": "array", "prefixItems": [{"type": "string"}]},
        "plain": {"type": "string"}
        """), title: "Order")
        let book = staff.book
        let resolved = book.fields(types: [order])
        let lines = try require(book.item(of: try require(resolved.field(named: "lines"))))
        expectEqual(lines.field.name, "")
        expectEqual(lines.source, order)
        expectEqual(book.members(of: lines).map(\.field.name), ["product", "quantity"])
        let tags = try require(book.item(of: try require(resolved.field(named: "tags"))))
        expectEqual(tags.field.schema["type"]?.string, "string")
        expectEqual(book.members(of: tags), [])
        for name in ["any", "tuple", "pair", "plain"] { expectEqual(book.item(of: try require(resolved.field(named: name))), nil, name) }
    },
    test("a file put in place is resolved again, and the service is the editor's one; without Types there is none") {
        let staff = try Staff()
        let editor = staff.editor
        let before = staff.book.fields(types: [staff.employee])
        expect(editor.fieldBook === staff.book)
        let revision = staff.book.revision
        let replaced = typeRecord(schema(#""only": {"type": "string"}"#), title: "Only")
        editor.replaceFile(with: CanvasFile(root: CanvasDocument(shapes: [replaced])), showing: .root)
        expect(staff.book.revision != revision)
        expectEqual(staff.book.fields(types: [staff.employee]).fields.count, 0, "the old types are not in this file")
        expectEqual(staff.book.fields(types: [replaced.id]).fields.map(\.field.name), ["only"])
        expect(!before.fields.isEmpty)
        let bare = CanvasEditor(registry: try Registry(plugins: []), file: CanvasFile(root: CanvasDocument()), scheduler: ManualScheduler())
        expect(bare.fieldBook == nil)
    },
    test("over the file's index: the lineage is the order the book reads in, longer by a type that is gone") {
        let staff = try Staff()
        let editor = staff.editor, types = try require(editor.types)
        let thing = editor.addType(schema(#""id": {"type": "string"}"#), title: "Thing")
        editor.addTypeLink(thing, to: staff.person)
        let other = editor.addType(schema(#""x": {"type": "string"}"#), title: "Other")
        let sue = editor.addInstance("Sue", of: [staff.employee, other])
        for shape in [staff.ann, sue, staff.employee] {
            expectEqual(types.lineage(of: shape), staff.book.fields(of: try require(editor.document[shape])).order.filter { $0 != shape }, "the one function")
        }
        editor.transact("Delete") { $0.delete([staff.person]) }
        let chain = staff.book.fields(of: try require(editor.document[sue]))
        expectEqual(types.lineage(of: sue), [other, staff.employee, staff.person])
        expect(types.lineage(of: sue).contains(staff.person), "the gone type is in the lineage")
        expect(!chain.order.contains(staff.person), "and not in what the book reads")
        expectEqual(types.lineage(of: sue).count, chain.order.count + 1)
    },
])
