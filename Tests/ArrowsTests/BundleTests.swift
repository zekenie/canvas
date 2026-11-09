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
    test("an arrow bound to rows is laid out again only when what it reads changes: a commit to a shape it doesn't read leaves it kept") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers)
        let id = b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 2)))
        _ = b.h.editor.shapeContext.geometry(of: id)
        answers.asked = []
        // Another shape added and one moved: nothing the arrow's ends read.
        b.h.add(Roster(CGRect(x: 900, y: 900, width: 200, height: 80), rows: [RosterRow(name: "far")]))
        b.h.editor.transact("Move") { tx in tx.update(b.right) { $0.box = $0.box?.offsetBy(dx: 0, dy: 0) } }
        _ = b.h.editor.shapeContext.geometry(of: id)
        expectEqual(answers.asked, [], "kept: it asked its bundle again for nothing")
        // A change to a shape it reads lays it out again.
        b.h.editor.transact("Resize") { tx in tx.update(b.right) { $0.box = $0.box?.offsetBy(dx: 0, dy: 20) } }
        _ = b.h.editor.shapeContext.geometry(of: id)
        expectEqual(answers.asked, [id], "laid out again, once")
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
        // A slot apart, and a little more for their ends a slot's shift apart along the rows' sides.
        expect(a.middle.distance(to: c.middle) >= 30 && a.middle.distance(to: c.middle) < 40, "\(a.middle) and \(c.middle)")
        expect(a.start.distance(to: c.start) >= 5, "they leave the row apart: \(a.start), \(c.start)")
        expectClose((a.middle - a.bendOrigin).dot(a.bendAxis), 0, within: 1e-6)  // the bend is measured from where the slot puts the middle
    },
    test("an arrow imprecise at both ends takes no slot's bow: the later of a pair holds a bend of its own, which a slot's could cancel") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers)
        // Two arrows between the shapes as wholes, the second bent apart when it was made (`ArrowConnections.pairBend`).
        let one = b.h.add(Arrow(start: b.whole(b.left), end: b.whole(b.right)))
        let two = b.h.add(Arrow(start: b.whole(b.left), end: b.whole(b.right), bend: -34))
        let apart = try b.geometry(one).middle.distance(to: b.geometry(two).middle)
        answers.answers = [one: ConnectionBundle(slot: 0, slots: 2), two: ConnectionBundle(slot: 1, slots: 2)]
        b.h.editor.connectionBundlesDidChange([one, two])
        let after = try b.geometry(one).middle.distance(to: b.geometry(two).middle)
        expectClose(after, apart, within: 1e-6)
        expect(after >= 30, "still a pair bend apart, not cancelled to \(after)")
    },
    test("bending a slotted arrow keeps its bow: its middle is under the pointer while dragged and after the release") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers)
        let one = b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 2)))
        let two = b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 2)))
        answers.answers = [one: ConnectionBundle(slot: 0, slots: 2), two: ConnectionBundle(slot: 1, slots: 2)]
        b.h.editor.connectionBundlesDidChange([one, two])
        let first = try b.geometry(two)
        let (origin, axis) = (first.middle, first.bendAxis)
        b.h.editor.selection = two
        b.h.press(at: b.h.view(origin))
        b.h.drag(to: b.h.view(origin + axis * 8))
        b.h.drag(to: b.h.view(origin + axis * 20))
        let held = try b.geometry(two)
        expect(held.middle.distance(to: origin + axis * 20) < 1, "under the pointer while dragged: \(held.middle) against \(origin + axis * 20)")
        b.h.release()
        let after = try b.geometry(two)
        expect(after.middle.distance(to: origin + axis * 20) < 1, "and where it was let go: \(after.middle) against \(origin + axis * 20)")
    },
    test("freeing an end of a slotted arrow keeps the line where it is drawn, bowed apart from its pair") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers)
        let one = b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 2)))
        let two = b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 2)))
        answers.answers = [one: ConnectionBundle(slot: 0, slots: 2), two: ConnectionBundle(slot: 1, slots: 2)]
        b.h.editor.connectionBundlesDidChange([one, two])
        let drawn = try b.geometry(two)
        // The shape it ends at deleted: the end is let go where it is drawn.
        b.h.editor.deleteShapes([b.right])
        guard case .free(let point)? = b.arrow(two)?.end else { return expect(false, "the end is free") }
        expect(point.distance(to: drawn.visiblePoint(at: .end)) < 1e-6, "\(point) against \(drawn.visiblePoint(at: .end))")
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
    test("an end at a shape as a whole, joined to a row of a shape above it whose span overlaps, comes in at the side that row leaves by, not back along it") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers)
        // Below the left shape, from x 250 to 450: its left side is nearer the row's right side than its right is, so a line
        // aimed at the nearer side would turn back along the row's own shape.
        let rows = ["one", "two"].map { RosterRow(name: $0) }
        let below = b.h.add(Roster(CGRect(x: 250, y: 400, width: 200, height: 80), rows: rows))
        let id = b.h.add(Arrow(start: b.end(b.left, 1), end: b.whole(below)))
        answers.answers[id] = ConnectionBundle(entries: [.end: rows[0].id])
        b.h.editor.connectionBundlesDidChange([id])
        let geometry = try b.geometry(id)
        expect(geometry.inward(at: .end).x > 0, "comes in at the right side, as the row leaves by it: \(geometry.inward(at: .end))")
        let cubic = try require(geometry.levelBody)
        expect(cubic.end.x > 450, "right of the shape it enters: \(cubic.end)")
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
