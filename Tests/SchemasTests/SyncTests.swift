@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import LanguageModels
import Observation
import Schemas
import TestKit

/// An editor with the schema plugins, a scripted model, and time that moves only when the test says
/// (a harness's, so a test can press and drag as a person does, at zoom 1, view points world units).
@MainActor
final class SyncBench {
    let model: ScriptedLanguageModel
    let harness: EditorHarness
    let sync: SchemaSync
    var editor: CanvasEditor { harness.editor }
    var scheduler: ManualScheduler { harness.scheduler }

    init(document: CanvasDocument = CanvasDocument(), more: [any CanvasPlugin] = []) throws {
        let model = ScriptedLanguageModel()
        self.model = model
        harness = try EditorHarness { scheduler in try schemaEditor(scheduler: scheduler, model: model, document: document, more: more) }
        sync = try require(harness.editor.schemaSync)
    }

    /// A card as the Schema tool places one: the starter, no prompt.
    func place() -> ShapeID {
        editor.add(SchemaCard(frame: CGRect(x: 0, y: 0, width: 240, height: 89)))
    }

    /// The person writing the prompt (a keystroke, or the lot).
    func typePrompt(_ id: ShapeID, _ text: String) {
        editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.prompt = text } }
    }

    /// The person writing the schema.
    func typeSchema(_ id: ShapeID, _ text: String) {
        editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setSchema(text) } }
    }

    func card(_ id: ShapeID) -> SchemaCard? { editor.schemaCard(id) }
    func status(_ id: ShapeID) -> SchemaSyncStatus { sync.status(of: id) }

    /// Commits and waits for the call's answer to land, `text` answering it.
    func sync(_ id: ShapeID, answer text: String) {
        model.queue(text)
        let asked = model.requests.count
        sync.commit(id)
        spinRunLoop(until: { self.model.requests.count > asked && !self.isUpdating(id) })
    }

    func isUpdating(_ id: ShapeID) -> Bool {
        if case .updating = status(id) { return true }
        return false
    }

    /// Runs the main run loop a few turns, for what isn't expected to happen.
    func settle() {
        for _ in 0..<10 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002)) }
    }

    /// The user message of the request `index`.
    func message(_ index: Int) -> String? {
        model.requests.indices.contains(index) ? model.requests[index].messages.first?.text : nil
    }
}

/// A schema of three fields, as the prompt asks the model to write one.
let petSchema = """
{
  "title": "Pet",
  "type": "object",
  "properties": {
    "name": {
      "type": "string"
    },
    "species": {
      "type": "string",
      "enum": ["dog", "cat"]
    },
    "birthYear": {
      "type": "integer"
    }
  }
}
"""

/// A count a closure keeps.
@MainActor final class Counter {
    var count = 0
}

@MainActor let syncTests = Suite("Schema sync", [
    test("a prompt committed asks for the schema at once; the answer is written, trimmed, the card fitted to it") {
        let b = try SyncBench()
        let id = b.place()
        b.typePrompt(id, "a pet in my household")
        b.settle()
        expectEqual(b.model.requests.count, 0, "not before the commit, nor before 3 s")
        b.model.queue("\n\(petSchema)\n")
        b.sync.commit(id)
        expectEqual(b.status(id), .updating(.schema))
        spinRunLoop(until: { b.status(id) == .idle })
        let request = try require(b.model.lastRequest)
        expectEqual(request.system, SchemaPrompts.toSchemaSystem)
        expectEqual([request.maxTokens], [16_000])
        expectEqual(request.temperature, 0)
        expectEqual(request.stopSequences, [])
        expectEqual(request.messages, [.user("<prompt>\na pet in my household\n</prompt>\n\n<schema>\n\(SchemaCard.starter)\n</schema>")])
        expectEqual(b.card(id)?.schema, petSchema)
        expectEqual(b.card(id)?.frame, CGRect(x: 0, y: 0, width: 240, height: 111), "three rows")
        expectEqual(b.card(id)?.prompt, "a pet in my household")
    },
    test("a schema is written as the model wrote it, never laid out again: its order and spacing are the model's") {
        let b = try SyncBench()
        let id = b.place()
        b.typePrompt(id, "a pet in my household")
        let compact = #"{"type":"object","title":"Pet","properties":{"species":{"enum":["dog","cat"]},"name":{"type":"string"},"birthYear":{"type":"integer"}}}"#
        b.sync(id, answer: compact)
        expectEqual(b.card(id)?.schema, compact)
        expectEqual(b.card(id)?.frame.height, 111, "three rows")
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 1, "and it's in step")
    },
    test("an edit syncs 3 s after the last keystroke, and not before") {
        let b = try SyncBench()
        let id = b.place()
        b.model.queue(petSchema)
        b.typePrompt(id, "a pet")
        b.scheduler.advance(by: .seconds(2))
        b.typePrompt(id, "a pet in my household")
        b.scheduler.advance(by: .milliseconds(2999))
        b.settle()
        expectEqual(b.model.requests.count, 0)
        b.scheduler.advance(by: .milliseconds(1))
        spinRunLoop(until: { b.model.requests.count == 1 && b.status(id) == .idle })
        expectEqual(b.card(id)?.schema, petSchema)
    },
    test("the sync's own write starts no sync") {
        let b = try SyncBench()
        let id = b.place()
        b.typePrompt(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        expectEqual(b.card(id)?.schema, petSchema)
        b.scheduler.advance(by: .seconds(10))
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 1)
        expectEqual(b.status(id), .idle)
    },
    test("a schema edited by hand asks for the prompt, with the prompt and the schema at the last sync") {
        let b = try SyncBench()
        let id = b.place()
        b.typePrompt(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        let edited = petSchema.replacingOccurrences(of: "\"birthYear\"", with: "\"microchipId\"")
        b.typeSchema(id, edited)
        b.sync(id, answer: "a pet in my household, with its microchip ID")
        let request = try require(b.model.lastRequest)
        expectEqual(request.system, SchemaPrompts.toPromptSystem)
        expectEqual([request.maxTokens], [2048])
        expectEqual(request.temperature, 0)
        expectEqual(request.messages, [.user("<prompt>\na pet in my household\n</prompt>\n\n<previous_schema>\n\(petSchema)\n</previous_schema>\n\n<schema>\n\(edited)\n</schema>")])
        expectEqual(b.card(id)?.prompt, "a pet in my household, with its microchip ID")
        expectEqual(b.card(id)?.schema, edited, "the side the person wrote isn't touched")
    },
    test("a prompt edited after a sync tells the model the prompt it was, as previous_prompt") {
        let b = try SyncBench()
        let id = b.place()
        b.typePrompt(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        b.typePrompt(id, "a pet in my household, no birth year")
        b.sync(id, answer: "NO_CHANGE")
        expectEqual(b.message(1), "<previous_prompt>\na pet in my household\n</previous_prompt>\n\n<prompt>\na pet in my household, no birth year\n</prompt>\n\n<schema>\n\(petSchema)\n</schema>")
    },
    test("a prompt written from nothing: an empty prompt is left out of the request") {
        let b = try SyncBench()
        let id = b.place()
        b.typeSchema(id, #"{"type": "object", "properties": {"email": {"type": "string"}}}"#)
        b.sync(id, answer: "A contact: email.")
        expectEqual(b.message(0), "<previous_schema>\n\(SchemaCard.starter)\n</previous_schema>\n\n<schema>\n{\"type\": \"object\", \"properties\": {\"email\": {\"type\": \"string\"}}}\n</schema>")
        expectEqual(b.card(id)?.prompt, "A contact: email.")
    },
    test("both sides edited before either synced: the schema is asked for, from the edited one") {
        let b = try SyncBench()
        let id = b.place()
        b.typePrompt(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        let edited = petSchema.replacingOccurrences(of: "\"integer\"", with: "\"number\"")
        b.typeSchema(id, edited)
        b.typePrompt(id, "a pet in my household, and its weight")
        b.sync(id, answer: "NO_CHANGE")
        expectEqual(b.model.lastRequest?.system, SchemaPrompts.toSchemaSystem)
        expectEqual(b.message(1), "<previous_prompt>\na pet in my household\n</previous_prompt>\n\n<prompt>\na pet in my household, and its weight\n</prompt>\n\n<schema>\n\(edited)\n</schema>")
    },
    test("text that isn't a JSON object never syncs, either way") {
        let b = try SyncBench()
        let id = b.place()
        for text in [#"{"type": "object", "properties": {"#, "[1, 2]", ""] {
            b.typeSchema(id, text)
            b.sync.commit(id)
            b.scheduler.advance(by: .seconds(5))
            b.typePrompt(id, "a pet \(text.count)")
            b.sync.commit(id)
            b.scheduler.advance(by: .seconds(5))
        }
        b.settle()
        expectEqual(b.model.requests.count, 0)
        expectEqual(b.status(id), .idle)
    },
    test("a read-only (locked) card never syncs; an answer landing on one writes nothing, is refused nothing, and its edit syncs once it's thawed") {
        let log = RefusalLog()
        let b = try SyncBench(more: [FreezingPlugin(log: log)])
        let id = b.place()
        b.typePrompt(id, "a pet in my household")
        b.editor.freeze([id])
        b.sync.commit(id)
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 0)
        b.editor.freeze([id], false)
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.editor.freeze([id])
        b.model.release()
        spinRunLoop(until: { b.status(id) == .idle })
        expectEqual(b.card(id)?.schema, SchemaCard.starter)
        expectEqual(log.refusals, [], "no write is tried, so nothing is refused (no shake)")
        // Its last sync is where it was: thawed, its prompt still asks for the schema, from nothing.
        b.editor.freeze([id], false)
        b.model.holdsAnswers = false
        b.sync(id, answer: petSchema)
        expectEqual(b.model.lastRequest?.system, SchemaPrompts.toSchemaSystem)
        expectEqual(b.message(1), "<prompt>\na pet in my household\n</prompt>\n\n<schema>\n\(SchemaCard.starter)\n</schema>")
        expectEqual(b.card(id)?.schema, petSchema)
    },
    test("a card seen for the first time is in step: on a board opened, and pasted") {
        var props = card(petSchema, at: .zero)
        props.prompt = "a pet in my household"
        let loaded = ShapeRecord(props)
        let b = try SyncBench(document: CanvasDocument(shapes: [AnyShapeRecord(loaded)]))
        b.sync.commit(loaded.id)
        let pasted = b.editor.add(card(petSchema, at: CGPoint(x: 400, y: 0)))
        b.editor.transact { $0.update(pasted, as: SchemaCard.self) { $0.props.prompt = "a pet" } }
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1, "the pasted card's prompt, changed after it came, syncs")
        b.sync.commit(loaded.id)
        b.settle()
        expectEqual(b.model.requests.count, 1, "the opened card doesn't")
        // What the opened card said is its last sync: a field taken out of its prompt is taken out.
        b.typePrompt(loaded.id, "a pet in my household, no birth year")
        b.sync(loaded.id, answer: "NO_CHANGE")
        expectEqual(b.message(1), "<previous_prompt>\na pet in my household\n</previous_prompt>\n\n<prompt>\na pet in my household, no birth year\n</prompt>\n\n<schema>\n\(petSchema)\n</schema>")
    },
    test("a card opened with a prompt over a schema with no fields was never answered: nothing syncs by itself, and a commit asks for the schema") {
        let loaded = ShapeRecord(SchemaCard(frame: CGRect(x: 0, y: 0, width: 240, height: 89), prompt: "a pet in my household"))
        let b = try SyncBench(document: CanvasDocument(shapes: [AnyShapeRecord(loaded)]))
        let pasted = b.editor.add(SchemaCard(frame: CGRect(x: 400, y: 0, width: 240, height: 89), prompt: "a book"))
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 0, "not on opening, nor on a paste")
        expectEqual(b.status(loaded.id), .idle)
        b.sync(loaded.id, answer: petSchema)
        expectEqual(b.model.lastRequest?.system, SchemaPrompts.toSchemaSystem)
        expectEqual(b.message(0), "<prompt>\na pet in my household\n</prompt>\n\n<schema>\n\(SchemaCard.starter)\n</schema>", "from nothing")
        expectEqual(b.card(loaded.id)?.schema, petSchema)
        b.sync(pasted, answer: "NO_CHANGE")
        expectEqual(b.model.requests.count, 2, "the pasted one too")
    },
    test("a board read again (a revert, a reload) isn't an edit: a call out for a card it changes is dropped, unwritten") {
        let b = try SyncBench()
        let id = b.place()
        b.typePrompt(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        let saved = b.editor.document
        b.model.holdsAnswers = true
        b.model.queue(petSchema.replacingOccurrences(of: "\"birthYear\"", with: "\"weight\""))
        b.typePrompt(id, "a pet in my household, and its weight")
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        let edits = Counter()
        b.editor.undoHistory.didChange = { event in if event != .cleared { edits.count += 1 } }
        b.editor.replaceDocument(with: saved)
        expectEqual(b.status(id), .idle)
        spinRunLoop(until: { b.model.answered == 2 })
        b.settle()
        expectEqual(b.card(id)?.prompt, "a pet in my household")
        expectEqual(b.card(id)?.schema, petSchema, "the answer isn't written onto the card read again")
        expectEqual(b.model.queued.count, 1, "the call was cancelled, and took no answer")
        b.model.holdsAnswers = false
        b.scheduler.advance(by: .seconds(5))
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 2, "nor does it sync after: it's in step as it was saved")
        expectEqual(edits.count, 0, "so the board read again isn't marked edited")
        expect(!b.editor.canUndo, "and nothing since is a step to undo")
    },
    test("a board read again with other text starts no sync, and drops an edit waiting for its 3 s; the next edit syncs from what was read") {
        let b = try SyncBench()
        let id = b.place()
        b.typePrompt(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        let saved = b.editor.document
        let weighed = petSchema.replacingOccurrences(of: "\"birthYear\"", with: "\"weight\"")
        b.typePrompt(id, "a pet in my household, and its weight")
        b.sync(id, answer: weighed)
        b.typePrompt(id, "a pet in my household, and its weight in kilograms")
        b.editor.replaceDocument(with: saved)
        b.scheduler.advance(by: .seconds(5))
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 2)
        b.typePrompt(id, "a pet in my household, no birth year")
        b.sync(id, answer: "NO_CHANGE")
        expectEqual(b.message(2), "<previous_prompt>\na pet in my household\n</previous_prompt>\n\n<prompt>\na pet in my household, no birth year\n</prompt>\n\n<schema>\n\(petSchema)\n</schema>")
    },
    test("an answer that lands while the card is dragged stays when Escape puts the card back, and no sync follows") {
        let b = try SyncBench()
        let id = b.place()
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        b.typePrompt(id, "a pet in my household")
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.harness.move(to: CGPoint(x: 100, y: 40))
        b.harness.press()
        b.harness.drag(to: CGPoint(x: 160, y: 80))
        expect(b.editor.session is TranslatingSession)
        expectEqual(b.card(id)?.frame.origin, CGPoint(x: 60, y: 40))
        b.model.release()
        spinRunLoop(until: { !b.isUpdating(id) })
        expectEqual(b.card(id)?.schema, petSchema)
        b.editor.cancel()
        expectEqual(b.card(id)?.frame, CGRect(x: 0, y: 0, width: 240, height: 111), "back where it was, and as tall as the answer")
        expectEqual(b.card(id)?.schema, petSchema, "Escape takes back the move, not the answer")
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1)
    },
    test("only the two sides are edits: a move, a lock and a restack start no sync, and leave a failure as it was") {
        let b = try SyncBench(more: [FreezingPlugin()])
        let id = b.place()
        _ = b.place()
        b.typePrompt(id, "a pet in my household")
        b.model.queue(.overloaded)
        b.sync.commit(id)
        spinRunLoop(until: { !b.isUpdating(id) })
        let failed = SchemaSyncStatus.failed(SchemaSyncFailure(writing: .schema, LanguageModelError.overloaded.message))
        expectEqual(b.status(id), failed)
        b.editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.frame.origin.x += 50 } }
        b.editor.freeze([id])
        b.editor.freeze([id], false)
        b.editor.transact { $0.bringToFront(id) }
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1)
        expectEqual(b.status(id), failed)
    },
    test("a card that failed for want of a key tries again once one is saved in Settings; one that failed otherwise waits for Retry") {
        let b = try SyncBench()
        let id = b.place(), other = b.place()
        b.typePrompt(id, "a pet in my household")
        b.typePrompt(other, "a book")
        b.model.queue(.noKey)
        b.sync.commit(id)
        spinRunLoop(until: { !b.isUpdating(id) })
        b.model.queue(.overloaded)
        b.sync.commit(other)
        spinRunLoop(until: { !b.isUpdating(other) })
        expectEqual(b.status(id), .failed(SchemaSyncFailure(writing: .schema, LanguageModelError.noKey.message, remedy: .key)))
        let directory = FileManager.default.temporaryDirectory.appending(path: "schema-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AnthropicKeySettings(keys: AnthropicKeyStore(url: directory.appending(path: "key")), model: ScriptedLanguageModel())
        settings.draft = "sk-ant-test"
        b.model.queue(petSchema)
        settings.save()
        spinRunLoop(until: { b.model.requests.count == 3 && b.status(id) == .idle })
        expectEqual(b.card(id)?.schema, petSchema)
        b.settle()
        expectEqual(b.model.requests.count, 3)
        expectEqual(b.status(other), .failed(SchemaSyncFailure(writing: .schema, LanguageModelError.overloaded.message)))
    },
    test("a schema too long to write whole isn't asked for: the status says to edit it by hand, and a hand edit writes the prompt") {
        let b = try SyncBench()
        let fields = (0..<700).map { "\"field\($0)\": {\"type\": \"string\", \"description\": \"Field number \($0).\"}" }
        let long = "{\"title\": \"Big\", \"type\": \"object\", \"properties\": {\(fields.joined(separator: ", "))}}"
        expect(long.utf8.count > SchemaPrompts.toSchemaMaxLength)
        let id = b.editor.add(card(long))
        b.typePrompt(id, "a big record")
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 0)
        expectEqual(b.status(id), .failed(SchemaSyncFailure(writing: .schema, SchemaSync.tooLongMessage, remedy: .editByHand)))
        let edited = long.replacingOccurrences(of: "\"field0\"", with: "\"name\"")
        b.typeSchema(id, edited)
        b.sync(id, answer: "a big record, with a name")
        expectEqual(b.model.lastRequest?.system, SchemaPrompts.toPromptSystem)
        expectEqual(b.card(id)?.prompt, "a big record, with a name")
        expectEqual(b.card(id)?.schema, edited)
    },
    test("an answer is dropped if the side it writes changed while it was out, and the change syncs after") {
        let b = try SyncBench()
        let id = b.place()
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        b.typePrompt(id, "a pet in my household")
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.editor.transact { $0.update(id, as: SchemaCard.self) { $0.props.setTitle("Mine") } }
        let renamed = try require(b.card(id)).schema
        b.model.release()
        spinRunLoop(until: { b.status(id) == .idle })
        expectEqual(b.card(id)?.schema, renamed)
        b.scheduler.advance(by: .seconds(3))
        spinRunLoop(until: { b.model.requests.count == 2 })
        expectEqual(b.message(1), "<prompt>\na pet in my household\n</prompt>\n\n<schema>\n\(renamed)\n</schema>")
    },
    test("edits to the prompt while its call is out wait, and sync once it lands, from what it wrote") {
        let b = try SyncBench()
        let id = b.place()
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        b.typePrompt(id, "a pet in my household")
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.typePrompt(id, "a pet in my household, and its weight")
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 1)
        b.model.holdsAnswers = false
        b.model.queue("NO_CHANGE")
        b.model.release()
        spinRunLoop(until: { b.model.requests.count == 2 && b.status(id) == .idle })
        expectEqual(b.card(id)?.schema, petSchema)
        expectEqual(b.message(1), "<previous_prompt>\na pet in my household\n</previous_prompt>\n\n<prompt>\na pet in my household, and its weight\n</prompt>\n\n<schema>\n\(petSchema)\n</schema>")
    },
    test("a card deleted while its call is out drops the answer") {
        let b = try SyncBench()
        let id = b.place()
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        b.typePrompt(id, "a pet in my household")
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.editor.transact { $0.delete([id]) }
        spinRunLoop(until: { b.model.answered == 1 })
        b.settle()
        expectEqual(b.editor.document.shapes.count, 0)
        expectEqual(b.model.queued.count, 1, "the call was cancelled, and took no answer")
        expectEqual(b.status(id), .idle)
    },
    test("a failure leaves both sides as typed and says why; Retry asks again") {
        let b = try SyncBench()
        let id = b.place()
        b.typePrompt(id, "a pet in my household")
        b.model.queue(.overloaded)
        b.sync.commit(id)
        spinRunLoop(until: { b.status(id) != .updating(.schema) })
        expectEqual(b.status(id), .failed(SchemaSyncFailure(writing: .schema, "Anthropic is overloaded. Try again in a moment.")))
        expectEqual(b.card(id)?.prompt, "a pet in my household")
        expectEqual(b.card(id)?.schema, SchemaCard.starter)
        b.model.queue(petSchema)
        b.sync.retry(id)
        spinRunLoop(until: { b.status(id) == .idle })
        expectEqual(b.model.requests.count, 2)
        expectEqual(b.model.requests[1], b.model.requests[0])
        expectEqual(b.card(id)?.schema, petSchema)
    },
    test("with no key saved, or one refused, the failure says to see Settings") {
        let b = try SyncBench()
        let id = b.place()
        b.typePrompt(id, "a pet in my household")
        for error in [LanguageModelError.noKey, .unauthorized] {
            b.model.queue(error)
            b.sync.commit(id)
            spinRunLoop(until: { !b.isUpdating(id) })
            expectEqual(b.status(id), .failed(SchemaSyncFailure(writing: .schema, error.message, remedy: .key)))
        }
        expectEqual(b.status(id), .failed(SchemaSyncFailure(writing: .schema, "Anthropic didn't accept the API key. Check it in Settings…", remedy: .key)))
    },
    test("a cancelled call says nothing, changes nothing, and the edit still syncs on the next commit") {
        let b = try SyncBench()
        let id = b.place()
        b.typePrompt(id, "a pet in my household")
        b.model.queue(.cancelled)
        b.sync.commit(id)
        spinRunLoop(until: { b.model.answered == 1 && !b.isUpdating(id) })
        expectEqual(b.status(id), .idle)
        expectEqual(b.card(id)?.schema, SchemaCard.starter)
        b.sync(id, answer: petSchema)
        expectEqual(b.model.requests.count, 2)
        expectEqual(b.card(id)?.schema, petSchema)
    },
    test("an answer that can't be used is a failure, and changes nothing: cut off (edit it by hand), not a schema (retry)") {
        let b = try SyncBench()
        let id = b.place()
        b.typePrompt(id, "a pet in my household")
        b.model.queue(ModelResponse(text: String(petSchema.prefix(40)), stopReason: .maxTokens))
        b.sync.commit(id)
        spinRunLoop(until: { !b.isUpdating(id) })
        expectEqual(b.status(id), .failed(SchemaSyncFailure(writing: .schema, "Claude's schema was too long, and was cut off. Edit the JSON Schema by hand, and the description follows.",
                                                            remedy: .editByHand)))
        b.model.queue("Sure! Here's a schema for a pet.")
        b.sync.retry(id)
        spinRunLoop(until: { !b.isUpdating(id) })
        expectEqual(b.status(id), .failed(SchemaSyncFailure(writing: .schema, "Claude's answer wasn't a JSON Schema.")))
        expectEqual(b.card(id)?.schema, SchemaCard.starter)
        b.typeSchema(id, petSchema)
        b.typePrompt(id, "")
        b.model.queue(ModelResponse(text: "Here's the updated prompt: a pet", stopReason: .endTurn))
        b.sync.commit(id)
        spinRunLoop(until: { !b.isUpdating(id) })
        expectEqual(b.status(id), .failed(SchemaSyncFailure(writing: .prompt, "Claude's answer wasn't a description.")))
        expectEqual(b.card(id)?.prompt, "", "never written over the person's prompt")
    },
    test("NO_CHANGE writes nothing, and the sync is done") {
        let b = try SyncBench()
        let id = b.place()
        b.typePrompt(id, "asdf")
        let revision = b.editor.revision
        b.sync(id, answer: "  NO_CHANGE\n")
        expectEqual(b.editor.revision, revision)
        expectEqual(b.status(id), .idle)
        b.sync.commit(id)
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1)
    },
    test("a schema laid out anew, an empty card named, and a prompt cleared ask nothing") {
        let b = try SyncBench()
        let id = b.place()
        b.typeSchema(id, #"{"type":"object","properties":{}}"#)
        b.sync.commit(id)
        b.typeSchema(id, #"{"title": "Pet", "type": "object", "properties": {}}"#)
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 0)
        b.typePrompt(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        b.typePrompt(id, "  ")
        b.sync.commit(id)
        b.typeSchema(id, #"{"title":"Pet","type":"object","properties":{"name":{"type":"string"},"species":{"enum":["dog","cat"],"type":"string"},"birthYear":{"type":"integer"}}}"#)
        b.sync.commit(id)
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1)
    },
    test("each card's status is observed alone") {
        let b = try SyncBench()
        let a = b.place(), other = b.place()
        b.typePrompt(a, "a pet")
        b.typePrompt(other, "a book")
        b.model.holdsAnswers = true
        let heard = Flag()
        withObservationTracking { _ = b.sync.status(of: a) } onChange: { heard.set() }
        b.sync.commit(other)
        expect(!heard.isSet)
        expectEqual(b.status(other), .updating(.schema))
        b.sync.commit(a)
        expect(heard.isSet)
        spinRunLoop(until: { b.model.waiting == 2 })
        b.model.queue(.overloaded)
        b.model.queue(.overloaded)
        b.model.release()
        spinRunLoop(until: { b.model.answered == 2 })
    },
])

@MainActor let promptTests = Suite("Schema prompts", [
    test("a request is blocks of trimmed text, the empty ones left out") {
        let toSchema = SchemaPrompts.toSchema(previousPrompt: nil, prompt: "  email required \n", schema: "{}")
        expectEqual(toSchema.messages, [.user("<prompt>\nemail required\n</prompt>\n\n<schema>\n{}\n</schema>")])
        expectEqual(SchemaPrompts.toSchema(previousPrompt: " ", prompt: "a", schema: "{}").messages.first?.text.hasPrefix("<prompt>"), true)
        let toPrompt = SchemaPrompts.toPrompt(prompt: "", previousSchema: nil, schema: "{\"a\": 1}")
        expectEqual(toPrompt.messages, [.user("<schema>\n{\"a\": 1}\n</schema>")])
        expectEqual([toSchema.maxTokens, toPrompt.maxTokens], [16_000, 2048])
        expectEqual([toSchema.temperature, toPrompt.temperature], [0, 0])
    },
    test("an answer: NO_CHANGE alone, a fenced or tagged answer unwrapped, a stop before the end a failure") {
        func parse(_ text: String, _ direction: SchemaPrompts.Direction = .toSchema, stop: StopReason = .endTurn) -> SchemaPrompts.Answer {
            SchemaPrompts.parse(ModelResponse(text: text, stopReason: stop), direction)
        }
        expectEqual(parse("\n NO_CHANGE \n"), .noChange)
        expectEqual(parse("NO_CHANGE", .toPrompt), .noChange)
        // NO_CHANGE as the first word, whatever follows: the model sometimes says why.
        expectEqual(parse("NO_CHANGE."), .noChange)
        expectEqual(parse("NO_CHANGE — the prompt already covers it.", .toPrompt), .noChange)
        expectEqual(parse("NO_CHANGE\n\nThe schema already says it."), .noChange)
        expectEqual(parse("a pet in my household\n\nNO_CHANGE", .toPrompt), .noChange, "the prompt said again, then NO_CHANGE")
        expectEqual(parse("{\"type\": \"object\"}\nNO_CHANGE."), .noChange)
        // A line of a tag alone at either end is a wrapper, whatever the tag.
        expectEqual(parse("{\"type\": \"object\"}\n</output>"), .text("{\"type\": \"object\"}"))
        expectEqual(parse("<answer>\nemail required\n</answer>", .toPrompt), .text("email required"))
        expectEqual(parse("NO_CHANGES"), .failure("Claude's answer wasn't a JSON Schema."))
        expectEqual(parse("NO_CHANGE_X", .toPrompt), .failure("Claude's answer wasn't a description."))
        // A prompt loses one pair of quotes around it, and isn't written if it reads as something else.
        expectEqual(parse("\"email required, phone\"", .toPrompt), .text("email required, phone"))
        expectEqual(parse("“a pet, with its weight”", .toPrompt), .text("a pet, with its weight"))
        expectEqual(parse("\"a\" and \"b\"", .toPrompt), .text("\"a\" and \"b\""))
        for answer in ["Here's the updated prompt: a pet", "Updated prompt: a pet", "Sure! a pet", "a pet (NO_CHANGE to the rest)", "a pet ```"] {
            expectEqual(parse(answer, .toPrompt), .failure("Claude's answer wasn't a description."), answer)
        }
        expectEqual(parse("Heretic saints: name, feast day", .toPrompt), .text("Heretic saints: name, feast day"))
        expectEqual(parse("```json\n{\"type\": \"object\"}\n```"), .text("{\"type\": \"object\"}"))
        expectEqual(parse("```\n{\"type\": \"object\"}"), .text("{\"type\": \"object\"}"))
        expectEqual(parse("{\"type\": \"object\"}\n```"), .text("{\"type\": \"object\"}"))
        // Wrappers from either end, in any nesting, until none is left; the other side's tags stay.
        expectEqual(parse("<schema>\n```json\n{\"type\": \"object\"}\n```\n</schema>"), .text("{\"type\": \"object\"}"))
        expectEqual(parse("```\n<schema>{}</schema>\n```"), .text("{}"))
        expectEqual(parse("```\nNO_CHANGE\n```"), .noChange)
        expectEqual(parse("<prompt>\nNO_CHANGE\n</prompt>", .toPrompt), .noChange)
        expectEqual(parse("<prompt>\nemail required, phone\n</prompt>", .toPrompt), .text("email required, phone"))
        expectEqual(parse("<schema>email</schema>", .toPrompt), .text("<schema>email</schema>"))
        expectEqual(parse("<prompt>{}</prompt>"), .failure("Claude's answer wasn't a JSON Schema."))
        expectEqual(parse("```\n```", .toPrompt), .failure("Claude's answer was empty."))
        expectEqual(parse("Here it is: {\"type\": \"object\"}"), .failure("Claude's answer wasn't a JSON Schema."))
        expectEqual(parse("[{}]"), .failure("Claude's answer wasn't a JSON Schema."))
        expectEqual(parse("{\"type\": }"), .failure("Claude's answer wasn't a JSON Schema."))
        expectEqual(parse("{}", stop: .refusal), .failure("Claude declined to answer."))
        expectEqual(parse("a pet", .toPrompt, stop: .maxTokens), .failure("Claude's answer was too long, and was cut off."))
        expectEqual(parse("{}", stop: StopReason(rawValue: "pause_turn")), .failure("Claude stopped before it finished (pause_turn)."))
        expectEqual(parse("  email required, phone \n", .toPrompt), .text("email required, phone"))
        expectEqual(parse(" \n", .toPrompt), .failure("Claude's answer was empty."))
    },
    test("the system prompts name the blocks the requests send and the no-change answer, and end in one line break") {
        for (system, tags) in [(SchemaPrompts.toSchemaSystem, ["<previous_prompt>", "<prompt>", "<schema>"]),
                               (SchemaPrompts.toPromptSystem, ["<prompt>", "<previous_schema>", "<schema>"])] {
            for tag in tags { expect(system.contains(tag), tag) }
            expect(system.contains(SchemaPrompts.noChange))
            // Each is its .txt byte for byte, final line break included (evals.py reads them out).
            expect(system.hasSuffix(".\n") && !system.hasSuffix("\n\n"))
        }
    },
])
