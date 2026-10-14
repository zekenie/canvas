@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit
import Titles
import Types

// What the index tells in `TypeChange` and the graph it keeps: every shape that holds a schema, those that
// hold the mark too, and the five ways a commit moved them, each told apart.

/// What the index told, commit after commit.
@MainActor private final class Told {
    var all: [TypeChange] = []
    var last: TypeChange? { all.last }
}

@MainActor private func told(by editor: CanvasEditor) throws -> Told {
    let told = Told()
    try require(editor.types).onChange { told.all.append($0) }
    return told
}

@MainActor let typeChangeTests = Suite("What a commit changed in the types", [
    test("the graph holds every shape that holds a schema, titled or not, and those of them that hold the mark") {
        let editor = try typeEditor()
        let plain = editor.addType(TypeSchemaProperty.starter, title: "Plain"), untitled = editor.addType(TypeSchemaProperty.starter)
        let employment = editor.addType(TypeSchemaProperty.starter, title: "Employment")
        let note = editor.addInstance("a note", of: [])
        editor.transact { $0.update(employment) { $0[RelationshipProperty.self] = true } }
        editor.transact { $0.update(note) { $0[RelationshipProperty.self] = true } }
        let graph = try require(editor.types).graph
        expectEqual(graph.types, [plain, untitled, employment], "an untitled type is a type")
        expectEqual(graph.relationshipTypes, [employment], "a mark with no schema is none")
        expectEqual(graph.names[untitled], nil)
        editor.undo()
        editor.undo()
        expectEqual(try require(editor.types).graph.relationshipTypes, [], "undone")
    },
    test("a flip of the mark alone is told in `marks` and nowhere else; the type's revision moves") {
        let editor = try typeEditor()
        let id = editor.addType(TypeSchemaProperty.starter, title: "Employment")
        let types = try require(editor.types)
        let heard = try told(by: editor)
        let before = try require(types.revision(of: id))
        editor.transact { $0.update(id) { $0[RelationshipProperty.self] = true } }
        let change = try require(heard.last)
        expectEqual(change.marks, [id])
        expect(change.types.isEmpty && change.membership.isEmpty && change.lineage.isEmpty && change.lists.isEmpty && !change.everything, "\(change)")
        expect(try require(types.revision(of: id)) > before)
        expectEqual(types.graph.relationshipTypes, [id])
        editor.undo()
        expectEqual(heard.last?.marks, [id], "and told again as it goes")
        expectEqual(types.graph.relationshipTypes, [])
        // A flip to false is the mark off.
        editor.transact { $0.update(id) { $0[RelationshipProperty.self] = true } }
        editor.transact { $0.update(id) { $0[RelationshipProperty.self] = false } }
        expectEqual(heard.last?.marks, [id])
        expectEqual(types.graph.relationshipTypes, [])
    },
    test("a note that becomes a type is told in `membership`, a schema keystroke in `types` alone, and a type marked as it is made in all three") {
        let editor = try typeEditor()
        let note = editor.add(memo("a pet"))
        let heard = try told(by: editor)
        editor.makeType(note)
        expectEqual(heard.last?.membership, [note])
        expectEqual(heard.last?.types, [note])
        expectEqual(heard.last?.marks, [])
        editor.transact { $0.update(note) { $0[TypeSchemaProperty.self] = SchemaText(#"{"type": "object", "properties": {"a": {}}}"#) } }
        expectEqual(heard.last?.types, [note], "a keystroke in its schema")
        expectEqual(heard.last?.membership, [], "is no one's coming or going")
        // Made and marked in one update.
        let other = editor.add(memo("an employment", at: CGPoint(x: 400, y: 40)))
        editor.transact { $0.update(other) {
            $0[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
            $0[RelationshipProperty.self] = true
        } }
        expectEqual(heard.last?.types, [other])
        expectEqual(heard.last?.membership, [other])
        expectEqual(heard.last?.marks, [other])
        // And taken together, by Remove Type.
        editor.removeType(other)
        expectEqual(heard.last?.marks, [other])
        expectEqual(heard.last?.membership, [other])
        expectEqual(heard.last?.types, [other])
        expect(try require(editor.types).graph.relationshipTypes.isEmpty)
        editor.undo()
        expectEqual(try require(editor.types).graph.relationshipTypes, [other], "undone: a type again, and marked")
        // Deleted: it goes as a relationship type.
        editor.transact { $0.delete([other]) }
        expectEqual(heard.last?.marks, [other])
        expect(try require(editor.types).graph.types.contains(other) == false)
    },
    test("a type's own list is told in `lineage` and `lists`, an instance's in `lists` alone, a removed shape that held one in `lists`") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person"), employee = editor.addType(TypeSchemaProperty.starter, title: "Employee")
        let ann = editor.addInstance("Ann", of: [employee])
        let heard = try told(by: editor)
        editor.addTypeLink(person, to: employee)
        expectEqual(heard.last?.lineage, [employee])
        expectEqual(heard.last?.lists, [employee])
        expectEqual(heard.last?.types, [employee], "as it always was")
        editor.addTypeLink(person, to: ann)
        expectEqual(heard.last?.lineage, [])
        expectEqual(heard.last?.lists, [ann])
        expectEqual(heard.last?.types, [])
        editor.transact { $0.delete([ann]) }
        expectEqual(heard.last?.lists, [ann], "a shape gone with its list")
        expectEqual(heard.last?.membership, [], "it was no type")
        let count = heard.all.count
        editor.transact { $0.update(employee, as: Memo.self) { $0.props.frame.origin.x += 10 } }
        expectEqual(heard.all.count, count, "a move tells nothing")
    },
    test("a file put in place is told as everything, with every type, mark and list there was and is") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let employment = editor.addType(TypeSchemaProperty.starter, title: "Employment")
        editor.transact { $0.update(employment) { $0[RelationshipProperty.self] = true } }
        let ann = editor.addInstance("Ann", of: [person])
        let heard = try told(by: editor)
        let other = typeRecord(TypeSchemaProperty.starter, title: "Other")
        editor.replaceFile(with: CanvasFile(root: CanvasDocument(shapes: [other])), showing: .root)
        let change = try require(heard.last)
        expect(change.everything)
        expectEqual(change.types, [person, employment, other.id])
        expectEqual(change.membership, [person, employment, other.id])
        expectEqual(change.marks, [employment])
        expectEqual(change.lists, [ann])
        expectEqual(try require(editor.types).graph.relationshipTypes, [])
    },
    test("only a type that is no relationship type can be embedded") {
        let editor = try typeEditor()
        let plain = editor.addType(TypeSchemaProperty.starter, title: "Address"), employment = editor.addType(TypeSchemaProperty.starter, title: "Employment")
        let note = editor.addInstance("a note", of: [])
        editor.transact { $0.update(employment) { $0[RelationshipProperty.self] = true } }
        let types = try require(editor.types)
        expect(types.canBeEmbedded(plain))
        expect(!types.canBeEmbedded(employment), "a relationship type's fields belong to its arrows")
        expect(!types.canBeEmbedded(note) && !types.canBeEmbedded(ShapeID()), "no type, no embedding")
        editor.transact { $0.update(employment) { $0[RelationshipProperty.self] = nil } }
        expect(types.canBeEmbedded(employment), "unmarked")
    },
])
