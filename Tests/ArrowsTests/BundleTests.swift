import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Geometry
import Mentions
import Selection
import TestKit

// Arrows drawn together (Connections' `ConnectionBundle`, here a fixture's answers, as LineRows provides them for folds): a
// bundle's lead draws once for its members, which keep its outline (never empty) and are drawn, hit, listed and spoken by
// nothing; the lead is said as what it draws for; a change to the members' answers lays out only the members. Arrows with the
// same two ends bow apart by a slot each; arrows fanned into one place come in at angles of their own (a marked end also a
// little apart along its side) and their labels slide toward their other ends; an end at a shape as a whole comes in at the
// row the answer names.

/// The answers a test gives, and the arrows the provider was asked about since `asked` was emptied.
@MainActor final class BundleAnswers {
    var answers: [ShapeID: ConnectionBundle] = [:]
    var asked: [ShapeID] = []
}

/// Two rosters (`LevelBoard`) whose arrows' bundles `answers` gives.
@MainActor private func bundleBoard(_ answers: BundleAnswers, looks: Bool = false) throws -> LevelBoard {
    try LevelBoard(looks: looks, more: [ArrowPortsPlugin(), Contributor(id: "bundles") { r in
        r.layoutInput(ConnectionBundle.input) { record, _ in
            answers.asked.append(record.id)
            return answers.answers[record.id]
        }
    }])
}

@MainActor let bundleTests = Suite("Arrows drawn together", [
    test("a lead draws for its members: they keep its outline, and are drawn, hit, listed and spoken by nothing; the lead is '3 arrows'") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers)
        let ids = (0..<3).map { b.h.add(Arrow(start: b.end(b.left, $0), end: b.end(b.right, 0))) }
        let own = try b.geometry(ids[2])
        answers.answers = [ids[0]: ConnectionBundle(role: .lead(count: 3, standing: nil)),
                           ids[1]: ConnectionBundle(role: .member(lead: ids[0])), ids[2]: ConnectionBundle(role: .member(lead: ids[0]))]
        b.h.editor.connectionBundlesDidChange(Set(ids))
        let shapes = b.h.editor.shapeContext
        let lead = try require(shapes.geometry(of: ids[0]))
        for member in ids.dropFirst() {
            let kept = try require(shapes.geometry(of: member))
            expect(kept.isHidden, "a member is hidden")
            expectEqual(kept.outline, lead.outline, "its outline its lead's, never empty")
            expectEqual(kept.label, nil, "no label of its own")
        }
        let drawn = b.h.editor.paintOrder(in: CGRect(x: 0, y: 0, width: 1000, height: 400)).map(\.id)
        expect(drawn.contains(ids[0]) && !drawn.contains(ids[1]) && !drawn.contains(ids[2]), "only the lead is drawn")
        // A member's own path (row 2 of L to R) is no hit; the lead's line is.
        let ownPoint = own.levelBody?.point(at: 0.3) ?? own.middle
        expect(b.h.editor.shape(at: ownPoint) != ids[2], "a member isn't hit on its own path")
        expectEqual(b.h.editor.shape(at: lead.outline[1]), ids[0], "the lead's line is")
        expect(!b.h.editor.accessibleShapes(limit: 500).contains(ids[1]))
        expectEqual(b.h.editor.accessibleDescription(of: ids[0])?.label.hasPrefix("3 arrows"), true,
                    "said as what it draws for: \(b.h.editor.accessibleDescription(of: ids[0])?.label ?? "")")
        // ⌥Tab from the roster lists the lead once (its members are its).
        let arrowParts = b.h.editor.shapeParts(of: b.right).filter { $0.role == .connection }
        expectEqual(arrowParts.count, 1, "\(arrowParts.map(\.title))")
        // Delete takes them all, and says so, since two of them weren't seen.
        b.h.editor.selectedShapeIDs = ids
        b.h.editor.deleteSelection()
        expectEqual(b.h.editor.undoHistory.undoName, "Delete 3 Arrows")
    },
    test("a change to the members' answers (a fold opened) lays out the members only, never the lead") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers)
        let ids = (0..<3).map { b.h.add(Arrow(start: b.end(b.left, $0), end: b.end(b.right, 0))) }
        answers.answers = [ids[0]: ConnectionBundle(role: .lead(count: 3, standing: nil)),
                           ids[1]: ConnectionBundle(role: .member(lead: ids[0])), ids[2]: ConnectionBundle(role: .member(lead: ids[0]))]
        b.h.editor.connectionBundlesDidChange(Set(ids))
        for id in ids { _ = b.h.editor.shapeContext.geometry(of: id) }
        answers.asked = []
        answers.answers[ids[1]] = nil
        answers.answers[ids[2]] = nil
        b.h.editor.connectionBundlesDidChange([ids[1], ids[2]])
        for id in ids { _ = b.h.editor.shapeContext.geometry(of: id) }
        expect(Set(answers.asked) == [ids[1], ids[2]], "only the members laid out again: \(answers.asked)")
        expectEqual(b.h.editor.shapeContext.geometry(of: ids[1])?.isHidden, false, "drawn again on its own")
    },
    test("arrows with the same two ends bow apart by a slot each, their middles a slot apart; the bend handle still puts the middle where it is dragged") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers)
        let one = b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 2)))
        let two = b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 2)))
        let before = try b.geometry(one).middle
        expectEqual(try b.geometry(two).middle, before, "one path")
        answers.answers = [one: ConnectionBundle(slot: 0, slots: 2), two: ConnectionBundle(slot: 1, slots: 2)]
        b.h.editor.connectionBundlesDidChange([one, two])
        let a = try b.geometry(one), c = try b.geometry(two)
        expectClose(a.middle.distance(to: c.middle), 30, within: 0.5)  // a slot apart
        expectClose(a.middle.distance(to: before), 15, within: 0.5)  // each half a slot off the one path
        expectClose((a.middle - a.bendOrigin).dot(a.bendAxis), 0, within: 1e-6)  // the bend is measured from where the slot puts the middle
    },
    test("arrows fanned into one row come in at angles of their own, the first from above; marked, they meet the row apart; their labels slide to their starts") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers, looks: true)
        let ids = (0..<3).map { b.h.add(Arrow(start: b.end(b.left, $0), end: b.end(b.right, 1), text: "k")) }
        let plain = try ids.map { try b.geometry($0) }
        expect(plain.allSatisfy { abs($0.inward(at: .end).y) < 1e-6 }, "unfanned, every one comes in level")
        let middles = try ids.map { try require(b.h.editor.arrowLabelFrame(of: $0)) }
        for (index, id) in ids.enumerated() { answers.answers[id] = ConnectionBundle(fans: [.init(end: .end, index: index, count: 3)]) }
        b.h.editor.connectionBundlesDidChange(Set(ids))
        let fanned = try ids.map { try b.geometry($0) }
        expect(fanned[0].inward(at: .end).y < -0.2, "the first comes in from above: \(fanned[0].inward(at: .end))")
        expectClose(fanned[1].inward(at: .end).y, 0, within: 1e-6)  // the middle one level
        expect(fanned[2].inward(at: .end).y > 0.2, "the last from below")
        let ends = fanned.map(\.end.y)
        expect(ends[0] < ends[1] && ends[1] < ends[2], "marked ends meet the row apart: \(ends)")
        expect(ends.allSatisfy { abs($0 - 180) <= 10 }, "within the row: \(ends)")
        for (index, id) in ids.enumerated() {
            let label = try require(b.h.editor.arrowLabelFrame(of: id))
            expect(label.midX < middles[index].midX - 20, "slid toward its start: \(label) from \(middles[index])")
        }
    },
    test("an end at a shape as a whole comes in at the row the answer names") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers)
        let id = b.h.add(Arrow(start: b.end(b.left, 1), end: b.whole(b.right)))
        answers.answers[id] = ConnectionBundle(entries: [.end: b.rightRows[2].id])
        b.h.editor.connectionBundlesDidChange([id])
        let geometry = try b.geometry(id)
        let cubic = try require(geometry.levelBody)
        expectClose(cubic.end.y, 200, within: 0.5)  // row 2's middle, a head's gap off its left side
        expect(cubic.end.x < 500 && cubic.end.x > 480, "off row 2's left side: \(cubic.end)")
    },
])
