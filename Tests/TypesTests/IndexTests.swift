@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Titles
import Types
import Validation

// The file's types (`editor.types`): read when the file opens, then kept by each commit's changes,
// on the board shown and on every other.

/// A root holding pocket P, whose board holds a type, Address.
@MainActor
private struct TypeInPocket {
    let p = ShapeID(), address = ShapeID(), house = ShapeID()
    var file: CanvasFile {
        CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 0, y: 300, width: 100, height: 100)))),
                                                 typeRecord(TypeSchemaProperty.starter, title: "House", id: house)]),
                   children: [p: CanvasDocument(shapes: [typeRecord(addressSchema, title: "Address", id: address)])])
    }
}

/// What the index told, commit after commit: `changes` the types that came, went or changed (a commit that
/// changed none adds nothing), `all` everything it delivered.
@MainActor private final class Heard {
    var changes: [Set<ShapeID>] = []
    var all: [TypeChange] = []

    func hear(_ change: TypeChange) {
        all.append(change)
        if !change.types.isEmpty { changes.append(change.types) }
    }
}

@MainActor let indexTests = Suite("The file's types", [
    test("a file's types are read as it opens, on every board; a shape that isn't one, or is of a kind that can't be, isn't") {
        let tree = TypeInPocket()
        let editor = try typeEditor(file: tree.file, more: [PocketsPlugin()])
        let types = try require(editor.types)
        expectEqual(types.types, [tree.house, tree.address])
        expect(types.isType(tree.address) && !types.isType(tree.p))
        expectEqual(types.name(of: tree.address), "Address")
        expectEqual(types.name(of: tree.p), nil)
        expect(types.revision(of: tree.address) != nil && types.revision(of: tree.p) == nil)
    },
    test("each commit keeps it: a type made, renamed, its schema written, no longer one, deleted; another shape's change tells nothing") {
        let editor = try typeEditor()
        let types = try require(editor.types)
        let heard = Heard()
        types.onChange { heard.hear($0) }
        let id = editor.add(memo("a pet"))
        let other = editor.add(memo("a book", at: CGPoint(x: 400, y: 40)))
        expectEqual(heard.changes, [], "no types yet")
        editor.makeType(id)
        expectEqual(heard.changes, [[id]])
        let made = try require(types.revision(of: id))
        editor.transact { $0.update(id) { $0[TitleProperty.self] = "Pet" } }
        expectEqual(types.name(of: id), "Pet")
        let renamed = try require(types.revision(of: id))
        expect(renamed > made, "a rename moves its revision")
        editor.transact { $0.update(id) { $0[TypeSchemaProperty.self] = SchemaText(pet) } }
        expect(try require(types.revision(of: id)) > renamed, "so does its schema")
        let count = heard.changes.count
        editor.transact { $0.update(id, as: Memo.self) { $0.props.frame.origin.x += 10 } }
        editor.transact { $0.update(other, as: Memo.self) { $0.props.text = "a long book" } }
        expectEqual(heard.changes.count, count, "a move, and another shape's words, tell nothing")
        editor.removeType(id)
        expect(!types.isType(id))
        expectEqual(heard.changes.last, [id])
        editor.undo()
        expect(types.isType(id))
        editor.transact { $0.delete([id]) }
        expect(!types.isType(id))
        expectEqual(heard.changes.last, [id])
    },
    test("a board taken with its owner, and brought back, takes its types and brings them back; a type moved onto another board is the same type") {
        let tree = TypeInPocket()
        let editor = try typeEditor(file: tree.file, more: [PocketsPlugin()])
        let types = try require(editor.types)
        editor.transact("Delete") { $0.delete([tree.p]) }
        expectEqual(types.types, [tree.house], "Address went with its board")
        editor.undo()
        expectEqual(types.types, [tree.house, tree.address])
        expectEqual(types.name(of: tree.address), "Address")
        editor.transact("Move In") { $0.move([tree.house], toBoardOwnedBy: tree.p) }
        expect(types.isType(tree.house), "still in the file")
        editor.transact(on: BoardID(owner: tree.p), "Rename") { $0.update(tree.house) { $0[TitleProperty.self] = "Home" } }
        expectEqual(types.name(of: tree.house), "Home", "a change on a board not shown")
    },
    test("a type whose own types changed is told, an instance whose types changed is not: it is in no chain") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person"), employee = editor.addType(TypeSchemaProperty.starter, title: "Employee")
        let ann = editor.addInstance("Ann", of: [person])
        let types = try require(editor.types)
        let heard = Heard()
        types.onChange { heard.hear($0) }
        editor.addTypeLink(employee, to: ann)
        editor.removeTypeLink(person, from: ann)
        expectEqual(heard.changes, [], "an instance's list changing tells no type")
        expectEqual(heard.all.map(\.lists), [[ann], [ann]], "it is told in `lists` alone")
        expect(heard.all.allSatisfy { $0.types.isEmpty && $0.lineage.isEmpty && $0.marks.isEmpty && $0.membership.isEmpty && !$0.everything })
        editor.addTypeLink(person, to: employee)
        expectEqual(heard.changes, [[employee]], "Employee is a Person now")
        editor.undo()
        expectEqual(heard.changes.last, [employee], "and not, once undone")
        editor.removeTypeLink(person, from: employee)
        expectEqual(heard.changes.count, 2, "a list that was already empty changes nothing")
        editor.addTypeLink(person, to: employee)
        editor.transact { $0.update(employee) { $0[TitleProperty.self] = "Staff" } }
        expectEqual(heard.changes.last, [employee], "a rename is told, as it was")
        // A type that stops being one, with its list, is told once as it goes.
        editor.removeType(employee)
        expectEqual(heard.changes.last, [employee])
        expect(!types.isType(employee))
    },
    test("`/is-a` refuses a type that is the shape in turn, however far: A is a B, B is a C") {
        let editor = try typeEditor()
        let a = editor.addType(TypeSchemaProperty.starter, title: "A"), b = editor.addType(TypeSchemaProperty.starter, title: "B")
        let c = editor.addType(TypeSchemaProperty.starter, title: "C"), d = editor.addType(TypeSchemaProperty.starter, title: "D")
        editor.addTypeLink(b, to: a)
        editor.addTypeLink(c, to: b)
        let types = try require(editor.types)
        expect(!types.admits(a, for: a), "itself")
        expect(!types.admits(b, for: a), "one it is")
        expect(!types.admits(a, for: b), "one that is it")
        expect(!types.admits(a, for: c), "one that is it, however far: a cycle")
        expect(types.admits(c, for: a), "one it is through B is no cycle")
        expect(types.admits(d, for: a) && types.admits(a, for: d), "unrelated types may")
        expect(types.admits(c, for: d))
    },
    test("a file put in place is read afresh") {
        let tree = TypeInPocket()
        let editor = try typeEditor(file: tree.file, more: [PocketsPlugin()])
        let types = try require(editor.types)
        let heard = Heard()
        types.onChange { heard.hear($0) }
        let other = typeRecord(TypeSchemaProperty.starter, title: "Other")
        editor.replaceFile(with: CanvasFile(root: CanvasDocument(shapes: [other])), showing: .root)
        expectEqual(types.types, [other.id])
        expectEqual(heard.changes.last, [tree.house, tree.address, other.id], "every type there was and is")
        editor.replaceDocument(with: CanvasDocument())
        expectEqual(types.types, [])
    },
])
