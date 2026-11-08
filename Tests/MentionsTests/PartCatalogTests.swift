import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Chrome
import Mentions
import TestKit
import Titles

// Mentions' catalog learns rows (`PartedShape`'s parts): a list that asks for them (`listingParts`) finds a row that doesn't
// stand alone only under its shape's name, `orders cust` and `orders.cust`, never by its name alone; it says where the row is
// (its shape's place, then the shape); a rule leaves rows out; a commit reads again the rows of the shapes it changed and no
// other; and a copy of a shape keeps its rows' ids. Rosters (CanvasTesting's), titled, in a corral named Shop.

/// Rosters and corrals named by their titles, and rosters mentionable.
@MainActor private var namedRosters: Contributor {
    Contributor(id: "named-rosters") {
        $0.title(Roster.self, contents: false)
        $0.title(Corral.self, contents: false)
        $0.mentionable(Roster.self)
    }
}

@MainActor private func titled<P: ShapeProps>(_ props: P, _ title: String, in container: ShapeID? = nil, id: ShapeID = ShapeID()) -> AnyShapeRecord {
    var record = ShapeRecord(id: id, props)
    record[TitleProperty.self] = title
    let any = AnyShapeRecord(record)
    return container.map { any.copy(as: id, container: $0) } ?? any
}

@MainActor private final class RosterBoard {
    let h: EditorHarness
    let shop = ShapeID(), orders = ShapeID(), customers = ShapeID()
    let customerID = RosterRow(name: "customer_id"), total = RosterRow(name: "total"), id = RosterRow(name: "id"), email = RosterRow(name: "email")
    var state: MentionState { h.editor.mentionState }

    init() throws {
        let shapes = [
            titled(Corral(CGRect(x: 0, y: 0, width: 600, height: 400)), "Shop", id: shop),
            titled(Roster(CGRect(x: 20, y: 40, width: 160, height: 80), rows: [RosterRow(name: "id"), customerID, total]), "orders", in: shop, id: orders),
            titled(Roster(CGRect(x: 300, y: 40, width: 160, height: 60), rows: [id, email]), "customers", id: customers),
        ]
        h = try EditorHarness(plugins: mentionPlugins([CorralsPlugin(), RostersPlugin(), namedRosters]), document: CanvasDocument(shapes: shapes))
    }

    func matches(_ query: String, rule: @escaping @MainActor (PartAddress) -> Bool = { _ in true }) -> [MentionCandidate] {
        state.candidates(matching: query, in: AnyMentionable.self, for: nil, listingParts: rule).matches
    }
}

@MainActor let partCatalogTests = Suite("Rows in the catalog", [
    test("a column is found under its table's name, `orders cust` and `orders.cust`, and said where it is; by its name alone, never") {
        let b = try RosterBoard()
        let spaced = b.matches("orders cust")
        let row = try require(spaced.first)
        expectEqual(row.address, PartAddress(b.orders, part: b.customerID.id))
        expectEqual(row.appearance.label, "customer_id")
        expectEqual(row.appearance.kindName, "Member")
        expectEqual(row.place?.steps.map(\.name), ["Shop", "orders"], "its shape's place, then its shape")
        expectEqual(row.matched, [0..<4], "the characters of its name the last word took")
        expectEqual(b.matches("orders.cust").first?.address, row.address, "a dot before a letter splits as a space")
        expect(b.matches("cust").allSatisfy { $0.part == nil }, "by its name alone it isn't listed")
        expect(b.matches("id").allSatisfy { $0.part == nil }, "so `id` doesn't list every table's")
        expectEqual(b.matches("customers email").first?.address, PartAddress(b.customers, part: b.email.id))
        expect(b.state.candidates(matching: "orders cust", in: AnyMentionable.self, for: nil).matches.allSatisfy { $0.part == nil },
               "a list that doesn't ask for rows lists none")
    },
    test("a rule leaves rows out, and the shapes' own rule holds for their rows") {
        let b = try RosterBoard()
        expect(b.matches("orders cust") { $0.part != b.customerID.id }.allSatisfy { $0.part?.id != b.customerID.id })
        let ruled = b.state.candidates(matching: "orders cust", in: AnyMentionable.self, for: nil, admitting: { $0 != b.orders }, listingParts: { _ in true })
        expect(ruled.matches.allSatisfy { $0.id != b.orders }, "a shape the list leaves out takes its rows with it")
    },
    test("a commit reads again the rows of the shapes it changed: a renamed row, an added one, a deleted shape; the rest are read no more") {
        let b = try RosterBoard()
        let editor = b.h.editor
        expectEqual(b.state.listedParts(of: b.orders).map(\.name), ["id", "customer_id", "total"])
        _ = b.matches("orders cust")
        let read = b.state.entriesRead
        editor.transact("Rename") { $0.update(b.orders, as: Roster.self) { $0.props.rows[1].name = "buyer_id"; $0.props.rows.append(RosterRow(name: "placed_at")) } }
        expectEqual(b.state.listedParts(of: b.orders).map(\.name), ["id", "buyer_id", "total", "placed_at"])
        expectEqual(b.state.entriesRead, read + 1, "the one shape changed")
        expectEqual(b.matches("orders buyer").first?.address, PartAddress(b.orders, part: b.customerID.id), "its id kept")
        expect(b.matches("orders cust").allSatisfy { $0.part?.id != b.customerID.id }, "its old name finds it no more")
        editor.transact("Delete") { $0.delete([b.customers]) }
        expectEqual(b.state.listedParts(of: b.customers), [])
        expect(b.matches("customers email").allSatisfy { $0.part == nil })
        editor.undo()
        expectEqual(b.state.listedParts(of: b.customers).map(\.name), ["id", "email"])
    },
    test("a copy of a shape keeps its rows' ids: its rows are listed under the copy with the same ids") {
        let b = try RosterBoard()
        let editor = b.h.editor
        let copy = ShapeID()
        let original = try require(editor.document[b.customers])
        var record = original.copy(as: copy)
        record[TitleProperty.self] = "clients"
        editor.transact("Paste") { $0.insert(record) }
        expectEqual(b.state.listedParts(of: copy).map(\.id), b.state.listedParts(of: b.customers).map(\.id))
        expectEqual(b.matches("clients email").first?.address, PartAddress(copy, part: b.email.id))
    },
])
