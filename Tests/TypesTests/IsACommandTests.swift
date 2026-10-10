@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import SlashCommands
import TestKit
import Titles
import Topology
import Types

// `/is-a @Person`: a command that takes one shape, offered on every shape that holds `is`, admitting
// the types a shape may be, and adding one in a step of its own.

@MainActor private func arguments(_ type: ShapeID, _ label: String = "Person") -> SlashArguments {
    SlashArguments([.shape(type, label: label)])
}

@MainActor private func isA(_ editor: CanvasEditor, on id: ShapeID) throws -> OfferedSlashCommand {
    try require(try require(editor.slashCommands).commands(for: id).first { $0.name == "is-a" }, "/is-a is offered")
}

@MainActor let isACommandTests = Suite("/is-a", [
    test("it is offered on a shape that holds `is`, a type or not, taking one shape, a type; never on a kind that holds none") {
        let editor = try typeEditor(more: [EchoesPlugin()])
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [])
        let echo = editor.add(Echo())
        let state = try require(editor.slashCommands)
        for id in [person, ann] {
            let command = try isA(editor, on: id)
            expectEqual(command.argument, "@type")
            expect(command.takesShape)
            expectEqual(command.admittedKinds, [Memo.kind], "the kinds that can be types: the picker ranks only those")
        }
        expect(!state.commands(for: echo).map(\.name).contains("is-a"))
        // After `title` and `type`: the order of the plugins that contribute them.
        expectEqual(state.commands(for: ann).map(\.name), ["title", "type", "is-a"])
        expectEqual(state.commands(for: person).map(\.name), ["title", "is-a"], "not /type: it is one")
    },
    test("it admits a type: on another board too; not the shape itself, a shape that isn't a type, one it is already, one that is it in turn, a pill, or a shape that isn't there") {
        let pocket = ShapeID(), far = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 600, width: 100, height: 100))))]),
                              children: [pocket: CanvasDocument(shapes: [typeRecord(TypeSchemaProperty.starter, title: "Far", id: far)])])
        let editor = try typeEditor(file: file, more: [PocketsPlugin(), EchoesPlugin()])
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person"), employee = editor.addType(TypeSchemaProperty.starter, title: "Employee")
        let plain = editor.add(memo("not a type", at: CGPoint(x: 600, y: 40)))
        let echo = editor.add(Echo(stands: [Citation(person)]))
        let ann = editor.addInstance("Ann", of: [person])
        let command = try isA(editor, on: ann)
        expect(command.admits(employee))
        expect(command.admits(far), "a type on another board of the file")
        expect(!command.admits(ann), "itself")
        expect(!command.admits(plain), "a shape that isn't a type")
        expect(!command.admits(person), "one it is already")
        expect(!command.admits(echo), "a pill")
        expect(!command.admits(ShapeID()), "a shape that isn't there")
        // On a type: only types, never itself.
        let onType = try isA(editor, on: employee)
        expect(onType.admits(person) && onType.admits(far))
        expect(!onType.admits(employee) && !onType.admits(plain))
        // No cycles: once Employee is a Person, Person may not be an Employee, nor Person a Person's Employee, however far.
        editor.addTypeLink(person, to: employee)
        expect(!(try isA(editor, on: person)).admits(employee), "Employee is a Person")
        let manager = editor.addType(TypeSchemaProperty.starter, title: "Manager")
        editor.addTypeLink(employee, to: manager)
        expect(!(try isA(editor, on: person)).admits(manager), "Manager is an Employee, a Person")
        expect((try isA(editor, on: manager)).admits(person), "the other way is only a shorter chain")
        expect(!(try isA(editor, on: manager)).admits(manager))
    },
    test("it runs with one shape it admits: the type goes at the end of the list, in one step, Add Type, which undo takes back exactly") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person"), employee = editor.addType(TypeSchemaProperty.starter, title: "Employee")
        let ann = editor.addInstance("Ann", of: [])
        let state = try require(editor.slashCommands)
        expect(state.run("is-a", on: ann, with: arguments(person)))
        expectEqual(editor.typesOf(ann), [person])
        expectEqual(editor.undoHistory.undoName, "Add Type")
        expect(state.run("is-a", on: ann, with: arguments(employee, "Employee")))
        expectEqual(editor.typesOf(ann), [person, employee], "appended: a later line wins")
        editor.undo()
        expectEqual(editor.typesOf(ann), [person])
        editor.undo()
        expectEqual(editor.document[ann]?[IsAProperty.self], nil, "the property is off again")
        editor.redo()
        expectEqual(editor.typesOf(ann), [person])
        // What it doesn't accept doesn't run: nothing, text, a shape that isn't admitted, two shapes, text and a shape.
        let plain = editor.add(memo("plain", at: CGPoint(x: 600, y: 40)))
        let before = editor.revision
        for typed in [SlashArguments(""), SlashArguments("Person"), arguments(plain), arguments(person), arguments(ann),
                      SlashArguments([.shape(employee, label: "Employee"), .shape(person, label: "Person")]),
                      SlashArguments([.text("a "), .shape(employee, label: "Employee")])] {
            expect(!state.run("is-a", on: ann, with: typed), "\(typed)")
        }
        expectEqual(editor.revision, before)
        expectEqual(editor.typesOf(ann), [person])
    },
    test("a type's supertypes are typed the same way: it is a type and an instance, and its edges and chips say both") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person"), employee = editor.addType(TypeSchemaProperty.starter, title: "Employee")
        expect(try require(editor.slashCommands).run("is-a", on: employee, with: arguments(person)))
        expectEqual(editor.typesOf(employee), [person])
        expect(editor.types?.isType(employee) == true)
        expectEqual(try require(editor.topology).edges(of: employee, .outgoing, types: .only(IsAEdge.id)).map(\.target), [person])
        expectEqual(editor.types?.lineage(of: employee), [person])
    },
    test("it is offered nothing on a read-only shape, which keeps its types; a type that is frozen can still be named") {
        let editor = try typeEditor(more: [FreezingPlugin()])
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [])
        let state = try require(editor.slashCommands)
        editor.freeze([ann])
        expectEqual(state.commands(for: ann).map(\.name), [])
        expect(!state.run("is-a", on: ann, with: arguments(person)))
        editor.addTypeLink(person, to: ann)
        expectEqual(editor.typesOf(ann), [], "refused by the core")
        editor.freeze([ann], false)
        editor.freeze([person])
        expect(state.run("is-a", on: ann, with: arguments(person)), "a frozen type is only named")
        expectEqual(editor.typesOf(ann), [person])
    },
    test("addTypeLink and removeTypeLink: once each, one step each, on a shape on another board too; nothing for a shape that isn't an instance") {
        let pocket = ShapeID(), ann = ShapeID(), person = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 600, width: 100, height: 100)))),
                                                           typeRecord(TypeSchemaProperty.starter, title: "Person", id: person)]),
                              children: [pocket: CanvasDocument(shapes: [instanceRecord("Ann", of: [], id: ann)])])
        let editor = try typeEditor(file: file, more: [PocketsPlugin()])
        editor.addTypeLink(person, to: ann)
        expectEqual(editor.file.record(ann)?[IsAProperty.self]?.map(\.shape), [person], "the shape is on a board that is not shown")
        expectEqual(editor.undoHistory.undoName, "Add Type")
        let steps = editor.revision
        editor.addTypeLink(person, to: ann)
        editor.removeTypeLink(ShapeID(), from: ann)
        editor.addTypeLink(person, to: person)
        expectEqual(editor.revision, steps, "a type it is already, one it isn't, and a type that is no instance of kind: nothing")
        editor.removeTypeLink(person, from: ann)
        expectEqual(editor.file.record(ann)?[IsAProperty.self], nil)
        expectEqual(editor.undoHistory.undoName, "Remove Type")
        editor.undo()
        expectEqual(editor.file.record(ann)?[IsAProperty.self]?.map(\.shape), [person])
    },
])
