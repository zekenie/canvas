import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Chrome
import Geometry
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

@MainActor private var namedDocks: Contributor {
    Contributor(id: "named-docks") {
        $0.title(Dock.self, contents: false)
        $0.mentionable(Dock.self)
    }
}

/// A shape whose rows stand alone (an endpoint: `stripe ref` finds one by its own name), registered beside the rosters.
private struct Dock: BoxShapeProps {
    static let kind: ShapeKind = "dock"
    static let properties = Properties<Dock> {
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

private struct DockDefinition: ShapeDefinition, PartedShape {
    func render(_ shape: ShapeRecord<Dock>, in context: RenderContext) {}

    func geometry(of shape: ShapeRecord<Dock>, in context: ShapeContext) -> ShapeGeometry {
        let frame = shape.frame
        let parts = shape.props.rows.enumerated().map { index, row in
            PartFrame(id: row.id, rect: CGRect(x: frame.minX, y: frame.minY + 10 + CGFloat(index) * 20, width: frame.width, height: 20))
        }
        return ShapeGeometry(outline: frame.polygon, bounds: frame, parts: PartFrames(parts))
    }

    func parts(of shape: ShapeRecord<Dock>) -> [PartName] {
        shape.props.rows.map { PartName(id: $0.id, name: $0.name, kindWord: "Endpoint", standsAlone: true) }
    }
}

private struct DocksPlugin: CanvasPlugin {
    let id: PluginID = "docks"
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(DockDefinition()) { _ in }
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
    test("a row that stands alone is found by its own name, in the name's band with the shapes, and its shape's rule still holds for it") {
        let ref = RosterRow(name: "stripe ref"), plain = RosterRow(name: "refund")
        let dock = ShapeID(), other = ShapeID()
        let shapes = [
            titled(Dock(CGRect(x: 0, y: 0, width: 160, height: 80), rows: [ref, plain]), "payments", id: dock),
            titled(Roster(CGRect(x: 300, y: 0, width: 160, height: 80), rows: [RosterRow(name: "stripe")]), "stripe", id: other),
        ]
        let h = try EditorHarness(plugins: mentionPlugins([CorralsPlugin(), RostersPlugin(), DocksPlugin(), namedRosters, namedDocks]), document: CanvasDocument(shapes: shapes))
        let state = h.editor.mentionState
        @MainActor func found(_ query: String, rule: @escaping @MainActor (ShapeID) -> Bool = { _ in true }) -> [MentionCandidate] {
            state.candidates(matching: query, in: AnyMentionable.self, for: nil, admitting: rule, listingParts: { _ in true }).matches
        }
        expectEqual(found("stripe ref").first?.address, PartAddress(dock, part: ref.id), "by its own name, no shape's name before it")
        expectEqual(found("refund").first?.address, PartAddress(dock, part: plain.id))
        expectEqual(found("payments refund").first?.address, PartAddress(dock, part: plain.id), "and by its path too")
        // Shapes and rows share one ranking: by band, then score, then the shorter name: the shape named `stripe` before the row `stripe ref`.
        let both = found("stripe")
        expectEqual(both.map { $0.part == nil }, [true, false], "the shorter name first: \(both.map(\.id))")
        expectEqual(both.first?.id, other)
        // The shape's rule holds for its rows.
        expect(found("stripe ref") { $0 != dock }.allSatisfy { $0.id != dock }, "a shape the list leaves out takes its rows with it")
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
