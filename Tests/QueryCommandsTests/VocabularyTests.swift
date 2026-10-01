import Automation
import Canvas
import CanvasRPC
import CanvasTesting
import Queries
import TestKit

// `canvas query-vocabulary`: what this app's queries can name, whichever board, as the block
// `--ask` sends and as lists.

/// A kind as the answer lists it.
struct KindLine: Decodable {
    let kind: String
    let label: String
    let naming: String
    let holdsShapes: Bool
    let holdsBoard: Bool
    let attributes: [String: String]
}

@MainActor let vocabularyTests = Suite("query-vocabulary", [
    test("an app command with no params") {
        let h = try shelfHarness()
        let spec = try require(h.editor.registry.automationCommands.first { $0.name == "query-vocabulary" })
        expectEqual(spec.scope, .app)
        expect(spec.arguments.isEmpty, "\(spec.arguments)")
    },
    test("the vocabulary block, each kind with its titles and attributes, the edge types under theirs, and every word by its plugin") {
        let h = try shelfHarness()
        let json = try answered(["query-vocabulary"], on: h)
        let vocabulary = QueryVocabulary(registry: h.editor.registry)
        expectEqual(json["vocabulary"], .string(vocabulary.text))
        expectEqual(json["vocabulary"], .string(try require(h.editor.queries).vocabulary.text), "the editor's, byte for byte")

        let kinds = try require(json["kinds"]).decode([KindLine].self)
        expectEqual(kinds.map(\.kind), vocabulary.kinds.map(\.kind.rawValue), "in registry order")
        let chore = try require(kinds.first { $0.kind == Chore.kind.rawValue })
        expectEqual(chore.label, "Task")
        expectEqual(chore.naming, "named")
        expectEqual(chore.holdsShapes, false)
        expectEqual(chore.holdsBoard, false)
        expectEqual(chore.attributes["caption"], "text")
        expectEqual(chore.attributes["status"], "todo|doing|blocked|done")
        expectEqual(chore.attributes["frame"], nil, "where it is isn't an attribute")
        let pocket = try require(kinds.first { $0.kind == Pocket.kind.rawValue })
        expectEqual(pocket.holdsShapes, true)
        expectEqual(pocket.holdsBoard, true)
        let link = try require(kinds.first { $0.kind == Link.kind.rawValue })
        expectEqual(link.naming, "none")

        expectEqual(json["edgeTypes"], [["type": "wire", "summary": "a link, from the shape it starts on to the shape it ends on"]])

        let words = try require(json["words"]?.arrayValue)
        expectEqual(words.map { $0["word"] }, vocabulary.words.map { .string($0.word) })
        let edgeTo = try require(words.first { $0["word"] == "edge-to" })
        expectEqual(edgeTo["from"], .string(PluginID.queries.rawValue))
        expectEqual(edgeTo["takes"], "a shape, then edge types if any")
        let picked = try require(words.first { $0["word"] == "picked" })
        expectEqual(picked, ["word": "picked", "takes": "no argument", "summary": "the person picked it", "example": ":picked", "from": "words"])
    },
    test("a kind whose shapes hold shapes on their board holds shapes and no board; the block says so") {
        let h = try shelfHarness(commandPlugins() + [CorralsPlugin()])
        let json = try answered(["query-vocabulary"], on: h)
        let kinds = try require(json["kinds"]).decode([KindLine].self)
        let corral = try require(kinds.first { $0.kind == Corral.kind.rawValue })
        expectEqual(corral.holdsShapes, true)
        expectEqual(corral.holdsBoard, false)
        expect(json["vocabulary"]?.stringValue?.contains("- corral (corral; untitled; holds shapes)") == true, "\(json["vocabulary"] ?? .null)")
    },
])
