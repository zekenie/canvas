import Arrows
@_spi(Host) import Canvas
import CanvasTesting
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
