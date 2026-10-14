@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Topology
import Types

// The rules an end can carry, read into the rows (`RelationshipIndex.ruledRows(for:)`) and what a commit names for them: a
// ruled row's verdict depends on its partition (which carriers are in which row, on which sides, with what rule), so the end
// type's notes are named when that changes (a row came, went, merged by name, split, changed rule or sides) and a rename that
// leaves it equal announces a redraw alone.

/// Person, Friendship (a relationship type) with an end at Person named `friends`, two Persons, a Company.
@MainActor private struct Scene {
    let editor: CanvasEditor
    let person: ShapeID, friendship: ShapeID, ann: ShapeID, bo: ShapeID
    let end: ShapeID
    let heard: RelationshipHeard

    init(rule: EndRule? = nil, name: String = "friends") throws {
        editor = try bondEditor()
        person = editor.addType(TypeSchemaProperty.starter, title: "Person", at: CGPoint(x: 40, y: 40))
        friendship = editor.addRelationshipType("Friendship")
        ann = editor.addInstance("Ann", of: [person])
        bo = editor.addInstance("Bo", of: [person], at: CGPoint(x: 400, y: 400))
        end = editor.addBond(person, friendship, name: name, rule: rule)
        heard = RelationshipHeard(editor)
    }

    var index: RelationshipIndex { editor.relationships! }
    var graph: RelationshipGraph { index.graph }

    func setRule(_ rule: EndRule?, on arrow: ShapeID? = nil) {
        editor.transact { $0.update(arrow ?? end) { $0[RelationshipEndProperty.self] = rule } }
    }
}

@MainActor let ruledRowsTests = Suite("The rules an end carries, in the rows and in what a commit names", [
    test("ruledRows lists the rows of a note's types that carry a rule, and the rule is the union of the ends merged into the row") {
        let s = try Scene(rule: EndRule(needed: true, onlyOne: false))
        let other = s.editor.addBond(s.person, s.friendship, name: "pals")
        let rows = s.index.ruledRows(for: [s.person])
        expectEqual(rows.map(\.key.label), [.typed("friends")], "pals has no rule")
        expectEqual(rows.first?.rule, EndRule(needed: true, onlyOne: false))
        s.setRule(EndRule(needed: false, onlyOne: true), on: other)
        expectEqual(s.index.ruledRows(for: [s.person]).map(\.key.label), [.typed("friends"), .typed("pals")])
        // Two ends merged by a name: either's rule, the row's.
        s.editor.transact { $0.update(other, as: Bond.self) { $0.props.text = MentionText(plain: "friends") } }
        let merged = s.index.ruledRows(for: [s.person])
        expectEqual(merged.map(\.key.label), [.typed("friends")])
        expectEqual(merged.first?.rule, EndRule(needed: true, onlyOne: true))
        expectEqual(merged.first?.carriers.count, 2)
        expect(s.index.ruledRows(for: [s.friendship]).isEmpty, "a relationship type's own note has no rows")
    },
    test("a rule set names the end type's notes, near and far, and not the types; clearing it and undo name them again") {
        let s = try Scene()
        let employee = s.editor.addType(TypeSchemaProperty.starter, title: "Employee", at: CGPoint(x: 400, y: 40))
        s.editor.addTypeLink(s.person, to: employee)
        let cy = s.editor.addInstance("Cy", of: [employee], at: CGPoint(x: 400, y: 200))
        s.setRule(EndRule(needed: true, onlyOne: false))
        var change = try require(s.heard.last)
        expect(change.notes.isSuperset(of: [s.ann, s.bo, cy]), "every instance of Person and of what builds on it: \(change.notes.count)")
        expect(!change.notes.contains(s.person) && !change.notes.contains(employee), "no type")
        expect(!change.arrows.contains(s.friendship), "a rule is not a fit")
        s.setRule(nil)
        change = try require(s.heard.last)
        expect(change.notes.isSuperset(of: [s.ann, s.bo, cy]), "cleared")
        s.editor.undo()
        expectEqual(s.index.ruledRows(for: [s.person]).count, 1, "undone: the rule is back")
        expect(try require(s.heard.last).notes.isSuperset(of: [s.ann, s.bo, cy]))
        // A rule on an arrow that is no end is inert and names nobody.
        let plain = s.editor.addBond(s.ann, s.bo)
        s.setRule(EndRule(needed: true, onlyOne: true), on: plain)
        expectEqual(s.index.ruledRows(for: [s.person]).count, 1, "the arrow that is no end gives no row")
    },
    test("a rename that leaves every ruled row's partition equal names no note: a redraw") {
        let s = try Scene(rule: EndRule(needed: true, onlyOne: false))
        s.editor.transact { $0.update(s.end, as: Bond.self) { $0.props.text = MentionText(plain: "buddies") } }
        let change = try require(s.heard.last)
        expect(change.rows, "the row's name changed")
        expect(change.notes.isEmpty && change.layout.isEmpty, "no note named, none laid out: \(change)")
        expect(!change.arrows.contains(s.ann) && !change.arrows.contains(s.bo))
        s.editor.transact { $0.update(s.end, as: Bond.self) { $0.props.text = MentionText(plain: "buddies!") } }
        expect(try require(s.heard.last).notes.isEmpty, "a keystroke more")
        // A row with no rule at all: a rename names nobody either.
        let t = try Scene()
        t.editor.transact { $0.update(t.end, as: Bond.self) { $0.props.text = MentionText(plain: "buddies") } }
        expect(try require(t.heard.last).notes.isEmpty)
    },
    test("an unruled end merged into a ruled row by its name, and split from it, names the end type's notes; two unruled rows merging name none") {
        let s = try Scene(rule: EndRule(needed: true, onlyOne: false))
        let pals = s.editor.addBond(s.person, s.friendship, name: "pals")
        expect(try require(s.heard.last).notes.isEmpty, "a new unruled row")
        s.editor.transact { $0.update(pals, as: Bond.self) { $0.props.text = MentionText(plain: "friends") } }
        expect(try require(s.heard.last).notes.isSuperset(of: [s.ann, s.bo]), "merged into the ruled row: its partition has a carrier more")
        s.editor.transact { $0.update(pals, as: Bond.self) { $0.props.text = MentionText(plain: "pals") } }
        expect(try require(s.heard.last).notes.isSuperset(of: [s.ann, s.bo]), "split from it")
        s.editor.undo()
        expect(try require(s.heard.last).notes.isSuperset(of: [s.ann, s.bo]), "and undo")
        // Two unruled rows that become one: a layout, and no verdict to move.
        let u = try Scene()
        let more = u.editor.addBond(u.person, u.friendship, name: "pals")
        u.editor.transact { $0.update(more, as: Bond.self) { $0.props.text = MentionText(plain: "friends") } }
        expect(try require(u.heard.last).notes.isEmpty && u.heard.last?.layout.contains(u.person) == true)
    },
    test("an end ruled and drawn, deleted or re-aimed names the notes of the types it leaves and reaches") {
        let s = try Scene()
        let company = s.editor.addType(TypeSchemaProperty.starter, title: "Company", at: CGPoint(x: 400, y: 40))
        let acme = s.editor.addInstance("Acme", of: [company], at: CGPoint(x: 700, y: 400))
        let to = s.editor.addBond(s.friendship, company, name: "owner", rule: EndRule(needed: true, onlyOne: false))
        expect(try require(s.heard.last).notes.contains(acme) && !s.heard.last!.notes.contains(s.ann), "drawn at Company")
        s.editor.transact { $0.update(to, as: Bond.self) { $0.props.to = s.person } }
        let moved = try require(s.heard.last)
        expect(moved.notes.isSuperset(of: [acme, s.ann, s.bo]), "re-aimed: Company's lose it, Person's gain it")
        s.editor.transact { $0.delete([to]) }
        expect(try require(s.heard.last).notes.isSuperset(of: [s.ann, s.bo]), "deleted")
    },
    test("at a hub of a thousand notes: a rule set names each once and no more, a keystroke in the ruled end's label names none, and a keystroke that merges an unruled end into the ruled row names them all") {
        let s = try Scene()
        let many = (0..<1_000).map { s.editor.addInstance("n\($0)", of: [s.person], at: CGPoint(x: 40 + Double($0 % 50) * 30, y: 900 + Double($0 / 50) * 30)) }
        s.setRule(EndRule(needed: true, onlyOne: false))
        var change = try require(s.heard.last)
        expect(change.notes.isSuperset(of: many) && change.notes.count == many.count + 2, "every instance, Ann and Bo too: \(change.notes.count)")
        expect(change.arrows.isDisjoint(with: many) && change.layout.isEmpty)
        for text in ["friend", "friends!", "friendz"] {
            s.editor.transact { $0.update(s.end, as: Bond.self) { $0.props.text = MentionText(plain: text) } }
            change = try require(s.heard.last)
            expect(change.notes.isEmpty && change.rows, "a keystroke in a ruled end's label names no note: '\(text)'")
        }
        let pals = s.editor.addBond(s.person, s.friendship, name: "pals")
        expect(try require(s.heard.last).notes.isEmpty, "a new row with no rule")
        s.editor.transact { $0.update(pals, as: Bond.self) { $0.props.text = MentionText(plain: "friendz") } }
        expect(try require(s.heard.last).notes.isSuperset(of: many), "merged into the ruled row")
    },
    test("a type related to itself has two ends, and each keeps its own rule") {
        let s = try Scene(name: "")
        // `end` is the from end (Person → Friendship); the to end is Friendship → Person.
        let toEnd = s.editor.addBond(s.friendship, s.person)
        s.setRule(EndRule(needed: true, onlyOne: false))
        let rows = s.index.rows(for: [s.person], isType: false)
        expectEqual(rows.count, 1, "unnamed ends on both sides with the same types are one row")
        expectEqual(rows.first?.rule, EndRule(needed: true, onlyOne: false))
        expectEqual(s.graph.sides(of: s.friendship).from.first?.rule, EndRule(needed: true, onlyOne: false))
        expectEqual(s.graph.sides(of: s.friendship).to.first?.rule, EndRule(), "the to end has none")
        // Only the `to` end ruled: it is the row's rule just the same, and the from end keeps none.
        s.setRule(nil)
        s.setRule(EndRule(needed: false, onlyOne: true), on: toEnd)
        expectEqual(s.graph.sides(of: s.friendship).from.first?.rule, EndRule())
        expectEqual(s.graph.sides(of: s.friendship).to.first?.rule, EndRule(needed: false, onlyOne: true))
        // A name on the from end splits the row in two; each end's rule stays its own.
        s.editor.transact { $0.update(s.end, as: Bond.self) { $0.props.text = MentionText(plain: "friends") } }
        let split = s.index.ruledRows(for: [s.person])
        expectEqual(split.count, 1, "only the to end carries a rule")
        expectEqual(split.first?.sides, [.to])
        expect(try require(s.heard.last).notes.isSuperset(of: [s.ann, s.bo]), "the row split: its sides changed")
    },
])
