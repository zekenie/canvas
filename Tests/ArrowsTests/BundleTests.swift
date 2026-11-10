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
    test("slotted lines nest at their ends whichever way they run, and at both ends of a C (review R20)") {
        // Whether two lines cross: the sign of their difference across, sampled along x between the sides, never changes.
        @MainActor func apart(_ a: ArrowGeometry, _ b: ArrowGeometry, from: CGFloat, to: CGFloat) throws -> Bool {
            let one = try require(a.levelBody).flattened(segments: 200), two = try require(b.levelBody).flattened(segments: 200)
            func y(_ points: [CGPoint], at x: CGFloat) -> CGFloat? {
                zip(points, points.dropFirst()).first { min($0.x, $1.x) <= x && x <= max($0.x, $1.x) && $0.x != $1.x }
                    .map { $0.y + ($1.y - $0.y) * (x - $0.x) / ($1.x - $0.x) }
            }
            let signs = stride(from: from + 0.5, through: to - 0.5, by: 2).compactMap { x in y(one, at: x).flatMap { a in y(two, at: x).map { a - $0 } } }
            return signs.allSatisfy { $0 > 0 } || signs.allSatisfy { $0 < 0 }
        }
        let answers = BundleAnswers()
        let b = try bundleBoard(answers)
        // Right to left: from R's row 1 to L's row 1.
        let one = b.h.add(Arrow(start: b.end(b.right, 1), end: b.end(b.left, 1)))
        let two = b.h.add(Arrow(start: b.end(b.right, 1), end: b.end(b.left, 1)))
        answers.answers = [one: ConnectionBundle(slot: 0, slots: 2), two: ConnectionBundle(slot: 1, slots: 2)]
        b.h.editor.connectionBundlesDidChange([one, two])
        expect(try apart(b.geometry(one), b.geometry(two), from: 300, to: 500), "right to left, they cross")
        // A C: a roster stacked below L, both rows leaving its right side.
        let rows = [RosterRow(name: "low")]
        let below = b.h.add(Roster(CGRect(x: 100, y: 400, width: 200, height: 40), rows: rows))
        let low = ArrowTerminal.bound(ArrowBinding(shapeID: below, normalizedAnchor: CGPoint(x: 1, y: 0.5), isPrecise: true, isExact: true, part: rows[0].id))
        let c1 = b.h.add(Arrow(start: b.end(b.left, 1), end: low)), c2 = b.h.add(Arrow(start: b.end(b.left, 1), end: low))
        answers.answers[c1] = ConnectionBundle(slot: 0, slots: 2)
        answers.answers[c2] = ConnectionBundle(slot: 1, slots: 2)
        b.h.editor.connectionBundlesDidChange([c1, c2])
        let (g1, g2) = (try b.geometry(c1), try b.geometry(c2))
        let reach1 = try require(g1.levelBody).bounds.maxX, reach2 = try require(g2.levelBody).bounds.maxX
        let (outer, inner) = reach1 > reach2 ? (g1, g2) : (g2, g1)
        expect(outer.start.y < inner.start.y, "the outer loop's top end above the inner's: \(outer.start), \(inner.start)")
        expect(outer.end.y > inner.end.y, "and its bottom end below: \(outer.end), \(inner.end)")
    },
    test("an arrow bound to shapes as wholes keeps no slot's bow when a move makes its ends precise (review R39)") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers)
        let one = b.h.add(Arrow(start: b.whole(b.left), end: b.whole(b.right)))
        let two = b.h.add(Arrow(start: b.whole(b.left), end: b.whole(b.right), bend: -34))
        answers.answers = [one: ConnectionBundle(slot: 0, slots: 2), two: ConnectionBundle(slot: 1, slots: 2)]
        b.h.editor.connectionBundlesDidChange([one, two])
        let before = try b.geometry(two).middle
        // What a nudge or a move alone writes first: its ends made precise where they are.
        b.h.editor.transact("Move") { $0.update(two, as: Arrow.self) { arrow in
            for end in [ArrowEnd.start, .end] { if var binding = arrow.props[end].binding { binding.isPrecise = true; arrow.props[end] = .bound(binding) } }
        } }
        expectClose(try b.geometry(two).middle, before, within: 1e-6)
    },
    test("two connections made at the sides of two shapes (precise, straight, bound as wholes) take their slots' bows, drawn apart, not on one line (review U9-C3)") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers)
        func side(_ id: ShapeID, x: CGFloat) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: x, y: 0.5), isPrecise: true, isExact: false))
        }
        let one = b.h.add(Arrow(start: side(b.left, x: 1), end: side(b.right, x: 0)))
        let two = b.h.add(Arrow(start: side(b.left, x: 1), end: side(b.right, x: 0)))
        answers.answers = [one: ConnectionBundle(slot: 0, slots: 2), two: ConnectionBundle(slot: 1, slots: 2)]
        b.h.editor.connectionBundlesDidChange([one, two])
        let (first, second) = (try b.geometry(one).middle, try b.geometry(two).middle)
        expect(first.distance(to: second) > 10, "drawn apart: \(first), \(second)")
    },
    test("a fanned arrow's label is edited where it is drawn, slid toward its start (review R22)") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers)
        let ids = (0..<2).map { b.h.add(Arrow(start: b.end(b.left, $0), end: b.end(b.right, 1), text: "k")) }
        for (index, id) in ids.enumerated() { answers.answers[id] = ConnectionBundle(fans: [.init(end: .end, index: index, count: 2)]) }
        b.h.editor.connectionBundlesDidChange(Set(ids))
        let label = try require(b.h.editor.arrowLabelFrame(of: ids[0]))
        b.h.editor.selection = ids[0]
        expect(b.h.key("\r"))
        expectEqual(b.h.editor.editingShapeID, ids[0])
        let editing = try require(b.h.editor.editingFrame)
        expect(abs(editing.midX - label.midX) < 4, "the editor over the label at \(label), not halfway: \(editing)")
    },
    test("one row's arrows to two places, slid toward the row by fans at their far ends, stack their pills in the row's band, each on its own line (UX walk 4 evolve-1)") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers)
        let ids = [b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 0), text: "first")),
                   b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 2), text: "second"))]
        // The second's far end is farther below the row (140): it stacks first, nearest the row.
        for (index, id) in ids.enumerated() {
            answers.answers[id] = ConnectionBundle(fans: [.init(end: .end, index: 0, count: 2)], parting: .init(end: .start, index: index, count: 2),
                                                   parted: [ids[1], ids[0]])
        }
        b.h.editor.connectionBundlesDidChange(Set(ids))
        let labels = try ids.map { try require(b.h.editor.arrowLabelFrame(of: $0)) }
        expect(!labels[0].intersects(labels[1]), "apart: \(labels)")
        expect(labels[1].midX < labels[0].midX, "the stack's first nearest the row: \(labels)")
        // Each level with the row (126.7 to 153.3), never out along its line into another row's.
        for label in labels { expect(label.midY > 100 + 80.0 / 3 && label.midY < 100 + 160.0 / 3, "in the row's band: \(label)") }
        // Their lines leave the row apart, top to bottom as their far ends are, and each runs straight past its pill.
        let geometries = try ids.map { try b.geometry($0) }
        // Inside the row's inner band (a quarter of its 26.7 either way) and its pills' room: 10 apart.
        expect(geometries[0].start.y < geometries[1].start.y - 8, "apart along the row's side: \(geometries.map(\.start))")
        for (geometry, label) in zip(geometries, labels) {
            expect(abs(geometry.point(label.maxX - 300 + 2, along: .start).point.y - geometry.start.y) < 1e-6, "straight past its pill: \(label)")
        }
    },
    test("a pill laid along its line moves out along it, clear of the other lines leaving its row (UX walk 3 connect-4)") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers)
        // Far below and right: its line leaves the row level and turns down under the other's pill, halfway to R's row 2.
        let below = b.h.add(Roster(CGRect(x: 700, y: 460, width: 200, height: 80), rows: [RosterRow(name: "one")]))
        let low = try require(b.h.editor.document[below]?.typed(as: Roster.self)?.props.rows[0].id)
        let lowEnd = ArrowTerminal.bound(ArrowBinding(shapeID: below, normalizedAnchor: CGPoint(x: 0, y: 0.5), isPrecise: true, isExact: true, part: low))
        let ids = [b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, 1), text: "label")),
                   b.h.add(Arrow(start: b.end(b.left, 1), end: lowEnd))]
        let before = try require(b.h.editor.arrowLabelFrame(of: ids[0]))
        for (index, id) in ids.enumerated() { answers.answers[id] = ConnectionBundle(parting: .init(end: .start, index: index, count: 2), parted: ids) }
        b.h.editor.connectionBundlesDidChange(Set(ids))
        let after = try require(b.h.editor.arrowLabelFrame(of: ids[0]))
        let other = try b.geometry(ids[1])
        expect(other.crosses(before.polygon), "halfway, the other line ran under it: \(before)")
        expect(!other.crosses(after.insetBy(dx: -2, dy: -2).polygon), "out along its line, clear of it: \(after)")
        expect(after.midX > before.midX, "away from the row: \(before) to \(after)")
        expect(try b.geometry(ids[0]).distance(to: CGPoint(x: after.midX, y: after.midY)) < 1, "still on its own line")
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
    test("arrows fanned into one row come in at angles of their own, the first from above; marked, they meet the row apart and level and stay level-shaped, each further one's marks further out where the row is short; their labels slide to their starts") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers, looks: true)
        let ids = (0..<3).map { b.h.add(Arrow(start: b.end(b.left, $0), end: b.end(b.right, 1), text: "k")) }
        let plain = try ids.map { try b.geometry($0) }
        expect(plain.allSatisfy { abs($0.inward(at: .end).y) < 1e-6 }, "unfanned, every one comes in level")
        let middles = try ids.map { try require(b.h.editor.arrowLabelFrame(of: $0)) }
        for (index, id) in ids.enumerated() { answers.answers[id] = ConnectionBundle(fans: [.init(end: .end, index: index, count: 3)]) }
        b.h.editor.connectionBundlesDidChange(Set(ids))
        let fanned = try ids.map { try b.geometry($0) }
        // Marked, each comes in level where its mark is (UX walk 3 tables-2: a fan tilted the bars), and its curve leaves its stub
        // level too (UX walk 4 tables-1: a turn after the stub made two keys' middles different shapes, and they crossed twice).
        expect(fanned.allSatisfy { abs($0.inward(at: .end).y) < 1e-6 }, "level at the row: \(fanned.map { $0.inward(at: .end) })")
        for geometry in fanned {
            guard case .level(let cubic, _, _) = geometry.path else { return expect(false, "level: \(geometry.path)") }
            expect(abs(cubic.end.y - cubic.control2.y) < 1e-6, "its curve leaves the stub level: \(cubic)")
        }
        let ends = fanned.map(\.end.y)
        expect(ends[0] < ends[1] && ends[1] < ends[2], "marked ends meet the row apart: \(ends)")
        // Three into one row: each in a third of it (its part, 20 tall: UX walk 4 tables-2), short of two bars' spacing (48), so the
        // middle one's marks stand a stub further out.
        let part = try require(b.h.editor.shapeContext.geometry(of: b.right)?.parts.frame(b.rightRows[1].id)?.rect)
        expectClose(ends[2] - ends[0], part.height * 2 / 3, within: 1e-6)
        expect(ends.allSatisfy { $0 > part.minY + 1 && $0 < part.maxY - 1 }, "inside the row: \(ends) in \(part)")
        let stubs = fanned.map { geometry -> CGFloat in
            guard case .level(let cubic, _, _) = geometry.path else { return 0 }
            return geometry.end.x - cubic.end.x
        }
        // Their lines run on up to the rows above (L is above R's row): each stub 30 past the one before it, the lower ones longer, so the
        // line that turns first never crosses the longer stub of the one below it (review U12-C2).
        expectClose(stubs[0], 36, within: 1e-6)
        expectClose(stubs[1], 66, within: 1e-6)
        expectClose(stubs[2], 96, within: 1e-6)
        for (index, id) in ids.enumerated() {
            let label = try require(b.h.editor.arrowLabelFrame(of: id))
            expect(label.midX < middles[index].midX - 20, "slid toward its start: \(label) from \(middles[index])")
        }
    },
    test("two keys fanned into one row, their marks staggered, never cross, whether their lines turn down or up to the other table (review U12-C2)") {
        for down in [false, true] {
            let answers = BundleAnswers()
            let b = try bundleBoard(answers, looks: true)
            // Down: into L's row 0 from R's rows 1 and 2, below it; up: into R's row 2 from L's rows 0 and 1, above it.
            let ids = down ? [1, 2].map { b.h.add(Arrow(start: b.end(b.right, $0), end: b.end(b.left, 0))) }
                           : [0, 1].map { b.h.add(Arrow(start: b.end(b.left, $0), end: b.end(b.right, 2))) }
            for (index, id) in ids.enumerated() { answers.answers[id] = ConnectionBundle(fans: [.init(end: .end, index: index, count: 2)]) }
            b.h.editor.connectionBundlesDidChange(Set(ids))
            let geometries = try ids.map { try b.geometry($0) }
            let offsets = geometries.map(\.markOffset.end)
            expectEqual(offsets.filter { $0 > 0 }.count, 1, "one of two stands its marks further out (\(down ? "down" : "up")): \(offsets)")
            // The one whose line runs on past the other's is the longer: the upper going down, the lower going up.
            expect(down ? offsets[0] > 0 : offsets[1] > 0, "the longer stub is the one the other's line turns away from: \(offsets)")
            expectEqual(arrowCrossings(try require(geometries[0].levelBody), try require(geometries[1].levelBody)), 0, "their lines never cross (\(down ? "down" : "up"))")
        }
    },
    test("four connections parting from one short row leave it on four points, in order, however little room the row has (review U12-C3)") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers)
        let ids = [0, 1, 2, 0].map { b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, $0))) }
        for (index, id) in ids.enumerated() { answers.answers[id] = ConnectionBundle(parting: .init(end: .start, index: index, count: 4), parted: ids) }
        b.h.editor.connectionBundlesDidChange(Set(ids))
        let starts = try ids.map { try b.geometry($0).start.y }
        let row = try require(b.h.editor.shapeContext.geometry(of: b.left)?.parts.frame(b.leftRows[1].id)?.rect)
        for (a, c) in zip(starts, starts.dropFirst()) { expect(c > a + 2, "four distinct points, top to bottom: \(starts)") }
        expect(starts.allSatisfy { $0 > row.minY && $0 < row.maxY }, "inside the row: \(starts) in \(row)")
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
    test("two keys fanned into a row too short to hold their bars a bar's height and a gap apart stand one's marks past the other's (UX walk 4 tables-2)") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers, looks: true)
        // R's row 1, 20 tall: short of the 24 two bars need (the kit's rows are 24: short too).
        let ids = (0..<2).map { b.h.add(Arrow(start: b.end(b.left, $0), end: b.end(b.right, 1))) }
        for (index, id) in ids.enumerated() { answers.answers[id] = ConnectionBundle(fans: [.init(end: .end, index: index, count: 2)]) }
        b.h.editor.connectionBundlesDidChange(Set(ids))
        let geometries = try ids.map { try b.geometry($0) }
        // Each in a half of the row, at its middle: 10 apart.
        expectClose(abs(geometries[1].end.y - geometries[0].end.y), 10, within: 1e-6)
        expectEqual(geometries.map(\.markOffset.end), [0, 30], "the second's marks a mark further out")
        // Each key's bars ("one" at its end: 12 and 17.5 out from its offset, 9 either side of its line), where they are drawn.
        let bars = geometries.map { geometry in [12, 17.5].map { geometry.point($0 + geometry.markOffset.end, along: .end).point } }
        for p in bars[0] { for q in bars[1] where abs(p.x - q.x) < 4 { expect(abs(p.y - q.y) > 18 + 2.5, "no bars cross: \(bars)") } }
        expect(bars.joined().allSatisfy { $0.y > 160 && $0.y < 200 }, "both at the row (160 to 200 with its neighbors' halves): \(bars)")
        expect(bars[1].allSatisfy { q in bars[0].allSatisfy { abs($0.x - q.x) >= 10 } }, "past the first's: \(bars)")
        // Still level where they are.
        for geometry in geometries { expect(abs(geometry.point(17.5 + geometry.markOffset.end, along: .end).inward.y) < 1e-6, "level") }
    },
    test("a row's only pill, slid to it by a fan at its far end, sits in its row's band on a level stub, the far table well above or well below (UX walk 5 evolve-1)") {
        for below in [false, true] {
            let answers = BundleAnswers()
            let b = try bundleBoard(answers)
            // L's rows 0 and 2 (100 to 126.7, 153.3 to 180) into one row of a table far above or below: fanned there, each pill slid to its row.
            let far = b.h.add(Roster(CGRect(x: 700, y: below ? 600 : -400, width: 200, height: 80), rows: [RosterRow(name: "one")]))
            let farRow = try require(b.h.editor.document[far]?.typed(as: Roster.self)?.props.rows[0].id)
            let farEnd = ArrowTerminal.bound(ArrowBinding(shapeID: far, normalizedAnchor: CGPoint(x: 0, y: 0.5), isPrecise: true, isExact: true, part: farRow))
            let rows = [0, 2]
            let ids = rows.map { b.h.add(Arrow(start: b.end(b.left, $0), end: farEnd, text: "label")) }
            for (index, id) in ids.enumerated() { answers.answers[id] = ConnectionBundle(fans: [.init(end: .end, index: index, count: 2)]) }
            b.h.editor.connectionBundlesDidChange(Set(ids))
            for (row, id) in zip(rows, ids) {
                let band = (100 + 80.0 / 3 * CGFloat(row))...(100 + 80.0 / 3 * CGFloat(row + 1))
                let label = try require(b.h.editor.arrowLabelFrame(of: id))
                let geometry = try b.geometry(id)
                expect(band.contains(label.midY), "row \(row)'s pill in its band \(band) (\(below ? "below" : "above")): \(label)")
                expect(band.contains(geometry.start.y), "its line leaves its own row: \(geometry.start)")
                expect(abs(geometry.point(label.maxX - geometry.start.x + 2, along: .start).point.y - geometry.start.y) < 1e-6,
                       "straight past its pill, turning only after it (\(below ? "below" : "above")): \(label)")
            }
        }
    },
    test("three connections parting from one row leave it inside its inner band, a quarter of the row either way of its middle, never near its edges (UX walk 5 connect-1)") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers)
        let ids = [0, 1, 2].map { b.h.add(Arrow(start: b.end(b.left, 1), end: b.end(b.right, $0))) }
        for (index, id) in ids.enumerated() { answers.answers[id] = ConnectionBundle(parting: .init(end: .start, index: index, count: 3), parted: ids) }
        b.h.editor.connectionBundlesDidChange(Set(ids))
        let row = try require(b.h.editor.shapeContext.geometry(of: b.left)?.parts.frame(b.leftRows[1].id)?.rect)
        let starts = try ids.map { try b.geometry($0).start.y }
        for (a, c) in zip(starts, starts.dropFirst()) { expect(c > a + 4, "apart, top to bottom: \(starts)") }
        for y in starts { expect(abs(y - row.midY) <= row.height * 0.25 + 1e-6, "inside the inner band: \(y) in \(row)") }
    },
    test("keys in a narrow gap turn past every key's marks at either side, never through a circle, and two keys into one row stand their bars in columns of their own (UX walk 5 tables-1)") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers, looks: true)
        // customers and orders 75 apart, rows 24 tall, as the walk's: orders' customer_id (nullable) and shipping into customers.id,
        // billing (nullable) into customers.email between them.
        let customers = b.h.add(Roster(CGRect(x: 100, y: 400, width: 200, height: 120), rows: ["id", "email", "name", "a", "b"].map { RosterRow(name: $0) }))
        let orders = b.h.add(Roster(CGRect(x: 375, y: 400, width: 200, height: 144),
                                    rows: ["id", "total", "null customer", "status", "null billing", "shipping"].map { RosterRow(name: $0) }))
        @MainActor func end(_ shape: ShapeID, _ index: Int) throws -> ArrowTerminal {
            let row = try require(b.h.editor.document[shape]?.typed(as: Roster.self)?.props.rows[index].id)
            return .bound(ArrowBinding(shapeID: shape, normalizedAnchor: CGPoint(x: 0, y: 0.5), isPrecise: true, isExact: true, part: row))
        }
        let customer = b.h.add(Arrow(start: try end(orders, 2), end: try end(customers, 0)))
        let billing = b.h.add(Arrow(start: try end(orders, 4), end: try end(customers, 1)))
        let shipping = b.h.add(Arrow(start: try end(orders, 5), end: try end(customers, 0)))
        let run = [customer, billing, shipping]
        // As LineRows says them: every key's crow's foot at orders, and at customers bars and circles, one of the fan at an odd place.
        let marks: [ConnectionBundle.End: ConnectionBundle.RunMarks] = [.start: .init(marks: [.many]), .end: .init(marks: [.zeroOrOne, .one], nudges: 1)]
        answers.answers[customer] = ConnectionBundle(fans: [.init(end: .end, index: 0, count: 2)], run: .init(end: .start, index: 0, count: 3), runMarks: marks)
        answers.answers[billing] = ConnectionBundle(run: .init(end: .start, index: 1, count: 3), runMarks: marks)
        answers.answers[shipping] = ConnectionBundle(fans: [.init(end: .end, index: 1, count: 2)], run: .init(end: .start, index: 2, count: 3), runMarks: marks)
        b.h.editor.connectionBundlesDidChange(Set(run))
        let geometries = try run.map { try b.geometry($0) }
        // Each circle (25 out from its offset, radius 5) clear of every other line by their half strokes and a point.
        for index in [0, 1] {
            let owner = geometries[index]
            let centre = owner.point(25 + owner.markOffset.end, along: .end).point
            for (other, geometry) in geometries.enumerated() where other != index {
                let line = try require(geometry.levelBody)
                expect(line.distance(to: centre) > 5 + 2.5 + 1, "line \(other) clear of line \(index)'s circle at \(centre): \(line.distance(to: centre))")
            }
        }
        // At customers.id the two keys' bars (12, and 17.5 for shipping's "one", out from each one's offset) are never in one column.
        let near = [12].map { geometries[0].point($0 + geometries[0].markOffset.end, along: .end).point }
        let theirs = [12, 17.5].map { geometries[2].point($0 + geometries[2].markOffset.end, along: .end).point }
        for p in near { for q in theirs { expect(abs(p.x - q.x) >= 4, "bars in columns of their own: \(near) and \(theirs)") } }
        expectEqual(arrowCrossings(try require(geometries[0].levelBody), try require(geometries[1].levelBody)), 0, "in order: never cross")
        expectEqual(arrowCrossings(try require(geometries[1].levelBody), try require(geometries[2].levelBody)), 1, "swapped: once")
    },
])

@MainActor let narrowRunTests = Suite("Keys in a narrow gap, further", [
    test("however narrow the gap, the keys' turn columns stay a stroke and a gap apart, never one column (review U13-E1)") {
        for gap in [50, 65, 75, 120] as [CGFloat] {
            let answers = BundleAnswers()
            let b = try bundleBoard(answers, looks: true)
            let customers = b.h.add(Roster(CGRect(x: 100, y: 400, width: 200, height: 120), rows: ["id", "email", "name", "a", "b"].map { RosterRow(name: $0) }))
            let orders = b.h.add(Roster(CGRect(x: 300 + gap, y: 400, width: 200, height: 144),
                                        rows: ["id", "total", "null customer", "status", "null billing", "shipping"].map { RosterRow(name: $0) }))
            @MainActor func end(_ shape: ShapeID, _ index: Int) throws -> ArrowTerminal {
                let row = try require(b.h.editor.document[shape]?.typed(as: Roster.self)?.props.rows[index].id)
                return .bound(ArrowBinding(shapeID: shape, normalizedAnchor: CGPoint(x: 0, y: 0.5), isPrecise: true, isExact: true, part: row))
            }
            let run = try [(2, 0), (4, 1), (5, 0)].map { b.h.add(Arrow(start: try end(orders, $0.0), end: try end(customers, $0.1))) }
            let marks: [ConnectionBundle.End: ConnectionBundle.RunMarks] = [.start: .init(marks: [.many]), .end: .init(marks: [.zeroOrOne, .one], nudges: 1)]
            answers.answers[run[0]] = ConnectionBundle(fans: [.init(end: .end, index: 0, count: 2)], run: .init(end: .start, index: 0, count: 3), runMarks: marks)
            answers.answers[run[1]] = ConnectionBundle(run: .init(end: .start, index: 1, count: 3), runMarks: marks)
            answers.answers[run[2]] = ConnectionBundle(fans: [.init(end: .end, index: 1, count: 2)], run: .init(end: .start, index: 2, count: 3), runMarks: marks)
            b.h.editor.connectionBundlesDidChange(Set(run))
            // Where each runs upright: its x where it is half way between its ends' heights.
            let columns: [CGFloat] = try run.map { id in
                let geometry = try b.geometry(id), line = try require(geometry.levelBody).flattened(segments: 400)
                let middle = (geometry.start.y + geometry.end.y) / 2
                return try require(line.min { abs($0.y - middle) < abs($1.y - middle) }).x
            }
            for (i, x) in columns.enumerated() { for y in columns[(i + 1)...] { expect(abs(x - y) >= 3.5, "gap \(gap): turn columns apart (a stroke is 2.5; sampled at the middle height of S curves, 5 by design): \(columns)") } }
        }
    },
    test("three keys fanned into one row too short to stagger stand their bars each in a column of its own (review U13-E2)") {
        let answers = BundleAnswers()
        let b = try bundleBoard(answers, looks: true)
        let customers = b.h.add(Roster(CGRect(x: 100, y: 400, width: 200, height: 120), rows: ["id", "email", "name", "a", "b"].map { RosterRow(name: $0) }))
        let orders = b.h.add(Roster(CGRect(x: 375, y: 400, width: 200, height: 144),
                                    rows: ["id", "total", "customer", "status", "billing", "shipping"].map { RosterRow(name: $0) }))
        @MainActor func end(_ shape: ShapeID, _ index: Int) throws -> ArrowTerminal {
            let row = try require(b.h.editor.document[shape]?.typed(as: Roster.self)?.props.rows[index].id)
            return .bound(ArrowBinding(shapeID: shape, normalizedAnchor: CGPoint(x: 0, y: 0.5), isPrecise: true, isExact: true, part: row))
        }
        let run = try [2, 4, 5].map { b.h.add(Arrow(start: try end(orders, $0), end: try end(customers, 0))) }
        let marks: [ConnectionBundle.End: ConnectionBundle.RunMarks] = [.start: .init(marks: [.many]), .end: .init(marks: [.one], nudges: 2)]
        for (index, id) in run.enumerated() {
            answers.answers[id] = ConnectionBundle(fans: [.init(end: .end, index: index, count: 3)], run: .init(end: .start, index: index, count: 3), runMarks: marks)
        }
        b.h.editor.connectionBundlesDidChange(Set(run))
        let bars = try run.map { id -> CGPoint in
            let geometry = try b.geometry(id)
            return geometry.point(12 + geometry.markOffset.end, along: .end).point
        }
        for (i, p) in bars.enumerated() { for q in bars[(i + 1)...] { expect(abs(p.x - q.x) >= 4, "bars in columns of their own: \(bars)") } }
    },
])

/// How many times two lines cross, by their flattened segments.
private func arrowCrossings(_ a: CubicChain, _ b: CubicChain) -> Int {
    let p = a.flattened(segments: 160), q = b.flattened(segments: 160)
    func cross(_ o: CGPoint, _ u: CGPoint, _ v: CGPoint) -> CGFloat { (u.x - o.x) * (v.y - o.y) - (u.y - o.y) * (v.x - o.x) }
    var count = 0
    for i in 1..<p.count {
        for j in 1..<q.count {
            let (a1, a2, b1, b2) = (p[i - 1], p[i], q[j - 1], q[j])
            let d1 = cross(b1, b2, a1), d2 = cross(b1, b2, a2), d3 = cross(a1, a2, b1), d4 = cross(a1, a2, b2)
            if (d1 > 0) != (d2 > 0), (d3 > 0) != (d4 > 0), d1 != 0, d2 != 0, d3 != 0, d4 != 0 { count += 1 }
        }
    }
    return count
}
