@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import TestKit

/// Every shape of a kind that opts in has stars (0 until rated).
enum Stars {}
extension Stars: ShapeProperty {
    static let key: PropertyKey = "stars"
    static var defaultValue: Int? { 0 }
}

/// Only the shapes someone puts a sticker on have one.
enum Sticker {}
extension Sticker: ShapeProperty {
    static let key: PropertyKey = "sticker"
    static var defaultValue: String? { nil }
}

/// A value with a shared definition, which takes its owner's name.
struct Ribbon: SchemaDefined, Equatable {
    static let properties = Properties<Ribbon>(definition: "ribbon") {
        Property("color", \.color)
    }
    var color = "blue"
}

enum Ribbons {}
extension Ribbons: ShapeProperty {
    static let key: PropertyKey = "ribbons"
    static var defaultValue: [Ribbon]? { [] }
}

/// Every shape of a kind that opts in has a temper: calm until it's set, and none when it's blank.
enum Temper {}
extension Temper: ShapeProperty {
    static let key: PropertyKey = "temper"
    static var defaultValue: String? { "calm" }
    static func isNone(_ temper: String) -> Bool { temper.allSatisfy(\.isWhitespace) }
}

/// A nickname only the shapes given one have, and none when it's blank.
enum Nickname {}
extension Nickname: ShapeProperty {
    static let key: PropertyKey = "nickname"
    static var defaultValue: String? { nil }
    static func isNone(_ name: String) -> Bool { name.allSatisfy(\.isWhitespace) }
}

/// A default that's none, which no shape could hold.
enum Hollow {}
extension Hollow: ShapeProperty {
    static let key: PropertyKey = "hollow"
    static var defaultValue: String? { "" }
    static func isNone(_ value: String) -> Bool { value.isEmpty }
}

/// A kind with a property of its own named like an added one.
struct Rated: BoxShapeProps {
    static let kind: ShapeKind = "rated"
    static let properties = Properties<Rated> {
        Property("frame", \.frame).required()
        Property("stars", \.stars)
    }
    var frame: CGRect = .zero
    var stars = 5
}

/// Declares the three; boxes opt into stars and stickers, and discs don't.
@MainActor func ratings(_ more: @escaping @MainActor (inout PluginRegistrar) -> Void = { _ in }) -> Contributor {
    Contributor(id: "ratings") { r in
        r.declare(Stars.self)
        r.declare(Sticker.self)
        r.declare(Ribbons.self)
        r.optIn(Box.self, to: Stars.self)
        r.optIn(Box.self, to: Sticker.self)
        more(&r)
    }
}

private let frame = CGRect(x: 0, y: 0, width: 100, height: 100)

@MainActor private func refusal(_ plugins: [any CanvasPlugin]) -> String? {
    do {
        _ = try Registry(plugins: plugins)
        return nil
    } catch {
        return "\(error)"
    }
}

@MainActor let addedPropertyTests = Suite("Added properties", [
    test("a shape of a kind that opts in gets each property's default when it's added; one of a kind that doesn't has none") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ratings()])
        let box = h.add(Box(frame)), disc = h.add(Disc(frame))
        let record = try require(h.editor.document[box])
        expectEqual(record[Stars.self], 0)
        expectEqual(record[Sticker.self], nil)
        expectEqual(try require(h.editor.document[box]?.typed(as: Box.self))[Stars.self], 0, "a typed record carries them")
        expectEqual(h.editor.document[disc]?[Stars.self], nil)
        expectEqual(h.editor.registry.properties(for: Box.kind), ["stars", "sticker"])
        expectEqual(h.editor.registry.properties(for: Disc.kind), [])
        expectEqual(h.editor.registry.declaredProperties, ["stars", "sticker", "ribbons"])
        expectEqual(h.editor.registry.owner(of: "stars"), "ratings")
    },
    test("a value is changed like the props: in a transaction, one commit, which changes nothing when it's the same") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ratings()])
        let box = h.add(Box(frame))
        let revision = h.editor.revision
        h.editor.transact { $0.update(box) { $0[Stars.self] = 3 } }
        expectEqual(h.editor.document[box]?[Stars.self], 3)
        expectEqual(h.editor.revision, revision + 1)
        h.editor.transact { $0.update(box) { $0[Stars.self] = 3 } }
        expectEqual(h.editor.revision, revision + 1, "the same value commits nothing")
        h.editor.transact { $0.update(box, as: Box.self) { $0[Stars.self]? += 1 } }
        expectEqual(h.editor.document[box]?[Stars.self], 4, "a typed update writes them too")
        h.editor.transact { $0.update(box) { $0[Sticker.self] = "gold" } }
        expectEqual(h.editor.document[box]?[Sticker.self], "gold")
        h.editor.transact { $0.update(box) { $0[Sticker.self] = nil } }
        expectEqual(h.editor.document[box]?[Sticker.self], nil, "a property only some shapes have can be removed")
    },
    test("writes that can't hold are dropped: nil for a property every shape has, and a value on a kind that doesn't opt in") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ratings()])
        let box = h.add(Box(frame)), disc = h.add(Disc(frame))
        let revision = h.editor.revision
        h.editor.transact {
            $0.update(box) { $0[Stars.self] = nil }
            $0.update(disc) { $0[Stars.self] = 4 }
        }
        expectEqual(h.editor.document[box]?[Stars.self], 0)
        expectEqual(h.editor.document[disc]?[Stars.self], nil)
        expectEqual(h.editor.revision, revision)
    },
    test("a value that's none is no value: a shape set to one holds nil, or its property's default; a board's reads the same") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), Contributor(id: "tempers") { r in
            r.declare(Temper.self)
            r.declare(Nickname.self)
            r.optIn(Box.self, to: Temper.self)
            r.optIn(Box.self, to: Nickname.self)
        }])
        let box = h.add(Box(frame))
        h.editor.transact { $0.update(box) { $0[Temper.self] = "stormy"; $0[Nickname.self] = "Boxy" } }
        h.editor.transact { $0.update(box) { $0[Temper.self] = "  "; $0[Nickname.self] = "" } }
        expectEqual(h.editor.document[box]?[Temper.self], "calm", "the default")
        expectEqual(h.editor.document[box]?[Nickname.self], nil)
        let board = """
            { "format" : 3, "versions" : { "added" : { "nickname" : 0, "temper" : 0 }, "kinds" : { "box" : 0 } }, "shapes" : [
              { "id" : "11111111-1111-1111-1111-111111111111", "index" : "a0", "kind" : "box",
                "props" : { "frame" : [[0, 0], [10, 10]] }, "added" : { "nickname" : " ", "temper" : "" } } ] }
            """
        let loaded = try BoardCodec(registry: h.editor.registry).decode(Data(board.utf8))
        expectEqual(loaded.report, LoadReport())
        expectEqual(loaded.document.shapes.first?[Temper.self], "calm")
        expectEqual(loaded.document.shapes.first?[Nickname.self], nil)
    },
    test("the registry refuses a property whose default is a value that's none") {
        expectEqual(refusal([FixturesPlugin(), Contributor(id: "hollows") { $0.declare(Hollow.self) }]),
                    "PropertyDeclarations: property hollow (from hollows): its default is a value that's none (isNone), which no shape holds")
    },
    test("a value written as null, added or kept, is none, as a missing one is: nothing is kept aside, and the shape takes one") {
        let registry = try Registry(plugins: [FixturesPlugin(), ratings()])
        let board = """
            { "format" : 3, "versions" : { "added" : { "stars" : 0, "sticker" : 0 }, "kinds" : { "box" : 0 } }, "shapes" : [
              { "id" : "11111111-1111-1111-1111-111111111111", "index" : "a0", "kind" : "box",
                "props" : { "frame" : [[0, 0], [10, 10]] }, "added" : { "stars" : null, "sticker" : null } },
              { "id" : "22222222-2222-2222-2222-222222222222", "index" : "a1", "kind" : "box",
                "props" : { "frame" : [[0, 0], [10, 10]] }, "kept" : { "sticker" : { "v" : 0, "value" : null } } } ] }
            """
        let loaded = try BoardCodec(registry: registry).decode(Data(board.utf8))
        expectEqual(loaded.report, LoadReport())
        expectEqual(loaded.document.shapes.map { $0[Stars.self] }, [0, 0], "the default")
        expectEqual(loaded.document.shapes.map { $0[Sticker.self] }, [nil, nil])
        expectEqual(loaded.document.shapes.map(\.keptProperties), [[], []])
        let editor = CanvasEditor(registry: registry, document: loaded.document, scheduler: ManualScheduler())
        for shape in loaded.document.shapes { editor.transact { $0.update(shape.id) { $0[Sticker.self] = "gold" } } }
        expectEqual(editor.document.shapes.map { $0[Sticker.self] }, ["gold", "gold"])
    },
    test("an editor fills in the defaults of a document it's given, or replaces its own with, without marking it edited") {
        let registry = try Registry(plugins: [FixturesPlugin(), ratings()])
        let first = ShapeRecord(Box(frame)), second = ShapeRecord(Box(frame))
        let editor = CanvasEditor(registry: registry, document: CanvasDocument(shapes: [AnyShapeRecord(first)]), scheduler: ManualScheduler())
        expectEqual(editor.document[first.id]?[Stars.self], 0)
        expect(!editor.canUndo)
        let events = UndoEvents(editor)
        editor.replaceDocument(with: CanvasDocument(shapes: [AnyShapeRecord(second)]))
        expectEqual(editor.document[second.id]?[Stars.self], 0)
        expect(!editor.canUndo)
        expectEqual(events.events, [.cleared], "no step began")
        expectEqual(registry.fillingDefaults(CanvasDocument(shapes: [AnyShapeRecord(first)])), CanvasDocument(shapes: [AnyShapeRecord(first)]).filled(with: registry))
    },
    test("a copy keeps its added values, and its meta") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), ratings()])
        let box = h.add(Box(frame))
        h.editor.transact { $0.update(box) { $0[Stars.self] = 2; $0[Sticker.self] = "gold" } }
        let copy = try require(h.editor.document[box]).copy()
        expectEqual(copy[Stars.self], 2)
        expectEqual(copy[Sticker.self], "gold")
    },
    test("an every-kind opt-in goes by each kind's definition, so by capability") {
        let registry = try Registry(plugins: [FixturesPlugin(), Contributor(id: "ratings") { r in
            r.declare(Stars.self)
            r.optInEveryShape(to: Stars.self, where: { !($0 is any PaintOrderAnchored) })
        }])
        expectEqual(registry.properties(for: Box.kind), ["stars"])
        expectEqual(registry.properties(for: Disc.kind), ["stars"])
        expectEqual(registry.properties(for: Tag.kind), [], "tags are anchored")
    },
    test("the registry refuses an undeclared property, two declarations of one, a kind opting in twice, and a kind's own property of the same name") {
        expectEqual(refusal([FixturesPlugin(), Contributor(id: "ratings") { $0.optIn(Box.self, to: Stars.self) }]),
                    "PropertyOptIns: ratings opts box into property stars, which no installed plugin declares")
        expectEqual(refusal([FixturesPlugin(), ratings(), Contributor(id: "more") { $0.declare(Stars.self) }]),
                    "ratings and more both claim stars in PropertyDeclarations")
        expectEqual(refusal([FixturesPlugin(), ratings(), Contributor(id: "more") { $0.optIn(Box.self, to: Stars.self) }]),
                    "ratings and more both claim box's stars in PropertyOptIns")
        expectEqual(refusal([FixturesPlugin(), ratings { $0.optInEveryShape(to: Stars.self) }]),
                    "PropertyOptIns: ratings opts box into property stars twice")
        expectEqual(refusal([FixturesPlugin(), ratings { $0.shape(PlainDefinition<Rated>()) { rated in rated.optIn(to: Stars.self) } }]),
                    "PropertyOptIns: rated has a property of its own named stars, so it can't opt into the one ratings declares; hand the member over to it (PropsMigration.handOver), or rename one")
    },
    test("the report shows who declares a property, and who opts which kind in") {
        let registry = try Registry(plugins: [FixturesPlugin(), ratings { $0.optInEveryShape(to: Ribbons.self) }])
        expectEqual(registry.report, """
        core          tool hand · command undo · command redo · command zoomIn in View · command zoomOut in View · command zoomToActualSize in View · command zoomToFit in View
        fixtures      shape box · shape disc · shape tag
        ratings       property stars · property sticker · property ribbons · property stars → box · property sticker → box · property ribbons → every shape
        """)
    },
    test("a kind's schema has each property it opts into, with its owner and default, and its definitions under their modules' names") {
        let registry = try Registry(plugins: [FixturesPlugin(), ratings { $0.optIn(Box.self, to: Ribbons.self) }])
        let json = try require(registry.schema(for: Box.kind)).json
        let properties = try require(json["properties"]?.objectValue)
        expectEqual(Set(properties.keys), ["frame", "stars", "sticker", "ribbons"])
        expectEqual(properties["stars"], ["type": "integer", "x-canvas-owner": "ratings", "default": 0])
        expectEqual(properties["sticker"], ["type": "string", "x-canvas-owner": "ratings"])
        expectEqual(properties["ribbons"], ["type": "array", "items": ["$ref": "#/$defs/canvastests.ribbon"], "x-canvas-owner": "ratings", "default": []])
        expectEqual(json["required"], ["frame"])
        expectEqual(danglingReferences(in: json), [])
        expectEqual(try require(registry.schema(for: Disc.kind)).json["properties"]?.objectValue?.keys.sorted(), ["frame"])
    },
])

extension CanvasDocument {
    /// Filled by hand: each box with stars at 0.
    @MainActor fileprivate func filled(with registry: Registry) -> CanvasDocument {
        CanvasDocument(shapes: shapes.map { record in
            var record = record
            if registry.properties(for: record.kind).contains("stars") { record[Stars.self] = 0 }
            return record
        })
    }
}
