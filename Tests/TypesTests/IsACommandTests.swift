import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import AppKit
import Colors
import Mentions
import Palette
import Selection
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

/// A chip's color as it is drawn in an appearance, as hex.
@MainActor private func drawn(_ color: NSColor?, dark: Bool) -> String? {
    var found: String?
    NSAppearance(named: dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance {
        found = color.flatMap { NSColor(cgColor: $0.cgColor) }.flatMap { $0.usingColorSpace(.sRGB) }
            .map { RGB($0.redComponent, $0.greenComponent, $0.blueComponent).hexString }
    }
    return found
}

/// The color of the row `/is-a` lists for the type titled Person.
@MainActor private func personChip(_ editor: CanvasEditor, on id: ShapeID) throws -> NSColor? {
    try isA(editor, on: id).choices().first { $0.title == "Person" }?.chip
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

/// `/is-a` for the shapes selected, as the command bar will ask it.
@MainActor private func isA(_ editor: CanvasEditor, selecting ids: [ShapeID]) throws -> OfferedSlashCommand {
    try require(try require(editor.slashCommands).commands(for: .selection(ids)).first { $0.name == "is-a" }, "/is-a is offered for the selection")
}

/// The titles of the rows `/is-a` lists for the shapes selected, in order.
@MainActor private func titles(_ editor: CanvasEditor, selecting ids: [ShapeID]) throws -> [String] {
    try isA(editor, selecting: ids).choices().map(\.title)
}

/// Picks the row of a title for the shapes selected, as the bar's list does.
@MainActor @discardableResult private func pick(_ title: String, selecting ids: [ShapeID], in editor: CanvasEditor) throws -> Bool {
    let command = try isA(editor, selecting: ids)
    let choice = try require(command.choices().first { $0.title == title }, "a row \(title)")
    return try require(editor.slashCommands).run(command, choosing: choice)
}

/// Memos side by side, each of the types.
@MainActor private func memos(_ count: Int, in editor: CanvasEditor, of types: [ShapeID] = []) -> [ShapeID] {
    (0..<count).map { editor.addInstance("m\($0)", of: types, at: CGPoint(x: 40 + Double($0) * 300, y: 400)) }
}

/// Every shape but the ones `known` names.
@MainActor private func added(to editor: CanvasEditor, since known: Set<ShapeID>) -> [ShapeID] {
    editor.document.shapes.map(\.id).filter { !known.contains($0) }
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
    test("its rows on a shape that is not a type: Type and Relationship Type, then the file's plain types by name, Untitled last; not the shape, one it is, one that is it in turn, a shape that isn't a type, a pill") {
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
        expectEqual(try titles(editor, on: ann), ["Type", "Relationship Type", "Far", "Person", "Zed", "Untitled"], "Employee is what Ann is; Far is on another board")
        let rows = try isA(editor, on: ann).choices()
        expectEqual(rows.map(\.group), [0, 0, 1, 1, 1, 1])
        expectEqual(rows.map(\.isPreferred), [false, false, true, false, false, false], "the first type")
        expectEqual(rows.map(\.step), ["Make Type", "Make Relationship Type", "Add Type", "Add Type", "Add Type", "Add Type"])
        expectEqual(rows.map(\.symbol), ["curlybraces", "arrow.right"] + Array(repeating: "curlybraces", count: 4))
        expect(rows.contains { $0.id == untitled.rawValue.uuidString })
        // No cycles: once Employee is a Person, Person may not be an Employee.
        editor.addTypeLink(person, to: employee)
        expectEqual(try titles(editor, on: person), ["Relationship Type", "Far", "Zed", "Untitled"], "a type: no Type row; not Employee, which is a Person")
        let manager = editor.addType(TypeSchemaProperty.starter, title: "Manager")
        editor.addTypeLink(employee, to: manager)
        expect(try !titles(editor, on: person).contains("Manager"), "Manager is an Employee, a Person")
        expect(try !titles(editor, on: manager).contains("Person"), "nor Person, which Manager is already, through Employee")
        expect(try !titles(editor, on: manager).contains("Manager"))
        _ = zed
    },
    test("/is-a type lists the Type row and the Relationship Type row, which are titled so: no New type “Type”, on a shape that is a type already too") {
        let editor = try typeEditor()
        let ann = editor.add(memo("Ann"))
        let line = try IsALine(on: ann, in: editor)
        line.type("/is-a type")
        expectEqual(line.titles, ["Type", "Relationship Type"])
        expectEqual(line.highlighted, "Type")
        line.returnKey()
        expectEqual(editor.schema(ann), TypeSchemaProperty.starter, "Return makes it a type")
        expectEqual(editor.undoHistory.undoName, "Make Type")

        let bo = editor.add(memo("Bo", at: CGPoint(x: 600, y: 40)))
        let typed = try IsALine(on: bo, in: editor)
        typed.type("/is-a typ")
        expectEqual(typed.titles, ["Type", "Relationship Type", "New type “Typ”"], "a title it only starts")

        let again = try IsALine(on: ann, in: editor)
        again.type("/is-a type")
        expectEqual(again.titles, ["Relationship Type"], "Ann is a type now: no Type row, and the list's own words name no new type")
    },
    test("the rows are chips: a type's color, Type and an untitled type gray") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person"), untitled = editor.addType(TypeSchemaProperty.starter)
        let ann = editor.addInstance("Ann", of: [])
        let rows = try isA(editor, on: ann).choices()
        expectEqual(rows.map(\.title), ["Type", "Relationship Type", "Person", "Untitled"])
        expectEqual(rows[0].chip, TypesStyle.grayChip)
        expectEqual(rows[1].chip, TypesStyle.grayChip)
        expectEqual(rows[2].chip, editor.types?.look(of: person).row)
        expectEqual(rows[3].chip, TypesStyle.grayChip)
        expectEqual(rows[2].chip, editor.types?.look(of: person).solid.color, "the pill's color")
        _ = untitled
    },
    test("a type whose shape holds a color is that color in the list: its solid, a hex value too; a name the file lacks is the id's") {
        let editor = try typeEditor(more: [Contributor(id: "memo-colors") { $0.colorable(Memo.self) }, ColorsPlugin()])
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [])
        let byId = try require(editor.types).look(of: person)
        expectEqual(try personChip(editor, on: ann), byId.row)
        let held: ShapeColor = TypeColors.name(of: person) == .green ? .teal : .green
        editor.setColor(held, of: [person])
        let swatch = try require(BuiltInColors.named(try require(held.name))).swatch
        expectEqual(try personChip(editor, on: ann), try require(editor.types).look(of: person).row)
        expectEqual(drawn(try personChip(editor, on: ann), dark: false), swatch.solid.light.hexString, "the color's solid")
        expectEqual(drawn(try personChip(editor, on: ann), dark: true), swatch.solid.dark.hexString, "in the dark too")
        editor.setColor(.value(RGB(hex: 0x4465E9)), of: [person])
        expectEqual(drawn(try personChip(editor, on: ann), dark: false), Swatch(RGB(hex: 0x4465E9)).solid.light.hexString)
        editor.transact("Color") { $0.update(person) { $0[ColorProperty.self] = .named("chartreuse") } }
        expectEqual(try personChip(editor, on: ann), byId.row)
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
        expectEqual(try titles(editor, on: ann), ["Type", "Relationship Type", "Person"])
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
    test("selected, three memos list Type, Relationship Type and the file's types by name, none counted; a pick gives the type to all three in one step, Add Type, undone whole") {
        let editor = try typeEditor()
        _ = editor.addType(TypeSchemaProperty.starter, title: "Zed", at: CGPoint(x: 40, y: 40))
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 340, y: 40))
        let ids = memos(3, in: editor)
        let command = try isA(editor, selecting: ids)
        expectEqual(command.shapes, ids)
        expect(!command.isPartial)
        expectEqual(command.reach, .together)
        let rows = command.choices()
        expectEqual(rows.map(\.title), ["Type", "Relationship Type", "Person", "Zed"])
        expectEqual(rows.map(\.detail), [nil, nil, nil, nil], "all three would gain each: nothing is counted")
        expectEqual(rows.map(\.group), [0, 0, 1, 1])
        expectEqual(rows.map(\.isPreferred), [false, false, true, false], "the first type")
        expectEqual(rows.map(\.step), ["Make Type", "Make Relationship Type", "Add Type", "Add Type"])
        expectEqual(rows.map(\.symbol), ["curlybraces", "arrow.right", "curlybraces", "curlybraces"])
        expect(try pick("Person", selecting: ids, in: editor))
        for id in ids { expectEqual(editor.typesOf(id), [person]) }
        expectEqual(editor.undoHistory.undoName, "Add Type")
        editor.undo()
        for id in ids { expectEqual(editor.typesOf(id), [], "all three in the one step") }
        editor.redo()
        for id in ids { expectEqual(editor.typesOf(id), [person]) }
    },
    test("a type some of the three are already is counted, 2 of 3, and the pick gives it to the other two; a type all three are is not listed; a type a shape is through another is already") {
        let editor = try typeEditor()
        let feature = editor.addType(TypeSchemaProperty.starter, title: "Feature", at: CGPoint(x: 40, y: 40))
        _ = editor.addType(TypeSchemaProperty.starter, title: "Zed", at: CGPoint(x: 340, y: 40))
        let a = editor.addInstance("a", of: [feature], at: CGPoint(x: 40, y: 400))
        let b = editor.addInstance("b", of: [], at: CGPoint(x: 340, y: 400)), c = editor.addInstance("c", of: [], at: CGPoint(x: 640, y: 400))
        let ids = [a, b, c]
        var rows = try isA(editor, selecting: ids).choices()
        expectEqual(rows.map(\.title), ["Type", "Relationship Type", "Feature", "Zed"])
        expectEqual(rows.map(\.detail), [nil, nil, "2 of 3", nil], "b and c would gain Feature; Zed all three")
        expect(try pick("Feature", selecting: ids, in: editor))
        for id in ids { expectEqual(editor.typesOf(id), [feature]) }
        expectEqual(editor.undoHistory.undoName, "Add Type")
        editor.undo()
        expectEqual(editor.typesOf(a), [feature], "it had it before")
        expectEqual(editor.typesOf(b), [])
        expectEqual(editor.typesOf(c), [], "the other two in the one step")
        editor.redo()
        rows = try isA(editor, selecting: ids).choices()
        expectEqual(rows.map(\.title), ["Type", "Relationship Type", "Zed"], "all three are a Feature: it would add nothing")
        // A Toyota is a Car through its type: myCar, a Toyota, already is one.
        let car = editor.addType(TypeSchemaProperty.starter, title: "Car", at: CGPoint(x: 940, y: 40))
        let toyota = editor.addType(TypeSchemaProperty.starter, title: "Toyota", at: CGPoint(x: 1240, y: 40))
        editor.addTypeLink(car, to: toyota)
        let myCar = editor.addInstance("myCar", of: [toyota], at: CGPoint(x: 940, y: 400)), plain = memos(2, in: editor)
        rows = try isA(editor, selecting: [myCar] + plain).choices()
        expectEqual(rows.map(\.title), ["Type", "Relationship Type", "Car", "Feature", "Toyota", "Zed"])
        expectEqual(rows.map(\.detail), [nil, nil, "2 of 3", nil, "2 of 3", nil], "Car and Toyota are not offered myCar, a Toyota")
    },
    test("Type is listed while every shape can be a type and none is, Relationship Type the same for its mark") {
        let editor = try typeEditor(more: [ChitsPlugin()])
        let ids = memos(2, in: editor)
        expectEqual(try titles(editor, selecting: ids), ["Type", "Relationship Type"])
        editor.makeType(ids[0])
        let mixed = try isA(editor, selecting: ids).choices()
        expectEqual(mixed.map(\.title), ["Relationship Type", "Untitled"], "one is a type: no Type; the other may be it, 1 of 2")
        expectEqual(mixed.map(\.detail), [nil, "1 of 2"])
        editor.makeRelationshipType(ids[0])
        expectEqual(try titles(editor, selecting: ids), [], "one is a relationship type: no mark to give, and a plain note is offered no relationship type")
        expectEqual(try titles(editor, selecting: [ids[1]]), ["Type", "Relationship Type"], "alone, the other is offered both")
        let chit = editor.add(Chit())
        let other = editor.addInstance("other", of: [], at: CGPoint(x: 940, y: 400))
        expectEqual(try titles(editor, selecting: [chit, other]), [], "a shape that cannot be a type: neither row")
        expectEqual(try titles(editor, selecting: [other]), ["Type", "Relationship Type"])
        // A pick of Type makes every one of them a type, in one step.
        let pair = [editor.addInstance("x", of: [], at: CGPoint(x: 1240, y: 400)), editor.addInstance("y", of: [], at: CGPoint(x: 1540, y: 400))]
        expect(try pick("Type", selecting: pair, in: editor))
        for id in pair { expectEqual(editor.schema(id), TypeSchemaProperty.starter) }
        expectEqual(editor.undoHistory.undoName, "Make Type")
        editor.undo()
        for id in pair { expectEqual(editor.schema(id), nil, "both in the one step") }
        expect(try pick("Relationship Type", selecting: pair, in: editor))
        for id in pair { expectEqual(editor.document[id]?[RelationshipProperty.self], true) }
        expectEqual(editor.undoHistory.undoName, "Make Relationship Type")
    },
    test("New type beside three selected memos: one note beside the box around them, all three made one of it, one step, New Type; undo takes the note and the three links") {
        let editor = try typeEditor()
        let ids = memos(3, in: editor)
        let known = Set(ids)
        let command = try isA(editor, selecting: ids)
        let row = try require(command.choice(otherwise: "feature"), "the New type row")
        expectEqual(row.title, "New type “Feature”")
        expectEqual(row.step, "New Type")
        expect(try require(editor.slashCommands).run(command, choosing: row))
        let made = try require(added(to: editor, since: known).first)
        expectEqual(added(to: editor, since: known).count, 1, "one note")
        expectEqual(editor.title(made), "Feature")
        expectEqual(editor.schema(made), TypeSchemaProperty.starter)
        expectEqual(editor.words(made), "")
        for id in ids { expectEqual(editor.typesOf(id), [made]) }
        expectEqual(editor.selectedShapeIDs, [made])
        expectEqual(editor.undoHistory.undoName, "New Type")
        let around = ids.compactMap { editor.document[$0]?.box }.reduce(CGRect.null) { $0.union($1) }
        let box = try require(editor.document[made]?.box)
        expect(!box.intersects(around), "beside the box around the three: \(box) and \(around)")
        expect(box.minX >= around.maxX, "right of them, where it is free: \(box) beside \(around)")
        editor.undo()
        expectEqual(added(to: editor, since: known), [], "the note goes")
        for id in ids { expectEqual(editor.typesOf(id), [], "and the three links, in the one step") }
        editor.redo()
        for id in ids { expectEqual(editor.typesOf(id), [made]) }
        // Where the box is to its right, the note goes elsewhere, clear of all of them.
        let wall = editor.add(memo("wall", at: CGPoint(x: around.maxX + 30, y: around.minY)))
        let second = try require(editor.newType(named: "Order", besides: ids))
        let other = try require(editor.document[second]?.box)
        for id in ids + [wall, made] { expect(!other.intersects(try require(editor.document[id]?.box)), "clear of \(id)") }
        expectEqual(editor.undoHistory.undoName, "New Type")
    },
    test("a bond and a memo selected: each type is offered to the one that may take it, counted 1 of 2; no Type, no New type; a pick goes to that one alone, in one step") {
        let editor = try typeEditor(more: [BondsPlugin()])
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        let employment = editor.addType(TypeSchemaProperty.starter, title: "Employment", at: CGPoint(x: 340, y: 40))
        editor.makeRelationshipType(employment)
        let left = editor.addInstance("Left", of: [], at: CGPoint(x: 40, y: 400)), right = editor.addInstance("Right", of: [], at: CGPoint(x: 640, y: 400))
        let ann = editor.addInstance("Ann", of: [], at: CGPoint(x: 40, y: 700))
        let bond = editor.addBond(left, right)
        let ids = [bond, ann]
        let command = try isA(editor, selecting: ids)
        expectEqual(command.shapes, ids)
        let rows = command.choices()
        expectEqual(rows.map(\.title), ["Employment", "Person"], "no Type: a bond cannot be one")
        expectEqual(rows.map(\.detail), ["1 of 2", "1 of 2"], "a relationship type for the arrow, a plain one for the note")
        expectEqual(rows.map(\.symbol), ["arrow.right", "curlybraces"])
        expectEqual(command.choice(otherwise: "Mentor"), nil, "an arrow and a note: the new type would be of two kinds")
        expect(try pick("Person", selecting: ids, in: editor))
        expectEqual(editor.typesOf(ann), [person])
        expectEqual(editor.typesOf(bond), [], "a plain type is no arrow's")
        expectEqual(editor.undoHistory.undoName, "Add Type")
        expect(try pick("Employment", selecting: ids, in: editor))
        expectEqual(editor.typesOf(bond), [employment])
        expectEqual(editor.typesOf(ann), [person], "a relationship type is no note's")
        editor.undo()
        expectEqual(editor.typesOf(bond), [])
        expectEqual(editor.typesOf(ann), [person])
        // Alone, each is offered what its own role is.
        expectEqual(try titles(editor, selecting: [bond]), ["Employment"])
        expectEqual(try titles(editor, selecting: [ann]), ["Type", "Relationship Type"], "alone, a note is offered no relationship type, and is a Person")
    },
    test("two bonds selected are offered New type as a relationship type: one note, no ends, both bonds made one of it in one step, New Relationship Type") {
        let editor = try typeEditor(more: [BondsPlugin()])
        let employment = editor.addType(TypeSchemaProperty.starter, title: "Employment", at: CGPoint(x: 340, y: 40))
        editor.makeRelationshipType(employment)
        let a = editor.addInstance("A", of: [], at: CGPoint(x: 40, y: 400)), b = editor.addInstance("B", of: [], at: CGPoint(x: 640, y: 400))
        let c = editor.addInstance("C", of: [], at: CGPoint(x: 1240, y: 400))
        let bonds = [editor.addBond(a, b), editor.addBond(b, c)]
        let known = Set(bonds + [a, b, c, employment])
        let command = try isA(editor, selecting: bonds)
        expectEqual(command.choices().map(\.title), ["Employment"])
        let row = try require(command.choice(otherwise: "mentor"), "all arrows that relate: one kind of type")
        expectEqual(row.step, "New Relationship Type")
        expect(try require(editor.slashCommands).run(command, choosing: row))
        let made = try require(added(to: editor, since: known).first)
        expectEqual(editor.title(made), "Mentor")
        expectEqual(editor.document[made]?[RelationshipProperty.self], true, "a relationship type, with no ends")
        for bond in bonds { expectEqual(editor.typesOf(bond), [made]) }
        expectEqual(editor.undoHistory.undoName, "New Relationship Type")
        editor.undo()
        for bond in bonds { expectEqual(editor.typesOf(bond), []) }
        expectEqual(added(to: editor, since: known), [])
    },
    test("an arrow that is an end of a relationship type is of nothing: counted among the shapes selected, given nothing, and no New type beside it") {
        let editor = try typeEditor(more: [BondsPlugin()])
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        let employment = editor.addType(TypeSchemaProperty.starter, title: "Employment", at: CGPoint(x: 640, y: 40))
        editor.makeRelationshipType(employment)
        let end = editor.addBond(person, employment)
        expect(editor.relationships?.end(end) != nil, "a bond from a type to a relationship type is an end")
        let ann = editor.addInstance("Ann", of: [], at: CGPoint(x: 40, y: 700))
        let ids = [end, ann]
        let command = try isA(editor, selecting: ids)
        expectEqual(command.choices().map(\.title), ["Person"])
        expectEqual(command.choices().map(\.detail), ["1 of 2"], "the end gains nothing")
        expectEqual(command.choice(otherwise: "Mentor"), nil)
        expect(try pick("Person", selecting: ids, in: editor))
        expectEqual(editor.typesOf(ann), [person])
        expectEqual(editor.typesOf(end), [])
        expectEqual(try titles(editor, selecting: [end]), [], "alone it has no rows, as ever")
    },
    test("a frozen memo in the selection is left out of the shapes /is-a acts on: the type goes to the others, the frozen one keeps its types and is not refused") {
        let log = RefusalLog()
        let editor = try typeEditor(more: [FreezingPlugin(log: log)])
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ids = memos(3, in: editor)
        editor.freeze([ids[2]])
        let command = try isA(editor, selecting: ids)
        expectEqual(command.shapes, [ids[0], ids[1]])
        expectEqual(command.targetCount, 3)
        expect(command.isPartial)
        let rows = command.choices()
        expectEqual(rows.map(\.title), ["Type", "Relationship Type", "Person"])
        expectEqual(rows.map(\.detail), [nil, nil, nil], "both would gain it: the third is not one of the shapes it acts on")
        expect(try pick("Person", selecting: ids, in: editor))
        expectEqual(editor.typesOf(ids[0]), [person])
        expectEqual(editor.typesOf(ids[1]), [person])
        expectEqual(editor.typesOf(ids[2]), [])
        expect(log.refusals.isEmpty, "left out, never tried")
        expect(try require(editor.slashCommands).commands(for: .selection([ids[2]])).isEmpty, "alone, a frozen memo is offered nothing")
    },
    test("one memo's rows are the same through its text and through a selection of one: a plain memo, a type, a memo with types, a bond") {
        let editor = try typeEditor(more: [BondsPlugin()])
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        let employment = editor.addType(TypeSchemaProperty.starter, title: "Employment", at: CGPoint(x: 340, y: 40))
        editor.makeRelationshipType(employment)
        let employee = editor.addType(TypeSchemaProperty.starter, title: "Employee", at: CGPoint(x: 640, y: 40))
        editor.addTypeLink(person, to: employee)
        let plain = editor.addInstance("plain", of: [], at: CGPoint(x: 40, y: 400))
        let typed = editor.addInstance("typed", of: [person], at: CGPoint(x: 340, y: 400))
        let left = editor.addInstance("left", of: [], at: CGPoint(x: 640, y: 400)), right = editor.addInstance("right", of: [], at: CGPoint(x: 940, y: 400))
        let bond = editor.addBond(left, right)
        for id in [plain, typed, person, employee, employment, bond] {
            let text = try isA(editor, on: id)
            let selected = try isA(editor, selecting: [id])
            expectEqual(selected.choices(), text.choices(), "the rows of \(editor.title(id) ?? "a shape")")
            expectEqual(selected.shapes, [id])
            expectEqual(selected.choice(otherwise: "Mentor"), text.choice(otherwise: "Mentor"), "and its New type")
        }
        expectEqual(try isA(editor, selecting: [plain]).choices().map(\.title), ["Type", "Relationship Type", "Employee", "Person"])
    },
    test("a type's own note among the shapes is asked on its own: it is never offered itself or a type built on it; the others are asked a group at a time") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        let employee = editor.addType(TypeSchemaProperty.starter, title: "Employee", at: CGPoint(x: 340, y: 40))
        editor.addTypeLink(person, to: employee)
        expectEqual(try titles(editor, selecting: [person, employee]), ["Relationship Type"], "Person is Employee's already, and Employee may not be built on what is built on it")
        let ann = editor.addInstance("Ann", of: [], at: CGPoint(x: 40, y: 400))
        let rows = try isA(editor, selecting: [person, employee, ann]).choices()
        expectEqual(rows.map(\.title), ["Relationship Type", "Employee", "Person"], "no Type: two are types; only Ann may take either")
        expectEqual(rows.map(\.detail), [nil, "1 of 3", "1 of 3"])
        expect(try pick("Employee", selecting: [person, employee, ann], in: editor))
        expectEqual(editor.typesOf(ann), [employee])
        expectEqual(editor.typesOf(person), [], "a cycle: refused by the rule, not by the pick")
        expectEqual(editor.typesOf(employee), [person])
    },
    test("a shape some list still names, a type taken away, is asked on its own: Car, no longer a type, is not offered the Toyota that is built on it, though a plain note is") {
        let editor = try typeEditor()
        let car = editor.addType(TypeSchemaProperty.starter, title: "Car", at: CGPoint(x: 40, y: 40))
        let toyota = editor.addType(TypeSchemaProperty.starter, title: "Toyota", at: CGPoint(x: 340, y: 40))
        editor.addTypeLink(car, to: toyota)
        editor.removeType(car)
        expectEqual(editor.typesOf(toyota), [car], "Toyota's list still names it")
        let ann = editor.addInstance("Ann", of: [], at: CGPoint(x: 40, y: 400))
        let rows = try isA(editor, selecting: [car, ann]).choices()
        expectEqual(rows.map(\.title), ["Type", "Relationship Type", "Toyota"])
        expectEqual(rows.map(\.detail), [nil, nil, "1 of 2"], "Car would make a cycle through Toyota's list; asked as one of a group with Ann it would not")
        expectEqual(try titles(editor, selecting: [car]), ["Type", "Relationship Type"], "alone, Car is offered no Toyota either")
    },
    test("the rows for several shapes are what each shape's own list says, summed, and a pick goes to the shapes whose list had the type: sixty random worlds of types, relationship types, bonds and notes") {
        var seed: UInt64 = 11
        func next(_ n: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int(seed >> 33) % n
        }
        for world in 0..<60 {
            let editor = try typeEditor(more: [BondsPlugin()])
            let types = (0..<6).map { editor.addType(TypeSchemaProperty.starter, title: "T\($0)", at: CGPoint(x: Double($0) * 300, y: 40)) }
            for type in types where next(3) == 0 { editor.makeRelationshipType(type) }
            // Types built on types, as far as the rules let them be.
            for _ in 0..<6 { editor.addTypeLink(types[next(6)], to: types[next(6)]) }
            let notes = (0..<6).map { editor.addInstance("m\($0)", of: [], at: CGPoint(x: Double($0) * 300, y: 400)) }
            for note in notes { for _ in 0..<next(3) { editor.addTypeLink(types[next(6)], to: note) } }
            // Bonds between notes and types: some are ends of a relationship type, some have a type of their own.
            let ends = notes + types
            var bonds: [ShapeID] = []
            for _ in 0..<4 {
                let from = next(ends.count)
                bonds.append(editor.addBond(ends[from], ends[(from + 1 + next(ends.count - 1)) % ends.count]))
            }
            for bond in bonds where next(2) == 0 { editor.addTypeLink(types[next(6)], to: bond) }
            // A type taken away, whose name the lists of its instances still hold.
            let gone = types[next(6)]
            if next(2) == 0 { editor.removeType(gone) }
            var pool = notes + bonds + types
            var ids: [ShapeID] = []
            for _ in 0..<(2 + next(7)) { ids.append(pool.remove(at: next(pool.count))) }

            let command = try isA(editor, selecting: ids)
            expectEqual(command.shapes, ids, "world \(world)")
            // What each shape's own list offers it, summed.
            var wanted: [ShapeID: Set<ShapeID>] = [:]
            for id in ids { for choice in editor.typeChoices(for: id) { wanted[choice.type, default: []].insert(id) } }
            let expected = wanted.map { (title: editor.title($0.key) ?? "Untitled", gainers: $0.value) }.sorted { $0.title < $1.title }
            let listed = command.choices().filter { $0.group == 1 }
            expectEqual(listed.map(\.title), expected.map(\.title), "world \(world): the types some shape would gain")
            expectEqual(listed.map(\.detail), expected.map { $0.gainers.count < ids.count ? "\($0.gainers.count) of \(ids.count)" : nil },
                        "world \(world): how many would")
            // A pick gives the type to the shapes whose list had it: a relationship type is no type note's, whatever its list says.
            guard let row = listed.first, let type = expected.first, let picked = wanted.first(where: { editor.title($0.key) == type.title })?.key else { continue }
            let had = Set(ids.filter { editor.typesOf($0).contains(picked) })
            let isRelationship = editor.types?.graph.relationshipTypes.contains(picked) == true
            let gainers = type.gainers.filter { !(isRelationship && editor.document[$0]?[TypeSchemaProperty.self] != nil) }
            expect(try require(editor.slashCommands).run(command, choosing: row), "world \(world): the pick runs")
            let now = Set(ids.filter { editor.typesOf($0).contains(picked) })
            expectEqual(now, had.union(gainers), "world \(world): the pick gives \(type.title) to those whose list had it")
        }
    },
    test("opening the list over a thousand selected memos in twenty lists over fifty types lists the types twenty times, not a thousand: the cost is the distinct lists") {
        let editor = try typeEditor()
        let types = (0..<50).map { editor.addType(TypeSchemaProperty.starter, title: "Type \($0)", at: CGPoint(x: Double($0 % 25) * 260, y: Double($0 / 25) * 100)) }
        var records: [AnyShapeRecord] = []
        for index in 0..<1000 {
            // Twenty lists of two types: the 1,000 notes come in them by turns.
            let list = [types[index % 20], types[20 + index % 20]]
            records.append(instanceRecord("n\(index)", of: list, at: CGPoint(x: Double(index % 40) * 260, y: 400 + Double(index / 40) * 80)))
        }
        editor.transact { transaction in for record in records { transaction.insert(record) } }
        let ids = records.map(\.id)
        let command = try isA(editor, selecting: ids)
        expectEqual(command.shapes.count, 1000)
        var rows: [SlashChoice] = []
        #if DEBUG
        let index = try require(editor.types)
        let before = index.choicesAsked
        rows = command.choices()
        expectEqual(index.choicesAsked - before, 20, "the types listed once for each of the twenty lists")
        #endif
        let took = (0..<5).map { _ in threadCPUTime { rows = command.choices() } }.min() ?? .zero
        expectEqual(rows.count, 52, "Type, Relationship Type and fifty types")
        expectEqual(rows.filter { $0.detail == "950 of 1000" }.count, 40, "each of the forty held by fifty of the notes")
        expectEqual(rows.filter { $0.detail == nil }.count, 12, "Type, Relationship Type and the ten nobody holds")
        expect(took < .milliseconds(50), "a thousand notes took \(took)")
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
        expectEqual(rows.count, 1002)
        expect(took < .milliseconds(25), "a thousand types took \(took)")
    },
])
