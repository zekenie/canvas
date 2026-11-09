import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// An arrow's end bound to a part (a row): `ArrowBinding.part`, drawn at the row's side facing the other end, unclipped; a
// part the geometry doesn't list at the stored anchor; re-aimed onto a roster, the row under the pointer, lit as the hint's
// part; a lone move keeping it; and its keys: ↑ ↓ step it a row ("Move Arrow End"), VoiceOver names the row. Rosters
// (CanvasTesting) stand in for tables: arrows know no kind.

/// Two rosters, L at the left and R at the right, three rows each (`one`, `two`, `three`), rows 20 apart under a 10-unit head.
@MainActor struct RosterBoard {
    let h: EditorHarness
    let left: ShapeID
    let right: ShapeID
    let leftRows: [RosterRow]
    let rightRows: [RosterRow]
    static let leftFrame = CGRect(x: 100, y: 100, width: 200, height: 80)
    static let rightFrame = CGRect(x: 500, y: 140, width: 200, height: 80)

    init() throws {
        // Ends on a roster bind a row of it (as the arrow ports' rule says for a channel on a kind's rows).
        let rule = Contributor(id: "roster-rows") { registrar in
            registrar.arrowPartRule { $0.shape.kind == Roster.kind }
        }
        h = try EditorHarness(plugins: arrowsPlugins(before: [RostersPlugin()], more: [rule]))
        leftRows = ["one", "two", "three"].map { RosterRow(name: $0) }
        rightRows = ["one", "two", "three"].map { RosterRow(name: $0) }
        left = h.add(Roster(Self.leftFrame, rows: leftRows))
        right = h.add(Roster(Self.rightFrame, rows: rightRows))
    }

    /// The middle of row `index` of a roster at `frame`, across.
    static func rowMiddle(_ index: Int, in frame: CGRect) -> CGFloat { frame.minY + Roster.head + Roster.rowHeight * (CGFloat(index) + 0.5) }

    /// An end bound to row `index` of `shape`.
    func end(_ shape: ShapeID, _ index: Int) -> ArrowTerminal {
        let rows = shape == left ? leftRows : rightRows
        return .bound(ArrowBinding(shapeID: shape, normalizedAnchor: CGPoint(x: 1, y: 0.5), isPrecise: true, isExact: true, part: rows[index].id))
    }

    func arrow(_ id: ShapeID) -> Arrow? { h.editor.document[id]?.typed(as: Arrow.self)?.props }
}

/// Half an arrow's stroke, which its head's gap from an outline adds (`ArrowGeometry`'s clipping).
private enum ArrowStyleWidth { static let half: CGFloat = 1.75 }

@MainActor let partBindingTests = Suite("An arrow's end bound to a row", [
    test("a row named on a binding to a shape that lists no rows (a pill for a table) is ignored by geometry: the end meets the shape as a whole, kept for Topology") {
        let b = try RosterBoard()
        let pill = b.h.add(Box(CGRect(x: 600, y: 400, width: 120, height: 40)))
        // As a move re-points a key's far end to a pill: the row's anchor (its right side, exact) and its part kept.
        let through = b.h.add(Arrow(start: b.end(b.left, 1), end: .bound(ArrowBinding(shapeID: pill, normalizedAnchor: CGPoint(x: 1, y: 0.5),
                                                                                       isPrecise: true, isExact: true, part: b.rightRows[2].id))))
        let whole = b.h.add(Arrow(start: b.end(b.left, 1), end: .bound(ArrowBinding(shapeID: pill, normalizedAnchor: CGPoint(x: 0.5, y: 0.5),
                                                                                     isPrecise: false, isExact: false))))
        let geometry = try require(b.h.editor.arrowGeometry(of: through)), plain = try require(b.h.editor.arrowGeometry(of: whole))
        expectEqual(geometry.endHandle, CGPoint(x: 660, y: 420), "the pill's middle, whatever anchor the binding kept")
        expectEqual(geometry.end, plain.end, "drawn as an end bound to the pill as a whole")
        expectEqual(geometry.partSide(at: .end), nil, "no row side on the pill")
        expectEqual(b.arrow(through)?.end.binding?.part, b.rightRows[2].id, "the row stays on the binding")
    },
    test("a row's end is at the middle of the row's side facing the other end, unclipped, and flips as the far end crosses") {
        let b = try RosterBoard()
        let id = b.h.add(Arrow(start: b.end(b.left, 1), end: .free(CGPoint(x: 800, y: 400))))
        var geometry = try require(b.h.editor.arrowGeometry(of: id))
        let middle = RosterBoard.rowMiddle(1, in: RosterBoard.leftFrame)
        expectEqual(geometry.startHandle, CGPoint(x: 300, y: middle))
        expectEqual(geometry.start, CGPoint(x: 300, y: middle), "it isn't clipped: it starts where the side is")
        expectEqual(geometry.partSide(at: .start), .right)
        expectEqual(geometry.partSide(at: .start)?.normal, CGPoint(x: 1, y: 0))
        expectEqual(geometry.partSide(at: .end), nil)
        b.h.editor.transact { $0.update(id, as: Arrow.self) { $0.props.end = .free(CGPoint(x: 20, y: 400)) } }
        geometry = try require(b.h.editor.arrowGeometry(of: id))
        expectEqual(geometry.startHandle, CGPoint(x: 100, y: middle), "the far end crossed to the left: so does the end")
        expectEqual(geometry.partSide(at: .start), .left)
    },
    test("two row ends face each other's rows' middles; a key between rows of one roster is on its right at both ends") {
        let b = try RosterBoard()
        let key = b.h.add(Arrow(start: b.end(b.left, 0), end: b.end(b.right, 2)))
        let geometry = try require(b.h.editor.arrowGeometry(of: key))
        expectEqual(geometry.startHandle, CGPoint(x: 300, y: RosterBoard.rowMiddle(0, in: RosterBoard.leftFrame)))
        expectEqual(geometry.endHandle, CGPoint(x: 500, y: RosterBoard.rowMiddle(2, in: RosterBoard.rightFrame)))
        let tie = b.h.add(Arrow(start: b.end(b.left, 0), end: b.end(b.left, 2)))
        let tied = try require(b.h.editor.arrowGeometry(of: tie))
        expectEqual(tied.startHandle.x, 300)
        expectEqual(tied.endHandle.x, 300)
        expectEqual([tied.partSide(at: .start), tied.partSide(at: .end)], [.right, .right])
    },
    test("rows one above the other leave one side, whatever their middles: a roster made wider as a row is typed flips no end") {
        let b = try RosterBoard()
        // R moved under L, as stacked tables are: their spans across overlap, so both ends leave the right.
        b.h.editor.transact { $0.update(b.right, as: Roster.self) { $0.props.frame = CGRect(x: 100, y: 300, width: 200, height: 80) } }
        let key = b.h.add(Arrow(start: b.end(b.left, 0), end: b.end(b.right, 2)))
        var geometry = try require(b.h.editor.arrowGeometry(of: key))
        expectEqual([geometry.partSide(at: .start), geometry.partSide(at: .end)], [.right, .right], "stacked, middles tied")
        // R wider (as a line typed wider than the card lays it out), its middle past L's: still both on the right.
        b.h.editor.transact { $0.update(b.right, as: Roster.self) { $0.props.frame = CGRect(x: 100, y: 300, width: 260, height: 80) } }
        geometry = try require(b.h.editor.arrowGeometry(of: key))
        expectEqual([geometry.partSide(at: .start), geometry.partSide(at: .end)], [.right, .right], "the middles untied: no flip across a roster")
        expectEqual(geometry.endHandle.x, 360, "at the wider roster's right edge")
        // Moved apart side by side again, each faces the other.
        b.h.editor.transact { $0.update(b.right, as: Roster.self) { $0.props.frame = CGRect(x: 500, y: 300, width: 200, height: 80) } }
        geometry = try require(b.h.editor.arrowGeometry(of: key))
        expectEqual([geometry.partSide(at: .start), geometry.partSide(at: .end)], [.right, .left])
    },
    test("tables side by side keep both ends facing each other while a line is typed wider than the gap: sides come from the boxes at rest, never a row's laid-out line") {
        let left = ShapeID(), right = ShapeID(), leftRow = PartID(), rightRow = PartID()
        let restLeft = CGRect(x: 0, y: 0, width: 200, height: 80), restRight = CGRect(x: 280, y: 0, width: 200, height: 80)
        func shape(_ id: ShapeID, rest: CGRect, laid: CGRect, row: PartID) -> ConnectableShape {
            ConnectableShape(id: id, outline: laid.polygon, bounds: laid, restBounds: rest,
                             parts: PartFrames([PartFrame(id: row, rect: CGRect(x: laid.minX, y: laid.minY + 10, width: laid.width, height: 20), isShown: true)]))
        }
        let key = Arrow(start: .bound(ArrowBinding(shapeID: left, normalizedAnchor: CGPoint(x: 1, y: 0.5), isPrecise: true, isExact: true, part: leftRow)),
                        end: .bound(ArrowBinding(shapeID: right, normalizedAnchor: CGPoint(x: 0, y: 0.5), isPrecise: true, isExact: true, part: rightRow)))
        // The left table laid out 340 wide as a long line is typed (reaching past the right one's left edge, 280), then back at rest.
        for laidLeft in [restLeft, CGRect(x: 0, y: 0, width: 340, height: 80), CGRect(x: 0, y: 0, width: 520, height: 80)] {
            let shapes = [left: shape(left, rest: restLeft, laid: laidLeft, row: leftRow), right: shape(right, rest: restRight, laid: restRight, row: rightRow)]
            let geometry = ArrowGeometry(arrow: key, strokeWidth: 3.5) { shapes[$0] }
            expectEqual([geometry.partSide(at: .start), geometry.partSide(at: .end)], [.right, .left], "laid out \(laidLeft.width) wide: still facing")
        }
    },
    test("a key between rosters in two corrals, or from a free roster to one in a corral, is painted just above the corral of the higher end, under the rosters, so no corral hides its end") {
        let rule = Contributor(id: "roster-rows") { registrar in registrar.arrowPartRule { $0.shape.kind == Roster.kind } }
        let h = try EditorHarness(plugins: arrowsPlugins(before: [RostersPlugin(), CorralsPlugin()], more: [rule]))
        @MainActor func roster(_ x: CGFloat, in corral: ShapeID?) -> (id: ShapeID, row: PartID) {
            let row = RosterRow(name: "one")
            let id = h.add(Roster(CGRect(x: x + 20, y: 40, width: 160, height: 60), rows: [row]))
            if let corral { h.editor.transact { $0.setContainer(id, to: corral) } }
            return (id, row.id)
        }
        @MainActor func key(_ a: (id: ShapeID, row: PartID), _ b: (id: ShapeID, row: PartID)) -> ShapeID {
            func end(_ r: (id: ShapeID, row: PartID)) -> ArrowTerminal {
                .bound(ArrowBinding(shapeID: r.id, normalizedAnchor: CGPoint(x: 1, y: 0.5), isPrecise: true, isExact: true, part: r.row))
            }
            return h.add(Arrow(start: end(a), end: end(b)))
        }
        let first = h.add(Corral(CGRect(x: 0, y: 0, width: 200, height: 140)))
        let a = roster(0, in: first)
        let second = h.add(Corral(CGRect(x: 400, y: 0, width: 200, height: 140)))
        let b = roster(400, in: second)
        let joined = key(a, b)
        expectEqual(h.editor.paintOrder().map(\.id), [first, a.id, second, joined, b.id], "above the second corral, whose opaque fill would hide its end, under the roster in it")
        // One end free of any corral: the corral of the other end still lies under it.
        let free = roster(800, in: nil)
        let third = h.add(Corral(CGRect(x: 1200, y: 0, width: 200, height: 140)))
        let c = roster(1200, in: third)
        let across = key(free, c)
        expectEqual(h.editor.paintOrder().map(\.id).suffix(4), [free.id, third, across, c.id])
        // The ends in the same corral: just below the lower of the two, above their corral, as ever.
        let r1 = roster(0, in: first), r2 = roster(100, in: first)
        let both = key(r1, r2)
        let order = h.editor.paintOrder().map(\.id)
        expectEqual(order.firstIndex(of: both).map { $0 + 1 }, order.firstIndex(of: r1.id), "just below the lower of its two rosters")
        expect(order.firstIndex(of: both)! > order.firstIndex(of: first)!, "above their corral")
    },
    test("a roster that joins a corral already below it (no change in the stack) puts the key to it above that corral") {
        let rule = Contributor(id: "roster-rows") { registrar in registrar.arrowPartRule { $0.shape.kind == Roster.kind } }
        let h = try EditorHarness(plugins: arrowsPlugins(before: [RostersPlugin(), CorralsPlugin()], more: [rule]))
        let row = RosterRow(name: "one"), farRow = RosterRow(name: "two")
        let near = h.add(Roster(CGRect(x: 20, y: 40, width: 160, height: 60), rows: [row]))
        let corral = h.add(Corral(CGRect(x: 400, y: 0, width: 200, height: 140)))
        let far = h.add(Roster(CGRect(x: 420, y: 40, width: 160, height: 60), rows: [farRow]))
        func end(_ id: ShapeID, _ part: PartID) -> ArrowTerminal {
            .bound(ArrowBinding(shapeID: id, normalizedAnchor: CGPoint(x: 1, y: 0.5), isPrecise: true, isExact: true, part: part))
        }
        let key = h.add(Arrow(start: end(near, row.id), end: end(far, farRow.id)))
        expectEqual(h.editor.paintOrder().map(\.id), [key, near, corral, far], "no corral holds it: below the lower")
        _ = h.editor.paintOrder()
        h.editor.transact { $0.setContainer(far, to: corral) }
        expectEqual(h.editor.paintOrder().map(\.id), [near, corral, key, far], "in the corral: above it, where its fill can't hide the end")
    },
    test("an arrow with an end at a row is painted just below the lower of its shapes, however it was made, so a card it passes covers it") {
        let b = try RosterBoard()
        // A roster between the two in the stack, which the key passes.
        let between = b.h.add(Roster(CGRect(x: 320, y: 100, width: 160, height: 200), rows: [RosterRow(name: "mid")]))
        b.h.editor.transact { $0.move(between, below: b.right) }
        let key = b.h.add(Arrow(start: b.end(b.left, 0), end: b.end(b.right, 2)))
        expectEqual(b.h.editor.paintOrder().map(\.id), [key, b.left, between, b.right], "under both rosters, and under the one it passes")
        // Bound to the rosters as wholes, it is above the higher, as tldraw's arrows are.
        let whole = b.h.add(Arrow(start: .bound(ArrowBinding(shapeID: b.left, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)),
                                  end: .bound(ArrowBinding(shapeID: b.right, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))))
        expectEqual(b.h.editor.paintOrder().map(\.id), [key, b.left, between, b.right, whole])
        // An end let go of its row: back above.
        b.h.editor.transact { $0.update(key, as: Arrow.self) { $0.props.end = .free(CGPoint(x: 900, y: 400)) } }
        expectEqual(b.h.editor.paintOrder().map(\.id), [key, b.left, between, b.right, whole], "still at a row at its start: below its one shape")
        b.h.editor.transact { $0.update(key, as: Arrow.self) { $0.props.start = .free(CGPoint(x: 0, y: 0)) } }
        expectEqual(b.h.editor.paintOrder().map(\.id), [b.left, between, b.right, whole, key], "bound to nothing: on top")
    },
    test("a part the shape doesn't list is drawn at the stored anchor; a folded one at what's shown in its place") {
        let b = try RosterBoard()
        let gone = b.h.add(Arrow(start: .bound(ArrowBinding(shapeID: b.left, normalizedAnchor: CGPoint(x: 0, y: 0.5), isPrecise: true, isExact: true,
                                                            part: PartID())),
                                 end: .free(CGPoint(x: 800, y: 140))))
        let geometry = try require(b.h.editor.arrowGeometry(of: gone))
        expectClose(geometry.startHandle, CGPoint(x: 100, y: 140), within: 0.5)
        expectEqual(geometry.partSide(at: .start), nil)
        b.h.editor.transact { $0.update(b.left, as: Roster.self) { $0.props.folded = 2 } }
        let folded = b.h.add(Arrow(start: b.end(b.left, 2), end: .free(CGPoint(x: 800, y: 140))))
        expectEqual(try require(b.h.editor.arrowGeometry(of: folded)).startHandle, CGPoint(x: 300, y: RosterBoard.rowMiddle(0, in: RosterBoard.leftFrame)))
    },
    test("an end with no part beside one that has a part keeps its handle at its anchor, and stands a head's gap off the side it meets") {
        let b = try RosterBoard()
        let whole = ArrowTerminal.bound(ArrowBinding(shapeID: b.right, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false))
        let id = b.h.add(Arrow(start: b.end(b.left, 1), end: whole))
        let geometry = try require(b.h.editor.arrowGeometry(of: id))
        expectEqual(geometry.endHandle, RosterBoard.rightFrame.center)
        expectClose(geometry.end.x, RosterBoard.rightFrame.minX - ArrowGeometry.boundGap - ArrowStyleWidth.half, within: 1)
    },
    test("re-aimed onto a roster, the end binds the row under the pointer, lit as the hint's part, and lets it go on release") {
        let b = try RosterBoard()
        let id = b.h.add(Arrow(start: b.end(b.left, 0), end: .free(CGPoint(x: 800, y: 500))))
        b.h.editor.selection = id
        b.h.move(to: CGPoint(x: 800, y: 500))
        b.h.press()
        let row = CGPoint(x: 600, y: RosterBoard.rowMiddle(1, in: RosterBoard.rightFrame))
        b.h.drag(to: CGPoint(x: 700, y: 300), speed: 3)
        b.h.drag(to: row, speed: 3)
        expectEqual(b.arrow(id)?.end.binding?.part, b.rightRows[1].id)
        expectEqual(b.h.editor.hintedShapeID, b.right)
        expectEqual(b.h.editor.hintedPart, b.rightRows[1].id)
        b.h.drag(to: CGPoint(x: 600, y: RosterBoard.rowMiddle(2, in: RosterBoard.rightFrame)), speed: 3)
        expectEqual(b.arrow(id)?.end.binding?.part, b.rightRows[2].id, "the row under the pointer, as it moves")
        expectEqual(b.h.editor.hintedPart, b.rightRows[2].id)
        b.h.release()
        expectEqual(b.arrow(id)?.end.binding?.part, b.rightRows[2].id)
        expectEqual(b.h.editor.hintedPart, nil)
        expectEqual(b.h.editor.undoHistory.undoName, "Move Arrow End")
    },
    test("an arrow moved alone keeps its row ends where they are") {
        let b = try RosterBoard()
        let id = b.h.add(Arrow(start: b.end(b.left, 0), end: b.end(b.right, 1)))
        let before = try require(b.arrow(id))
        let geometry = try require(b.h.editor.arrowGeometry(of: id))
        let middle = (geometry.start + geometry.end) / 2
        b.h.editor.selection = id
        b.h.press(at: b.h.view(middle))
        b.h.drag(to: b.h.view(middle + CGPoint(x: 0, y: 120)), speed: 3)
        b.h.release()
        expectEqual(b.arrow(id)?.start, before.start)
        expectEqual(b.arrow(id)?.end, before.end)
    },
    test("a row end's binding lists its part, which a part moved or taken out reaches") {
        let b = try RosterBoard()
        let id = b.h.add(Arrow(start: b.end(b.left, 0), end: b.end(b.right, 1)))
        let record = try require(b.h.editor.document[id])
        expectEqual(record.boundParts(in: b.h.editor.registry),
                    [PartAddress(b.left, part: b.leftRows[0].id), PartAddress(b.right, part: b.rightRows[1].id)])
        b.h.editor.transact { $0.moveParts([PartAddress(b.right, part: b.rightRows[1].id): PartAddress(b.right, part: b.rightRows[2].id)]) }
        expectEqual(b.arrow(id)?.end.binding?.part, b.rightRows[2].id)
        b.h.editor.transact { $0.removeParts([PartAddress(b.left, part: b.leftRows[0].id)]) }
        let start = try require(b.arrow(id)?.start.binding)
        expectEqual(start.part, nil, "a roster takes nothing along: the end is bound to it as a whole")
        expectEqual(start.shapeID, b.left)
        expectEqual(start.isPrecise, false)
    },
])

@MainActor let partEndKeyTests = Suite("A row end by the keys", [
    test("↑ ↓ on a row end step it a row on its roster, one step, and VoiceOver hears the row; ← → leave it; past the ends, nothing") {
        let b = try RosterBoard()
        let id = b.h.add(Arrow(start: b.end(b.left, 0), end: b.end(b.right, 1)))
        b.h.editor.selection = id
        _ = b.h.key(Chord.optionBackTab)
        expectEqual(b.h.editor.focusedPart?.title, "End")
        _ = b.h.key(Chord.down)
        expectEqual(b.arrow(id)?.end.binding?.part, b.rightRows[2].id)
        expectEqual(b.h.editor.undoHistory.undoName, "Move Arrow End")
        expectEqual(b.h.editor.announcements.last, "three in roster")
        _ = b.h.key(Chord.down)
        expectEqual(b.arrow(id)?.end.binding?.part, b.rightRows[2].id, "no row below the last")
        _ = b.h.key(Chord.left)
        _ = b.h.key(Chord.right)
        expectEqual(b.arrow(id)?.end.binding?.part, b.rightRows[2].id, "← → change nothing: the side follows the far end")
        _ = b.h.key(Chord.up)
        expectEqual(b.arrow(id)?.end.binding?.part, b.rightRows[1].id, "↑ undoes ↓ exactly")
        b.h.editor.undo()
        b.h.editor.undo()
        expectEqual(b.arrow(id)?.end.binding?.part, b.rightRows[1].id)
    },
    test("↑ ↓ never step an end onto the row the other end is at: a key is not a loop on one row") {
        let b = try RosterBoard()
        let id = b.h.add(Arrow(start: b.end(b.left, 0), end: b.end(b.left, 1)))
        b.h.editor.selection = id
        _ = b.h.key(Chord.optionBackTab)
        expectEqual(b.h.editor.focusedPart?.title, "End")
        let steps = b.h.editor.undoHistory.undoName
        _ = b.h.key(Chord.up)
        expectEqual(b.arrow(id)?.end.binding?.part, b.leftRows[1].id, "row one is where the start is: the end stays")
        expectEqual(b.h.editor.undoHistory.undoName, steps, "and no step is made")
        _ = b.h.key(Chord.down)
        expectEqual(b.arrow(id)?.end.binding?.part, b.leftRows[2].id, "the other way is free")
    },
    test("VoiceOver says where a row's arrow runs by its rows") {
        let b = try RosterBoard()
        let id = b.h.add(Arrow(start: b.end(b.left, 0), end: b.end(b.right, 1)))
        let description = try require(b.h.editor.accessibleDescription(of: id))
        expect(description.label.contains("from one in roster to two in roster"), "said: \(description.label)")
        expectEqual(b.h.editor.accessibleName(of: PartAddress(b.right, part: b.rightRows[1].id)), "two in roster")
        expectEqual(b.h.editor.accessibleName(of: PartAddress(b.right, part: PartID())), nil)
    },
])
