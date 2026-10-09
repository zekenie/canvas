@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Titles
import Topology
import Types

// `is`, the types a shape is, and the `is-a` edge derived from it: over a memo that opts in as a
// note does (`typeable()`), and a stand-in of the tests' own.

/// A box that says where its words are but opts into nothing: `typeable()` is refused on it.
private struct Scrap: BoxShapeProps {
    static let kind: ShapeKind = "scrap"
    static let properties = Properties<Scrap>(title: "Scrap") {
        Property("frame", \.frame).required()
        Property("text", \.text)
    }
    var frame = CGRect(x: 0, y: 0, width: 100, height: 40)
    var text: MentionText = ""
    init() {}
}

@MainActor private struct ScrapDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Scrap>, in context: RenderContext) {}
}

private struct ScrapsPlugin: CanvasPlugin {
    var words: Bool
    var id: PluginID { "scraps" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(ScrapDefinition()) { scrap in
            if words { scrap.typeWords(\.text, drawnIn: { _ in nil }) }
            scrap.typeable()
        }
    }
}

/// A box that stands for the shapes it cites (its record names them).
private struct Echo: BoxShapeProps {
    static let kind: ShapeKind = "echo"
    static let properties = Properties<Echo>(title: "Echo") {
        Property("frame", \.frame).required()
        Property("stands", \.stands)
    }
    var frame: CGRect
    var stands: [Citation]
    init(_ frame: CGRect = CGRect(x: 600, y: 40, width: 100, height: 40), stands: [Citation] = []) {
        self.frame = frame
        self.stands = stands
    }
    init() { self.init(stands: []) }
}

@MainActor private struct EchoDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Echo>, in context: RenderContext) {}
}

private struct EchoesPlugin: CanvasPlugin {
    var id: PluginID { "echoes" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(EchoDefinition()) { echo in
            echo.standsIn { shape, _ in shape.props.stands.isEmpty ? nil : .shapes(shape.props.stands.map(\.shape)) }
        }
    }
}

@MainActor private func isEdges(_ editor: CanvasEditor, from id: ShapeID) throws -> [Edge] {
    try require(editor.topology).edges(of: id, .outgoing, types: .only(IsAEdge.id))
}

@MainActor let isAPropertyTests = Suite("What a shape is", [
    test("a kind that opts in holds `is`, and the report says so; typeable() needs typeWords, like canBeType() does") {
        let registry = try Registry(plugins: typePlugins())
        expect(registry.properties(for: Memo.kind).contains(IsAProperty.key))
        expect(registry.isTypeable(Memo.kind))
        let report = registry.report
        expect(report.contains("property is → memo"), report)
        expect(report.contains("edge type is-a"), report)
        let plain = try Registry(plugins: typePlugins() + [ScrapsPlugin(words: true)])
        expect(plain.isTypeable(Scrap.kind))
        expectThrows(RegistryError.invalid(point: "TypeWords", reason: "scrap holds is but has no typeWords")) {
            _ = try Registry(plugins: typePlugins() + [ScrapsPlugin(words: false)])
        }
    },
    test("its schema: an array of strings said to be types, none twice; `ShapeID` itself names nothing") {
        let registry = try Registry(plugins: typePlugins())
        let schema = try require(registry.schema(for: Memo.kind))
        let text = String(decoding: schema.data, as: UTF8.self)
        expect(text.contains("text/x-canvas-type"), text)
        expect(text.contains("\"uniqueItems\" : true"), text)
        expectEqual(TypeLink.mediaType, "text/x-canvas-type")
        // The id alone names no shape (an arrow's bindings are ids, and are not names); the link does.
        expect(!(ShapeID() is any ShapeNaming))
        expect((TypeLink(ShapeID()) as Any) is any ShapeNaming)
    },
    test("it is saved as the ids' strings, in the order they were added, and read back as they were; an empty list is none") {
        let registry = try Registry(plugins: typePlugins())
        let codec = BoardCodec(registry: registry)
        let a = ShapeID(), b = ShapeID(), c = ShapeID()
        var record = ShapeRecord(id: ShapeID(), memo("an employee"))
        record[IsAProperty.self] = [b, a, c].map(TypeLink.init)
        let document = registry.fillingDefaults(CanvasDocument(shapes: [AnyShapeRecord(record)]))
        let data = try codec.encode(document)
        let shapes = try require(try JSONDecoder().decode(JSONValue.self, from: data)["shapes"]?.arrayValue)
        expectEqual(shapes.first?["added"]?["is"], .array([b, a, c].map { .string($0.description) }), "the bare ids, in order")
        let loaded = try codec.decode(data)
        expect(loaded.report.isEmpty, "\(loaded.report)")
        expectEqual(loaded.document, document)
        expectEqual(loaded.document.shapes.first?[IsAProperty.self]?.map(\.shape), [b, a, c])
        record[IsAProperty.self] = []
        expectEqual(record[IsAProperty.self], nil, "emptying the list takes the property off")
        let none = registry.fillingDefaults(CanvasDocument(shapes: [AnyShapeRecord(record)]))
        let written = try require(try JSONDecoder().decode(JSONValue.self, from: try codec.encode(none))["shapes"]?.arrayValue)
        expectEqual(written.first?["added"]?["is"], nil)
    },
    test("a copy is an instance of the copy of a type copied along, and of the original of one not; a shape named twice stays twice") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person"), employee = editor.addType(TypeSchemaProperty.starter, title: "Employee")
        let ann = editor.addInstance("Ann", of: [person, employee])
        let copyOfPerson = ShapeID(), copyOfAnn = ShapeID()
        let rename: (ShapeID) -> ShapeID? = { [person: copyOfPerson, ann: copyOfAnn][$0] }
        let copy = try require(editor.document[ann]?.remappingReferences(rename, in: editor.shapeContext))
        expectEqual(copy[IsAProperty.self]?.map(\.shape), [copyOfPerson, employee], "the one copied along is renamed, the rest kept, in order")
        let alone = try require(editor.document[ann]?.remappingReferences({ _ in nil }, in: editor.shapeContext))
        expectEqual(alone[IsAProperty.self]?.map(\.shape), [person, employee])
    },
    test("deleting a type leaves the names of it behind, pointing nowhere until the delete is undone") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [person])
        editor.transact("Delete") { $0.delete([person]) }
        expectEqual(editor.typesOf(ann), [person], "the list is as it was")
        expectEqual(try isEdges(editor, from: ann).map(\.target), [person], "its edge names a shape that isn't there, as a mention's does")
        expect(editor.file.record(person) == nil)
        expectEqual(editor.types?.name(of: TypeLink(person)), .missing(lastKnown: "Person"))
        editor.undo()
        expectEqual(editor.typesOf(ann), [person])
        expectEqual(try isEdges(editor, from: ann).map(\.target), [person])
        expectEqual(editor.types?.name(of: TypeLink(person)), .live("Person"))
    },
])

@MainActor let isAEdgeTests = Suite("The is-a edge", [
    test("one edge to each type a shape is, in the order of its list, slot `is`, carried by the instance; a shape that isn't any carries none") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person"), employee = editor.addType(TypeSchemaProperty.starter, title: "Employee")
        let ann = editor.addInstance("Ann", of: [employee, person])
        let bob = editor.add(memo("Bob", at: CGPoint(x: 400, y: 400)))
        let edges = try isEdges(editor, from: ann)
        expectEqual(edges.map(\.target), [employee, person])
        expect(edges.allSatisfy { $0.type == IsAEdge.id && $0.slot == "is" && $0.carrier == ann && $0.source == ann && $0.count == 1 })
        expectEqual(try isEdges(editor, from: bob), [])
        expectEqual(try require(editor.topology).edges(of: person, .incoming, types: .only(IsAEdge.id)).map(\.source), [ann])
        expectEqual(try require(editor.topology).types.summary(of: IsAEdge.id), "from a shape to each type it is, in the order of its list")
        expectEqual(try require(editor.topology).types.parent(of: IsAEdge.id), nil, "a root")
    },
    test("an edge follows its record: a type added, removed, the list emptied, undone") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [])
        expectEqual(try isEdges(editor, from: ann), [])
        editor.transact("Set") { $0.update(ann) { $0[IsAProperty.self] = [TypeLink(person)] } }
        expectEqual(try isEdges(editor, from: ann).map(\.target), [person])
        editor.transact("Set") { $0.update(ann) { $0[IsAProperty.self] = [] } }
        expectEqual(try isEdges(editor, from: ann), [])
        editor.undo()
        expectEqual(try isEdges(editor, from: ann).map(\.target), [person])
    },
    test("an instance of a stand-in is an instance of what it stands for: the edge is forwarded, and keeps the stand-in as its literal end") {
        let editor = try typeEditor(more: [EchoesPlugin()])
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let echo = editor.add(Echo(stands: [Citation(person)]))
        let ann = editor.addInstance("Ann", of: [echo])
        let edge = try require(try isEdges(editor, from: ann).first)
        expectEqual(edge.target, person)
        expectEqual(edge.literalTarget, echo)
        expectEqual(try require(editor.topology).edges(of: ann, .outgoing, types: .only(IsAEdge.id), view: .literal).map(\.target), [echo])
    },
    test("a move reads no record, and a type's rename none of its instances'") {
        let editor = try typeEditor()
        let person = editor.addType(TypeSchemaProperty.starter, title: "Person")
        let ann = editor.addInstance("Ann", of: [person])
        let topology = try require(editor.topology), index = try require(editor.types)
        let (topologyReads, indexReads) = (topology.recordsRead, index.recordsRead)
        editor.transact("Move") { $0.translate([ann, person], by: CGPoint(x: 30, y: 20)) }
        expectEqual(topology.recordsRead, topologyReads, "Topology reads nothing")
        expectEqual(index.recordsRead, indexReads, "nor does the index")
        expectEqual(try isEdges(editor, from: ann).map(\.target), [person])
    },
])
