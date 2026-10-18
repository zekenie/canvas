import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Titles
import Topology
import Types
import Validation

// Only one replacing from a row: a pick in a row whose rule is Only one, where the note already has one, takes it away (with its
// values and the pill it empties, on whichever board) and draws the new one, in the one step `Add Relationship`; in the row's card the
// same, in the card's step. By hand nothing is refused: a second arrow drawn at a port is the note's issue. Over `RelationScene`.

private let onlyOne = EndRule(needed: false, onlyOne: true)

extension RelationScene {
    /// Sets the rule of the Feature end (the arrow from Feature into the relationship type).
    @discardableResult
    func ruleFeatureEnd(_ rule: EndRule?) -> ShapeID {
        let end = index.graph.sides(of: rel).from.first!.carrier
        editor.transact { $0.update(end) { $0[RelationshipEndProperty.self] = rule } }
        return end
    }
}

@MainActor let relationOnlyOneTests = Suite("Only one, replacing from a row", [
    test("a pick where the row holds one replaces it in the one step Add Relationship: the old arrow goes with its values, the new one is drawn, one Undo takes both back") {
        let s = try RelationScene.drawn()
        s.ruleFeatureEnd(onlyOne)
        let second = s.addLayerNote("Second")
        let first = try require(s.editor.relate(s.note, to: s.layerNote, in: try s.featureRow()))
        s.editor.transact { $0.update(first) { $0[FieldValuesProperty.self] = FieldValues(["role": "kept?"]) } }
        s.editor.undoHistory.seal()
        let before = s.editor.document
        let replacement = try require(s.editor.relate(s.note, to: second, in: try s.featureRow()))
        expectEqual(s.editor.undoHistory.undoName, "Add Relationship")
        expect(s.editor.document[first] == nil, "the old arrow is gone, with its values")
        expectEqual(s.relationships().map(\.id), [replacement])
        expectEqual(try s.pills(s.note, "in").pills.map(\.target), [second])
        expectEqual(s.editor.fieldChecks?.fullCheck(of: try require(s.editor.document[s.note])).problems ?? [], [], "one: nothing to say")
        s.editor.undo()
        expectEqual(s.editor.document, before, "one Undo takes both back")
        s.editor.redo()
        expectEqual(s.relationships().map(\.id), [replacement])
    },
    test("a row without Only one adds, and a rule taken off stops replacing") {
        let s = try RelationScene.drawn()
        let second = s.addLayerNote("Second")
        let first = try require(s.editor.relate(s.note, to: s.layerNote, in: try s.featureRow()))
        let added = try require(s.editor.relate(s.note, to: second, in: try s.featureRow()))
        expectEqual(Set(s.relationships().map(\.id)), [first, added], "no rule: both")
        s.editor.undo()
        s.ruleFeatureEnd(onlyOne)
        let third = s.addLayerNote("Third")
        let replaced = try require(s.editor.relate(s.note, to: third, in: try s.featureRow()))
        expectEqual(s.relationships().map(\.id), [replaced])
        s.ruleFeatureEnd(nil)
        let fourth = s.addLayerNote("Fourth")
        let kept = try require(s.editor.relate(s.note, to: fourth, in: try s.featureRow()))
        expectEqual(Set(s.relationships().map(\.id)), [replaced, kept], "Only one off: adds")
    },
    test("a second arrow drawn by hand is never taken away: the note carries the issue, and the arrows none; deleting one clears it") {
        let s = try RelationScene.drawn()
        s.ruleFeatureEnd(onlyOne)
        let other = s.addLayerNote("Other")
        let first = s.relate(s.note, s.layerNote), second = s.relate(s.note, other)
        expectEqual(Set(s.relationships().map(\.id)), [first, second], "nothing was refused or deleted")
        let issues = s.editor.issues(s.note)
        expectEqual(issues.map(\.message), ["in has 2 notes, and should have at most 1"])
        expectEqual(issues.first?.severity, .error)
        expectEqual(s.editor.issues(first) + s.editor.issues(second), [])
        // A pick now replaces both: the row holds more than one.
        let third = s.addLayerNote("Third")
        let replaced = try require(s.editor.relate(s.note, to: third, in: try s.featureRow()))
        expectEqual(s.relationships().map(\.id), [replaced], "both go")
        expectEqual(s.editor.issues(s.note), [])
        s.editor.undo()
        expectEqual(Set(s.relationships().map(\.id)), [first, second])
        expectEqual(s.editor.issues(s.note).count, 1)
    },
    test("far: a replaced arrow through a pill on another board takes the pill it empties with it; a far pick replaces a near one; one Undo returns both boards byte for byte") {
        let s = try RelationScene.drawn()
        s.ruleFeatureEnd(onlyOne)
        s.setOpen(s.awayLayer)
        let far = try require(s.editor.relate(s.note, to: s.awayLayer, in: try s.featureRow()))
        expectEqual(s.relays().count, 1)
        let start = try s.bytes()
        // A near note replaces the far one: its arrow and its pill go.
        let near = try require(s.editor.relate(s.note, to: s.layerNote, in: try s.featureRow()))
        expect(s.editor.document[far] == nil)
        expectEqual(s.relays().count, 0, "the pill it emptied")
        expectEqual(s.relationships().map(\.id), [near])
        expectEqual(s.editor.undoHistory.undoName, "Add Relationship")
        s.editor.undo()
        expect(try s.bytes() == start, "byte for byte")
        // A far note replaces the near one.
        s.editor.undo()
        s.editor.undo()
        let nearFirst = try require(s.editor.relate(s.note, to: s.layerNote, in: try s.featureRow()))
        let farAfter = try require(s.editor.relate(s.note, to: s.awayLayer, in: try s.featureRow()))
        expect(s.editor.document[nearFirst] == nil)
        expectEqual(s.relationships().map(\.id), [farAfter])
        expectEqual(s.relays().count, 1)
        s.editor.undo()
        expectEqual(s.relationships().map(\.id), [nearFirst])
        expectEqual(s.relays().count, 0)
    },
    test("a replaced arrow that is locked refuses the whole pick: nothing changes, no step, and the note shakes") {
        let log = RefusalLog()
        let s = try RelationScene.drawn(more: [FreezingPlugin(log: log)])
        s.ruleFeatureEnd(onlyOne)
        let second = s.addLayerNote("Second")
        let first = try require(s.editor.relate(s.note, to: s.layerNote, in: try s.featureRow()))
        s.editor.freeze([first])
        let before = s.editor.document, steps = s.editor.undoHistory.undoName
        log.refusals = []
        expectEqual(s.editor.relate(s.note, to: second, in: try s.featureRow()), nil)
        expectEqual(s.editor.document, before)
        expectEqual(s.editor.undoHistory.undoName, steps)
        expect(log.refusals.contains { $0.contains(s.note) }, "the note shakes")
    },
    test("in the row's card the blank line's pick replaces too, in the card's step: one Undo after the card closes") {
        let r = try RowCardRig()
        defer { r.close() }
        r.s.ruleFeatureEnd(onlyOne)
        let zed = r.s.addLayerNote("Zed"), alpha = r.s.addLayerNote("Alpha")
        let a1 = try require(r.s.editor.relate(r.s.note, to: alpha, in: r.row))
        _ = zed
        let start = r.editor.document
        expect(try r.open())
        let form = try require(r.form)
        let blank = form.sheet.lines.count - 1
        form.focus(r.stop(blank, 0))
        r.window.type("Zed")
        r.window.pressReturn()
        let now = r.arrows
        expectEqual(now.count, 1, "replaced, not added: \(now)")
        expect(!now.contains(a1))
        r.cards.close()
        expectEqual(r.editor.undoHistory.undoName, "Change In")
        r.editor.undo()
        expectEqual(r.editor.document, start, "one Undo")
    },
])
