import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import Geometry
import LanguageModels
import Schemas
import TestKit

/// The owner's example: a description, the schema it says, and what Sonnet 5.5 linked in the evals.
let jiraPrompt = "a jira ticket we point to: its key, a one-line summary and a link to it"
let jiraSchema = """
{
  "title": "Jira ticket",
  "type": "object",
  "properties": {
    "key": {
      "type": "string",
      "pattern": "^[A-Z][A-Z0-9]+-[0-9]+$"
    },
    "summary": {
      "type": "string",
      "maxLength": 255
    },
    "url": {
      "type": "string",
      "format": "uri"
    }
  },
  "required": ["key", "summary", "url"]
}
"""
let jiraAnswer = #"[{"text": "jira ticket", "pointer": ""}, {"text": "key", "pointer": "/properties/key"}, {"text": "one-line", "pointer": "/properties/summary/maxLength"}, {"text": "summary", "pointer": "/properties/summary"}, {"text": "link to it", "pointer": "/properties/url"}]"#

/// An editor of schema cards whose model answers highlights with `answer` (and fails anything
/// else), nothing kept from a test before, and frames drawn as the canvas draws them.
@MainActor
final class HighlightBench {
    let model = ScriptedLanguageModel()
    let scheduler = ManualScheduler()
    let editor: CanvasEditor
    var answer: Result<ModelResponse, LanguageModelError> = .success(ModelResponse(text: jiraAnswer))

    init() throws {
        SchemaHighlightAnswers.forgetEverything()
        editor = try schemaEditor(scheduler: scheduler, model: model)
        model.fallback = { [unowned self] request in
            request.model == SchemaPrompts.highlightsModel ? self.answer : .failure(.server(status: 0, message: "no answer for the sync"))
        }
    }

    /// A key saved in Settings, as its notification says, heard.
    func keySaved() {
        NotificationCenter.default.post(name: .languageModelKeyDidChange, object: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    var highlighter: SchemaHighlighter { editor.schemaSync!.highlighter }
    var asked: [ModelRequest] { model.requests.filter { $0.model == SchemaPrompts.highlightsModel } }

    /// A frame of the canvas, 800 × 600 at the camera's zoom: what's drawn in full is read.
    func frame() { _ = renderBitmap(editor, size: CGSize(width: 800, height: 600)) }

    /// Waits for every highlights call to land.
    func settle() { spinRunLoop(until: { self.highlighter.callsOut == 0 && self.highlighter.callsWaiting == 0 }) }

    func card(_ id: ShapeID) -> ShapeRecord<SchemaCard>? { editor.document[id]?.typed(as: SchemaCard.self) }

    /// The card's highlights as it's drawn: each one's words, and its kind.
    func shown(_ id: ShapeID) -> [String] {
        guard let card = card(id) else { return [] }
        let text = card.props.prompt as NSString
        return SchemaHighlightAnswers.placed(for: card).map { "\(text.substring(with: $0.range)) \($0.kind == .field ? "field" : "rule")" }
    }
}

@MainActor let highlightTests = Suite("Schema highlights", [
    test("a JSON Pointer reads as RFC 6901 writes one: the root, escapes, indexes and a fragment's #; and leads nowhere past what's there") {
        expectEqual(JSONPointer("")?.tokens, [])
        expectEqual(JSONPointer("/")?.tokens, [""])
        expectEqual(JSONPointer("/a~1b/c~0d/~01")?.tokens, ["a/b", "c~d", "~1"], "~1 is read before ~0")
        expectEqual(JSONPointer("#/properties/key")?.tokens, ["properties", "key"])
        expectEqual(JSONPointer("properties/key"), nil)
        expectEqual(JSONPointer(tokens: ["a/b", "c~d"]).description, "/a~1b/c~0d")
        let text = #"{"a": {"b": [10, {"c": true}]}, "a": {"b": [20]}, "e/f": 1}"#
        let root = try JSONReader.read(text)
        @MainActor func at(_ pointer: String) -> String? {
            guard let target = JSONPointer(pointer)?.resolve(in: root) else { return nil }
            return SchemaHighlights.fragment(target.range, of: text)
        }
        expectEqual(at("/a/b/0"), "20", "of two members of one name, the last")
        expectEqual(at("/a/b/1"), nil)
        expectEqual(at("/e~1f"), #""e/f": 1"#, "a member from its key")
        expectEqual(at("/a/b"), #""b": [20]"#)
        expectEqual(at(""), text, "the whole")
        for nowhere in ["/a/b/01", "/a/b/-", "/a/b/+0", "/x", "/e~1f/g", "/a/b/99999999999999999999"] {
            expectEqual(at(nowhere), nil, nowhere)
        }
    },
    test("what words pointing somewhere say: a field through the data's places, a rule at any other keyword or through what combines or conditions") {
        let cases: [(String, SchemaHighlight.Kind)] = [
            ("", .field), ("/title", .field), ("/properties", .field), ("/properties/key", .field),
            ("/properties/properties", .field), ("/properties/lines/items", .field), ("/properties/lines/items/properties/amount", .field),
            ("/$defs/address", .field), ("/$defs/address/properties/zip", .field), ("/properties/row/prefixItems/0", .field),
            ("/properties/summary/description", .field), ("/additionalProperties", .field),
            ("/properties/summary/maxLength", .validation), ("/required", .validation), ("/required/0", .validation),
            ("/properties/status/enum", .validation), ("/properties/status/enum/1", .validation), ("/properties/status/default", .validation),
            ("/properties/due/format", .validation), ("/properties/lines/minItems", .validation), ("/properties/tags/uniqueItems", .validation),
            ("/anyOf", .validation), ("/anyOf/0/required", .validation), ("/if", .validation), ("/if/properties/method/const", .validation),
            ("/then/required", .validation), ("/not", .validation),
        ]
        for (pointer, kind) in cases { expectEqual(SchemaHighlights.kind(of: try require(JSONPointer(pointer))), kind, pointer) }
    },
    test("words are found in order, whole words first, as written first, never overlapping: words written twice go to their places in turn") {
        let text = "the customer's name and email, and each product's name, keyboard and key"
        @MainActor func found(_ words: [String], in text: String = text) -> [Int?] {
            SchemaHighlights.anchor(words, in: text).map { $0.map { text.distance(from: text.startIndex, to: $0.lowerBound) } }
        }
        expectEqual(found(["customer", "name", "email", "product", "name", "key"]), [4, 15, 24, 40, 50, 69], "the second name after the first; key, not keyboard's")
        expectEqual(found(["email", "customer"]), [24, 4], "listed out of order: from the start once nothing's after")
        expectEqual(found(["Customer", "EMAIL"]), [4, 24], "as written first, then ignoring case")
        expectEqual(found(["customer's name", "name"]), [4, 50], "never inside one found")
        expectEqual(found(["phone", "", "name"]), [nil, nil, 15])
        expectEqual(found(["keyboard"]), [56])
        expectEqual(found(["key"], in: "keyboard"), [0], "inside a word only when it's nowhere else")
        expectEqual(found(["タイトル", "必須"], in: "書籍：タイトル（必須）"), [3, 8])
    },
    test("placing keeps what's in the description and leads somewhere in the schema, in the description's order, each with the part it shows") {
        let root = try JSONReader.read(jiraSchema)
        var highlights = try require(SchemaPrompts.parseHighlights(ModelResponse(text: jiraAnswer)))
        highlights.append(SchemaHighlight(words: "key", pointer: "/properties/id"))            // leads nowhere
        highlights.append(SchemaHighlight(words: "priority", pointer: "/properties/key"))       // not in the words
        let placed = SchemaHighlights.place(highlights, in: jiraPrompt, schema: root)
        let text = jiraPrompt as NSString
        expectEqual(placed.map { text.substring(with: $0.range) }, ["jira ticket", "key", "one-line", "summary", "link to it"])
        expectEqual(placed.map(\.kind), [.field, .field, .validation, .field, .field])
        let parts = placed.map { SchemaHighlights.fragment($0.part, of: jiraSchema) }
        expectEqual(parts[0], jiraSchema, "the thing itself: the whole schema")
        expectEqual(parts[2], #""maxLength": 255"#)
        expectEqual(parts[3], """
        "summary": {
          "type": "string",
          "maxLength": 255
        }
        """, "as written, at the left margin")
    },
    test("an answer is read as the model writes it: an array, fenced, taken back and written again, explained after; else not at all") {
        @MainActor func read(_ text: String, _ stop: StopReason = .endTurn) -> [String]? {
            SchemaPrompts.parseHighlights(ModelResponse(text: text, stopReason: stop))?.map { "\($0.words) \($0.pointer)" }
        }
        let one = #"[{"text": "key", "pointer": "/properties/key"}]"#
        expectEqual(read(one), ["key /properties/key"])
        expectEqual(read("```json\n\(one)\n```"), ["key /properties/key"])
        expectEqual(read(#"[{"text": "Key", "pointer": ""}]"# + "\n\nWait, the prompt writes it lowercase.\n\n" + one), ["key /properties/key"], "the last one")
        expectEqual(read(one + "\n\nThe second key repeats the first, so I linked it once."), ["key /properties/key"])
        expectEqual(read(#"[{"text": "a"}, {"pointer": "/x"}, {"text": " ", "pointer": ""}, {"text": "b", "pointer": 1}, {"text": "c", "pointer": ""}]"#), ["c "],
                    "items without words, or a pointer, left out")
        expectEqual(read("[]"), [])
        expectEqual(read("I can't link these words."), nil)
        expectEqual(read(one, .maxTokens), nil, "cut off")
        expectEqual(read(one, .refusal), nil)
    },
    test("the request asks Sonnet 5.5 at low effort, its temperature its own, the description and the schema in their blocks") {
        let request = SchemaPrompts.toHighlights(prompt: " a pet \n", schema: "{}")
        expectEqual(request.model, "claude-sonnet-5-5")
        expectEqual(request.effort, "low")
        expectEqual(request.temperature, nil)
        expectEqual(request.fallbacks, .default)
        expectEqual(request.maxTokens, 2048)
        expectEqual(request.system, SchemaPrompts.highlightsSystem)
        expectEqual(request.messages, [.user("<prompt>\na pet\n</prompt>\n\n<schema>\n{}\n</schema>")])
    },
    test("a card drawn in full, in step, is asked about once: its answer is drawn, and a pair asked about isn't asked about again, on any card") {
        let b = try HighlightBench()
        let id = b.editor.add(card(jiraSchema, prompt: jiraPrompt))
        expectEqual(b.asked.count, 0, "not before it's drawn")
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 1)
        expectEqual(b.asked.first?.messages, [.user("<prompt>\n\(jiraPrompt)\n</prompt>\n\n<schema>\n\(jiraSchema)\n</schema>")])
        expectEqual(b.shown(id), ["jira ticket field", "key field", "one-line rule", "summary field", "link to it field"])
        expectEqual(b.highlighter.revision(of: id), 1)
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 1, "asked once")
        let copy = b.editor.add(card(jiraSchema, prompt: jiraPrompt, at: CGPoint(x: 400, y: 40)))
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 1, "the same texts on another card")
        expectEqual(b.shown(copy).count, 5)
    },
    test("a card is asked about only once it's in step: while its description waits to sync, or the schema's being written, it waits, and is asked as the sync lands") {
        let b = try HighlightBench()
        b.model.holdsAnswers = true
        let id = b.editor.add(SchemaCard(frame: CGRect(x: 40, y: 40, width: 240, height: 52)))
        b.editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setPrompt(jiraPrompt) } }
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 0, "an edit waiting")
        b.model.fallback = { request in
            request.model == SchemaPrompts.highlightsModel ? .success(ModelResponse(text: jiraAnswer)) : .success(ModelResponse(text: jiraSchema))
        }
        try require(b.editor.schemaSync).commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.frame()
        expectEqual(b.asked.count, 0, "the schema being written")
        b.model.holdsAnswers = false
        b.model.release()
        spinRunLoop(until: { b.card(id)?.props.schema == jiraSchema })
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 1, "in step once the answer's written")
        expectEqual(b.shown(id).count, 5)
    },
    test("a card zoomed out to its skeleton, or out of view, is asked about nothing") {
        let b = try HighlightBench()
        _ = b.editor.add(card(jiraSchema, prompt: jiraPrompt, at: CGPoint(x: 4000, y: 40)))
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 0, "out of view")
        b.editor.camera.setZoom(0.3, around: .zero)
        _ = b.editor.add(card(jiraSchema, prompt: "\(jiraPrompt), zoomed out", at: CGPoint(x: 40, y: 40)))
        b.frame()
        b.settle()
        expect(b.editor.drawsSkeletons)
        expectEqual(b.asked.count, 0, "a skeleton")
    },
    test("a pair that failed, or whose answer can't be read, isn't asked about again, but once a key is saved in Settings") {
        let b = try HighlightBench()
        b.answer = .failure(.noKey)
        let id = b.editor.add(card(jiraSchema, prompt: jiraPrompt))
        b.frame()
        b.settle()
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 1, "asked once")
        expectEqual(b.shown(id), [])
        b.answer = .success(ModelResponse(text: "Sorry, I can't."))
        b.keySaved()
        b.frame()
        b.settle()
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 2, "asked again once, after the key; unreadable, then not again")
        b.answer = .success(ModelResponse(text: jiraAnswer))
        b.keySaved()
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 3)
        expectEqual(b.shown(id).count, 5)
    },
    test("at most 4 calls are out at once, the rest waiting their turn") {
        let b = try HighlightBench()
        b.model.holdsAnswers = true
        for n in 0..<6 {
            b.editor.add(card(jiraSchema, prompt: "\(jiraPrompt) (\(n))", at: CGPoint(x: 40 + CGFloat(n % 3) * 250, y: 40 + CGFloat(n / 3) * 150)))
        }
        b.frame()
        spinRunLoop(until: { b.model.waiting == 4 })
        expectEqual(b.highlighter.callsOut, 4)
        expectEqual(b.highlighter.callsWaiting, 2)
        b.model.holdsAnswers = false
        b.model.release()
        b.settle()
        expectEqual(b.asked.count, 6)
    },
    test("typing keeps the words still there: the card's last answer is found in its text as it's typed, and words taken out lose theirs") {
        let b = try HighlightBench()
        let id = b.editor.add(card(jiraSchema, prompt: jiraPrompt))
        b.frame()
        b.settle()
        b.editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setPrompt("its status, then " + jiraPrompt) } }
        expectEqual(b.shown(id), ["jira ticket field", "key field", "one-line rule", "summary field", "link to it field"], "in their new places")
        b.editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setPrompt(jiraPrompt.replacingOccurrences(of: "one-line summary", with: "title")) } }
        expectEqual(b.shown(id), ["jira ticket field", "key field", "link to it field"])
        b.editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.schema = jiraSchema.replacingOccurrences(of: "\"url\"", with: "\"link\"") } }
        expectEqual(b.shown(id), ["jira ticket field", "key field"], "a part renamed")
    },
])
