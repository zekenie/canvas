import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Foundation
import TestKit
import Selection
import Titles
import Topology
import Types

// What Types says of an arrow that is an end of a relationship type, for the kind that draws arrows to lay out as half of one line
// through the type's pill (`EndArrow`, the layout input `EndArrow.input`): which type, which side, and the partner when the type has
// the one end on each side; told again (`shapesDidChangeLayout`) when that changes, and not when a name or a rule on an end does.
// And Straighten: the pill onto the middle of the line between the two shapes, in one step.

@MainActor private struct Line {
    let h: EditorHarness
    var editor: CanvasEditor { h.editor }
    let person: ShapeID, company: ShapeID, hub: ShapeID
    let fromEnd: ShapeID, toEnd: ShapeID, plain: ShapeID

    init() throws {
        h = try EditorHarness { scheduler in try rowEditor(scheduler: scheduler, more: [BondsPlugin(), RelaysPlugin(), PocketsPlugin()]) }
        let editor = h.editor
        person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 300))
        company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 900, y: 300))
        hub = editor.addRelationshipType("Employment", at: CGPoint(x: 500, y: 40))
        fromEnd = editor.addBond(person, hub, name: "jobs")
        toEnd = editor.addBond(hub, company, name: "staff")
        plain = editor.addBond(person, company)
    }

    func role(_ id: ShapeID) -> EndArrow? { editor.shapeContext.layoutInput(EndArrow.input, for: id) }
    func middle(_ id: ShapeID) -> CGPoint? { editor.shapeContext.frame(of: id).map { CGPoint(x: $0.midX, y: $0.midY) } }
}

@MainActor let endArrowTests = Suite("The line through a relationship type's pill", [
    test("an end is told which type, which side and, with one end on each side, its partner; a plain arrow is told nothing") {
        let l = try Line()
        expectEqual(l.role(l.fromEnd), EndArrow(hub: l.hub, side: .from, partner: l.toEnd))
        expectEqual(l.role(l.toEnd), EndArrow(hub: l.hub, side: .to, partner: l.fromEnd))
        expectEqual(l.role(l.plain), nil, "an arrow between two types is no end")
        expectEqual(l.role(l.person), nil, "nor is a type")
    },
    test("a second end on a side leaves nobody a partner, and the end taken away gives it back; each in a layout the core is told of") {
        let l = try Line()
        let revision = l.editor.layoutRevision
        let third = l.editor.addBond(l.company, l.hub, name: "owners")
        expectEqual(l.role(l.fromEnd)?.partner, nil)
        expectEqual(l.role(l.toEnd)?.partner, nil)
        expectEqual(l.role(third), EndArrow(hub: l.hub, side: .from, partner: nil))
        expect(l.editor.layoutRevision > revision, "told")
        let after = l.editor.layoutRevision
        l.editor.transact("Delete") { $0.delete([third]) }
        expectEqual(l.role(l.fromEnd)?.partner, l.toEnd)
        expectEqual(l.role(third), nil)
        expect(l.editor.layoutRevision > after, "told again")
        // Undone, the third is an end again.
        l.editor.undo()
        expectEqual(l.role(third)?.partner, nil)
        expectEqual(l.role(l.toEnd)?.partner, nil)
    },
    test("an arrow that stops being an end is told so, though nothing but its type's mark changed: its hub is no relationship type any more") {
        let l = try Line()
        expect(l.role(l.fromEnd) != nil)
        let revision = l.editor.layoutRevision
        l.editor.transact("Plain") { $0.update(l.hub) { $0[RelationshipProperty.self] = nil } }
        expectEqual(l.role(l.fromEnd), nil)
        expect(l.editor.layoutRevision > revision, "told")
        l.editor.undo()
        expect(l.role(l.fromEnd) != nil)
    },
    test("a name or a rule on an end, a rename of the type and a move of a type tell nothing: what an end is told is none of them") {
        let l = try Line()
        let revision = l.editor.layoutRevision
        l.editor.transact("Name") { $0.update(l.fromEnd) { $0[RelationshipEndProperty.self] = EndRule(needed: true, onlyOne: false) } }
        l.editor.setEndRule([l.toEnd], onlyOne: true)
        l.editor.transact("Rename") { $0.update(l.hub) { $0[TitleProperty.self] = "Hired" } }
        l.editor.transact("Move") { $0.translate([l.company], by: CGPoint(x: 0, y: 200)) }
        expectEqual(l.editor.layoutRevision, revision, "no end changed, so nothing is laid out again for it")
    },
    test("an end re-aimed to another type keeps its partner; one re-aimed to a free end stays an end of nothing") {
        let l = try Line()
        let other = l.editor.addType(TypeSchemaProperty.starter, title: "Other", at: CGPoint(x: 900, y: 600))
        l.editor.transact("Re-aim") { $0.update(l.toEnd, as: Bond.self) { $0.props.to = other } }
        expectEqual(l.role(l.fromEnd)?.partner, l.toEnd)
        expectEqual(l.role(l.toEnd), EndArrow(hub: l.hub, side: .to, partner: l.fromEnd))
        l.editor.transact("Free") { $0.update(l.toEnd, as: Bond.self) { $0.props.to = nil } }
        expectEqual(l.role(l.toEnd), nil, "a loose end is none")
        expectEqual(l.role(l.fromEnd)?.partner, nil)
    },
    test("Straighten puts the pill's middle on the middle of the line between the two types, in one step named for it, one Undo exact") {
        let l = try Line()
        let a = try require(l.middle(l.person)), b = try require(l.middle(l.company))
        expect(l.editor.straighten(l.hub))
        let pill = try require(l.middle(l.hub))
        let middle = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
        expect(abs(pill.x - middle.x) < 0.001 && abs(pill.y - middle.y) < 0.001, "\(pill) for \(middle)")
        expectEqual(l.editor.undoHistory.undoName, "Straighten")
        expect(!l.editor.straighten(l.hub), "already there: nothing, and no step")
        expectEqual(l.editor.undoHistory.undoName, "Straighten")
        l.editor.undo()
        expect(l.middle(l.hub) != pill)
        l.editor.redo()
        expectEqual(l.middle(l.hub), pill)
    },
    test("Straighten is for a type with the one end on each side that run to two shapes: a second end, a type related to itself, a plain type and any other shape have none") {
        let l = try Line()
        expect(!l.editor.straighten(l.plain) && !l.editor.straighten(l.person) && !l.editor.straighten(ShapeID()))
        let third = l.editor.addBond(l.company, l.hub)
        expect(!l.editor.straighten(l.hub), "two ends on a side")
        l.editor.transact("Delete") { $0.delete([third]) }
        l.editor.transact("Re-aim") { $0.update(l.toEnd, as: Bond.self) { $0.props.to = l.person } }
        expect(!l.editor.straighten(l.hub), "a type related to itself: both run to Person")
        expect(l.editor.undoHistory.undoName != "Straighten")
    },
    test("its menu: the item is in the menu of such a type and no other; choosing it straightens in a step") {
        let l = try Line()
        l.editor.selectedShapeIDs = [l.hub]
        let at = try require(l.middle(l.hub))
        var menu = try require(l.h.secondaryClick(at: at))
        expect(menu.outline.contains("Straighten"), "\(menu.outline)")
        try menu.choose("Straighten")
        expectEqual(l.editor.undoHistory.undoName, "Straighten")
        let a = try require(l.middle(l.person)), b = try require(l.middle(l.company))
        let pill = try require(l.middle(l.hub))
        expect(abs(pill.x - (a.x + b.x) / 2) < 0.001 && abs(pill.y - (a.y + b.y) / 2) < 0.001)
        // A plain type's and a plain arrow's menus have none.
        l.editor.selectedShapeIDs = [l.person]
        menu = try require(l.h.secondaryClick(at: try require(l.middle(l.person))))
        expect(!menu.outline.contains("Straighten"), "\(menu.outline)")
        _ = l.editor.addBond(l.company, l.hub)
        l.editor.selectedShapeIDs = [l.hub]
        menu = try require(l.h.secondaryClick(at: try require(l.middle(l.hub))))
        expect(!menu.outline.contains("Straighten"), "two ends on a side: \(menu.outline)")
    },
])
