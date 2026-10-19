@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import TestKit

// A plugin puts down a record it built through a placement (`mapping`, `sized`), and reads one added
// value by its key as JSON (`addedJSON(for:)`).

@MainActor private func registry() throws -> Registry {
    try Registry(plugins: [FixturesPlugin(), TilesPlugin(), Contributor(id: "stars") { r in
        r.declare(Stars.self)
        r.optIn(Tile.self, to: Stars.self)
    }])
}

@MainActor let placementHelperTests = Suite("Placements a plugin builds", [
    test("a placement mapped makes what its function makes of each shape, in the frame it was given") {
        let registry = try registry()
        let place = registry.placement(for: Tile.kind)!
        expectEqual(place.shape(at: CGPoint(x: 100, y: 100)).box, CGRect(x: 40, y: 60, width: 120, height: 80))
        let mapped = place.mapping { record in
            var record = record
            record[Stars.self] = 3
            record.box?.size.width += 10
            return record
        }
        let shape = mapped.shape(at: CGPoint(x: 100, y: 100))
        expectEqual(shape[Stars.self], 3)
        expectEqual(shape.box, CGRect(x: 40, y: 60, width: 130, height: 80))
        expectEqual(mapped.size, place.size, "its size is as it was")
        expectEqual(mapped.kind, Tile.kind)
        expectEqual(place.shape(at: .zero)[Stars.self], nil, "and the one it was made from is untouched")
    },
    test("a mapped placement places in the editor: the shape is put down as mapped") {
        let registry = try registry()
        let editor = CanvasEditor(registry: registry, scheduler: ManualScheduler())
        let mapped = registry.placement(for: Tile.kind)!.mapping { record in
            var record = record
            record[Stars.self] = 5
            return record
        }
        editor.place(mapped, at: CGPoint(x: 200, y: 200))
        expectEqual(editor.document.shapes.last?[Stars.self], 5)
    },
    test("a placement sized makes shapes of that size, and keeps its minimum") {
        let registry = try registry()
        let place = registry.placement(for: Tile.kind)!.sized(CGSize(width: 40, height: 20))
        expectEqual(place.size, CGSize(width: 40, height: 20))
        expectEqual(place.shape(at: CGPoint(x: 100, y: 100)).box, CGRect(x: 80, y: 90, width: 40, height: 20))
        let chained = place.mapping { $0 }.sized(CGSize(width: 10, height: 10))
        expectEqual(chained.shape(at: CGPoint(x: 10, y: 10)).box, CGRect(x: 5, y: 5, width: 10, height: 10))
    },
    test("an added value is read by its key as the JSON a board would write; none, for a key the shape holds no value for") {
        let registry = try registry()
        let editor = CanvasEditor(registry: registry, scheduler: ManualScheduler())
        var shape = registry.placement(for: Tile.kind)!.shape(at: .zero)
        expectEqual(shape.addedJSON(for: Stars.key), nil, "no value yet")
        shape[Stars.self] = 4
        expectEqual(shape.addedJSON(for: Stars.key), .number(4))
        expectEqual(shape.addedJSON(for: "nope"), nil)
        var plain = AnyShapeRecord(ShapeRecord(Disc(.zero)))
        plain[Stars.self] = 2
        editor.transact { $0.insert(shape); $0.insert(plain) }
        expectEqual(editor.document[shape.id]?.addedJSON(for: Stars.key), .number(4))
        expectEqual(editor.document[plain.id]?.addedJSON(for: Stars.key), nil, "a kind that doesn't opt in holds none")
    },
])
