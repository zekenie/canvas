@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import Observation
import TestKit
import Titles
import Topology
import Types

// What is what, in the file's index (`editor.types`): the types each shape is, the instances of each
// type, the chain a shape's types make, and what a type is called where it's listed; kept by each
// commit, on every board.

/// A root holding pocket P, whose board holds pocket Q, whose board holds an instance, with the
/// types spread over the three boards: Person at the root, Employee on P's board, Intern on Q's.
@MainActor
private struct ThreeBoards {
    let p = ShapeID(), q = ShapeID(), person = ShapeID(), employee = ShapeID(), intern = ShapeID()
    let ann = ShapeID(), bob = ShapeID(), cy = ShapeID()
    var file: CanvasFile {
        CanvasFile(
            root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 0, y: 600, width: 100, height: 100)))),
                                          typeRecord(TypeSchemaProperty.starter, title: "Person", id: person),
                                          instanceRecord("Ann", of: [person], title: "Ann", at: CGPoint(x: 400, y: 40), id: ann)]),
            children: [p: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: q, Pocket(CGRect(x: 0, y: 600, width: 100, height: 100)))),
                                                  typeRecord(TypeSchemaProperty.starter, title: "Employee", id: employee),
                                                  instanceRecord("Bob", of: [person, employee], at: CGPoint(x: 400, y: 40), id: bob)]),
                       q: CanvasDocument(shapes: [typeRecord(TypeSchemaProperty.starter, title: "Intern", id: intern),
                                                  instanceRecord("Cy", of: [employee, intern], at: CGPoint(x: 400, y: 40), id: cy)])])
    }
}

/// A service installed before Types': when a memo's words become "go", it makes another commit
/// while hearing that one, so Types hears the second before the first.
private struct ChaserPlugin: CanvasPlugin {
    let target: ShapeID, type: ShapeID
    var id: PluginID { "chaser" }
    func register(into registrar: inout PluginRegistrar) {
        let target = target, type = type
        registrar.service { _ in Chaser(target: target, type: type) }
    }
}

@MainActor private final class Chaser {
    let target: ShapeID, type: ShapeID
    var chased = false
    init(target: ShapeID, type: ShapeID) {
        self.target = target
        self.type = type
    }
}

extension Chaser: EditorService {
    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        guard !chased, editor.document.shapes.contains(where: { $0.typed(as: Memo.self)?.props.text.stored == "go" }) else { return }
        chased = true
        editor.transact("Chase") { $0.update(target) { $0[IsAProperty.self] = [TypeLink(type)] } }
    }
}

/// Every instance's list in the file, as its record says, against what the index holds.
@MainActor private func expectIndexMatchesFile(_ editor: CanvasEditor, _ message: String = "") throws {
    let index = try require(editor.types), file = editor.file
    var holders: [ShapeID: [ShapeID]] = [:]
    for board in [file.root] + Array(file.children.values) {
        for record in board.shapes where editor.registry.isTypeable(record.kind) {
            let listed = record[IsAProperty.self]?.map(\.shape) ?? []
            expectEqual(index.links(of: record.id).map(\.shape), listed, "links of \(record.id) \(message)")
            for type in listed { holders[type, default: []].append(record.id) }
        }
    }
    for (type, held) in holders { expectEqual(index.instances(of: type), Set(held), "instances of \(type) \(message)") }
}

@MainActor let typeLinkTests = Suite("What the file's shapes are", [
    test("every shape's types and every type's instances are read as the file opens, on every board") {
        let tree = ThreeBoards()
        let editor = try typeEditor(file: tree.file, more: [PocketsPlugin()])
        let types = try require(editor.types)
        expectEqual(types.links(of: tree.bob), [TypeLink(tree.person), TypeLink(tree.employee)], "in the order of its list")
        expectEqual(types.links(of: tree.person), [], "a type that is none")
        expectEqual(types.instances(of: tree.person), [tree.ann, tree.bob])
        expectEqual(types.instances(of: tree.employee), [tree.bob, tree.cy])
        expectEqual(types.instances(of: tree.intern), [tree.cy])
        expectEqual(types.instances(of: tree.p), [])
        try expectIndexMatchesFile(editor)
    },
    test("each commit keeps them: a list set, extended and emptied, a shape added, deleted and undone; a move reads nothing") {
        let tree = ThreeBoards()
        let editor = try typeEditor(file: tree.file, more: [PocketsPlugin()])
        let types = try require(editor.types)
        editor.transact("Add") { $0.update(tree.ann) { $0[IsAProperty.self] = [TypeLink(tree.person), TypeLink(tree.employee)] } }
        expectEqual(types.instances(of: tree.employee), [tree.ann, tree.bob, tree.cy])
        editor.transact("Remove") { $0.update(tree.ann) { $0[IsAProperty.self] = [TypeLink(tree.employee)] } }
        expectEqual(types.instances(of: tree.person), [tree.bob], "Ann is no longer a Person")
        editor.transact("Empty") { $0.update(tree.ann) { $0[IsAProperty.self] = [] } }
        expectEqual(types.links(of: tree.ann), [])
        expectEqual(types.instances(of: tree.employee), [tree.bob, tree.cy])
        let dan = editor.addInstance("Dan", of: [tree.person, tree.person])
        expectEqual(types.instances(of: tree.person), [tree.bob, dan])
        let before = types.recordsRead
        editor.transact("Move") { $0.translate([dan], by: CGPoint(x: 5, y: 5)) }
        expectEqual(types.recordsRead, before, "a move reads nothing")
        editor.transact("Delete") { $0.delete([dan]) }
        expectEqual(types.instances(of: tree.person), [tree.bob])
        expectEqual(types.links(of: dan), [])
        editor.undo()
        expectEqual(types.instances(of: tree.person), [tree.bob, dan])
        try expectIndexMatchesFile(editor)
    },
    test("an instance moved onto another board is the same instance; a board taken with its owner takes the instances on it, and undo brings them back") {
        let tree = ThreeBoards()
        let editor = try typeEditor(file: tree.file, more: [PocketsPlugin()])
        let types = try require(editor.types)
        editor.transact("Move In") { $0.move([tree.ann], toBoardOwnedBy: tree.p) }
        expectEqual(types.links(of: tree.ann), [TypeLink(tree.person)])
        expectEqual(types.instances(of: tree.person), [tree.ann, tree.bob])
        editor.transact(on: BoardID(owner: tree.q), "Change") { $0.update(tree.cy) { $0[IsAProperty.self] = [TypeLink(tree.person)] } }
        expectEqual(types.instances(of: tree.person), [tree.ann, tree.bob, tree.cy], "a change on a board not shown")
        editor.transact("Delete") { $0.delete([tree.p]) }
        expectEqual(types.instances(of: tree.person), [], "Ann, Bob and Cy went with the board")
        expectEqual(types.links(of: tree.bob), [])
        editor.undo()
        expectEqual(types.instances(of: tree.person), [tree.ann, tree.bob, tree.cy])
        try expectIndexMatchesFile(editor)
    },
    test("the lineage is what a shape's types lead to, level by level, later first, each once, never the shape itself") {
        let editor = try typeEditor()
        let thing = editor.addType(TypeSchemaProperty.starter, title: "Thing"), person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let employee = editor.addType(TypeSchemaProperty.starter, title: "Employee"), manager = editor.addType(TypeSchemaProperty.starter, title: "Manager")
        let types = try require(editor.types)
        editor.transact("Is") {
            $0.update(person) { $0[IsAProperty.self] = [TypeLink(thing)] }
            $0.update(employee) { $0[IsAProperty.self] = [TypeLink(person), TypeLink(thing)] }
            $0.update(manager) { $0[IsAProperty.self] = [TypeLink(employee), TypeLink(person)] }
        }
        expectEqual(types.lineage(of: manager), [person, employee, thing], "later first, then what those are; Thing once")
        expectEqual(types.lineage(of: employee), [thing, person])
        expectEqual(types.lineage(of: thing), [])
        let ann = editor.addInstance("Ann", of: [employee, manager])
        expectEqual(types.lineage(of: ann), [manager, employee, person, thing])
        // A cycle ends where it comes back, and never holds the shape itself.
        editor.transact("Cycle") { $0.update(thing) { $0[IsAProperty.self] = [TypeLink(manager)] } }
        expectEqual(types.lineage(of: manager), [person, employee, thing])
        expectEqual(types.lineage(of: thing), [manager, person, employee])
        editor.transact("Self") { $0.update(thing) { $0[IsAProperty.self] = [TypeLink(thing), TypeLink(person)] } }
        expectEqual(types.lineage(of: thing), [person])
    },
    test("a deleted type is in the lineage as a name that leads nowhere") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person"), employee = editor.addType(TypeSchemaProperty.starter, title: "Employee")
        editor.transact("Is") { $0.update(employee) { $0[IsAProperty.self] = [TypeLink(person)] } }
        let ann = editor.addInstance("Ann", of: [employee])
        editor.transact("Delete") { $0.delete([person]) }
        let types = try require(editor.types)
        expectEqual(types.lineage(of: ann), [employee, person])
        expect(!types.isType(person))
    },
    test("what a change to some shapes affects is their instances, near and far, each once") {
        let editor = try typeEditor()
        let thing = editor.addType(TypeSchemaProperty.starter, title: "Thing"), person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let employee = editor.addType(TypeSchemaProperty.starter, title: "Employee")
        editor.transact("Is") {
            $0.update(person) { $0[IsAProperty.self] = [TypeLink(thing)] }
            $0.update(employee) { $0[IsAProperty.self] = [TypeLink(person)] }
        }
        let ann = editor.addInstance("Ann", of: [employee]), bob = editor.addInstance("Bob", of: [person, employee])
        let types = try require(editor.types)
        expectEqual(types.affected(by: [person]), [employee, ann, bob])
        expectEqual(types.affected(by: [thing]), [person, employee, ann, bob])
        expectEqual(types.affected(by: [ann]), [])
        expectEqual(types.affected(by: []), [])
        editor.transact("Cycle") { $0.update(thing) { $0[IsAProperty.self] = [TypeLink(employee)] } }
        expectEqual(types.affected(by: [person]), [employee, ann, bob, thing, person], "a cycle comes back to where it began, once")
    },
    test("a type is called by its title while it is one; renamed, the readers of its name hear it; deleted or no longer one, it is missing, remembered by its last title; undone, whole") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person"), untitled = editor.addType(TypeSchemaProperty.starter)
        let types = try require(editor.types)
        expectEqual(types.name(of: TypeLink(person)), .live("Person"))
        expectEqual(types.name(of: TypeLink(untitled)), .live(nil))
        let heard = Flag()
        withObservationTracking { _ = types.name(of: TypeLink(person)) } onChange: { heard.set() }
        editor.transact("Rename") { $0.update(person) { $0[TitleProperty.self] = "Human" } }
        expect(heard.isSet, "a reader of its name hears a rename")
        expectEqual(types.name(of: TypeLink(person)), .live("Human"))
        editor.removeType(person)
        expectEqual(types.name(of: TypeLink(person)), .missing(lastKnown: "Human"), "no longer a type")
        editor.undo()
        expectEqual(types.name(of: TypeLink(person)), .live("Human"))
        editor.transact("Delete") { $0.delete([person]) }
        expectEqual(types.name(of: TypeLink(person)), .missing(lastKnown: "Human"))
        expectEqual(types.name(of: TypeLink(ShapeID())), .missing(lastKnown: nil), "a shape the index never knew")
        editor.undo()
        expectEqual(types.name(of: TypeLink(person)), .live("Human"))
        let again = Flag()
        withObservationTracking { _ = types.name(of: TypeLink(person)) } onChange: { again.set() }
        editor.transact("Delete") { $0.delete([person]) }
        expect(again.isSet, "and hears it deleted")
    },
    test("a file put in place is read afresh: the lists, the instances, and what a name was") {
        let tree = ThreeBoards()
        let editor = try typeEditor(file: tree.file, more: [PocketsPlugin()])
        let types = try require(editor.types)
        expectEqual(types.name(of: TypeLink(tree.person)), .live("Person"))
        let flat = instanceRecord("Zed", of: [tree.person, tree.intern], title: "Zed")
        editor.replaceFile(with: CanvasFile(root: CanvasDocument(shapes: [flat, typeRecord(TypeSchemaProperty.starter, title: "Intern", id: tree.intern)])), showing: .root)
        expectEqual(types.links(of: flat.id), [TypeLink(tree.person), TypeLink(tree.intern)])
        expectEqual(types.links(of: tree.ann), [])
        expectEqual(types.instances(of: tree.person), [flat.id])
        expectEqual(types.name(of: TypeLink(tree.person)), .missing(lastKnown: nil), "Person is not in this file")
        expectEqual(types.name(of: TypeLink(tree.intern)), .live("Intern"))
        editor.replaceDocument(with: CanvasDocument())
        expectEqual(types.instances(of: tree.intern), [])
        try expectIndexMatchesFile(editor)
    },
    test("a commit heard out of turn, after one a service made while hearing it, leaves the index whole") {
        let person = ShapeID(), watcher = ShapeID(), target = ShapeID()
        let document = CanvasDocument(shapes: [typeRecord(TypeSchemaProperty.starter, title: "Person", id: person),
                                               AnyShapeRecord(ShapeRecord(id: watcher, memo("quiet"))),
                                               instanceRecord("Target", of: [], at: CGPoint(x: 400, y: 400), id: target)])
        let registry = try Registry(plugins: [ChaserPlugin(target: target, type: person)] + typePlugins())
        let editor = CanvasEditor(registry: registry, file: CanvasFile(root: document), scheduler: ManualScheduler())
        let types = try require(editor.types)
        expectEqual(types.instances(of: person), [])
        editor.transact("Go") { $0.update(watcher, as: Memo.self) { $0.props.text = "go" } }
        expectEqual(editor.revision, 2, "two commits: the person's, and the service's while hearing it")
        expectEqual(types.links(of: target), [TypeLink(person)])
        expectEqual(types.instances(of: person), [target])
        try expectIndexMatchesFile(editor)
    },
    test("a commit heard out of turn that deleted a type leaves it known by the title it had") {
        let person = ShapeID(), watcher = ShapeID(), target = ShapeID()
        let document = CanvasDocument(shapes: [typeRecord(TypeSchemaProperty.starter, title: "Person", id: person),
                                               AnyShapeRecord(ShapeRecord(id: watcher, memo("quiet"))),
                                               instanceRecord("Target", of: [], at: CGPoint(x: 400, y: 400), id: target)])
        let registry = try Registry(plugins: [ChaserPlugin(target: target, type: person)] + typePlugins())
        let editor = CanvasEditor(registry: registry, file: CanvasFile(root: document), scheduler: ManualScheduler())
        let types = try require(editor.types)
        editor.transact("Go") {
            $0.update(watcher, as: Memo.self) { $0.props.text = "go" }
            $0.delete([person])
        }
        expectEqual(types.links(of: target), [TypeLink(person)])
        expectEqual(types.name(of: TypeLink(person)), .missing(lastKnown: "Person"), "the title it had, though the commit that deleted it was heard late")
        try expectIndexMatchesFile(editor)
    },
])
