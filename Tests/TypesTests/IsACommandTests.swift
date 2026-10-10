import Adornments
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

// `/is-a`: a command that takes one choice, offered on every shape that holds `is`: `Type` while the
// shape can be one and isn't, and the types it may be; a pick runs at once, in a step of its own.

/// A box that says where its words are and may be typed, but cannot be a type itself.
private struct Chit: BoxShapeProps {
    static let kind: ShapeKind = "chit"
    static let properties = Properties<Chit>(title: "Chit") {
        Property("frame", \.frame).required()
        Property("text", \.text)
    }
    var frame = CGRect(x: 0, y: 0, width: 100, height: 40)
    var text: MentionText = ""
    init() {}
}

@MainActor private struct ChitDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Chit>, in context: RenderContext) {}
}

private struct ChitsPlugin: CanvasPlugin {
    var id: PluginID { "chits" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(ChitDefinition()) { chit in
            chit.typeWords(\.text, drawnIn: { _ in nil })
            chit.typeable()
        }
    }
}

@MainActor private func isA(_ editor: CanvasEditor, on id: ShapeID) throws -> OfferedSlashCommand {
    try require(try require(editor.slashCommands).commands(for: id).first { $0.name == "is-a" }, "/is-a is offered")
}

/// The titles of the rows `/is-a` lists for a shape, in order.
@MainActor private func titles(_ editor: CanvasEditor, on id: ShapeID) throws -> [String] {
    try isA(editor, on: id).choices().map(\.title)
}

/// Picks the row of a title, as a list does.
@MainActor @discardableResult private func pick(_ title: String, on id: ShapeID, in editor: CanvasEditor) throws -> Bool {
    let command = try isA(editor, on: id)
    let choice = try require(command.choices().first { $0.title == title }, "a row \(title)")
    return try require(editor.slashCommands).run(command, on: id, choosing: choice)
}

@MainActor let isACommandTests = Suite("/is-a", [
    test("it takes a choice, on every shape that holds `is`, a type or not; never on a kind that holds none") {
        let editor = try typeEditor(more: [EchoesPlugin()])
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [])
        let echo = editor.add(Echo())
        let state = try require(editor.slashCommands)
        for id in [person, ann] {
            let command = try isA(editor, on: id)
            expectEqual(command.argument, "type")
            expect(command.takesChoice)
            expect(!command.takesShape)
            expectEqual(command.admittedKinds, nil)
        }
        expect(!state.commands(for: echo).map(\.name).contains("is-a"))
        expectEqual(state.commands(for: ann).map(\.name), ["title", "is-a"])
        expectEqual(state.commands(for: person).map(\.name), ["title", "is-a"], "a type too")
        expect(!state.run("is-a", on: ann, with: SlashArguments("Person")), "it never runs with arguments")
    },
    test("its rows on a shape that is not a type: Type, then the file's types by name, Untitled last; not the shape, one it is, one that is it in turn, a shape that isn't a type, a pill") {
        let pocket = ShapeID(), far = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 0, y: 600, width: 100, height: 100))))]),
                              children: [pocket: CanvasDocument(shapes: [typeRecord(TypeSchemaProperty.starter, title: "Far", id: far)])])
        let editor = try typeEditor(file: file, more: [PocketsPlugin(), EchoesPlugin()])
        let zed = editor.addType(TypeSchemaProperty.starter, title: "Zed")
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let untitled = editor.addType(TypeSchemaProperty.starter)
        let employee = editor.addType(TypeSchemaProperty.starter, title: "Employee")
        _ = editor.add(memo("not a type", at: CGPoint(x: 600, y: 40)))
        _ = editor.add(Echo(stands: [Citation(person)]))
        let ann = editor.addInstance("Ann", of: [employee])
        expectEqual(try titles(editor, on: ann), ["Type", "Far", "Person", "Zed", "Untitled"], "Employee is what Ann is; Far is on another board")
        let rows = try isA(editor, on: ann).choices()
        expectEqual(rows.map(\.group), [0, 1, 1, 1, 1])
        expectEqual(rows.map(\.isPreferred), [false, true, false, false, false], "the first type")
        expectEqual(rows.map(\.step), ["Make Type", "Add Type", "Add Type", "Add Type", "Add Type"])
        expectEqual(rows.map(\.symbol), Array(repeating: "curlybraces", count: 5))
        expect(rows.contains { $0.id == untitled.rawValue.uuidString })
        // No cycles: once Employee is a Person, Person may not be an Employee.
        editor.addTypeLink(person, to: employee)
        expectEqual(try titles(editor, on: person), ["Far", "Zed", "Untitled"], "a type: no Type row; not Employee, which is a Person")
        let manager = editor.addType(TypeSchemaProperty.starter, title: "Manager")
        editor.addTypeLink(employee, to: manager)
        expect(try !titles(editor, on: person).contains("Manager"), "Manager is an Employee, a Person")
        expect(try titles(editor, on: manager).contains("Person"), "the other way is only a shorter chain")
        expect(try !titles(editor, on: manager).contains("Manager"))
        _ = zed
    },
    test("the rows are chips: a type's color, Type and an untitled type gray") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person"), untitled = editor.addType(TypeSchemaProperty.starter)
        let ann = editor.addInstance("Ann", of: [])
        let rows = try isA(editor, on: ann).choices()
        expectEqual(rows.map(\.title), ["Type", "Person", "Untitled"])
        expectEqual(rows[0].chip, TypesStyle.grayChip)
        expectEqual(rows[1].chip, TypeColors.base(person))
        expectEqual(rows[2].chip, TypesStyle.grayChip)
        expectEqual(rows[1].chip, TypeColors.solid(person).color, "the pill's color")
        _ = untitled
    },
    test("a shape of a kind that cannot be a type is offered no Type; with no types in the file the list is empty") {
        let editor = try typeEditor(more: [ChitsPlugin()])
        let chit = editor.add(Chit())
        let command = try isA(editor, on: chit)
        expectEqual(command.choices().map(\.title), [])
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        expectEqual(try titles(editor, on: chit), ["Person"])
        expect(try pick("Person", on: chit, in: editor))
        expectEqual(editor.typesOf(chit), [person])
        let ann = editor.add(memo("Ann", at: CGPoint(x: 600, y: 40)))
        expectEqual(try titles(editor, on: ann), ["Type", "Person"])
    },
    test("Type makes the shape a type in one step, Make Type; undo is exact; a type takes no Type row") {
        let editor = try typeEditor()
        let id = editor.add(memo("a pet in my household"))
        try pick("Type", on: id, in: editor)
        expectEqual(editor.schema(id), TypeSchemaProperty.starter)
        expectEqual(editor.words(id), "a pet in my household")
        expectEqual(editor.undoHistory.undoName, "Make Type")
        expect(try !titles(editor, on: id).contains("Type"))
        editor.undo()
        expectEqual(editor.schema(id), nil)
    },
    test("a type picked goes at the end of the list, in one step, Add Type, which undo takes back exactly") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person"), employee = editor.addType(TypeSchemaProperty.starter, title: "Employee")
        let ann = editor.addInstance("Ann", of: [])
        try pick("Person", on: ann, in: editor)
        expectEqual(editor.typesOf(ann), [person])
        expectEqual(editor.undoHistory.undoName, "Add Type")
        try pick("Employee", on: ann, in: editor)
        expectEqual(editor.typesOf(ann), [person, employee], "appended: a later line wins")
        editor.undo()
        expectEqual(editor.typesOf(ann), [person])
        editor.undo()
        expectEqual(editor.document[ann]?[IsAProperty.self], nil, "the property is off again")
        editor.redo()
        expectEqual(editor.typesOf(ann), [person])
        // A pick that is no longer allowed does nothing.
        let before = editor.revision
        let command = try isA(editor, on: ann)
        let stale = SlashChoice(person.rawValue.uuidString, title: "Person")
        expect(try require(editor.slashCommands).run(command, on: ann, choosing: stale))
        expectEqual(editor.revision, before, "a type it is already")
        expectEqual(editor.typesOf(ann), [person])
    },
    test("a type's supertypes are picked the same way: it is a type and an instance, and its edges say both") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person"), employee = editor.addType(TypeSchemaProperty.starter, title: "Employee")
        try pick("Person", on: employee, in: editor)
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
        let command = try isA(editor, on: ann)
        let choice = try require(command.choices().first { $0.title == "Person" })
        editor.freeze([ann])
        expectEqual(state.commands(for: ann).map(\.name), [])
        editor.addTypeLink(person, to: ann)
        expectEqual(editor.typesOf(ann), [], "refused by the core")
        editor.makeType(ann)
        expectEqual(editor.schema(ann), nil, "and so is Type")
        editor.freeze([ann], false)
        editor.freeze([person])
        expect(state.run(command, on: ann, choosing: choice), "a frozen type is only named")
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
    test("the plural forms are one step for several shapes, and leave out the shapes that cannot take the change") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let a = editor.addInstance("a", of: []), b = editor.addInstance("b", of: [person]), c = editor.addInstance("c", of: [])
        editor.addTypeLink(person, to: [a, b, c])
        expectEqual(editor.typesOf(a), [person])
        expectEqual(editor.typesOf(b), [person], "b was one already")
        expectEqual(editor.typesOf(c), [person])
        expectEqual(editor.undoHistory.undoName, "Add Type")
        editor.undo()
        expectEqual(editor.typesOf(a), [])
        expectEqual(editor.typesOf(b), [person])
        let steps = editor.revision
        editor.addTypeLink(person, to: [person, b])
        editor.removeTypeLink(person, from: [a, c])
        expectEqual(editor.revision, steps, "nothing left to change: no step")
    },
    test("opening the list over a thousand types costs what the types are: every type asked about once, sorted by name, in well under a frame") {
        let editor = try typeEditor()
        for index in 0..<1000 {
            _ = editor.addType(TypeSchemaProperty.starter, title: "Type \(index)", at: CGPoint(x: Double(index % 40) * 260, y: Double(index / 40) * 60 + 600))
        }
        let ann = editor.addInstance("Ann", of: [])
        let command = try isA(editor, on: ann)
        var rows: [SlashChoice] = []
        let took = (0..<5).map { _ in threadCPUTime { rows = command.choices() } }.min() ?? .zero
        expectEqual(rows.count, 1001)
        expect(took < .milliseconds(25), "a thousand types took \(took)")
    },
])
