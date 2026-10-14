import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Foundation
import Mentions
import Selection
import TestKit
import Types

// Is a ▸ in a shape's menu, read with a secondary click and chosen as a click would: nothing goes on
// screen. TypesTests' list has no Locking, which Types does not use: where Is a sits by Lock is a
// shipped test.

@MainActor private struct Bench {
    let h: EditorHarness
    let log: RefusalLog
    var editor: CanvasEditor { h.editor }

    init(more: [any CanvasPlugin] = []) throws {
        let log = RefusalLog()
        self.log = log
        h = try EditorHarness { scheduler in try typeEditor(scheduler: scheduler, more: [FreezingPlugin(log: log)] + more) }
    }

    /// The middle of a shape, where a click is on it.
    func middle(_ id: ShapeID) -> CGPoint {
        let frame = editor.document[id]?.box ?? .zero
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    func menu(on id: ShapeID, selecting ids: [ShapeID]? = nil) throws -> NSMenu {
        editor.selectedShapeIDs = ids ?? [id]
        return try require(h.secondaryClick(at: middle(id)))
    }

    func notes(_ count: Int) -> [ShapeID] {
        (0..<count).map { editor.addInstance("n\($0)", of: [], at: CGPoint(x: 40 + Double($0) * 300, y: 400)) }
    }
}

@MainActor let isAMenuTests = Suite("Is a ▸", [
    test("the submenu holds Type, a line, then the file's types by name, in the menu of a note") {
        let b = try Bench()
        _ = b.editor.addType(TypeSchemaProperty.starter, title: "Zed", at: CGPoint(x: 40, y: 40))
        _ = b.editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 340, y: 40))
        let note = b.editor.addInstance("Ann", of: [])
        let outline = try b.menu(on: note).outline
        expect(outline.contains("Is a ▸"), "\(outline)")
        let at = try require(outline.firstIndex(of: "Is a ▸"))
        expectEqual(Array(outline[at...].prefix(6)), ["Is a ▸", "  Type", "  Relationship Type", "  —", "  Person", "  Zed"])
    },
    test("checks: an item every selected shape has is checked, a type some have is not (there is no mixed state)") {
        let b = try Bench()
        let person = b.editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ids = b.notes(3)
        b.editor.addTypeLink(person, to: [ids[0], ids[1], ids[2]])
        var outline = try b.menu(on: ids[0], selecting: ids).outline
        expect(outline.contains("  ✓ Person"), "\(outline)")
        b.editor.removeTypeLink(person, from: ids[2])
        outline = try b.menu(on: ids[0], selecting: ids).outline
        expect(outline.contains("  Person"), "unchecked: some have it \(outline)")
        b.editor.removeTypeLink(person, from: [ids[0], ids[1]])
        outline = try b.menu(on: ids[0], selecting: ids).outline
        expect(outline.contains("  Person"), "none have it")
    },
    test("choosing an unchecked type on three selected notes is one step, Add Type, and undo is exact; a checked one is Remove Type") {
        let b = try Bench()
        let person = b.editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ids = b.notes(3)
        b.editor.addTypeLink(person, to: ids[1])
        let before = b.editor.revision
        try b.menu(on: ids[0], selecting: ids).choose("Is a", "Person")
        for id in ids { expectEqual(b.editor.typesOf(id), [person]) }
        expectEqual(b.editor.undoHistory.undoName, "Add Type")
        expect(b.editor.revision > before)
        b.editor.undo()
        expectEqual(b.editor.typesOf(ids[0]), [])
        expectEqual(b.editor.typesOf(ids[1]), [person], "the one that had it still has it")
        b.editor.redo()
        try b.menu(on: ids[0], selecting: ids).choose("Is a", "Person")
        for id in ids { expectEqual(b.editor.typesOf(id), [], "checked: taken off all") }
        expectEqual(b.editor.undoHistory.undoName, "Remove Type")
    },
    test("Type: checked when every selected shape is a type; Make Type otherwise, Remove Type when checked") {
        let b = try Bench()
        let ids = b.notes(2)
        var outline = try b.menu(on: ids[0], selecting: ids).outline
        expect(outline.contains("  Type"), "\(outline)")
        try b.menu(on: ids[0], selecting: ids).choose("Is a", "Type")
        expect(ids.allSatisfy { b.editor.schema($0) != nil })
        expectEqual(b.editor.undoHistory.undoName, "Make Type")
        outline = try b.menu(on: ids[0], selecting: ids).outline
        expect(outline.contains("  ✓ Type"), "\(outline)")
        try b.menu(on: ids[0], selecting: ids).choose("Is a", "Type")
        expect(ids.allSatisfy { b.editor.schema($0) == nil })
        expectEqual(b.editor.undoHistory.undoName, "Remove Type")
        b.editor.makeType(ids[0])
        outline = try b.menu(on: ids[0], selecting: ids).outline
        expect(outline.contains("  Type"), "one is a type, one is not: unchecked \(outline)")
        try b.menu(on: ids[0], selecting: ids).choose("Is a", "Type")
        expect(ids.allSatisfy { b.editor.schema($0) != nil }, "the rest are made")
    },
    test("a type some shape is or may be is listed; one none may be is not") {
        let b = try Bench()
        let person = b.editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        let employee = b.editor.addType(TypeSchemaProperty.starter, title: "Employee", at: CGPoint(x: 340, y: 40))
        b.editor.addTypeLink(person, to: employee)
        // Person may not be an Employee (a cycle): a menu for Person alone does not list Employee.
        let outline = try b.menu(on: person).outline
        expect(!outline.contains("  Employee"), "\(outline)")
        expect(outline.contains("  ✓ Type"), "\(outline)")
        let both = try b.menu(on: person, selecting: [person, employee]).outline
        expect(both.contains("  Employee") || both.contains("  Person"), "\(both)")
    },
    test("no Type item where a selected shape cannot be a type, no Is a where one holds no is, and none where it would be empty") {
        let echoes = try Bench(more: [EchoesPlugin()])
        let echo = echoes.editor.add(Echo())
        let note = echoes.editor.addInstance("Ann", of: [])
        expect(!(try echoes.menu(on: echo).outline).contains("Is a ▸"), "an echo holds no is")
        expect(!(try echoes.menu(on: note, selecting: [note, echo]).outline).contains("Is a ▸"), "nor a selection with one")
        let none = try Bench(more: [ChitsMenuPlugin()])
        let chit = none.editor.add(MenuChit())
        expect(!(try none.menu(on: chit).outline).contains("Is a ▸"), "no types in the file and no Type: empty")
        let person = none.editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 400, y: 40))
        let outline = try none.menu(on: chit).outline
        expect(outline.contains("Is a ▸") && !outline.contains("  Type"), "\(outline)")
        _ = person
    },
    test("read-only: the items show, a pick changes nothing and the shape shakes; with others selected they change in one step") {
        let b = try Bench()
        let person = b.editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ids = b.notes(3)
        b.editor.freeze([ids[2]])
        let outline = try b.menu(on: ids[2]).outline
        expect(outline.contains("Is a ▸") && outline.contains("  Person"), "\(outline)")
        try b.menu(on: ids[2]).choose("Is a", "Person")
        expectEqual(b.editor.typesOf(ids[2]), [])
        expect(b.log.refusals.contains { $0.contains(ids[2]) }, "it shakes")
        b.log.refusals = []
        let steps = b.editor.revision
        _ = steps
        try b.menu(on: ids[0], selecting: ids).choose("Is a", "Person")
        expectEqual(b.editor.typesOf(ids[0]), [person])
        expectEqual(b.editor.typesOf(ids[1]), [person])
        expectEqual(b.editor.typesOf(ids[2]), [], "the read-only one is refused")
        expect(b.log.refusals.contains { $0.contains(ids[2]) }, "and shakes")
        expectEqual(b.editor.undoHistory.undoName, "Add Type")
        b.editor.undo()
        expectEqual(b.editor.typesOf(ids[0]), [], "the two changed in one step")
        expectEqual(b.editor.typesOf(ids[1]), [])
    },
])

/// A box that holds `is` but cannot be a type, for a menu with no Type item.
private struct MenuChit: BoxShapeProps {
    static let kind: ShapeKind = "menu-chit"
    static let properties = Properties<MenuChit>(title: "Chit") {
        Property("frame", \.frame).required()
        Property("text", \.text)
    }
    var frame = CGRect(x: 40, y: 200, width: 100, height: 40)
    var text: MentionText = ""
    init() {}
}

@MainActor private struct MenuChitDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<MenuChit>, in context: RenderContext) {}
}

private struct ChitsMenuPlugin: CanvasPlugin {
    var id: PluginID { "menu-chits" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(MenuChitDefinition()) { chit in
            chit.typeWords(\.text, drawnIn: { _ in nil })
            chit.typeable()
        }
    }
}
