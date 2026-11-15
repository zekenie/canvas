import Automation
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Draw
import EmbeddingModels
import Foundation
import TestKit

// `canvas measure --tightness` of a document: how alike the two notes of each link are, by the registry's embedding model.
// The kinds are these tests' own: a memo (its words are `text`), a dossier (`text`, `description` and `blurb`: the words of
// the first of them that has any, `text` first, then the others in code-unit order), a pen (holds shapes: a frame's place),
// and a binder (owns a board: a subboard's). A property whose schema says its text is of `refsMediaType` is words a kind's
// shapes say, and the vectors are the test's, set by the text a note is embedded by.

struct WordMemo: BoxShapeProps {
    static let kind: ShapeKind = "word-memo"
    static let properties = Properties<WordMemo>(title: "Word memo") {
        Property("frame", \.frame).required()
        Property("label", \.label)
        Property("text", \.text)
    }
    var frame: CGRect
    var label = ""
    var text: RefText<AnyRef> = ""

    init() { self.init(.zero) }
    init(_ frame: CGRect) { self.frame = frame }
}

struct WordDossier: BoxShapeProps {
    static let kind: ShapeKind = "word-dossier"
    static let properties = Properties<WordDossier>(title: "Word dossier") {
        Property("frame", \.frame).required()
        Property("label", \.label)
        Property("text", \.text)
        Property("description", \.description)
        Property("blurb", \.blurb)
    }
    var frame: CGRect
    var label = ""
    var text: RefText<AnyRef> = ""
    var description: RefText<AnyRef> = ""
    var blurb: RefText<AnyRef> = ""

    init() { self.init(.zero) }
    init(_ frame: CGRect) { self.frame = frame }
}

/// A card that owns a board, as a subboard does.
struct WordBinder: BoxShapeProps {
    static let kind: ShapeKind = "word-binder"
    static let properties = Properties<WordBinder>(title: "Word binder") {
        Property("frame", \.frame).required()
        Property("label", \.label)
    }
    var frame: CGRect
    var label = ""

    init() { self.init(.zero) }
    init(_ frame: CGRect) { self.frame = frame }
}

struct WordBinderDefinition {}

extension WordBinderDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<WordBinder>, in context: RenderContext) {}
}

extension WordBinderDefinition: BoardOwning {}

struct WordMemoDefinition {}
struct WordDossierDefinition {}

extension WordMemoDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<WordMemo>, in context: RenderContext) {}
}

extension WordDossierDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<WordDossier>, in context: RenderContext) {}
}

/// The kinds, their names (a label), and the format that writes their texts as they are.
private let wordKinds = Contributor(id: "word-kinds") { registrar in
    registrar.shape(WordMemoDefinition()) { memo in
        memo.tool(label: "Memo", systemImage: "note", placing: memo.placement(size: CGSize(width: 100, height: 60)) { WordMemo() })
    }
    registrar.shape(WordDossierDefinition()) { dossier in
        dossier.tool(label: "Dossier", systemImage: "folder", placing: dossier.placement(size: CGSize(width: 100, height: 60)) { WordDossier() })
    }
    registrar.shape(WordBinderDefinition()) { binder in
        binder.tool(label: "Binder", systemImage: "book", placing: binder.placement(size: CGSize(width: 100, height: 60)) { WordBinder() })
    }
    registrar.drawTextFormat(mediaType: refsMediaType, describes: "words") { text, _ throws(DrawError) in text }
    registrar.drawNames(name: { record, _ in
        if let memo = record.typed(as: WordMemo.self) { return fold(memo.props.label) }
        if let dossier = record.typed(as: WordDossier.self) { return fold(dossier.props.label) }
        if let pen = record.typed(as: Pen.self) { return fold(pen.props.label) }
        if let binder = record.typed(as: WordBinder.self) { return fold(binder.props.label) }
        return nil
    }, namingProperty: { kind, _ in [WordMemo.kind, WordDossier.kind, WordBinder.kind, Pen.kind].contains(kind) ? "label" : nil },
       isDerived: { _, _ in false }, fold: fold)
}

/// An editor with the kinds, and `model` as the embedding model (none without one).
@MainActor private func tightnessEditor(_ model: ScriptedEmbeddingModel?, memory: EmbeddingMemory? = nil) throws -> CanvasEditor {
    try makeEditor([edgesPlugin(), pens, wordKinds] + (model.map { [EmbeddingModelsPlugin(model: $0, memory: memory)] } ?? []))
}

private func node(_ key: String, _ kind: String, in holder: String? = nil, title: String? = nil, props: JSONObject = [:]) -> JSON {
    var members = props
    if let title { members["title"] = .string(title) }
    var json: JSON = ["key": .string(key), "kind": .string(kind), "props": .object(members)]
    if let holder { json["in"] = .string(holder) }
    return json
}

private func edge(_ from: String, _ to: String) -> JSON { ["from": .string(from), "to": .string(to)] }

private func document(_ nodes: [JSON], _ edges: [JSON]) -> String {
    (["nodes": .array(nodes), "edges": .array(edges)] as JSON).compactText
}

private func text(_ title: String?, _ words: String?) -> String { EmbeddingText.of(title: title, words: words) }

/// The pairs a measure's `tightness` lists, each as `a b board value`.
private func pairs(_ answer: JSON) -> [(a: String, b: String, board: String?, tightness: Double)] {
    (answer["tightness"]?["pairs"]?.arrayValue ?? []).compactMap { row in
        guard let a = row["a"]?.stringValue, let b = row["b"]?.stringValue, let tightness = row["tightness"]?.numberValue else { return nil }
        return (a, b, row["board"]?.stringValue, tightness)
    }
}

/// A board's centred cosines, worked out in plain sequential `Double` arithmetic from the vectors of every note of the board:
/// the reference the command's numbers are held to, `i` and `j` places in `vectors`.
private func cosine(_ vectors: [[Float]], _ i: Int, _ j: Int) -> Double {
    let d = vectors[0].count, n = Double(vectors.count)
    var mean = [Double](repeating: 0, count: d)
    for v in vectors { for k in 0..<d { mean[k] += Double(v[k]) / n } }
    func unit(_ v: [Float]) -> [Double] {
        var s = 0.0
        let c = (0..<d).map { Double(v[$0]) - mean[$0] }
        for x in c { s += x * x }
        let length = s.squareRoot() == 0 ? 1 : s.squareRoot()
        return c.map { $0 / length }
    }
    let x = unit(vectors[i]), y = unit(vectors[j])
    var dot = 0.0
    for k in 0..<d { dot += x[k] * y[k] }
    return dot
}

/// Sets the vector of each of `keys`' notes, by the text its title and words make.
@MainActor private func setVectors(_ model: ScriptedEmbeddingModel, _ vectors: [(title: String?, words: String?, vector: [Float])]) {
    for each in vectors { model.set(each.vector, for: text(each.title, each.words)) }
}

@MainActor let tightnessTests = Suite("canvas measure --tightness", [
    test("a pair is two notes a link joins on one board, once whichever way it is written; frames are left out; a binder (a subboard's card) is, and a link into a frame is no pair") {
        let model = ScriptedEmbeddingModel()
        let editor = try tightnessEditor(model)
        setVectors(model, [("A", "one", [1, 0, 0]), ("B", "two", [0, 1, 0]), ("C", "three", [0, 0, 1]), ("D", "four", [1, 1, 1]), (nil, nil, [2, 0, 1])])
        let nodes = [node("a", "word-memo", title: "A", props: ["text": "one"]), node("b", "word-memo", title: "B", props: ["text": "two"]),
                     node("c", "word-memo", in: "pen", title: "C", props: ["text": "three"]), node("d", "word-memo", title: "D", props: ["text": "four"]),
                     node("pen", "pen", title: "Pen"), node("card", "word-binder")]
        let answer = try run(["measure", "-", "--tightness"], on: editor, input: document(nodes, [
            edge("b", "a"), edge("a", "b"), edge("c", "d"), edge("a", "pen"), edge("a", "a"), edge("card", "a"), edge("d", "c"),
        ])).get()
        let found = pairs(answer)
        expectEqual(found.map { "\($0.a) \($0.b)" }, ["a b", "a card", "c d"], "each once, by key, a pen (a frame) in none")
        expectEqual(found.map(\.board), [nil, nil, nil], "the drawing's own board: left out")
        let t = try require(answer["tightness"])
        expectEqual(t["model"], "scripted")
        expectEqual(t["texts"], 5, "the notes of the board that has a pair, a frame's none")
        expectEqual(t["asked"], 5)
        expect(t["unavailable"] == nil && t["reason"] == nil)
    },
    test("the values are the centred cosine: each vector less the board's mean, over every note of the board, whether it is in a pair or not") {
        let model = ScriptedEmbeddingModel()
        let editor = try tightnessEditor(model)
        let vectors: [(String?, String?, [Float])] = [("A", "x", [1, 0]), ("B", "y", [0, 1]), ("C", "z", [-1, -1]), ("Loose", nil, [5, 5])]
        setVectors(model, vectors.map { (title: $0.0, words: $0.1, vector: $0.2) })
        let nodes = [node("a", "word-memo", title: "A", props: ["text": "x"]), node("b", "word-memo", title: "B", props: ["text": "y"]),
                     node("c", "word-memo", title: "C", props: ["text": "z"]), node("loose", "word-memo", title: "Loose")]
        let found = pairs(try run(["measure", "-", "--tightness"], on: editor, input: document(nodes, [edge("a", "b"), edge("a", "c")])).get())
        // The board's mean is (1.25, 1.25) with the loose note in it.
        let all = nodes.indices.map { vectors[$0].2 }
        expectEqual(found.count, 2)
        expectEqual(found[0].tightness, cosine(all, 0, 1))
        expectEqual(found[1].tightness, cosine(all, 0, 2))
        // And by hand: a - mean = (-0.25, -1.25), b - mean = (-1.25, -0.25).
        let a = (-0.25, -1.25), b = (-1.25, -0.25)
        let expected = (a.0 * b.0 + a.1 * b.1) / ((a.0 * a.0 + a.1 * a.1).squareRoot() * (b.0 * b.0 + b.1 * b.1).squareRoot())
        expect(abs(found[0].tightness - expected) < 1e-12, "\(found[0].tightness) is not \(expected)")
    },
    test("a note's words are its text, else its blurb, else its description (the others in code-unit order), and its title is the title as written") {
        let model = ScriptedEmbeddingModel()
        let editor = try tightnessEditor(model)
        setVectors(model, [("D1", "from text", [1, 0]), ("D2", "from blurb", [0, 1]), ("D3", "from description", [1, 1]), ("Plain", nil, [2, 1])])
        let nodes = [node("d1", "word-dossier", title: "D1", props: ["text": "from text", "description": "no", "blurb": "no"]),
                     node("d2", "word-dossier", title: "D2", props: ["text": "", "description": "from description", "blurb": "from blurb"]),
                     node("d3", "word-dossier", title: "D3", props: ["description": "from description"]),
                     node("p", "word-memo", title: "Plain")]
        _ = try run(["measure", "-", "--tightness"], on: editor, input: document(nodes, [edge("d1", "d2"), edge("d2", "d3"), edge("d3", "p")])).get()
        expectEqual(Set(model.requests.flatMap { $0 }), Set([text("D1", "from text"), text("D2", "from blurb"), text("D3", "from description"), text("Plain", nil)]))
    },
    test("a note in a frame inside a subboard is on the subboard's board, whose key is the pair's; the subboard's card is on the board it is on; no pair joins two boards") {
        let model = ScriptedEmbeddingModel()
        let editor = try tightnessEditor(model)
        for (title, vector) in [("Top", [1, 0, 0]), ("Other", [0, 1, 0]), ("In", [0, 0, 1]), ("Deep", [1, 1, 0]), ("Also", [0, 1, 1])] as [(String, [Float])] {
            setVectors(model, [(title, nil, vector)])
        }
        setVectors(model, [(nil, nil, [1, 0, 1])])
        let nodes = [node("top", "word-memo", title: "Top"), node("other", "word-memo", title: "Other"), node("p", "word-binder"),
                     node("in", "word-memo", in: "p", title: "In"), node("pen", "pen", in: "p", title: "Pen"), node("deep", "word-memo", in: "pen", title: "Deep"),
                     node("also", "word-memo", in: "p", title: "Also")]
        let answer = try run(["measure", "-", "--tightness"], on: editor, input: document(nodes, [
            edge("top", "other"), edge("top", "p"), edge("in", "deep"), edge("deep", "also"), edge("top", "in"), edge("other", "deep"),
        ])).get()
        let found = pairs(answer)
        expectEqual(found.map { "\($0.a) \($0.b) \($0.board ?? "-")" }, ["also deep p", "deep in p", "other top -", "p top -"])
        expectEqual(answer["tightness"]?["texts"], 6, "every note of a board that has a pair: not the pen")
    },
    test("a second measure asks nothing: the vectors are kept by text") {
        let model = ScriptedEmbeddingModel.hashing()
        let editor = try tightnessEditor(model)
        let doc = document([node("a", "word-memo", title: "A"), node("b", "word-memo", title: "B"), node("c", "word-memo", title: "C")], [edge("a", "b"), edge("b", "c")])
        let first = try run(["measure", "-", "--tightness"], on: editor, input: doc).get()
        expectEqual(first["tightness"]?["asked"], 3)
        expectEqual(model.requests.count, 1)
        let second = try run(["measure", "-", "--tightness"], on: editor, input: doc).get()
        expectEqual(second["tightness"]?["asked"], 0)
        expectEqual(second["tightness"]?["texts"], 3)
        expectEqual(model.requests.count, 1, "no new request")
        expectEqual(pairs(second).map(\.tightness), pairs(first).map(\.tightness))
    },
    test("a document with no pair answers none and asks nothing, with a model or without") {
        let model = ScriptedEmbeddingModel()
        let doc = document([node("a", "word-memo", title: "A"), node("b", "word-memo", title: "B"), node("pen", "pen")], [edge("a", "pen")])
        let answer = try run(["measure", "-", "--tightness"], on: try tightnessEditor(model), input: doc).get()
        expectEqual(answer["tightness"], ["model": "scripted", "texts": 0, "asked": 0, "pairs": []])
        expectEqual(model.requests.count, 0)
        let without = try run(["measure", "-", "--tightness"], on: try tightnessEditor(nil), input: doc).get()
        expectEqual(without["tightness"], ["unavailable": "No embedding model", "reason": "no_model"], "no pair: not asked, so not a failure, but it has no model")
    },
    test("with no model, no key or a failed request it says why, the sizes answered and the same as without the flag; nothing partial") {
        let doc = document([node("a", "word-memo", title: "A"), node("b", "word-memo", title: "B")], [edge("a", "b")])
        let plain = try run(["measure", "-"], on: try tightnessEditor(ScriptedEmbeddingModel.hashing()), input: doc).get()
        expect(plain["tightness"] == nil, "not asked, not answered")
        let model = ScriptedEmbeddingModel.hashing()
        let editor = try tightnessEditor(model)
        model.queue(.noKey)
        let key = try run(["measure", "-", "--tightness"], on: editor, input: doc).get()
        expectEqual(key["tightness"]?["reason"], "no_key")
        expect(key["tightness"]?["unavailable"]?.stringValue?.isEmpty == false)
        expect(key["tightness"]?["pairs"] == nil, "nothing partial")
        expectEqual(key["nodes"], plain["nodes"])
        expectEqual(key["pills"], plain["pills"])
        expectEqual(key["constants"], plain["constants"])
        model.queue(.rateLimited)
        let failed = try run(["measure", "-", "--tightness"], on: editor, input: doc).get()
        expectEqual(failed["tightness"]?["reason"], "failed")
        model.queue(.unauthorized)
        expectEqual(try run(["measure", "-", "--tightness"], on: editor, input: doc).get()["tightness"]?["reason"], "no_key", "a rejected key is one the person fixes in Settings")
        let after = try run(["measure", "-", "--tightness"], on: editor, input: doc).get()
        expectEqual(pairs(after).count, 1, "and the next call asks again")
        let missing = try run(["measure", "-", "--tightness"], on: try tightnessEditor(nil), input: doc).get()
        expectEqual(missing["tightness"], ["unavailable": "No embedding model", "reason": "no_model"])
        expectEqual(missing["nodes"], plain["nodes"])
    },
    test("a failure at the second request keeps the first: the next measure asks only for the rest") {
        let model = ScriptedEmbeddingModel(textsPerRequest: 2)
        var queued = false
        model.fallback = { [unowned model] _ in
            if !queued {
                queued = true
                model.queue(.rateLimited)
            }
            return [1, 2, 3]
        }
        let editor = try tightnessEditor(model)
        let doc = document([node("a", "word-memo", title: "A"), node("b", "word-memo", title: "B"), node("c", "word-memo", title: "C"), node("d", "word-memo", title: "D")],
                           [edge("a", "b"), edge("c", "d")])
        let failed = try run(["measure", "-", "--tightness"], on: editor, input: doc).get()
        expectEqual(failed["tightness"]?["reason"], "failed")
        expectEqual(model.requests.map(\.count), [2, 2], "the first request answered, the second failed")
        let again = try run(["measure", "-", "--tightness"], on: editor, input: doc).get()
        expectEqual(again["tightness"]?["asked"], 2)
        expectEqual(model.requests.last, [text("C", nil), text("D", nil)], "only what was missing")
        expectEqual(pairs(again).count, 2)
    },
    test("a script with --tightness is refused: a script's notes have no links, as --on is a document's") {
        let editor = try tightnessEditor(ScriptedEmbeddingModel.hashing())
        guard case .failure(let error) = try run(["measure", "-", "--tightness"], on: editor, input: #"word-memo "A""#) else { return expect(false, "a script was measured for tightness") }
        expectEqual(error.reason, "invalid_params")
        expect(error.message.contains("--tightness"), error.message)
    },
    test("the numbers read back from the wire are the Doubles worked out, to the last bit") {
        let model = ScriptedEmbeddingModel()
        let editor = try tightnessEditor(model)
        let vectors: [[Float]] = [[0.1, 0.7, -0.3, 0.05], [0.9, -0.2, 0.4, 0.33], [-0.5, 0.45, 0.8, -0.12], [0.25, 0.25, -0.6, 0.77]]
        let titles = ["A", "B", "C", "D"]
        setVectors(model, zip(titles, vectors).map { (title: $0, words: nil, vector: $1) })
        let nodes = titles.map { node($0.lowercased(), "word-memo", title: $0) }
        let found = pairs(try run(["measure", "-", "--tightness"], on: editor, input: document(nodes, [edge("a", "b"), edge("b", "c"), edge("c", "d"), edge("a", "d")])).get())
        expectEqual(found.map { "\($0.a)\($0.b)" }, ["ab", "ad", "bc", "cd"])
        let places = ["a": 0, "b": 1, "c": 2, "d": 3]
        for pair in found { expect(pair.tightness == cosine(vectors, places[pair.a]!, places[pair.b]!), "\(pair.a) \(pair.b): \(pair.tightness)") }
        expect(found.allSatisfy { $0.tightness > -1 && $0.tightness < 1 })
    },
    test("the numbers equal the spike's arithmetic to the last bit: values worked out once in JavaScript (cluster.mjs: the mean built as v/n over the nodes in key order, each centred vector divided by its length, a dot in index order), for nodes written out of key order") {
        let model = ScriptedEmbeddingModel()
        let editor = try tightnessEditor(model)
        // Float32 vectors with wide magnitudes, so that a different order of summing is a different last bit (a-q's differs by one).
        let vectors: [String: [Float]] = [
            "m": [0.015515404753386974, -0.19518566131591797, 1.3248348236083984, 49.58810806274414, 0.0179461482912302, 0.17312335968017578, -3.273019790649414, 38.31720733642578],
            "c": [0.020727384835481644, 0.327534556388855, 2.394193410873413, -16.225826263427734, 0.029389608651399612, -0.3077899217605591, 0.7987156510353088, -26.623798370361328],
            "x": [-0.029105160385370255, 0.28757351636886597, 3.713064193725586, 34.398746490478516, -0.03886613994836807, -0.02961251139640808, 2.313331365585327, -13.398658752441406],
            "a": [-0.022068273276090622, -0.13174450397491455, 4.187244415283203, 37.07646179199219, -0.008073103614151478, -0.07134449481964111, 3.197082281112671, -32.72734832763672],
            "q": [-0.034168872982263565, -0.18212956190109253, -1.2302106618881226, 0.4497349262237549, 0.04729742929339409, -0.032465457916259766, 2.53507137298584, -27.469873428344727],
            "f": [-0.006398245692253113, 0.3734368085861206, 3.1893670558929443, -19.213115692138672, 0.0035797476302832365, 0.34657180309295654, 2.002214193344116, -38.89332962036133],
        ]
        let written = ["m", "c", "x", "a", "q", "f"]
        setVectors(model, written.map { (title: $0.uppercased(), words: nil, vector: vectors[$0]!) })
        let nodes = written.map { node($0, "word-memo", title: $0.uppercased()) }
        let links = [("m", "c"), ("x", "a"), ("q", "f"), ("c", "x"), ("a", "q"), ("f", "m")].map { edge($0.0, $0.1) }
        let found = pairs(try run(["measure", "-", "--tightness"], on: editor, input: document(nodes, links)).get())
        // From cluster.mjs's arithmetic, printed with JavaScript's shortest round-trip form.
        let expected: [String: Double] = [
            "cm": -0.7676703551834843, "ax": 0.7136724790477379, "fq": 0.9717297123900319,
            "cx": -0.986094695434604, "aq": -0.30045535314697885, "fm": -0.9120972124546602,
        ]
        expectEqual(found.count, expected.count)
        for pair in found {
            let want = try require(expected[pair.a + pair.b])
            expect(pair.tightness.bitPattern == want.bitPattern, "\(pair.a) \(pair.b): \(pair.tightness) is not \(want)")
        }
        // The texts are asked in key order, which is the order the mean is summed in.
        expectEqual(model.requests.flatMap { $0 }, ["a", "c", "f", "m", "q", "x"].map { text($0.uppercased(), nil) })
    },
    test("pairs and nodes are in UTF-16 code-unit order: a key past U+FFFF comes before one in U+E000 to U+FFFF; two keys that are one string only under canonical equivalence are a refused duplicate") {
        let model = ScriptedEmbeddingModel.hashing()
        let editor = try tightnessEditor(model)
        let astral = "\u{1F600}", high = "\u{FF21}", low = "z"
        let nodes = [node(high, "word-memo", title: "High"), node(astral, "word-memo", title: "Astral"), node(low, "word-memo", title: "Low")]
        let found = pairs(try run(["measure", "-", "--tightness"], on: editor, input: document(nodes, [edge(high, astral), edge(low, high), edge(astral, low)])).get())
        // By UTF-16: z (7A) < U+1F600 (D83D DE00) < U+FF21.
        expectEqual(found.map { "\($0.a)|\($0.b)" }, ["\(low)|\(astral)", "\(low)|\(high)", "\(astral)|\(high)"])
        expectEqual(model.requests.flatMap { $0 }, [text("Low", nil), text("Astral", nil), text("High", nil)], "the nodes, whose order is the order the mean is summed in, are in UTF-16 order too")
        expect(!(astral < high), "Swift's own order is by scalar: U+1F600 is after U+FF21")
        let precomposed = "caf\u{E9}", decomposed = "cafe\u{301}"
        let twice = document([node(precomposed, "word-memo", title: "A"), node(decomposed, "word-memo", title: "B")], [edge(precomposed, decomposed)])
        guard case .failure(let error) = try run(["measure", "-", "--tightness"], on: editor, input: twice) else { return expect(false, "two keys of one string were measured") }
        expectEqual(error.reason, "duplicate")
        expect(error.message.contains("two nodes"), error.message)
    },
    test("without --tightness the answer has no tightness and makes no request; the command's spec lists it, waits as long as the model may, and the protocol stays 2") {
        let model = ScriptedEmbeddingModel.hashing()
        let editor = try tightnessEditor(model)
        let doc = document([node("a", "word-memo", title: "A"), node("b", "word-memo", title: "B")], [edge("a", "b")])
        let answer = try run(["measure", "-"], on: editor, input: doc).get()
        expect(answer["tightness"] == nil)
        expectEqual(model.requests.count, 0)
        let spec = try require(editor.registry.automationCommands.first { $0.name == "measure" })
        expectEqual(spec.params["properties"]?["tightness"]?["type"], "boolean")
        expectEqual(spec.params["properties"]?["tightness"]?["x-timeout"], 120)
        expect(spec.params["required"]?.arrayValue?.contains("tightness") != true)
        expectEqual(RPC.protocolVersion, 2)
    },
])
