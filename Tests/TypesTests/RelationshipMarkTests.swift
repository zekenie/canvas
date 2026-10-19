@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit
import Titles
import Types

// The two stored properties of relationships and what opts a kind into each: `relationship`, the mark
// of a relationship type (the note's `canBeRelationshipType()`), and `endRule`, an arrow's rule for
// the end it is (`relating()`). Types knows no kind: these run over memos and a tie of the tests' own.

/// A box of words that relates, the way an arrow does: an instance of types and a relating kind.
private struct Tie: BoxShapeProps {
    static let kind: ShapeKind = "tie"
    static let properties = Properties<Tie>(title: "Tie") {
        Property("frame", \.frame).required()
        Property("text", \.text)
    }
    var frame = CGRect(x: 0, y: 0, width: 100, height: 40)
    var text: MentionText = ""
    init() {}
}

@MainActor private struct TieDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Tie>, in context: RenderContext) {}
}

private struct TiesPlugin: CanvasPlugin {
    enum Shape { case full, noValues, onlyMark, noWords }
    var shape: Shape
    var id: PluginID { "ties" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(TieDefinition()) { tie in
            tie.typeWords(\.text, drawnIn: { _ in nil })
            switch shape {
            case .full:
                tie.typeable()
                tie.relating()
            case .noValues:
                tie.relating()
            case .onlyMark:
                tie.canBeRelationshipType()
            case .noWords:
                tie.canBeType()
                tie.canBeRelationshipType()
            }
        }
    }
}

@MainActor let relationshipMarkTests = Suite("The mark of a relationship type", [
    test("the mark is an added property the memo opts into, the end rule one a relating kind does; the report says so") {
        let registry = try Registry(plugins: typePlugins() + [TiesPlugin(shape: .full)])
        expect(registry.canBeRelationshipType(Memo.kind))
        expect(!registry.canBeRelationshipType(Tie.kind), "a tie can't be a relationship type")
        expect(registry.relates(Tie.kind) && !registry.relates(Memo.kind), "only the tie relates")
        let report = registry.report
        expect(report.contains("property relationship → memo"), report)
        expect(report.contains("property endRule → tie"), report)
    },
    test("the mark needs schema; a kind that relates is an instance of types, with is and fieldValues") {
        expectThrows(RegistryError.invalid(point: "TypeWords", reason: "tie holds relationship but not schema")) {
            _ = try Registry(plugins: typePlugins() + [TiesPlugin(shape: .onlyMark)])
        }
        expectThrows(RegistryError.invalid(point: "TypeWords", reason: "tie holds endRule but not both is and fieldValues")) {
            _ = try Registry(plugins: typePlugins() + [TiesPlugin(shape: .noValues)])
        }
        // A kind that can be a type and a relationship type, with words, is fine.
        _ = try Registry(plugins: typePlugins() + [TiesPlugin(shape: .noWords)])
    },
    test("a shape is a relationship type while it holds schema and the mark; Remove Type takes both and undo brings both back") {
        let editor = try typeEditor()
        let id = editor.addType(TypeSchemaProperty.starter, title: "Employment")
        editor.transact { $0.update(id) { $0[RelationshipProperty.self] = true } }
        expectEqual(editor.document[id]?[RelationshipProperty.self], true)
        editor.removeType(id)
        expectEqual(editor.document[id]?[TypeSchemaProperty.self], nil)
        expectEqual(editor.document[id]?[RelationshipProperty.self], nil, "Remove Type clears the mark too")
        editor.undo()
        expect(editor.document[id]?[TypeSchemaProperty.self] != nil)
        expectEqual(editor.document[id]?[RelationshipProperty.self], true, "one step: the undo brings the mark back with the schema")
        // The mark alone is inert: held, and no type.
        let note = editor.addInstance("a note", of: [])
        editor.transact { $0.update(note) { $0[RelationshipProperty.self] = true } }
        expectEqual(editor.document[note]?[RelationshipProperty.self], true)
        expect(editor.types?.isType(note) == false)
    },
    test("false is none: the mark is kept as the bare true, and a board saves and reads it back") {
        let registry = try Registry(plugins: typePlugins())
        let codec = BoardCodec(registry: registry)
        var marked = typeRecord(TypeSchemaProperty.starter, title: "Employment")
        marked[RelationshipProperty.self] = true
        var unmarked = typeRecord(TypeSchemaProperty.starter, title: "Plain")
        unmarked[RelationshipProperty.self] = false
        expectEqual(unmarked[RelationshipProperty.self], nil, "false is none")
        let document = registry.fillingDefaults(CanvasDocument(shapes: [marked, unmarked]))
        let data = try codec.encode(document)
        let shapes = try require(try JSONDecoder().decode(JSONValue.self, from: data)["shapes"]?.arrayValue)
        expectEqual(shapes[0]["added"]?["relationship"], .bool(true))
        expectEqual(shapes[1]["added"]?["relationship"], nil)
        let loaded = try codec.decode(data)
        expect(loaded.report.isEmpty, "\(loaded.report)")
        expectEqual(loaded.document, document)
    },
    test("an arrow's rule is saved as an object of both members, and a board reads it back") {
        let registry = try Registry(plugins: typePlugins() + [TiesPlugin(shape: .full)])
        let codec = BoardCodec(registry: registry)
        var both = AnyShapeRecord(ShapeRecord(id: ShapeID(), Tie()))
        both[RelationshipEndProperty.self] = EndRule(needed: true, onlyOne: true)
        var one = AnyShapeRecord(ShapeRecord(id: ShapeID(), Tie()))
        one[RelationshipEndProperty.self] = EndRule(needed: false, onlyOne: true)
        let none = AnyShapeRecord(ShapeRecord(id: ShapeID(), Tie()))
        let document = registry.fillingDefaults(CanvasDocument(shapes: [both, one, none]))
        let data = try codec.encode(document)
        let shapes = try require(try JSONDecoder().decode(JSONValue.self, from: data)["shapes"]?.arrayValue)
        expectEqual(shapes[0]["added"]?["endRule"], .object(["needed": .bool(true), "onlyOne": .bool(true)]))
        expectEqual(shapes[1]["added"]?["endRule"], .object(["needed": .bool(false), "onlyOne": .bool(true)]))
        expectEqual(shapes[2]["added"]?["endRule"], nil)
        let loaded = try codec.decode(data)
        expect(loaded.report.isEmpty, "\(loaded.report)")
        expectEqual(loaded.document, document)
    },
    test("an arrow's rule is an object that is none while both are false; the merge keeps the members a statement does not name") {
        var record = ShapeRecord(id: ShapeID(), Tie())
        let registry = try Registry(plugins: typePlugins() + [TiesPlugin(shape: .full)])
        _ = registry
        record[RelationshipEndProperty.self] = EndRule(needed: false, onlyOne: false)
        expectEqual(record[RelationshipEndProperty.self], nil, "both false is none")
        record[RelationshipEndProperty.self] = EndRule(needed: true, onlyOne: false)
        expectEqual(record[RelationshipEndProperty.self], EndRule(needed: true, onlyOne: false))
        let held = JSONValue.object(["needed": .bool(true)])
        expectEqual(EndRuleMerge.merged(.object(["onlyOne": .bool(true)]), into: held), .object(["needed": .bool(true), "onlyOne": .bool(true)]), "Only one joins Needed")
        expectEqual(EndRuleMerge.merged(.object(["needed": .bool(false)]), into: held), .null, "nothing true is left: none")
        expectEqual(EndRuleMerge.merged(.object(["needed": .null]), into: .object(["needed": .bool(true), "onlyOne": .bool(true)])), .object(["onlyOne": .bool(true)]), "null takes a member away")
        expectEqual(EndRuleMerge.merged(.object(["needed": .bool(true)]), into: nil), .object(["needed": .bool(true)]))
        expectEqual(EndRuleMerge.merged(.null, into: held), .null, "null is the whole rule off")
    },
])
