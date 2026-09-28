import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// Making and changing shapes outside the pointer (the command line's `draw`): what a kind's tool
// places, a shape from its properties as one JSON object, the inverse of `propertiesJSON`, and a
// shape with some of them set (`shape(_:setting:)`).

/// Boxes (no tool), and cards (a tool places them, 100 × 60), which have stars and may have a sticker.
@MainActor func cardsWithStars() throws -> Registry {
    try Registry(plugins: [FixturesPlugin(), CardsPlugin(), Contributor(id: "stars") { registrar in
        registrar.declare(Stars.self)
        registrar.declare(Sticker.self)
        registrar.optIn(Card.self, to: Stars.self)
        registrar.optIn(Card.self, to: Sticker.self)
    }])
}

@MainActor func shapeError(_ body: () throws(ShapePropertiesError) -> AnyShapeRecord) -> ShapePropertiesError? {
    do throws(ShapePropertiesError) {
        _ = try body()
        return nil
    } catch {
        return error
    }
}

@MainActor let shapePropertiesTests = Suite("Shapes from their properties", [
    test("some of a kind's properties, as JSON, checked against its schema before they're read: what reading would drop shows") {
        let registry = try cardsWithStars()
        expectEqual(registry.schemaViolations(of: ["text": "Hi", "stars": 3], kind: Card.kind).map(\.pointer), ["/frame"],
                    "only the required frame it leaves out")
        let wrong = registry.schemaViolations(of: ["frame": [[0, 0], [10, 10]], "stars": "three", "colour": "red"], kind: Card.kind)
        expectEqual(wrong.map { "\($0.pointer) \($0.keyword)" }, ["/stars type", "/colour additionalProperties"])
        expectEqual(registry.schemaViolations(of: ["text": "Hi"], kind: ShapeKind(rawValue: "nothing")), [], "a kind nobody registers")
    },
    test("a kind's placement is its tool's: its size, and the shape it puts down with its middle on a point") {
        let registry = try cardsWithStars()
        let placement = try require(registry.placement(for: Card.kind))
        expectEqual(placement.size, CGSize(width: 100, height: 60))
        let card = placement.shape(at: CGPoint(x: 10, y: 10))
        expectEqual(card.kind, Card.kind)
        expectEqual(card.box, CGRect(x: -40, y: -20, width: 100, height: 60))
        expect(registry.placement(for: Box.kind) == nil, "no tool places a box")
    },
    test("a second fixture kind a tool places: tiles, 120 × 80, with a label and a finish of two words") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), CardsPlugin(), TilesPlugin()])
        let registry = h.editor.registry
        expectEqual(registry.tools.map(\.id), [.hand, ToolID(placing: Card.kind), ToolID(placing: Tile.kind)])
        let placement = try require(registry.placement(for: Tile.kind))
        expectEqual(placement.size, TilesPlugin.size)
        expectEqual(placement.shape(at: CGPoint(x: 100, y: 100)).box, CGRect(x: 40, y: 60, width: 120, height: 80))
        h.editor.setTool(ToolID(placing: Tile.kind))
        h.click(at: CGPoint(x: 300, y: 200))
        let tile = try require(h.editor.document.shapes.first?.typed(as: Tile.self))
        expectEqual(tile.frame, CGRect(x: 240, y: 160, width: 120, height: 80))
        expectEqual(tile.props.finish, .matte)
        let finish = try require(registry.schema(for: Tile.kind)?.json["properties"]?["finish"])
        expectEqual(finish["oneOf"], [["const": "matte", "title": "Matte"], ["const": "glossy", "title": "Glossy"]])
        let glossy = try registry.shape(Tile.kind, properties: ["frame": [[0, 0], [10, 10]], "label": "Hi", "finish": "glossy"])
        expectEqual(glossy.typed(as: Tile.self)?.props, Tile(CGRect(x: 0, y: 0, width: 10, height: 10), label: "Hi", finish: .glossy))
    },
    test("a shape read from what propertiesJSON writes is that shape, own and added properties alike, under a new id") {
        let registry = try cardsWithStars()
        var card = AnyShapeRecord(ShapeRecord(Card(CGRect(x: 1, y: 2, width: 3, height: 4), text: "Hi")))
        card[Stars.self] = 3
        card[Sticker.self] = "gold"
        let json = try require(card.propertiesJSON)
        let read = try registry.shape(Card.kind, properties: json)
        expect(read.id != card.id)
        expectEqual(read.typed(as: Card.self)?.props, card.typed(as: Card.self)?.props)
        expectEqual(read[Stars.self], 3)
        expectEqual(read[Sticker.self], "gold")
        expectEqual(read.propertiesJSON, json)
        let id = ShapeID()
        expectEqual(try registry.shape(Card.kind, properties: json, id: id).id, id)
    },
    test("what's left out, or null, is as the kind has it: its own default, an added property's, or none") {
        let registry = try cardsWithStars()
        let read = try registry.shape(Card.kind, properties: ["frame": [[0, 0], [10, 10]], "sticker": nil])
        expectEqual(read.typed(as: Card.self)?.props.text, "")
        expectEqual(read[Stars.self], 0)
        expectEqual(read[Sticker.self], nil)
    },
    test("an added property given a value that's none is as if left out: its default, or none") {
        let registry = try Registry(plugins: [FixturesPlugin(), Contributor(id: "tempers") { r in
            r.declare(Temper.self)
            r.declare(Nickname.self)
            r.optIn(Box.self, to: Temper.self)
            r.optIn(Box.self, to: Nickname.self)
        }])
        let read = try registry.shape(Box.kind, properties: ["frame": [[0, 0], [10, 10]], "temper": "  ", "nickname": " "])
        expectEqual(read[Temper.self], "calm")
        expectEqual(read[Nickname.self], nil)
    },
    test("a kind nobody registers, a property the kind doesn't have, and a value that doesn't read are refused, saying which") {
        let registry = try cardsWithStars()
        let frame: JSONValue = [[0, 0], [10, 10]]
        expectEqual(shapeError { () throws(ShapePropertiesError) in try registry.shape("nope", properties: [:]) }, .unknownKind("nope"))
        expectEqual(shapeError { () throws(ShapePropertiesError) in try registry.shape(Card.kind, properties: ["frame": frame, "colour": "red"]) },
                    .unknownProperty("colour", kind: Card.kind))
        expectEqual(shapeError { () throws(ShapePropertiesError) in try registry.shape(Box.kind, properties: ["stars": 1, "frame": frame]) },
                    .unknownProperty("stars", kind: Box.kind), "boxes don't opt in")
        expectEqual(shapeError { () throws(ShapePropertiesError) in try registry.shape(Card.kind, properties: ["text": "Hi"]) },
                    .unreadable("frame is missing"))
        expectEqual(shapeError { () throws(ShapePropertiesError) in try registry.shape(Card.kind, properties: ["frame": [["nan", 0], [1, 1]]]) },
                    .unreadable("its frame isn't finite"))
        guard case .unreadable(let why)? = shapeError({ () throws(ShapePropertiesError) in
            try registry.shape(Card.kind, properties: ["frame": frame, "stars": "many"])
        }) else { return expect(false, "stars aren't words") }
        expect(why.hasPrefix("stars"), why)
    },
    test("setting properties on a shape changes only those: its id, place in the stack, metadata and every other member stay exactly as they were") {
        let registry = try samplesWithStars()
        let editor = CanvasEditor(registry: registry)
        var sample = Sample()
        sample.frame = CGRect(x: 0, y: 0, width: 50, height: 50)
        sample.due = Date(timeIntervalSince1970: 1_000_000.125)      // what a round trip through JSON would lose
        sample.parts = [Sample.Part(label: "tail")]
        let id = editor.add(sample)
        editor.transact { $0.update(id) { $0[Sticker.self] = "gold" } }
        var record = try require(editor.document[id])
        record.meta[Origin.self] = Origin.Value(source: "board", count: 2)
        let set = try registry.shape(record, setting: ["name": "Kite", "stars": 4])
        expectEqual(set.id, id)
        expectEqual(set.stackingKey, record.stackingKey)
        expectEqual(set.meta, record.meta)
        let props = try require(set.typed(as: Sample.self)?.props)
        expectEqual(props.name, "Kite")
        expectEqual(props.due, sample.due, "to the fraction of a second")
        expectEqual(props.parts, sample.parts)
        expectEqual(props.frame, sample.frame)
        expectEqual(set[Stars.self], 4)
        expectEqual(set[Sticker.self], "gold")
        expectEqual(try registry.shape(record, setting: [:]), record, "nothing set, nothing changed")
        expectEqual(try registry.shape(record, setting: ["name": "untitled", "sticker": "gold"]), record, "set as it was, the same shape")
        editor.transact { tx in tx.update(id) { $0 = set } }
        expectEqual(editor.document[id]?.typed(as: Sample.self)?.props.name, "Kite", "a transaction takes it")
    },
    test("null puts a property back to its default, own or added; a required one refuses it") {
        let registry = try samplesWithStars()
        var sample = Sample()
        sample.name = "Kite"
        sample.count = 7
        sample.due = Date(timeIntervalSince1970: 0)
        var record = AnyShapeRecord(ShapeRecord(sample))
        record[Stars.self] = 3
        record[Sticker.self] = "gold"
        let reset = try registry.shape(record, setting: ["name": nil, "due": nil, "stars": nil, "sticker": nil])
        let props = try require(reset.typed(as: Sample.self)?.props)
        expectEqual(props.name, "untitled")
        expectEqual(props.due, nil)
        expectEqual(props.count, 7, "what isn't set stays")
        expectEqual(reset[Stars.self], 0)
        expectEqual(reset[Sticker.self], nil)
        expectEqual(shapeError { () throws(ShapePropertiesError) in try registry.shape(record, setting: ["frame": nil]) },
                    .unreadable("frame: it's required, so it can't be null"))
    },
    test("what can't be set is refused as when shapes are made, and so is a value kept aside, or a shape; values kept aside stay") {
        let registry = try samplesWithStars()
        let board = #"""
            { "format" : 3, "versions" : { "kinds" : { "sample" : 0, "gadget" : 0 }, "added" : { "stars" : 0, "sticker" : 0 } }, "shapes" : [
              { "id" : "00000000-0000-0000-0000-000000000001", "kind" : "sample", "index" : "a0", "props" : { "frame" : [[0, 0], [10, 10]] },
                "added" : { "sticker" : 12, "stars" : 2 } },
              { "id" : "00000000-0000-0000-0000-000000000002", "kind" : "gadget", "index" : "a1", "props" : { "gears" : 3 } } ] }
            """#
        let loaded = try BoardCodec(registry: registry).decode(Data(board.utf8))
        let sample = try require(loaded.document.shapes.first), gadget = try require(loaded.document.shapes.last)
        expectEqual(sample.keptProperties, ["sticker"])
        expect(gadget.isOpaque)
        let set = try registry.shape(sample, setting: ["stars": 5])
        expectEqual(set[Stars.self], 5)
        expectEqual(set.keptProperties, ["sticker"], "kept as it was")
        guard case .unreadable(let kept)? = shapeError({ () throws(ShapePropertiesError) in try registry.shape(sample, setting: ["sticker": "gold"]) })
        else { return expect(false, "a value kept aside was set") }
        expect(kept.hasPrefix("sticker"), kept)
        guard case .unreadable? = shapeError({ () throws(ShapePropertiesError) in try registry.shape(gadget, setting: [:]) })
        else { return expect(false, "a shape kept aside was set") }
        expectEqual(shapeError { () throws(ShapePropertiesError) in try registry.shape(sample, setting: ["colour": "red"]) },
                    .unknownProperty("colour", kind: Sample.kind))
        expectEqual(shapeError { () throws(ShapePropertiesError) in try registry.shape(sample, setting: ["frame": [["nan", 0], [1, 1]]]) },
                    .unreadable("its frame isn't finite"))
        guard case .unreadable(let why)? = shapeError({ () throws(ShapePropertiesError) in try registry.shape(sample, setting: ["count": "many"]) })
        else { return expect(false, "a count isn't a word") }
        expect(why.hasPrefix("count"), why)
        let other = try Registry(plugins: [FixturesPlugin()])
        expectEqual(shapeError { () throws(ShapePropertiesError) in try other.shape(sample, setting: [:]) }, .unknownKind(Sample.kind))
    },
])

/// Samples (every kind of property), which have stars and may have a sticker.
@MainActor func samplesWithStars() throws -> Registry {
    try Registry(plugins: [FixturesPlugin(), Contributor(id: "stars") { registrar in
        registrar.shape(PlainDefinition<Sample>())
        registrar.declare(Stars.self)
        registrar.declare(Sticker.self)
        registrar.optIn(Sample.self, to: Stars.self)
        registrar.optIn(Sample.self, to: Sticker.self)
    }])
}
