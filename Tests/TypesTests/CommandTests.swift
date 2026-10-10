import Adornments
@_spi(Host) import Canvas
import CanvasTesting
import ContextMenus
import DetailPanel
import CoreGraphics
import Foundation
import Keyboard
import LanguageModels
import Mentions
import Selection
import SlashCommands
import TableOfContents
import TestKit
import Titles
import Topology
import Types
import Validation

// Becoming a type and stopping: `/is-a type` on a line of a kind's words, Remove Type, and what the
// registry asks of a list that installs Types.

/// A box with words that can't be a type: it hands Types its words, and opts into nothing more.
private struct Slip: BoxShapeProps {
    static let kind: ShapeKind = "slip"
    static let properties = Properties<Slip>(title: "Slip") {
        Property("frame", \.frame).required()
        Property("text", \.text)
    }
    var frame = CGRect(x: 0, y: 0, width: 100, height: 40)
    var text: MentionText = ""
    init() {}
}

@MainActor private struct SlipDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Slip>, in context: RenderContext) {}
}

/// Slips that may, or may not, say where their words are: `canBeType()` without `typeWords` is refused.
private struct SlipsPlugin: CanvasPlugin {
    var words: Bool
    var canBeType: Bool
    var id: PluginID { "slips" }
    func register(into registrar: inout PluginRegistrar) {
        registrar.shape(SlipDefinition()) { slip in
            if words { slip.typeWords(\.text, drawnIn: { _ in nil }) }
            if canBeType { slip.canBeType() }
        }
    }
}

@MainActor private func isAOffersType(_ editor: CanvasEditor, on id: ShapeID) throws -> Bool {
    try require(editor.slashCommands).command(named: "is-a", for: id)?.choices().contains { $0.title == "Type" } ?? false
}

@MainActor let commandTests = Suite("Making types", [
    test("makeType makes the shape a type in one step, Make Type: the starter schema, its words as they were, not public; undo takes it all back") {
        let editor = try typeEditor()
        let id = editor.add(memo("a pet in my household"))
        editor.makeType(id)
        expectEqual(editor.schema(id), TypeSchemaProperty.starter)
        expectEqual(editor.words(id), "a pet in my household")
        expectEqual(editor.undoHistory.undoName, "Make Type")
        expect(editor.types?.isType(id) == true)
        let steps = editor.revision
        editor.makeType(id)
        expectEqual(editor.revision, steps, "nothing for a type")
        editor.undo()
        expectEqual(editor.schema(id), nil)
        expect(editor.types?.isType(id) == false)
        let other = try typeEditor(more: [SlipsPlugin(words: true, canBeType: false)])
        let slip = other.add(Slip())
        let before = other.revision
        other.makeType(slip)
        expectEqual(other.revision, before, "nothing for a kind that cannot be one")
    },
    test("makeType on a read-only shape is refused by the core") {
        let editor = try typeEditor(more: [FreezingPlugin()])
        let id = editor.add(memo("a pet"))
        editor.freeze([id])
        editor.makeType(id)
        expectEqual(editor.schema(id), nil)
    },
    test("words that are a JSON object become the schema as written, but for the whitespace around them") {
        let editor = try typeEditor()
        let json = "{\n  \"type\": \"object\",\n  \"properties\": {\"name\": {\"type\": \"string\"}}\n}"
        let id = editor.add(memo("\n" + json + "\n  "))
        editor.makeType(id)
        expectEqual(editor.schema(id), json, "the inner layout and the key order are kept")
        expectEqual(editor.words(id)?.stored, "\n" + json + "\n  ", "the words are not touched here: the sync writes them")
        let empty = editor.add(memo("{}", at: CGPoint(x: 400, y: 40)))
        editor.makeType(empty)
        expectEqual(editor.schema(empty), "{}")
    },
    test("words that hold a mention, an array, a number, plain text or nothing get the starter") {
        let editor = try typeEditor()
        let target = editor.add(memo("Pet", at: CGPoint(x: 600, y: 400)))
        let withMention = editor.add(Memo(frame: CGRect(x: 0, y: 0, width: 240, height: 60),
                                          text: MentionText([.text("{\"title\": \""), .mention(target, label: "Pet"), .text("\"}")])))
        var origin = 100.0
        var ids: [ShapeID] = [withMention]
        for words in ["[1, 2]", "42", "a pet in my household", "", "{\"type\": "] {
            origin += 60
            ids.append(editor.add(memo(words, at: CGPoint(x: origin, y: 40))))
        }
        for id in ids {
            editor.makeType(id)
            expectEqual(editor.schema(id), TypeSchemaProperty.starter, "\(editor.words(id)?.stored ?? "")")
        }
    },
    test("makeTypes on several shapes is one step") {
        let editor = try typeEditor()
        let ids = (0..<3).map { editor.add(memo("n\($0)", at: CGPoint(x: Double($0) * 300, y: 40))) }
        editor.makeTypes(ids)
        expect(ids.allSatisfy { editor.schema($0) != nil })
        expectEqual(editor.undoHistory.undoName, "Make Type")
        editor.undo()
        expect(ids.allSatisfy { editor.schema($0) == nil }, "one undo takes all three")
        let steps = editor.revision
        editor.makeTypes([])
        expectEqual(editor.revision, steps)
    },
    test("Remove Type takes the schema away in one step, Remove Type; the words stay; undo brings the schema back") {
        let editor = try typeEditor()
        let id = editor.addType(pet, words: "a pet in my household", title: "Pet")
        editor.removeType(id)
        expectEqual(editor.schema(id), nil)
        expectEqual(editor.words(id), "a pet in my household")
        expectEqual(editor.title(id), "Pet")
        expectEqual(editor.undoHistory.undoName, "Remove Type")
        expect(editor.types?.isType(id) == false)
        expect(try isAOffersType(editor, on: id), "it can be made one again")
        editor.undo()
        expectEqual(editor.schema(id), pet)
        expect(editor.types?.isType(id) == true)
        let plain = editor.add(memo("not a type", at: CGPoint(x: 400, y: 40)))
        let before = editor.revision
        editor.removeType(plain)
        expectEqual(editor.revision, before, "nothing for a shape that isn't one")
    },
    test("a kind that can be a type says where its words are: canBeType without typeWords is refused") {
        expectThrows(RegistryError.invalid(point: "TypeWords", reason: "slip holds schema but has no typeWords")) {
            _ = try Registry(plugins: typePlugins() + [SlipsPlugin(words: false, canBeType: true)])
        }
        _ = try Registry(plugins: typePlugins() + [SlipsPlugin(words: true, canBeType: true)])
        _ = try Registry(plugins: typePlugins() + [SlipsPlugin(words: true, canBeType: false)])
    },
    test("Types' rules and panel are plugins of their own") {
        let faces: Set<PluginID> = ["type-validation", "type-details"]
        _ = try Registry(plugins: typePlugins().filter { !faces.contains($0.id) })
        let report = try Registry(plugins: typePlugins()).report
        expect(report.contains("type words → memo"), report)
        expect(report.contains("property schema → memo"), report)
    },
])
