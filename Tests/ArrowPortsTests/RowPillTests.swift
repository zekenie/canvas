import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import TestKit
import Topology

// Arrows into a pill (K10): a pill for a row (an endpoint's) is that row, so a drag let go on it binds the row, on the row's channel,
// taken on the pill's own sides; a pill for a roster as a whole stands for its rows' keys on their parts, which have no side of the
// pill's to end on, so a drag let go on it binds nothing. A part named on a binding to a pill is the roster's row, ignored by the
// geometry, which meets the pill as a whole.

/// A box that stands for a roster, or for one row of it, and has ports on every channel, left and right, as a reference pill does.
private struct Badge: BoxShapeProps {
    static let kind: ShapeKind = "badge"
    static let properties = Properties<Badge> {
        Property("frame", \.frame).required()
        Property("roster", \.roster)
        Property("row", \.row)
    }
    var frame: CGRect
    var roster: Citation?
    var row: PartID?
    init(_ frame: CGRect, roster: ShapeID? = nil, row: PartID? = nil) {
        self.frame = frame
        self.roster = roster.map(Citation.init)
        self.row = row
    }
    init() { self.init(.zero) }
}

private struct BadgeDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Badge>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .systemYellow)
    }
}

@MainActor private struct PillBoard {
    let rows: RowBoard
    let rowPill: ShapeID, wholePill: ShapeID
    static let rowPillFrame = CGRect(x: 720, y: 120, width: 90, height: 40)
    static let wholePillFrame = CGRect(x: 720, y: 220, width: 90, height: 40)

    init() throws {
        let badges = Contributor(id: "badges") { registrar in
            registrar.shape(BadgeDefinition()) { badge in
                badge.portsOnEveryChannel(sides: [.left, .right])
                badge.standsIn { shape, _ in
                    guard let roster = shape.props.roster?.shape else { return nil }
                    return shape.props.row.map { .row(roster, $0) } ?? .shapes([roster])
                }
            }
        }
        rows = try RowBoard(more: [badges])
        let right = rows.right
        let row = try require(rows.board.h.editor.document[right]?.typed(as: Roster.self)?.props.rows[1].id)
        rowPill = rows.board.h.add(Badge(Self.rowPillFrame, roster: right, row: row))
        wholePill = rows.board.h.add(Badge(Self.wholePillFrame, roster: right))
    }
}

@MainActor let rowPillArrowTests = Suite("Arrows into a pill for a row", [
    test("a drag from a row's dot let go on a pill for a row binds the pill and names the row on the binding; its edge reaches the roster's row") {
        let b = try PillBoard()
        let rosterRows = try require(b.rows.board.h.editor.document[b.rows.right]?.typed(as: Roster.self)?.props.rows)
        let leftRows = try require(b.rows.board.h.editor.document[b.rows.left]?.typed(as: Roster.self)?.props.rows)
        let row = RowBoard.row(1, of: rosterL)
        b.rows.board.h.move(to: row)
        b.rows.board.h.move(to: CGPoint(x: rosterL.maxX + 12, y: row.y))
        b.rows.board.h.press()
        b.rows.board.h.drag(to: CGPoint(x: PillBoard.rowPillFrame.midX, y: PillBoard.rowPillFrame.midY), speed: fast)
        b.rows.board.h.release()
        let arrow = try require(b.rows.board.arrows.first)
        expectEqual(arrow.props.start.binding?.address, PartAddress(b.rows.left, part: leftRows[1].id))
        expectEqual(arrow.props.end.binding?.shapeID, b.rowPill)
        expectEqual(arrow.props.end.binding?.part, rosterRows[1].id, "the pill is the row: the binding names it")
        expectEqual(arrow[ChannelProperty.self], Tie.id)
        let topology = try require(b.rows.board.h.editor.topology)
        expectEqual(topology.edges(of: b.rows.right, part: rosterRows[1].id, .incoming).map(\.carrier), [arrow.id], "the roster's row has the key")
        expectEqual(b.rows.board.h.editor.undoHistory.undoName, "Add Arrow")
    },
    test("a pill for a roster as a whole takes its rows' key on no side: let go on it, the drag binds nothing") {
        let b = try PillBoard()
        let row = RowBoard.row(1, of: rosterL)
        b.rows.board.h.move(to: row)
        b.rows.board.h.move(to: CGPoint(x: rosterL.maxX + 12, y: row.y))
        b.rows.board.h.press()
        b.rows.board.h.drag(to: CGPoint(x: PillBoard.wholePillFrame.midX, y: PillBoard.wholePillFrame.midY), speed: fast)
        b.rows.board.h.release()
        expect(b.rows.board.arrows.allSatisfy { $0.props.end.binding?.shapeID != b.wholePill }, "no key ends on the roster's pill: \(b.rows.board.arrows.map { String(describing: $0.props.end) })")
    },
])
