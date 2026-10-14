import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import DetailPanel
import Foundation
import Mentions
import Selection
import TestKit
import Titles
import Topology
import Types

// The rule of an end, set: `setEndRule` (the one writer), the arrow's context menu and its panel, shown only while the arrow is
// an end of a relationship type; and a type related to itself, whose two ends each keep their own.

@MainActor private struct Bench {
    let h: EditorHarness
    let log: RefusalLog
    var editor: CanvasEditor { h.editor }
    let person: ShapeID, company: ShapeID, employment: ShapeID
    let fromEnd: ShapeID, toEnd: ShapeID, plain: ShapeID
    let ann: ShapeID, acme: ShapeID

    init() throws {
        let log = RefusalLog()
        self.log = log
        h = try EditorHarness { scheduler in try rowEditor(scheduler: scheduler, more: [BondsPlugin(), RelaysPlugin(), PocketsPlugin(), FreezingPlugin(log: log)]) }
        let editor = h.editor
        person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 300))
        company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 600))
        employment = editor.addRelationshipType("Employment", at: CGPoint(x: 700, y: 40))
        fromEnd = editor.addBond(person, employment, name: "jobs")
        toEnd = editor.addBond(employment, company, name: "staff")
        ann = editor.addInstance("Ann", of: [person], at: CGPoint(x: 40, y: 800))
        acme = editor.addInstance("Acme", of: [company], at: CGPoint(x: 500, y: 800))
        plain = editor.addBond(ann, acme)
    }

    func rule(_ id: ShapeID) -> EndRule? { editor.document[id]?[RelationshipEndProperty.self] }

    /// The menu of the arrows (or others) selected, opened with a secondary click on the first arrow's line.
    func menu(on ids: [ShapeID]) throws -> NSMenu {
        editor.selectedShapeIDs = ids
        let outline = try require(editor.shapeContext.geometry(of: ids[0])?.outline, "an arrow's line")
        let middle = CGPoint(x: (outline[0].x + outline[outline.count - 1].x) / 2, y: (outline[0].y + outline[outline.count - 1].y) / 2)
        return try require(h.secondaryClick(at: middle))
    }
}

private let needed = EndRule(needed: true, onlyOne: false)
private let onlyOne = EndRule(needed: false, onlyOne: true)

@MainActor let endRuleTests = Suite("Setting the rule of an end", [
    test("setEndRule writes the members it names and keeps the rest, in one step named for the first change; both off take the property off") {
        let b = try Bench()
        expect(b.editor.setEndRule([b.fromEnd], needed: true))
        expectEqual(b.rule(b.fromEnd), needed)
        expectEqual(b.editor.undoHistory.undoName, "Make Needed")
        expect(b.editor.setEndRule([b.fromEnd], onlyOne: true))
        expectEqual(b.rule(b.fromEnd), EndRule(needed: true, onlyOne: true), "the other member kept")
        expectEqual(b.editor.undoHistory.undoName, "Allow Only One")
        expect(b.editor.setEndRule([b.fromEnd], onlyOne: false))
        expectEqual(b.rule(b.fromEnd), needed)
        expectEqual(b.editor.undoHistory.undoName, "Allow Several")
        expect(b.editor.setEndRule([b.fromEnd], needed: false))
        expectEqual(b.rule(b.fromEnd), nil, "no rule is no property")
        expectEqual(b.editor.undoHistory.undoName, "Make Optional")
        b.editor.undo()
        expectEqual(b.rule(b.fromEnd), needed)
        b.editor.undo()
        expectEqual(b.rule(b.fromEnd), EndRule(needed: true, onlyOne: true))
        // Both at once, from a panel: one step named for the first.
        b.editor.undo()
        b.editor.undo()
        expectEqual(b.rule(b.fromEnd), nil)
        expect(b.editor.setEndRule([b.fromEnd], needed: true, onlyOne: true))
        expectEqual(b.editor.undoHistory.undoName, "Make Needed")
        expectEqual(b.rule(b.fromEnd), EndRule(needed: true, onlyOne: true))
        b.editor.undo()
        expectEqual(b.rule(b.fromEnd), nil, "one Undo")
    },
    test("it changes nothing, and makes no step, for a rule that is already so, an arrow that is no end and a shape that is no arrow") {
        let b = try Bench()
        b.editor.setEndRule([b.fromEnd], needed: true)
        let name = b.editor.undoHistory.undoName
        expect(!b.editor.setEndRule([b.fromEnd], needed: true), "already so")
        expect(!b.editor.setEndRule([b.fromEnd], onlyOne: false), "already so")
        expect(!b.editor.setEndRule([b.plain, b.ann, b.person], needed: true), "no end among them")
        expect(b.editor.document[b.plain]?[RelationshipEndProperty.self] == nil && b.editor.document[b.ann]?[RelationshipEndProperty.self] == nil)
        expectEqual(b.editor.undoHistory.undoName, name)
        // Several arrows, ends among them: the ends are written in one step.
        expect(b.editor.setEndRule([b.fromEnd, b.plain, b.toEnd], onlyOne: true))
        expectEqual(b.rule(b.fromEnd), EndRule(needed: true, onlyOne: true))
        expectEqual(b.rule(b.toEnd), onlyOne)
        expectEqual(b.rule(b.plain), nil)
        b.editor.undo()
        expectEqual(b.rule(b.fromEnd), needed)
        expectEqual(b.rule(b.toEnd), nil, "one step for both")
    },
    test("a locked end is refused and shakes, and the ends beside it change in the one step") {
        let b = try Bench()
        b.editor.freeze([b.fromEnd])
        expect(!b.editor.setEndRule([b.fromEnd], needed: true) || b.rule(b.fromEnd) == nil, "not written")
        expectEqual(b.rule(b.fromEnd), nil)
        expect(b.log.refusals.contains { $0.contains(b.fromEnd) }, "it shakes")
        b.log.refusals = []
        b.editor.setEndRule([b.fromEnd, b.toEnd], needed: true)
        expectEqual(b.rule(b.fromEnd), nil, "refused")
        expectEqual(b.rule(b.toEnd), needed, "the other changed")
        expect(b.log.refusals.contains { $0.contains(b.fromEnd) })
        expectEqual(b.editor.undoHistory.undoName, "Make Needed")
    },
    test("the arrow's menu has Needed and Only one, checked by what every selected end has; a pick sets the rule in a step and the item reads the other way after") {
        let b = try Bench()
        // An arrow's line is hit only through a selection of two (a shape with no box has no selection box alone): the two ends.
        let both = [b.fromEnd, b.toEnd]
        var outline = try b.menu(on: both).outline
        expect(outline.contains("Needed") && outline.contains("Only one"), "\(outline)")
        expect(!outline.contains("✓ Needed") && !outline.contains("✓ Only one"), "\(outline)")
        try b.menu(on: both).choose("Needed")
        expectEqual(b.rule(b.fromEnd), needed)
        expectEqual(b.rule(b.toEnd), needed)
        expectEqual(b.editor.undoHistory.undoName, "Make Needed")
        outline = try b.menu(on: both).outline
        expect(outline.contains("✓ Needed") && outline.contains("Only one") && !outline.contains("✓ Only one"), "\(outline)")
        try b.menu(on: both).choose("Only one")
        expectEqual(b.rule(b.fromEnd), EndRule(needed: true, onlyOne: true))
        expectEqual(b.editor.undoHistory.undoName, "Allow Only One")
        try b.menu(on: both).choose("Only one")
        expectEqual(b.rule(b.fromEnd), needed)
        expectEqual(b.editor.undoHistory.undoName, "Allow Several")
        try b.menu(on: both).choose("Needed")
        expectEqual(b.rule(b.fromEnd), nil)
        expectEqual(b.rule(b.toEnd), nil)
        expectEqual(b.editor.undoHistory.undoName, "Make Optional")
        b.editor.undo()
        expectEqual(b.rule(b.fromEnd), needed, "undone")
    },
    test("several ends selected: an item is checked only when every one has it, a pick gives it to all in one step, and a checked one takes it from all") {
        let b = try Bench()
        b.editor.setEndRule([b.fromEnd], needed: true)
        var outline = try b.menu(on: [b.fromEnd, b.toEnd]).outline
        expect(outline.contains("Needed") && !outline.contains("✓ Needed"), "one of two: \(outline)")
        try b.menu(on: [b.fromEnd, b.toEnd]).choose("Needed")
        expectEqual(b.rule(b.fromEnd), needed)
        expectEqual(b.rule(b.toEnd), needed)
        expectEqual(b.editor.undoHistory.undoName, "Make Needed")
        b.editor.undo()
        expectEqual(b.rule(b.toEnd), nil, "one step")
        b.editor.redo()
        outline = try b.menu(on: [b.fromEnd, b.toEnd]).outline
        expect(outline.contains("✓ Needed"), "both: \(outline)")
        try b.menu(on: [b.fromEnd, b.toEnd]).choose("Needed")
        expectEqual(b.rule(b.fromEnd), nil)
        expectEqual(b.rule(b.toEnd), nil)
        expectEqual(b.editor.undoHistory.undoName, "Make Optional")
    },
    test("the items are shown only while every shape of the menu is an end: a plain arrow, a note, and an end beside either have none") {
        let b = try Bench()
        let other = b.editor.addBond(b.acme, b.ann)
        let plainMenu = try b.menu(on: [b.plain, other]).outline
        expect(!plainMenu.contains("Needed") && !plainMenu.contains("Only one"), "\(plainMenu)")
        let mixed = try b.menu(on: [b.fromEnd, b.plain]).outline
        expect(!mixed.contains("Needed"), "an end beside a plain arrow: \(mixed)")
        b.editor.selectedShapeIDs = [b.ann]
        let note = try require(b.h.secondaryClick(at: CGPoint(x: b.editor.document[b.ann]?.box?.midX ?? 0, y: b.editor.document[b.ann]?.box?.midY ?? 0))).outline
        expect(!note.contains("Needed"), "\(note)")
        // An arrow that stops being an end (the relationship type unmarked) loses them.
        b.editor.transact { $0.update(b.employment) { $0[RelationshipProperty.self] = nil } }
        let gone = try b.menu(on: [b.fromEnd, b.toEnd]).outline
        expect(!gone.contains("Needed"), "\(gone)")
    },
])

@MainActor let endRulePanelTests = Suite("The panel of an end", [
    test("the Types tab of an end has an End section with Needed and Only one, ticked from the rule and following it; a plain arrow and a note have none") {
        let panel = try TypePanelWindow(more: [RowSlipsPlugin(), BondsPlugin()])
        let editor = panel.editor
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        let company = editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 40, y: 400))
        let employment = editor.addRelationshipType("Employment", at: CGPoint(x: 700, y: 40))
        let end = editor.addBond(person, employment, name: "jobs")
        let plain = editor.addBond(person, company)
        @MainActor func sections(_ id: ShapeID) throws -> [String] {
            try require(editor.detailPanel?.layout(for: try require(editor.document[id]))).sections(in: .of(TypesTab.self)).map(\.section)
        }
        let ofEnd = try sections(end), ofPlain = try sections(plain), ofType = try sections(person)
        expect(ofEnd.contains("end-rule"), "\(ofEnd)")
        expect(!ofPlain.contains("end-rule") && !ofType.contains("end-rule"))
        editor.selection = end
        panel.window.spin { panel.checkboxes.count >= 2 }
        let boxes = panel.checkboxes
        expectEqual(boxes.map(\.state), [.off, .off])
        // The boxes follow the rule, whoever sets it (a checkbox's click is `setEndRule`, which the writer's tests hold).
        editor.setEndRule([end], needed: true)
        panel.window.spin { panel.checkboxes.first?.state == .on }
        expectEqual(panel.checkboxes.map(\.state), [.on, .off])
        editor.setEndRule([end], onlyOne: true)
        panel.window.spin { panel.checkboxes.last?.state == .on }
        editor.undo()
        panel.window.spin { panel.checkboxes.last?.state == .off }
        expectEqual(panel.checkboxes.first?.state, .on)
        // Not an end any more: the section goes.
        editor.transact { $0.update(employment) { $0[RelationshipProperty.self] = nil } }
        let after = try sections(end)
        expect(!after.contains("end-rule"))
    },
])

@MainActor let selfRelatedRuleTests = Suite("A type related to itself, its two ends", [
    test("Needed and Only one set on the from end are not the to end's: each end keeps its own through a rename, an undo and a restatement") {
        let editor = try typeEditorWithDraw()
        try drawScript(#"""
        memo "Person" schema: "{\"type\": \"object\"}"
        memo "Friendship" right of "Person" schema: "{\"type\": \"object\"}" relationship: true
        edge "Person" -> "Friendship" text: "friends" endRule: {"needed": true, "onlyOne": true}
        edge "Friendship" -> "Person" text: "friend of"
        """#, on: editor)
        let ends = editor.document.shapes.filter { editor.relationships?.end($0.id) != nil }
        expectEqual(ends.count, 2)
        let from = try require(ends.first { editor.relationships?.end($0.id)?.side == .from })
        let to = try require(ends.first { editor.relationships?.end($0.id)?.side == .to })
        expectEqual(from[RelationshipEndProperty.self], EndRule(needed: true, onlyOne: true))
        expectEqual(to[RelationshipEndProperty.self], nil)
        let friendship = try require(editor.relationships?.end(from.id)?.type)
        @MainActor func rules() -> (from: EndRule, to: EndRule) {
            let sides = editor.relationships?.graph.sides(of: friendship) ?? RelationshipSides()
            return (sides.from.first?.rule ?? EndRule(), sides.to.first?.rule ?? EndRule())
        }
        expect(rules().from == EndRule(needed: true, onlyOne: true) && rules().to.isNone)
        // Two names: two rows, the from end's ruled and the to end's not.
        let person = try require(editor.relationships?.graph.sides(of: friendship).from.first?.type)
        let noteRows = editor.relationships?.graph.rows(for: [person], isType: false) ?? []
        expectEqual(noteRows.map(\.key.label), [.typed("friends"), .typed("friend of")])
        expectEqual(noteRows.map(\.rule), [EndRule(needed: true, onlyOne: true), EndRule()])
        // A rename of either end keeps both rules.
        editor.transact { $0.update(from.id, as: Bond.self) { $0.props.text = MentionText(plain: "pals") } }
        expect(rules().from == EndRule(needed: true, onlyOne: true) && rules().to.isNone, "renamed the from end")
        editor.transact { $0.update(to.id, as: Bond.self) { $0.props.text = MentionText(plain: "pal of") } }
        expect(rules().from == EndRule(needed: true, onlyOne: true) && rules().to.isNone, "renamed the to end")
        // The rule set on the to end, then undone.
        editor.setEndRule([to.id], needed: true)
        expect(rules().from == EndRule(needed: true, onlyOne: true) && rules().to == EndRule(needed: true, onlyOne: false))
        editor.undo()
        expect(rules().from == EndRule(needed: true, onlyOne: true) && rules().to.isNone, "undone")
        editor.undo()
        expect(rules().from == EndRule(needed: true, onlyOne: true), "the rename undone")
        // `canvas draw` restates the from end's rule and says nothing of the to end's: each keeps its own.
        try drawScript(#"""
        edge "Person" -> "Friendship" endRule: {"onlyOne": false}
        """#, on: editor)
        expect(rules().from == EndRule(needed: true, onlyOne: false) && rules().to.isNone, "a member taken off one end")
        try drawScript(#"""
        edge "Friendship" -> "Person" endRule: {"onlyOne": true}
        edge "Person" -> "Friendship" endRule: {"onlyOne": true}
        """#, on: editor)
        expect(rules().from == EndRule(needed: true, onlyOne: true) && rules().to == EndRule(needed: false, onlyOne: true), "each its own")
        // Draw again, as written: nothing changes.
        let before = editor.document.shapes
        try drawScript(#"""
        edge "Friendship" -> "Person" endRule: {"onlyOne": true}
        edge "Person" -> "Friendship" endRule: {"onlyOne": true}
        """#, on: editor)
        expectEqual(editor.document.shapes, before)
    },
])
