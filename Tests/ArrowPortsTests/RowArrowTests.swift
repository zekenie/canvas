import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Keyboard
import Selection
import TestKit
import Topology

// Arrows drawn between rows (`partPorts`): a drag from a row's dot starts the arrow at that row and binds the row under its
// end, lit as the hint's part, outlining the shapes that take the channel either way; let go on its own row it draws nothing,
// on another row of its shape a key both ends on the right. Connect and a request by name bind the rows they name, and the
// arrow's edge carries both parts. Rosters (with rows' ports) stand in for tables, a muster (rows, no ports) for an enum.

/// A key-like channel, row to row, which kinds open to every channel don't take.
enum Tie {}
extension Tie: Channel {
    static let id: ChannelID = "tie"
    static var isOnEveryChannel: Bool { false }
}

let rosterL = CGRect(x: 80, y: 80, width: 200, height: 80)
let rosterR = CGRect(x: 460, y: 120, width: 200, height: 80)
let musterM = CGRect(x: 460, y: 400, width: 200, height: 80)

@MainActor struct RowBoard {
    let board: PortBoard
    let left: ShapeID
    let right: ShapeID
    let muster: ShapeID
    let leftRows = ["id", "customer_id", "placed_at"].map { RosterRow(name: $0) }
    let rightRows = ["id", "email", "name"].map { RosterRow(name: $0) }

    init() throws {
        let ties = Contributor(id: "ties") { registrar in
            registrar.channel(Tie.self)
            registrar.partPorts(Roster.self, on: Tie.self)
        }
        board = try PortBoard(more: [RostersPlugin(), StrapsPlugin(), ties])
        left = board.h.add(Roster(rosterL, rows: leftRows))
        right = board.h.add(Roster(rosterR, rows: rightRows))
        muster = board.h.add(Muster(musterM, rows: [RosterRow(name: "pending")]))
    }

    var h: EditorHarness { board.h }

    static func row(_ index: Int, of frame: CGRect) -> CGPoint {
        CGPoint(x: frame.midX, y: frame.minY + Roster.head + Roster.rowHeight * (CGFloat(index) + 0.5))
    }

    /// Hovers row `index` of L, presses its right dot and drags to `point`, released unless `release` is false.
    func drag(fromRow index: Int, to point: CGPoint, release: Bool = true) {
        let row = Self.row(index, of: rosterL)
        h.move(to: row)
        h.move(to: CGPoint(x: rosterL.maxX + 12, y: row.y))
        h.press()
        h.drag(to: point, speed: fast)
        if release { h.release() }
    }
}

@MainActor let rowArrowTests = Suite("Arrows between rows", [
    test("a drag from a row's dot onto another roster's row draws an arrow from row to row on the row's channel, one step") {
        let b = try RowBoard()
        b.drag(fromRow: 1, to: RowBoard.row(0, of: rosterR))
        let arrow = try require(b.board.arrows.first)
        expectEqual(arrow.props.start.binding?.address, PartAddress(b.left, part: b.leftRows[1].id))
        expectEqual(arrow.props.end.binding?.address, PartAddress(b.right, part: b.rightRows[0].id))
        expectEqual(arrow[ChannelProperty.self], Tie.id)
        expectEqual(b.h.editor.undoHistory.undoName, "Add Arrow")
        let geometry = try require(b.h.editor.arrowGeometry(of: arrow.id))
        expectEqual(geometry.startHandle, CGPoint(x: rosterL.maxX, y: RowBoard.row(1, of: rosterL).y))
        expectEqual(geometry.endHandle, CGPoint(x: rosterR.minX, y: RowBoard.row(0, of: rosterR).y))
        // Its edge carries both rows.
        let edge = try require(b.h.editor.topology?.edges(carriedBy: arrow.id).first)
        expectEqual(edge.sourcePart, b.leftRows[1].id)
        expectEqual(edge.targetPart, b.rightRows[0].id)
        expectEqual(b.h.editor.topology?.edges(of: b.right, part: b.rightRows[0].id, .incoming).map(\.carrier), [arrow.id])
        expectEqual(b.h.editor.topology?.edges(of: b.right, part: b.rightRows[1].id, .incoming).count, 0)
    },
    test("while it is drawn the row under its end is lit as the hint's part, and the shapes that take the channel either way are outlined, the muster not") {
        let b = try RowBoard()
        let plain = renderBitmap(b.h.editor, size: CGSize(width: 800, height: 600))
        b.drag(fromRow: 0, to: CGPoint(x: 380, y: 330), release: false)
        let drawing = renderBitmap(b.h.editor, size: CGSize(width: 800, height: 600))
        let band = { (rect: CGRect) in CGRect(x: rect.minX + 20, y: rect.minY - 3, width: rect.width - 40, height: 6) }
        expect(changedPixels(plain, drawing, in: band(rosterR)) > 0, "the other roster takes the channel: outlined")
        expectEqual(changedPixels(plain, drawing, in: band(musterM)), 0, "the muster has no ports: not outlined")
        b.h.drag(to: RowBoard.row(2, of: rosterR), speed: fast)
        expectEqual(b.h.editor.hintedShapeID, b.right)
        expectEqual(b.h.editor.hintedPart, b.rightRows[2].id)
        b.h.release()
        expectEqual(b.h.editor.hintedPart, nil)
    },
    test("let go on its own row it draws nothing; on another row of its roster, a key with both ends on the right") {
        let b = try RowBoard()
        b.drag(fromRow: 1, to: RowBoard.row(1, of: rosterL))
        expectEqual(b.board.arrows.count, 0, "its own row: nothing")
        b.drag(fromRow: 1, to: RowBoard.row(2, of: rosterL))
        let arrow = try require(b.board.arrows.first)
        expectEqual(arrow.props.start.binding?.part, b.leftRows[1].id)
        expectEqual(arrow.props.end.binding?.part, b.leftRows[2].id)
        let geometry = try require(b.h.editor.arrowGeometry(of: arrow.id))
        expectEqual([geometry.startHandle.x, geometry.endHandle.x], [rosterL.maxX, rosterL.maxX])
    },
    test("a request by name binds the rows it names, at the sides facing each other; a row to itself is refused") {
        let b = try RowBoard()
        let request = ConnectionRequest(from: b.left, to: b.right, fromPart: b.leftRows[1].id, toPart: b.rightRows[0].id, channel: Tie.id)
        let made = try require(b.h.editor.registry.connection(request, in: b.h.editor.shapeContext)?.typed(as: Arrow.self))
        expectEqual(made.props.start.binding?.part, b.leftRows[1].id)
        expectEqual(made.props.end.binding?.part, b.rightRows[0].id)
        expectEqual(made.props.start.binding?.isExact, true)
        expectEqual(made[ChannelProperty.self], Tie.id)
        let itself = ConnectionRequest(from: b.left, to: b.left, fromPart: b.leftRows[0].id, toPart: b.leftRows[0].id, channel: Tie.id)
        expect(b.h.editor.registry.connection(itself, in: b.h.editor.shapeContext) == nil)
        let selfKey = ConnectionRequest(from: b.left, to: b.left, fromPart: b.leftRows[0].id, toPart: b.leftRows[2].id, channel: Tie.id)
        let key = try require(b.h.editor.registry.connection(selfKey, in: b.h.editor.shapeContext)?.typed(as: Arrow.self))
        expectEqual(key.props.bend, 0, "rows of one roster: no loop")
        expectEqual(key.props.end.binding?.part, b.leftRows[2].id)
    },
    test("a shape's arrows as its parts are titled by the row at the far end") {
        let b = try RowBoard()
        b.drag(fromRow: 1, to: RowBoard.row(0, of: rosterR))
        b.h.editor.selection = b.left
        let titles = b.h.editor.shapeParts(of: b.left).map(\.title)
        expect(titles.contains("Arrow to id in roster"), "\(titles)")
        b.h.editor.selection = b.right
        expect(b.h.editor.shapeParts(of: b.right).map(\.title).contains("Arrow from customer_id in roster"))
    },
])
