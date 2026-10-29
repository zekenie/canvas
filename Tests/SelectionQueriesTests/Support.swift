import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Keyboard
import Queries
import QueryLanguage
import Selection
import TestKit
import Topology

// Fixtures only: CanvasTesting's boxes and tiles, a tile named for queries by its label, and a word
// the main actor answers that selects box 2 the first time it's asked: a selection changed while a
// query runs.

/// Tiles named by their labels.
func namesPlugin() -> Contributor {
    Contributor(id: "names") { registrar in
        registrar.queryNames(attribute: "name",
                             source: { kind, _ in kind == Tile.kind ? .named : .none },
                             named: { ($0.props as? Tile).map(\.label) },
                             derived: { _, _ in nil },
                             fold: { $0 })
    }
}

/// `:shifting`, asked of every box on the main actor: selects box 2 the first time, and holds for none.
func shiftingPlugin() -> Contributor {
    Contributor(id: "shifting") { registrar in
        registrar.queryPseudoClass("shifting", "the selection shifts as it's asked", example: ":shifting", prepare: { _ in () },
                                   matches: { shape, _ in shape.record.kind == Box.kind ? .onMain : .no },
                                   onMain: { _, _, _, context in
                                       if context.editor.selectedShapeIDs != [id(2)] { context.editor.selectedShapeIDs = [id(2)] }
                                       return false
                                   })
    }
}

/// The keyboard and the selection first, Topology, the fixtures, Queries and the names, then
/// `SelectionQueriesPlugin`.
@MainActor func selectionPlugins(withPlugin: Bool = true) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), TilesPlugin(), QueriesPlugin(), namesPlugin(), shiftingPlugin()]
        + (withPlugin ? [SelectionQueriesPlugin()] : [])
}

func uuid(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }
func id(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: uuid(n))!) }

let unit = CGRect(x: 0, y: 0, width: 120, height: 80)

func record<P: ShapeProps>(_ n: Int, _ props: P) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id(n), props)) }

/// On one board: tile 1 "Kiosk", box 2, tile 3 "Booth" and box 4.
@MainActor func selectionHarness(withPlugin: Bool = true) throws -> EditorHarness {
    try EditorHarness(plugins: selectionPlugins(withPlugin: withPlugin), file: CanvasFile(root: CanvasDocument(shapes: [
        record(1, Tile(unit, label: "Kiosk")), record(2, Box(unit)), record(3, Tile(unit, label: "Booth")), record(4, Box(unit)),
    ])))
}

/// The shapes a query matches on `h`'s editor, in the order it lists them, the main run loop turned
/// while it runs.
@MainActor func matched(_ text: String, on h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) throws -> [ShapeID] {
    let queries = try require(h.editor.queries, file: file, line: line)
    return try awaitResult(file: file, line: line) {
        try await queries.run(QueryRequest(text, limit: QueryRequest.every, properties: .none))
    }.rows.map(\.id)
}

/// Why `h`'s editor refuses a query; nil if it answers.
@MainActor func refusal(_ text: String, on h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) throws -> QueryError? {
    do {
        _ = try matched(text, on: h, file: file, line: line)
        return nil
    } catch let error as QueryError {
        return error
    }
}

/// Where `h`'s person is, for `--ask`, with up to `limit` selected shapes.
@MainActor func whereThePersonIs(on h: EditorHarness, limit: Int = 20) throws -> QueryWhere {
    let queries = try require(h.editor.queries)
    return try awaitResult { try await queries.whereThePersonIs(selectedLimit: limit) }
}
