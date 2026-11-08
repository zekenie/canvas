import AppKit
import Arrows
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import Connections
import CoreGraphics
import Draw
import Geometry
import LanguageModels
import Mentions
import References
import Selection
import ShippedTesting
import SlashCommands
import StickyNotes
import Subboards
import TestKit
import Titles
import Topology

// A pill for a row that stands alone (K10; an endpoint, which ships with the API kinds), proved over a fixture kind in the shipped
// list: a ledger, whose entries stand alone. ⌘L to an entry on another board puts down a pill for that entry (and reuses it), a move
// across boards keeps an arrow bound to an entry through a pill for it, and `canvas draw` names an entry on another board and draws
// it through a pill (drawn again `unchanged`, deleted by `delete edge`).

private struct Ledger: BoxShapeProps {
    static let kind: ShapeKind = "ledger"
    static let properties = Properties<Ledger> {
        Property("frame", \.frame).required()
        Property("rows", \.rows)
    }
    var frame: CGRect
    var rows: [RosterRow]
    init(_ frame: CGRect, rows: [RosterRow] = []) {
        self.frame = frame
        self.rows = rows
    }
    init() { self.init(.zero) }
}

private struct LedgerDefinition: ShapeDefinition, PartedShape {
    func render(_ shape: ShapeRecord<Ledger>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), .systemTeal)
    }

    func geometry(of shape: ShapeRecord<Ledger>, in context: ShapeContext) -> ShapeGeometry {
        let frame = shape.frame
        let parts = shape.props.rows.enumerated().map { index, row in
            PartFrame(id: row.id, rect: CGRect(x: frame.minX, y: frame.minY + 10 + CGFloat(index) * 20, width: frame.width, height: 20))
        }
        return ShapeGeometry(outline: frame.polygon, bounds: frame, parts: PartFrames(parts))
    }

    func parts(of shape: ShapeRecord<Ledger>) -> [PartName] {
        shape.props.rows.map { PartName(id: $0.id, name: $0.name, kindWord: "Entry", lead: .symbol("bolt"), standsAlone: true) }
    }
}

private let ledgersPlugin = Contributor(id: "ledgers") { registrar in
    registrar.shape(LedgerDefinition()) { _ in }
    registrar.title(Ledger.self)
    registrar.mentionable(Ledger.self, symbol: { _ in "book" }, tint: { _ in .systemTeal })
    // A note's link: the entries take it on their rows.
    registrar.partPorts(Ledger.self, on: NoteLink.self)
}

@MainActor private struct Vault {
    let editor: CanvasEditor
    let board: BoardID
    let cart: ShapeID, ledger: ShapeID
    let refund = RosterRow(name: "refund"), charge = RosterRow(name: "charge")

    /// The shipped list and a ledger kind: a note "Cart" on the root, a subboard "vault", and on its board the ledger "Stripe" with two entries.
    init() throws {
        let registry = try Registry(plugins: ShippedPlugins.plugins(model: ScriptedLanguageModel()) + [ledgersPlugin])
        editor = CanvasEditor(registry: registry, document: CanvasDocument(), scheduler: ManualScheduler())
        editor.viewportDidResize(to: CGSize(width: 1440, height: 900))
        _ = try drawnInProcess(#"""
            sticky-note "Cart" text: "the cart"
            subboard "vault" right of "Cart"
            """#, on: editor)
        cart = try require(editor.document.shapes.first { $0[TitleProperty.self] == "Cart" }).id
        let owner = try require(editor.document.shapes.first { $0[TitleProperty.self] == "vault" })
        board = BoardID(owner: owner.id)
        var stripe = ShapeRecord(Ledger(CGRect(x: 100, y: 100, width: 200, height: 80), rows: [refund, charge]))
        stripe[TitleProperty.self] = "Stripe"
        ledger = stripe.id
        editor.transact(on: board, "Add Ledger") { $0.insert(stripe) }
        editor.undoHistory.seal()
    }

    var pills: [ShapeRecord<Reference>] { editor.document.shapes.compactMap { $0.typed(as: Reference.self) } }
    var arrows: [ShapeRecord<Arrow>] { editor.document.shapes.compactMap { $0.typed(as: Arrow.self) } }
}

@MainActor let rowPillShippedTests = Suite("A pill for a row, shipped", [
    test("⌘L to an entry on another board puts a pill for the entry beside the start, the entry on the binding; a second to it reuses the pill, one to the other entry gets its own") {
        let v = try Vault()
        let made = try require(v.editor.connect(ConnectEnd(v.cart), to: ConnectEnd(v.ledger, part: v.refund.id)))
        expectEqual(v.editor.undoHistory.undoName, "Connect")
        let pill = try require(v.pills.first)
        expectEqual(v.pills.count, 1)
        expectEqual(pill.props.target, ReferenceTarget(id: v.ledger, label: "refund", row: v.refund.id), "a pill for the entry, not for the ledger")
        let arrow = try require(v.arrows.first { $0.id == made })
        expectEqual(arrow.props.end.binding?.shapeID, pill.id)
        expectEqual(arrow.props.end.binding?.part, v.refund.id, "the entry on the binding")
        let topology = try require(v.editor.topology)
        expectEqual(topology.edges(of: v.ledger, part: v.refund.id, .incoming, types: .only(EdgeTypeID(rawValue: NoteLink.id.rawValue))).map(\.carrier), [made])
        v.editor.connect(ConnectEnd(v.cart), to: ConnectEnd(v.ledger, part: v.refund.id))
        expectEqual(v.pills.count, 1, "the pill for that entry is reused")
        v.editor.connect(ConnectEnd(v.cart), to: ConnectEnd(v.ledger, part: v.charge.id))
        expectEqual(Set(v.pills.compactMap(\.props.target?.row)), [v.refund.id, v.charge.id], "another entry, a pill of its own")
        expectEqual(v.arrows.count, 3)
    },
    test("an arrow to an entry on the board it moves from is kept across boards: /move-to the vault puts a pill for the entry beside the note on the new board, one Move, undone exactly") {
        let v = try Vault()
        // The ledger on the root with the note; an arrow from the note to its entry.
        let owner = try require(v.board.owner)
        v.editor.transact(on: v.board, "Take Out") { $0.delete([v.ledger]) }
        var stripe = ShapeRecord(Ledger(CGRect(x: 100, y: 500, width: 200, height: 80), rows: [v.refund, v.charge]))
        stripe[TitleProperty.self] = "Stripe"
        v.editor.transact { $0.insert(stripe) }
        v.editor.connect(ConnectEnd(v.cart), to: ConnectEnd(stripe.id, part: v.refund.id))
        expectEqual(v.arrows.count, 1)
        expectEqual(v.pills.count, 0, "the entry is on the board: no pill")
        v.editor.undoHistory.seal()
        let before = v.editor.file
        v.editor.selectedShapeIDs = [v.cart]
        let state = try require(v.editor.slashCommands)
        let command = try require(state.command(named: "move-to", for: .selection([v.cart])))
        expect(state.run(command, with: SlashArguments([.shape(owner, label: "vault")])))
        expectEqual(v.editor.undoHistory.undoName, "Move")
        let arrow = try require(v.editor.contents(of: v.board).shapes.compactMap { $0.typed(as: Arrow.self) }.first, "the arrow went where its start went")
        let pill = try require(v.editor.contents(of: v.board).shapes.compactMap { $0.typed(as: Reference.self) }.first, "a pill for the entry, where it went")
        expectEqual(pill.props.target?.row, v.refund.id)
        expectEqual(arrow.props.end.binding?.shapeID, pill.id)
        expectEqual(arrow.props.end.binding?.part, v.refund.id)
        v.editor.undo()
        expectEqual(v.editor.file[v.board], before[v.board])
        expectEqual(v.editor.file[.root], before[.root])
    },
    test("canvas draw names an entry on another board: the edge is drawn through a pill for the entry, a run again is unchanged, delete edge takes the arrow") {
        let v = try Vault()
        func did(_ result: JSON) -> [String] { result["changes"]?.arrayValue?.compactMap { $0["did"]?.stringValue } ?? [] }
        let script = #"edge "Cart" -> "Stripe".refund"#
        let first = try drawnInProcess(script, on: v.editor)
        expect(did(first).contains("connected"), "\(first)")
        let pill = try require(v.pills.first)
        expectEqual(v.pills.count, 1)
        expectEqual(pill.props.target?.row, v.refund.id, "a pill for the entry")
        expectEqual(v.arrows.first?.props.end.binding?.shapeID, pill.id)
        let again = try drawnInProcess(script, on: v.editor)
        expectEqual(Set(did(again)), ["unchanged"])
        expectEqual(v.pills.count, 1, "nothing drawn twice")
        _ = try drawnInProcess(#"delete edge "Cart" -> "Stripe".refund"#, on: v.editor)
        expectEqual(v.arrows.count, 0)
    },
])
