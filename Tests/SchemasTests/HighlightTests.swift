import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import Geometry
import LanguageModels
import Mentions
import ProseMaps
import Schemas
import TestKit

/// Whether a request asks for highlights, not the sync: its message has a `<prose>` block. They name one
/// model now (Haiku 5.5), so the model can't tell them apart.
func isHighlightRequest(_ request: ModelRequest) -> Bool { request.messages.first?.text.hasPrefix("<prose>") == true }

/// The owner's example: a description, the schema it says, and what the model linked in the evals.
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
let jiraAnswer = #"[{"text": "jira ticket", "address": ""}, {"text": "key", "address": "/properties/key"}, {"text": "one-line", "address": "/properties/summary/maxLength"}, {"text": "summary", "address": "/properties/summary"}, {"text": "link to it", "address": "/properties/url"}]"#

/// An editor of schema cards whose model answers highlights with `answer` (and fails anything
/// else), nothing kept from a test before, and frames drawn as the canvas draws them.
@MainActor
final class HighlightBench {
    let model = ScriptedLanguageModel()
    let scheduler = ManualScheduler()
    let editor: CanvasEditor
    var answer: Result<ModelResponse, LanguageModelError> = .success(ModelResponse(text: jiraAnswer))

    init() throws {
        ProseMapService.forgetEveryAnswer()
        SchemaHighlightsShown.forgetEverything()
        editor = try schemaEditor(scheduler: scheduler, model: model)
        model.fallback = { [unowned self] request in
            isHighlightRequest(request) ? self.answer : .failure(.server(status: 0, message: "no answer for the sync"))
        }
    }

    /// A key saved in Settings, as its notification says, heard.
    func keySaved() {
        NotificationCenter.default.post(name: .languageModelKeyDidChange, object: nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.01))
    }

    var maps: ProseMapService { editor.proseMaps! }
    var asked: [ModelRequest] { model.requests.filter { isHighlightRequest($0) } }

    /// A frame of the canvas, 800 × 600 at the camera's zoom: what's drawn in full is read.
    func frame() { _ = renderBitmap(editor, size: CGSize(width: 800, height: 600)) }

    /// Waits for every highlights call to land.
    func settle() { spinRunLoop(until: { self.maps.callsOut == 0 && self.maps.callsWaiting == 0 }) }

    func card(_ id: ShapeID) -> ShapeRecord<SchemaCard>? { editor.document[id]?.typed(as: SchemaCard.self) }

    /// The card's highlights as it shows them: their words and what each says.
    func placed(_ card: ShapeRecord<SchemaCard>) -> [PlacedHighlight] {
        SchemaHighlightsShown.placed(for: card, maps: editor.proseMaps, sync: editor.schemaSync)
    }

    /// Where the card's highlights are drawn, each mention's pill as it shows.
    func lines(_ card: ShapeRecord<SchemaCard>) -> [[CGRect]] {
        SchemaHighlightsShown.lines(of: card, maps: editor.proseMaps, sync: editor.schemaSync) {
            self.editor.registry.mentionResolution(of: $0, lookup: { self.editor.shape(inFile: $0) })
        }
    }

    /// The card's highlights as it's drawn: each one's words, and what they say of it.
    func shown(_ id: ShapeID) -> [String] {
        guard let card = card(id) else { return [] }
        let text = card.props.prompt.stored as NSString
        return placed(card).map { "\(text.substring(with: $0.range)) \($0.role == .element ? "field" : "rule")" }
    }
}

/// Counts the canvas's redraws. (Its delegate protocol is the host's, so it can't be public in
/// CanvasTesting.)
final class RedrawCounter: CanvasEditorDelegate {
    var redraws = 0
    func editorNeedsDisplay(_ editor: CanvasEditor) { redraws += 1 }
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {}
}

@MainActor let highlightTests = Suite("Schema highlights", [
    test("a JSON Pointer reads as RFC 6901 writes one: the root, escapes, indexes and a fragment's #, percent-decoded; and leads nowhere past what's there") {
        expectEqual(JSONPointer("")?.tokens, [])
        expectEqual(JSONPointer("/")?.tokens, [""])
        expectEqual(JSONPointer("/a~1b/c~0d/~01")?.tokens, ["a/b", "c~d", "~1"], "~1 is read before ~0")
        expectEqual(JSONPointer("#/properties/key")?.tokens, ["properties", "key"])
        expectEqual(JSONPointer("properties/key"), nil)
        expectEqual(JSONPointer("#/$defs/My%20Thing")?.tokens, ["$defs", "My Thing"], "a fragment is decoded")
        expectEqual(JSONPointer("#/caf%C3%A9/a~1b%7E0")?.tokens, ["café", "a/b~"], "UTF-8, and decoded before ~ is read")
        expectEqual(JSONPointer("/My%20Thing")?.tokens, ["My%20Thing"], "a pointer that isn't a fragment isn't")
        expectEqual(JSONPointer("#/50%/x")?.tokens, ["50%", "x"], "a malformed escape, as written")
        expectEqual(JSONPointer(tokens: ["a/b", "c~d"]).description, "/a~1b/c~0d")
        let text = #"{"a": {"b": [10, {"c": true}]}, "a": {"b": [20]}, "e/f": 1}"#
        @MainActor func at(_ pointer: String) -> String? {
            guard let pointer = JSONPointer(pointer), let part = SchemaTarget.locate([pointer], in: text).first ?? nil else { return nil }
            return ProseMapText.excerpt(part, of: text)
        }
        expectEqual(at("/a/b/0"), "20", "of two members of one name, the last")
        expectEqual(at("/a/b/1"), nil)
        expectEqual(at("/e~1f"), #""e/f": 1"#, "a member from its key")
        expectEqual(at("/a/b"), #""b": [20]"#)
        expectEqual(at(""), text, "the whole")
        for nowhere in ["/a/b/01", "/a/b/-", "/a/b/+0", "/x", "/e~1f/g", "/a/b/99999999999999999999"] {
            expectEqual(at(nowhere), nil, nowhere)
        }
        expectEqual(SchemaTarget.locate([JSONPointer(tokens: [])], in: "{"), [nil], "in text that isn't JSON, nowhere")
        expectEqual(JSONPointer(JSONPointer(tokens: ["a/b", "c~d"]).description), JSONPointer(tokens: ["a/b", "c~d"]), "read as the model writes one")
    },
    test("what words pointing somewhere say: a field (an element) through the data's places, a rule at any other keyword or through what combines or conditions") {
        let cases: [(String, LinkRole)] = [
            ("", .element), ("/title", .element), ("/properties", .element), ("/properties/key", .element),
            ("/properties/properties", .element), ("/properties/lines/items", .element), ("/properties/lines/items/properties/amount", .element),
            ("/$defs/address", .element), ("/$defs/address/properties/zip", .element), ("/properties/row/prefixItems/0", .element),
            ("/properties/summary/description", .element), ("/additionalProperties", .element),
            ("/properties/summary/maxLength", .rule), ("/required", .rule), ("/required/0", .rule),
            ("/properties/status/enum", .rule), ("/properties/status/enum/1", .rule), ("/properties/status/default", .rule),
            ("/properties/due/format", .rule), ("/properties/lines/minItems", .rule), ("/properties/tags/uniqueItems", .rule),
            ("/anyOf", .rule), ("/anyOf/0/required", .rule), ("/if", .rule), ("/if/properties/method/const", .rule),
            ("/then/required", .rule), ("/not", .rule),
        ]
        for (pointer, role) in cases { expectEqual(SchemaTarget.role(of: try require(JSONPointer(pointer))), role, pointer) }
    },
    test("placing keeps what's in the description and leads somewhere in the schema, in the description's order, each with the part it shows") {
        var links = try require(ProseMapPrompt.links(from: ModelResponse(text: jiraAnswer))).compactMap { link in
            JSONPointer(link.address).map { ProseLink(quote: link.quote, address: $0) }
        }
        links.append(ProseLink(quote: "key", address: try require(JSONPointer("/properties/id"))))            // leads nowhere
        links.append(ProseLink(quote: "priority", address: try require(JSONPointer("/properties/key"))))       // not in the words
        let map = ProseMap<SchemaTarget>(placing: links, prose: jiraPrompt, target: jiraSchema)
        expectEqual(map.links.map { String(jiraPrompt[$0.inProse]) }, ["jira ticket", "key", "one-line", "summary", "link to it"])
        expectEqual(map.links.map(\.role), [.element, .element, .rule, .element, .element])
        let parts = map.links.map { map.excerpt(of: $0) }
        expectEqual(parts[0], jiraSchema, "the thing itself: the whole schema")
        expectEqual(parts[2], #""maxLength": 255"#)
        expectEqual(parts[3], """
        "summary": {
          "type": "string",
          "maxLength": 255
        }
        """, "as written, at the left margin")
    },
    test("the request asks Haiku 5.5 at medium effort, its temperature its own and no fallback, told of a schema by its guide, the description and the schema in their blocks") {
        let request = ProseMapPrompt.request(SchemaTarget.self, prose: " a pet \n", target: "{}")
        expectEqual(request.model, "claude-haiku-5-5")
        expectEqual(request.effort, "medium")
        expectEqual(request.temperature, nil)
        expectEqual(request.fallbacks, nil)
        expectEqual(request.maxTokens, 2048)
        let system = try require(request.system)
        expect(system.hasPrefix("A user writes in a few plain words what their schema says."), system)
        expect(system.contains("- <schema>: the schema, which says what the words say (and may say more).\n"), system)
        expect(system.contains("\n\nThe schema is a JSON Schema (draft 2020-12)"), "the guide, a paragraph of its own")
        expect(system.contains("\"address\": \"/properties/loans/items/properties/dueDate\"}]\n\nReply [] when no words link."), "its example, then the frame's")
        expect(!system.contains("{name}") && !system.contains("{guide}"))
        expectEqual(request.messages, [.user("<prose>\na pet\n</prose>\n\n<schema>\n{}\n</schema>")])
    },
    test("a card drawn in full, in step, is asked about once: its answer is drawn, and a pair asked about isn't asked about again, on any card") {
        let b = try HighlightBench()
        let id = b.editor.add(card(jiraSchema, prompt: jiraPrompt))
        expectEqual(b.asked.count, 0, "not before it's drawn")
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 1)
        expectEqual(b.asked.first?.messages, [.user("<prose>\n\(jiraPrompt)\n</prose>\n\n<schema>\n\(jiraSchema)\n</schema>")])
        expectEqual(b.shown(id), ["jira ticket field", "key field", "one-line rule", "summary field", "link to it field"])
        expectEqual(b.maps.revision(of: id), 1)
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
        b.editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setPrompt(SchemaPromptText(plain: jiraPrompt)) } }
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 0, "an edit waiting")
        b.model.fallback = { request in
            isHighlightRequest(request) ? .success(ModelResponse(text: jiraAnswer)) : .success(ModelResponse(text: jiraSchema))
        }
        try require(b.editor.schemaSync).commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.frame()
        expectEqual(b.asked.count, 0, "the schema being written")
        b.model.holdsAnswers = false
        b.model.release()
        spinRunLoop(until: { b.card(id)?.props.schema.text == jiraSchema })
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 1, "in step once the answer's written")
        expectEqual(b.shown(id).count, 5)
    },
    test("an answer that leaves the schema as it was brings the card into step though it commits nothing, and the canvas draws again to ask about its texts") {
        let b = try HighlightBench()
        b.model.fallback = { request in
            isHighlightRequest(request) ? .success(ModelResponse(text: jiraAnswer)) : .success(ModelResponse(text: jiraSchema))
        }
        let id = b.editor.add(card(jiraSchema, prompt: jiraPrompt))
        b.frame()
        b.settle()
        b.editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setPrompt(SchemaPromptText(plain: jiraPrompt + ", as before")) } }
        let canvas = RedrawCounter()
        b.editor.delegate = canvas
        try require(b.editor.schemaSync).commit(id)
        spinRunLoop(until: { b.editor.schemaSync?.isInStep(id) == true })
        expectEqual(b.card(id)?.props.schema.text, jiraSchema, "nothing written")
        expect(canvas.redraws > 0, "drawn again")
        b.frame()
        b.settle()
        expectEqual(b.asked.count, 2, "the new pair asked about")
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
        expectEqual(b.maps.callsOut, 4)
        expectEqual(b.maps.callsWaiting, 2)
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
        b.editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setPrompt(SchemaPromptText(plain: "its status, then " + jiraPrompt)) } }
        expectEqual(b.shown(id), ["jira ticket field", "key field", "one-line rule", "summary field", "link to it field"], "in their new places")
        b.editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setPrompt(SchemaPromptText(plain: jiraPrompt.replacingOccurrences(of: "one-line summary", with: "title"))) } }
        expectEqual(b.shown(id), ["jira ticket field", "key field", "link to it field"])
        b.editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.schema.text = jiraSchema.replacingOccurrences(of: "\"url\"", with: "\"link\"") } }
        expectEqual(b.shown(id), ["jira ticket field", "key field"], "a part renamed")
    },
])
