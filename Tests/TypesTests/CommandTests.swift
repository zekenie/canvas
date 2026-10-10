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

// Becoming a type and stopping: `/type` on a line of a kind's words, Remove Type, and what the
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

@MainActor let commandTests = Suite("Making types", [
    test("/type is offered on a shape that can be a type and isn't one; never on a type, nor on a kind that can't be one") {
        let editor = try typeEditor()
        let plain = editor.add(memo("a pet"))
        let type = editor.addType(TypeSchemaProperty.starter, words: "a book", at: CGPoint(x: 400, y: 40))
        let state = try require(editor.slashCommands)
        expect(state.commands(for: plain).map(\.name).contains("type"))
        expectEqual(state.commands(for: plain).first { $0.name == "type" }?.argument, nil, "it takes nothing")
        expect(!state.commands(for: type).map(\.name).contains("type"))
        let other = try typeEditor(more: [SlipsPlugin(words: true, canBeType: false)])
        let slip = other.add(Slip())
        expect(!(try require(other.slashCommands)).commands(for: slip).map(\.name).contains("type"))
    },
    test("/type makes the shape a type in one step, Make Type: the starter schema, its words as they were; undo takes it all back") {
        let editor = try typeEditor()
        let id = editor.add(memo("a pet in my household"))
        expect(try require(editor.slashCommands).run("type", on: id, with: SlashArguments("")))
        expectEqual(editor.schema(id), TypeSchemaProperty.starter)
        expectEqual(editor.words(id), "a pet in my household")
        expectEqual(editor.undoHistory.undoName, "Make Type")
        expect(editor.types?.isType(id) == true)
        editor.undo()
        expectEqual(editor.schema(id), nil)
        expect(editor.types?.isType(id) == false)
    },
    test("/type takes no argument, and isn't run on a read-only shape") {
        let editor = try typeEditor(more: [FreezingPlugin()])
        let id = editor.add(memo("a pet"))
        let state = try require(editor.slashCommands)
        expect(!state.run("type", on: id, with: SlashArguments("Pet")))
        expectEqual(editor.schema(id), nil)
        editor.freeze([id])
        expect(!state.run("type", on: id, with: SlashArguments("")))
        editor.makeType(id)
        expectEqual(editor.schema(id), nil, "refused by the core")
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
        expect(try require(editor.slashCommands).commands(for: id).map(\.name).contains("type"), "it can be made one again")
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
