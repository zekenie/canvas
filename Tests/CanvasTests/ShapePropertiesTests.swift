import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

// Making shapes outside the pointer (the command line's `create`): what a kind's tool places, and
// a shape from its properties as one JSON object, the inverse of `propertiesJSON`.

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
    test("a kind's placement is its tool's: its size, and the shape it puts down with its middle on a point") {
        let registry = try cardsWithStars()
        let placement = try require(registry.placement(for: Card.kind))
        expectEqual(placement.size, CGSize(width: 100, height: 60))
        let card = placement.shape(at: CGPoint(x: 10, y: 10))
        expectEqual(card.kind, Card.kind)
        expectEqual(card.box, CGRect(x: -40, y: -20, width: 100, height: 60))
        expect(registry.placement(for: Box.kind) == nil, "no tool places a box")
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
])
