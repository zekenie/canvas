import Canvas
import CanvasTesting
import ContextMenus
import CoreGraphics
import Foundation
import Grouping
import Keyboard
import Queries
import QueryLanguage
import Selection
import TestKit
import Topology

// `:grouped-with(S)`: the shapes in a group with a shape S matches, the outermost group that counts on
// its board, on every board of the file. Fixtures only: CanvasTesting's tiles, named for queries by
// their labels, and pockets for another board.

/// Tiles named by their labels.
private func queryTileNames() -> Contributor {
    Contributor(id: "names") { registrar in
        registrar.queryNames(attribute: "name", source: { kind, _ in kind == Tile.kind ? .named : .none },
                             named: { ($0.props as? Tile).map(\.label) }, derived: { _, _ in nil }, fold: { $0 })
    }
}

private func tile(_ label: String, _ x: CGFloat, in groups: [String] = [], id: ShapeID = ShapeID()) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: id, Tile(CGRect(x: x, y: 0, width: 120, height: 80), label: label)))
    if !groups.isEmpty { record[GroupsProperty.self] = groups }
    return record
}

/// On the root: Kiosk and Booth in "inner", both with Stall in "outer"; Cart alone; and pocket P,
/// whose board holds Van and Bus in "fleet", and Bike.
@MainActor private func market() throws -> EditorHarness {
    let pocket = ShapeID()
    let root = CanvasDocument(shapes: [tile("Kiosk", 0, in: ["outer", "inner"]), tile("Booth", 200, in: ["outer", "inner"]),
                                       tile("Stall", 400, in: ["outer"]), tile("Cart", 600),
                                       AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 800, y: 0, width: 100, height: 100))))])
    let board = CanvasDocument(shapes: [tile("Van", 0, in: ["fleet"]), tile("Bus", 200, in: ["fleet"]), tile("Bike", 400)])
    return try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), TilesPlugin(), PocketsPlugin(),
                                       ContextMenusPlugin(), GroupingPlugin(), QueriesPlugin(), queryTileNames(), GroupQueriesPlugin()],
                             file: CanvasFile(root: root, children: [pocket: board]))
}

/// The labels of the tiles a query matches, in the order it lists them.
@MainActor private func labels(_ text: String, on h: EditorHarness) throws -> [String] {
    let queries = try require(h.editor.queries)
    let rows = try awaitResult { try await queries.run(QueryRequest(text, limit: QueryBudget.maxRows, properties: .none)) }.rows
    return rows.compactMap { row in h.editor.file.record(row.id).flatMap { ($0.props as? Tile)?.label } }
}

@MainActor let groupQueriesTests = Suite("Groups in queries", [
    test(":grouped-with(S) is what a click on S selects with it, its outermost group, on any board; never S itself") {
        let h = try market()
        expectEqual(try labels(#":grouped-with("Kiosk")"#, on: h), ["Booth", "Stall"])
        expectEqual(try labels(#":grouped-with("Stall")"#, on: h), ["Kiosk", "Booth"])
        expectEqual(try labels(#":grouped-with("Cart")"#, on: h), [])
        expectEqual(try labels(#":grouped-with("Van")"#, on: h), ["Bus"], "on another board")
        expectEqual(try labels(":grouped-with(*)", on: h), ["Kiosk", "Booth", "Stall", "Van", "Bus"])
        expectEqual(try labels(":not(:grouped-with(*))", on: h).filter { !$0.isEmpty }, ["Cart", "Bike"])
        expectEqual(try labels(#""Kiosk":grouped-with("Booth")"#, on: h), ["Kiosk"], "a yes or no")
    },
    test("a group left with one part is none: Booth deleted, Kiosk is in outer alone, with Stall") {
        let h = try market()
        let booth = try require(h.editor.document.shapes.first { ($0.props as? Tile)?.label == "Booth" }).id
        h.editor.transact { $0.delete([booth]) }
        expectEqual(try labels(#":grouped-with("Kiosk")"#, on: h), ["Stall"])
        let stall = try require(h.editor.document.shapes.first { ($0.props as? Tile)?.label == "Stall" }).id
        h.editor.transact { $0.delete([stall]) }
        expectEqual(try labels(":grouped-with(*)", on: h), ["Van", "Bus"])
    },
    test("it reads only the file, is listed in the vocabulary, and the groups a shape holds are no attribute") {
        let h = try market()
        let queries = try require(h.editor.queries)
        expect(try queries.check(":grouped-with(*)").readsOnlyTheFile)
        let words = queries.vocabulary.words.filter { $0.from == GroupQueriesPlugin().id }
        expectEqual(words.map(\.form), [":grouped-with(S)"])
        do {
            _ = try labels("[groups]", on: h)
            expect(false, "[groups] answered")
        } catch let error as QueryError {
            expectEqual(error.reason, .unknownAttribute)
        }
    },
])
