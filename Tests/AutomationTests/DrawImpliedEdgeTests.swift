@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import TestKit

// `canvas draw` with a value that implies edges (`DrawValueWriting.edges`, a writer's `implies`): the edges are drawn with the
// script's own, on the line of the statement that writes the value; one the script writes too is that edge, drawn once; a run
// again is unchanged; a value that implies none leaves the shape's edges alone; a name the edge can't find is refused on the
// line; and an untitled shape can't start one. These tests' property is `points`, titles a line each, on tiles.

enum PointsProperty {}

extension PointsProperty: ShapeProperty {
    static let key: PropertyKey = "points"
    static var defaultValue: String? { nil }
}

/// `points` on tiles: its text kept as written, and each line an edge from the tile to the tile of that title, warm.
@MainActor func pointsPlugin() -> Contributor {
    Contributor(id: "points") { registrar in
        registrar.declare(PointsProperty.self)
        registrar.optIn(Tile.self, to: PointsProperty.self)
        registrar.drawValueWriter(for: PointsProperty.key, describes: "titles, a line each", write: { value, _ throws(DrawError) in value },
                                  implies: { value, _ throws(DrawError) in
            guard case .string(let text) = value else { return [] }
            return text.split(whereSeparator: \.isNewline).map { DrawImpliedEdge(fromRow: nil, to: String($0), toRow: nil, attributes: [Tone.key.rawValue: "warm"]) }
        }, merge: { written, _ in written })
    }
}

@MainActor let drawImpliedEdgeTests = Suite("draw: edges a value implies", [
    test("a value's edges are drawn on its statement's line, an edge the script writes too is drawn once, a run again is unchanged") {
        let editor = try drawEditor([pointsPlugin()])
        let script = "tile \"A\" points: \"B\\nC\"\ntile \"B\" right of \"A\"\ntile \"C\" below \"B\"\nedge \"A\" -> \"B\" tone: warm"
        let first = try drawn(script, on: editor)
        expectEqual(links(in: editor).sorted(), ["A -> B", "A -> C"])
        let made = rows(first).filter { $0["kind"]?.stringValue == Link.kind.rawValue }
        expectEqual(made.compactMap { $0["line"]?.intValue }.sorted(), [1, 4], "A -> C on the line that implies it; A -> B on its own")
        expectEqual(editor.document.shapes.compactMap { $0.typed(as: Link.self) }.map { $0[Tone.self] }, ["warm", "warm"])
        let again = try drawn(script, on: editor)
        expectEqual(Set(rows(again).compactMap { $0["did"]?.stringValue }), ["unchanged"])
    },
    test("a value that implies none leaves the shape's edges alone; a name it can't find is refused on its line; an untitled shape can't start one") {
        let editor = try drawEditor([pointsPlugin()])
        _ = try drawn("tile \"A\" points: \"B\"\ntile \"B\" right of \"A\"", on: editor)
        _ = try drawn("tile \"A\" points: \"\"", on: editor)
        expectEqual(links(in: editor), ["A -> B"])
        let missing = try refused("tile \"B\"\ntile \"A\" points: \"Nobody\"", on: editor)
        expectEqual(missing.reason, "unknown_title")
        expectEqual(missing.data?["line"]?.intValue, 2)
        let untitled = try refused("tile points: \"B\" below \"A\"", on: editor)
        expectEqual(untitled.reason, "unsupported")
    },
])
