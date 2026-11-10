@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Engineering
import TestKit

// How a key looks (T3 panel 4, the kit's answer to Connections' `ConnectionLooks`): a crow's foot at the column's end, two bars
// when the column is unique (or its table's one primary key); two bars at the row it references, a bar and a circle when the
// column may be null; 2.5 wide; nothing for a connection on another channel. And where a line to a table as a whole meets it:
// its first row's sides. Straps stand in for arrows (KeyTests' `KeyBoard`).

/// The look the kit gives a strap on `channel` from `from`'s column to `to`'s.
@MainActor private func look(_ b: KeyBoard, _ from: ShapeID, _ column: String, to: ShapeID, _ toColumn: String,
                             channel: ChannelID? = ForeignKey.id) throws -> ConnectionLook? {
    var strap = ShapeRecord(Strap(from: PartAddress(from, part: b.column(from, column)), to: PartAddress(to, part: b.column(to, toColumn))))
    strap[ChannelProperty.self] = channel
    let record = AnyShapeRecord(strap)
    return b.editor.registry.connectionLook(of: record, from: strap.props.from, to: strap.props.to, in: b.editor.shapeContext)
}

/// `orders`' column `name` changed by `change`, in a step.
@MainActor private func change(_ b: KeyBoard, _ name: String, _ change: @escaping (inout Column) -> Void) {
    b.editor.transact("Change Column") { tx in
        tx.update(b.orders, as: DatabaseTable.self) { table in
            guard let index = table.props.columns.firstIndex(where: { $0.name == name }) else { return }
            change(&table.props.columns[index])
        }
    }
}

@MainActor let keyLookTests = Suite("How a key looks", [
    test("a plain column's key: a crow's foot at it and two bars at the row it references, 2.5 wide") {
        let b = try KeyBoard()
        expectEqual(try look(b, b.orders, "customer_id", to: b.customers, "id"), ConnectionLook(start: .many, end: .one, lineWidth: 2.5))
    },
    test("T3 panel 4: a unique column's key is bars at both ends; a nullable one's is a bar and a circle at the row it references") {
        let b = try KeyBoard()
        change(b, "customer_id") { $0.unique = true }
        expectEqual(try look(b, b.orders, "customer_id", to: b.customers, "id"), ConnectionLook(start: .one, end: .one, lineWidth: 2.5))
        change(b, "customer_id") { $0.unique = false; $0.nullable = true }
        expectEqual(try look(b, b.orders, "customer_id", to: b.customers, "id"), ConnectionLook(start: .many, end: .zeroOrOne, lineWidth: 2.5))
        change(b, "customer_id") { $0.unique = true }
        expectEqual(try look(b, b.orders, "customer_id", to: b.customers, "id"), ConnectionLook(start: .one, end: .zeroOrOne, lineWidth: 2.5))
    },
    test("a table's one primary key is unique; one of two primary key columns isn't") {
        let b = try KeyBoard()
        expectEqual(try look(b, b.orders, "id", to: b.customers, "id")?.start, .one, "orders' id, its one primary key")
        change(b, "placed_at") { $0.primaryKey = true }
        expectEqual(try look(b, b.orders, "id", to: b.customers, "id")?.start, .many, "a key of two columns")
    },
    test("a connection on another channel, or none, is no key's: the kit says nothing of it") {
        let b = try KeyBoard()
        expectEqual(try look(b, b.orders, "customer_id", to: b.customers, "id", channel: nil), nil)
        expectEqual(try look(b, b.orders, "customer_id", to: b.customers, "id", channel: "a-test-channel"), nil)
    },
    test("a key from a table as a whole has a plain column's marks") {
        let b = try KeyBoard()
        var strap = ShapeRecord(Strap(from: PartAddress(b.orders), to: PartAddress(b.customers, part: b.column(b.customers, "id"))))
        strap[ChannelProperty.self] = ForeignKey.id
        let record = AnyShapeRecord(strap)
        expectEqual(b.editor.registry.connectionLook(of: record, from: PartAddress(b.orders), to: strap.props.to, in: b.editor.shapeContext),
                    ConnectionLook(start: .many, end: .one, lineWidth: 2.5))
    },
    test("a line to a table as a whole meets its first row: the row's two sides, facing out; a table with no rows gives none") {
        let b = try KeyBoard()
        let geometry = try require(b.editor.shapeContext.geometry(of: b.orders))
        let first = try require(geometry.parts.first).rect
        expectEqual(geometry.entries, [ShapeEntry(point: CGPoint(x: first.minX, y: first.midY), normal: CGPoint(x: -1, y: 0)),
                                       ShapeEntry(point: CGPoint(x: first.maxX, y: first.midY), normal: CGPoint(x: 1, y: 0))])
        expectEqual(first.minX, 100)
        expectEqual(first.maxX, 360)
        let empty = b.h.add(DatabaseTable(frame: CGRect(x: 100, y: 500, width: 200, height: 44), columns: []))
        expectEqual(b.editor.shapeContext.geometry(of: empty)?.entries, [])
        expectEqual(b.editor.shapeContext.geometry(of: b.status)?.entries, [], "an enum's rows are no entry")
    },
])
