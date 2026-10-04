import Adornments
import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Keyboard
import Queries
import QueryLanguage
import QueryLexicon
import Selection
import SlashCommands
import TestKit
import Titles
import Topology

// Fixtures only, titled as TitleNamesTests title theirs: cards named (the title Titles keeps), tiles
// named with a title worked out from their label for those nobody named, discs only worked out
// (from their size), and boxes with none.

/// Titles for the fixtures: cards named, tiles named or worked out from their label, discs worked out.
@MainActor func fixtureTitles() -> Contributor {
    Contributor(id: "fixture-titles") { registrar in
        registrar.title(Card.self, contents: false)
        registrar.optIn(Tile.self, to: TitleProperty.self)
        registrar.title(Tile.self, contents: false) { tile in TitleProperty.folded(tile[TitleProperty.self]) ?? tile.props.label }
        registrar.title(Disc.self, contents: false) { disc in "Disc, \(Int(disc.props.frame.width)) × \(Int(disc.props.frame.height))" }
    }
}

/// The keyboard and the selection (which Titles' pills need), Topology, the fixtures, Titles (with
/// the slash commands it offers) and Queries, then `TitleQueriesPlugin`, then `more`.
@MainActor func titledPlugins(withPlugin: Bool = true, more: [any CanvasPlugin] = []) -> [any CanvasPlugin] {
    [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), CardsPlugin(), TilesPlugin(), AdornmentsPlugin(), SlashCommandsPlugin(),
     TitlesPlugin(), fixtureTitles(), QueriesPlugin()] + (withPlugin ? [TitleQueriesPlugin()] : []) + more
}

func uuid(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-%012d", n) }
func id(_ n: Int) -> ShapeID { ShapeID(UUID(uuidString: uuid(n))!) }

let unit = CGRect(x: 0, y: 0, width: 120, height: 80)

/// A shape with an id numbered `n`, titled `title` if given.
func shape<P: ShapeProps>(_ n: Int, _ props: P, titled title: String? = nil) -> AnyShapeRecord {
    var record = AnyShapeRecord(ShapeRecord(id: id(n), props))
    record[TitleProperty.self] = title
    return record
}

/// On one board: card 1 "API gateway", card 2 titled over two lines with spaces around ("Auth
/// service" as it reads), card 3 untitled, tile 4 labeled "Kiosk" and untitled (so called "Kiosk"),
/// tile 5 labeled "Kiosk" and titled "Lobby", disc 6 (called "Disc, 120 × 80"), and box 7.
func titledFile() -> CanvasFile {
    CanvasFile(root: CanvasDocument(shapes: [
        shape(1, Card(unit), titled: "API gateway"), shape(2, Card(unit), titled: "  Auth \n  service "), shape(3, Card(unit)),
        shape(4, Tile(unit, label: "Kiosk")), shape(5, Tile(unit, label: "Kiosk"), titled: "Lobby"), shape(6, Disc(unit)), shape(7, Box(unit)),
    ]))
}

@MainActor func titledHarness(withPlugin: Bool = true, more: [any CanvasPlugin] = []) throws -> EditorHarness {
    try EditorHarness(plugins: titledPlugins(withPlugin: withPlugin, more: more), file: titledFile())
}

/// A query's answer on `h`'s editor, every row, the main run loop turned while it runs.
@MainActor func answer(_ text: String, on h: EditorHarness, properties: QueryRequest.Properties = .all,
                       file: StaticString = #fileID, line: UInt = #line) throws -> QueryResult {
    let queries = try require(h.editor.queries, file: file, line: line)
    return try awaitResult(file: file, line: line) {
        try await queries.run(QueryRequest(text, limit: QueryBudget.maxRows, properties: properties))
    }
}

/// Why `h`'s editor refuses a query; nil if it answers.
@MainActor func refusal(_ text: String, on h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) throws -> QueryError? {
    do {
        _ = try answer(text, on: h, file: file, line: line)
        return nil
    } catch let error as QueryError {
        return error
    }
}

/// Each query matches the shapes numbered, in that order.
@MainActor func expectMatches(_ cases: KeyValuePairs<String, [Int]>, on h: EditorHarness, file: StaticString = #fileID, line: UInt = #line) {
    for (text, numbers) in cases {
        do {
            expectEqual(try answer(text, on: h, properties: .none, file: file, line: line).rows.map(\.id), numbers.map(id), text, file: file, line: line)
        } catch {
            expect(false, "\(text) is refused: \(error)", file: file, line: line)
        }
    }
}

/// Something a closure sets and a test reads.
@MainActor final class Flag {
    var value = false
}
