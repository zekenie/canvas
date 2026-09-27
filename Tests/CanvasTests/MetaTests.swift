@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import TestKit

/// A plugin's metadata member, as a horizontal would declare one.
enum Origin {}
extension Origin: ShapeMetaKey {
    struct Value: Codable, Equatable, Sendable {
        var source: String
        var count: Int
    }
    static var owner: PluginID { "origins" }
    static var name: String { "origin" }
}

/// Points with no frame, moved by its own translation, and naming the shape it follows.
struct Trail: ShapeProps {
    static let kind: ShapeKind = "trail"
    var points: [CGPoint]
    var follows: ShapeID?
}

struct TrailDefinition {}

extension TrailDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Trail>, in context: RenderContext) {}
    func geometry(of shape: ShapeRecord<Trail>, in context: ShapeContext) -> ShapeGeometry {
        ShapeGeometry(outline: shape.props.points, isClosed: false)
    }
}

extension TrailDefinition: CustomTranslation {
    func beginTranslation(of shape: ShapeRecord<Trail>, movingWith _: Set<ShapeID>, in _: inout Transaction) -> ShapeTranslation<Trail> {
        let start = shape.props.points
        return ShapeTranslation { delta, shape, _ in shape.props.points = start.map { $0 + delta } }
    }
}

extension TrailDefinition: ShapeReferencing {
    func remappingReferences(of shape: ShapeRecord<Trail>, _ map: (ShapeID) -> ShapeID?, in context: ShapeContext) -> Trail {
        Trail(points: shape.props.points, follows: shape.props.follows.flatMap(map))
    }
}

@MainActor private func editor() throws -> CanvasEditor {
    CanvasEditor(registry: try Registry(plugins: [FixturesPlugin(), Contributor(id: "trails") { $0.shape(TrailDefinition()) }]))
}

@MainActor let metaTests = Suite("Shape metadata", [
    test("a member is typed by its key, stored as JSON by owner.name; setting nil removes it") {
        var meta = ShapeMeta()
        expect(meta.isEmpty)
        expectEqual(meta[Origin.self], nil)
        meta[Origin.self] = Origin.Value(source: "paste", count: 2)
        expectEqual(meta[Origin.self], Origin.Value(source: "paste", count: 2))
        expectEqual(meta.json, ["origins.origin": ["source": "paste", "count": 2]])
        meta[Origin.self] = nil
        expect(meta.isEmpty)
    },
    test("a member that doesn't decode as its key's value reads as nil, and is kept") {
        let meta = ShapeMeta(json: ["origins.origin": "not an object"])
        expectEqual(meta[Origin.self], nil)
        expectEqual(meta.json["origins.origin"], "not an object")
    },
    test("a record's metadata is changed in a transaction, which commits it as a change of that shape") {
        let editor = try editor()
        let id = editor.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let revision = editor.revision
        editor.transact { $0.update(id) { $0.meta[Origin.self] = Origin.Value(source: "test", count: 1) } }
        expectEqual(editor.revision, revision + 1)
        expectEqual(editor.document[id]?.meta[Origin.self]?.source, "test")
        editor.transact { $0.update(id) { $0.meta[Origin.self] = Origin.Value(source: "test", count: 1) } }
        expectEqual(editor.revision, revision + 1, "the same value commits nothing")
        editor.transact { $0.update(id, as: Box.self) { $0.frame.origin.x = 5 } }
        expectEqual(editor.document[id]?.meta[Origin.self]?.count, 1, "a typed update keeps it")
    },
    test("boards keep metadata beside the props, known or not, and one without any as before") {
        let registry = try Registry(plugins: [FixturesPlugin()])
        var tagged = AnyShapeRecord(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 10, height: 10))))
        tagged.meta = ShapeMeta(json: ["origins.origin": ["source": "paste", "count": 2], "someone.else": [1, 2]])
        let plain = AnyShapeRecord(ShapeRecord(Box(CGRect(x: 20, y: 0, width: 10, height: 10))))
        let codec = BoardCodec(registry: registry)
        let data = try codec.encode(CanvasDocument(shapes: [tagged, plain]))
        let json = try require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let shapes = try require(json["shapes"] as? [[String: Any]])
        expectEqual(shapes.map { $0["meta"] != nil }, [true, false])
        let read = try codec.decode(data)
        expectEqual(read.report, LoadReport())
        expectEqual(read.document.shapes.map(\.meta), [tagged.meta, ShapeMeta()])
        expectEqual(read.document.shapes.first?.meta[Origin.self], Origin.Value(source: "paste", count: 2))
    },
    test("a shape kept aside keeps its metadata; metadata that isn't an object is left out") {
        let registry = try Registry(plugins: [FixturesPlugin()])
        let json = #"""
        { "format" : 1, "schema" : {}, "shapes" : [
          { "id" : "00000000-0000-0000-0000-000000000001", "index" : "a0", "kind" : "comet", "props" : {}, "meta" : { "a.b" : true } },
          { "id" : "00000000-0000-0000-0000-000000000002", "index" : "a1", "kind" : "box", "props" : { "frame" : [[0, 0], [1, 1]] }, "meta" : 3 }
        ] }
        """#
        let codec = BoardCodec(registry: registry)
        let read = try codec.decode(Data(json.utf8))
        expectEqual(read.document.shapes.map(\.meta), [ShapeMeta(json: ["a.b": true]), ShapeMeta()])
        let again = try codec.decode(try codec.encode(read.document))
        expectEqual(again.document.shapes.first?.meta, ShapeMeta(json: ["a.b": true]))
    },
])

@MainActor let copyingTests = Suite("Copying shapes", [
    test("a record's copy has another id, its kind, props and metadata, and no place in a stack") {
        let editor = try editor()
        let id = editor.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        editor.transact { $0.update(id) { $0.meta[Origin.self] = Origin.Value(source: "x", count: 0) } }
        let original = try require(editor.document[id])
        let copy = original.copy()
        expect(copy.id != id)
        expectEqual(copy.kind, original.kind)
        expectEqual(copy.box, original.box)
        expectEqual(copy.meta, original.meta)
        expectEqual(copy.stackingKey, nil)
        let named = ShapeID()
        expectEqual(original.copy(as: named).id, named)
    },
    test("remapping passes a ShapeReferencing kind's references through the map, and leaves any other kind as it is") {
        let editor = try editor()
        let box = editor.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let trail = editor.add(Trail(points: [.zero], follows: box))
        let other = ShapeID()
        let record = try require(editor.document[trail])
        expectEqual(record.remappingReferences({ $0 == box ? other : nil }, in: editor.shapeContext).typed(as: Trail.self)?.props.follows, other)
        expectEqual(record.remappingReferences({ _ in nil }, in: editor.shapeContext).typed(as: Trail.self)?.props.follows, nil)
        let boxRecord = try require(editor.document[box])
        expectEqual(boxRecord.remappingReferences({ _ in nil }, in: editor.shapeContext), boxRecord)
    },
    test("translate moves boxes by their frames and other kinds by their own translation, in one commit") {
        let editor = try editor()
        let box = editor.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        let trail = editor.add(Trail(points: [CGPoint(x: 1, y: 1), CGPoint(x: 5, y: 3)]))
        let tag = editor.add(Tag(target: box))
        let still = editor.add(Box(CGRect(x: 50, y: 50, width: 10, height: 10)))
        let before = editor.document[tag]
        let revision = editor.revision
        editor.transact { $0.translate([box, trail, tag], by: CGPoint(x: 10, y: -5)) }
        expectEqual(editor.revision, revision + 1)
        expectEqual(editor.document[box]?.box, CGRect(x: 10, y: -5, width: 10, height: 10))
        expectEqual(editor.document[trail]?.typed(as: Trail.self)?.props.points, [CGPoint(x: 11, y: -4), CGPoint(x: 15, y: -2)])
        expectEqual(editor.document[tag], before, "no frame and no translation of its own: it stays")
        expectEqual(editor.document[still]?.box, CGRect(x: 50, y: 50, width: 10, height: 10))
    },
])
