import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import Engineering
import Selection
import TestKit
import Topology

// Keys, as the kit keeps them: a table's columns take the foreign-key channel both ways (dots at the ends of the hovered row);
// the key index reads each table's keys from Topology's edges with their parts, and the column's link mark reads it; the kit's
// kinds take what is bound to them along (deleting a table or a column deletes its keys, and the step says so); and a row
// taken out by id (draw's `delete "orders".id`). Arrows are a product of their own, so a strap (CanvasTesting's, bound at
// each end to a shape or a row) is the connector here, as an arrow is when the kit ships.

/// The straps' family of edges, as the connector's: each channel's edge type under it.
enum Lashing {}
extension Lashing: EdgeType {
    static let id: EdgeTypeID = "lashing"
}

/// Straps as what connections are: a strap's ends are the shapes it's bound to, and its edge carries their rows.
@MainActor func strapConnector() -> Contributor {
    Contributor(id: "strap-connector") { registrar in
        registrar.connects(Strap.self, edgeType: Lashing.self, canConnect: { _, _ in true },
                           ends: { record in
                               guard let strap = record.typed(as: Strap.self)?.props, let from = strap.from, let to = strap.to else { return nil }
                               return (from.shape, to.shape)
                           },
                           parts: { record in
                               let strap = record.typed(as: Strap.self)?.props
                               return (strap?.from?.part, strap?.to?.part)
                           },
                           begin: { _, _ in nil })
    }
}

/// orders (id, customer_id, placed_at) and customers (id, email), and an enum, on the kit's board with straps as keys.
@MainActor struct KeyBoard {
    let h: EditorHarness
    let orders: ShapeID
    let customers: ShapeID
    let status: ShapeID

    init(_ refusals: RefusalLog = RefusalLog()) throws {
        h = try EditorHarness(plugins: kitPlugins(refusals) + [StrapsPlugin(), strapConnector()])
        h.editor.viewportDidResize(to: CGSize(width: 1000, height: 800))
        h.editor.turn(EngineeringKit.self, on: true)
        orders = h.add(DatabaseTable(frame: CGRect(x: 100, y: 100, width: 260, height: 92),
                                     columns: ["id uuid pk", "customer_id uuid", "placed_at timestamptz"].compactMap { ColumnGrammar.read($0) }),
                       titled: "orders")
        customers = h.add(DatabaseTable(frame: CGRect(x: 500, y: 100, width: 260, height: 68),
                                        columns: ["id uuid pk", "email text unique"].compactMap { ColumnGrammar.read($0) }),
                          titled: "customers")
        status = h.add(DatabaseEnum(frame: CGRect(x: 500, y: 300, width: 200, height: 68), values: [EnumValue(text: "pending")]), titled: "order_status")
        h.editor.undoHistory.seal()
    }

    var editor: CanvasEditor { h.editor }

    func column(_ table: ShapeID, _ name: String) -> PartID {
        editor.document[table]!.typed(as: DatabaseTable.self)!.props.columns.first { $0.name == name }!.id
    }

    /// A key from `from`'s column to `to`'s, as a strap on foreign-key, in a step of its own.
    @discardableResult
    func key(_ from: ShapeID, _ fromColumn: String, to: ShapeID, _ toColumn: String) -> ShapeID {
        var strap = ShapeRecord(Strap(from: PartAddress(from, part: column(from, fromColumn)), to: PartAddress(to, part: column(to, toColumn))))
        strap[ChannelProperty.self] = ForeignKey.id
        editor.transact("Add Arrow") { $0.insert(strap) }
        return strap.id
    }

    /// The keys of `table`, by its columns' names, each to "column in table".
    func keys(_ table: ShapeID) -> [String: String] {
        let index = Dictionary(uniqueKeysWithValues: (editor.document[table]?.typed(as: DatabaseTable.self)?.props.columns ?? []).map { ($0.id, $0.name) })
        var said: [String: String] = [:]
        for edge in editor.topology?.edges(of: table, .outgoing, types: .only(EdgeTypeID(rawValue: ForeignKey.id.rawValue))) ?? [] {
            guard let part = edge.sourcePart, let name = index[part] else { continue }
            said[name] = editor.accessibleName(of: PartAddress(edge.target, part: edge.targetPart))
        }
        return said
    }

    /// The pixel row of `orders`' row `index` across (rows at 108, 132 and 156, 24 tall), at its gutter mark.
    func gutter(_ index: Int) -> CGRect { CGRect(x: 108, y: 112 + CGFloat(index) * 24, width: 16, height: 16) }
}

private func blue(_ p: [Int]) -> Bool { p[2] > p[0] + 60 && p[2] > p[1] + 30 }

@MainActor let keyTests = Suite("Keys", [
    test("a table's columns take the foreign-key channel both ways, on its rows; an enum and a database take none") {
        let b = try KeyBoard()
        let registry = b.editor.registry
        expect(registry.takesOnParts(DatabaseTable.kind, ForeignKey.id, as: .source))
        expect(registry.takesOnParts(DatabaseTable.kind, ForeignKey.id, as: .target))
        expectEqual(registry.partDotChannels(of: DatabaseTable.kind), [ForeignKey.id])
        expectEqual(registry.dotChannels(of: DatabaseTable.kind), [], "no dot on a table's sides")
        expectEqual(registry.portChannels(of: DatabaseEnum.kind), [])
        expectEqual(registry.portChannels(of: Database.kind), [])
        expect(registry.takingBoundKinds.isSuperset(of: [DatabaseTable.kind, DatabaseEnum.kind, Database.kind]))
    },
    test("a column that starts a key wears the link in its gutter, read from the key; a primary key keeps its key; gone with the key") {
        let b = try KeyBoard()
        let before = render(b.editor, size: CGSize(width: 900, height: 400))
        expect(!some(before, in: b.gutter(1), blue), "no key yet: no link")
        let strap = b.key(b.orders, "customer_id", to: b.customers, "id")
        let keyed = render(b.editor, size: CGSize(width: 900, height: 400))
        expect(some(keyed, in: b.gutter(1), blue), "customer_id's link")
        expect(!some(keyed, in: b.gutter(0), blue), "id keeps its key, which comes first")
        expectEqual(b.keys(b.orders), ["customer_id": "id in customers"])
        b.editor.transact { $0.delete([strap]) }
        expect(!some(render(b.editor, size: CGSize(width: 900, height: 400)), in: b.gutter(1), blue), "the key gone: plain again")
        b.editor.undo()
        expect(some(render(b.editor, size: CGSize(width: 900, height: 400)), in: b.gutter(1), blue), "undone: linked again")
    },
    test("the key index follows a key moved to another row, and names the far row by its live name") {
        let b = try KeyBoard()
        let strap = b.key(b.orders, "customer_id", to: b.customers, "id")
        b.editor.transact { $0.moveParts([PartAddress(b.orders, part: b.column(b.orders, "customer_id")): PartAddress(b.orders, part: b.column(b.orders, "placed_at"))]) }
        expectEqual(b.keys(b.orders), ["placed_at": "id in customers"])
        b.editor.transact { tx in
            tx.update(b.customers, as: DatabaseTable.self) { $0.props.columns[0].name = "customer_key" }
        }
        expectEqual(b.keys(b.orders), ["placed_at": "customer_key in customers"], "a rename follows with nothing written to the key")
        let edge = try require(b.editor.topology?.edges(carriedBy: strap).first)
        expectEqual(edge.type, EdgeTypeID(rawValue: ForeignKey.id.rawValue))
    },
    test("deleting a table takes its keys, either way, and the step says so; one undo brings all back") {
        let b = try KeyBoard()
        b.key(b.orders, "customer_id", to: b.customers, "id")
        b.key(b.customers, "email", to: b.orders, "id")
        let other = b.h.add(DatabaseTable(frame: CGRect(x: 100, y: 400, width: 200, height: 44), columns: [Column(name: "id", type: TypeRef("uuid"))]))
        b.key(other, "id", to: b.customers, "id")
        b.editor.undoHistory.seal()
        b.editor.selectedShapeIDs = [b.orders]
        expect(b.h.key("\u{7f}"), "Delete is heard")
        expect(b.editor.undoHistory.undoName?.hasPrefix("Delete Table and 2 ") == true, "\(String(describing: b.editor.undoHistory.undoName))")
        expectEqual(b.editor.document.shapes.filter { $0.kind == Strap.kind }.count, 1, "the key between the others stays")
        b.editor.undo()
        expectEqual(b.editor.document.shapes.filter { $0.kind == Strap.kind }.count, 3)
    },
    test("a row taken out by id: the kind's props without it, its height its rows'; a key at it goes with it in the same step") {
        let b = try KeyBoard()
        b.key(b.orders, "customer_id", to: b.customers, "id")
        let record = try require(b.editor.document[b.orders])
        let column = b.column(b.orders, "customer_id")
        let without = try require(b.editor.registry.removing([column], from: record)?.typed(as: DatabaseTable.self))
        expectEqual(without.props.columns.map(\.name), ["id", "placed_at"])
        expectEqual(without.props.frame.height, KitStyle.height(rows: 2))
        expectEqual(b.editor.registry.removing([PartID()], from: record), nil, "none of its rows: nothing")
        b.editor.transact("Delete Row") { tx in
            tx.update(b.orders) { $0 = AnyShapeRecord(without) }
            tx.removeParts([PartAddress(b.orders, part: column)])
        }
        expectEqual(b.editor.document.shapes.filter { $0.kind == Strap.kind }.count, 0, "the key went with its column")
        b.editor.undo()
        expectEqual(b.editor.document.shapes.filter { $0.kind == Strap.kind }.count, 1)
    },
])
