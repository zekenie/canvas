@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import LanguageModels
import Mentions
import Observation
import ProseMaps
import TestKit
import Titles
import Types

/// An editor with the type plugins, a scripted model, and time that moves only when the test says
/// (a harness's, so a test can press and drag as a person does, at zoom 1, view points world units).
@MainActor
final class SyncBench {
    let model: ScriptedLanguageModel
    let harness: EditorHarness
    let sync: TypeSync<TypeSchemaProperty>
    var editor: CanvasEditor { harness.editor }
    var scheduler: ManualScheduler { harness.scheduler }

    init(document: CanvasDocument = CanvasDocument(), file: CanvasFile? = nil, more: [any CanvasPlugin] = []) throws {
        let model = ScriptedLanguageModel()
        self.model = model
        harness = try EditorHarness { scheduler in try typeEditor(scheduler: scheduler, model: model, document: document, file: file, more: more) }
        sync = try require(harness.editor.typeSync)
    }

    /// A type as `/is-a type` leaves one: the starter, no words, untitled.
    func place() -> ShapeID {
        let record = typeRecord(TypeSchemaProperty.starter, at: .zero)
        editor.transact { $0.insert(record) }
        return record.id
    }

    /// The person writing the words (a keystroke, or the lot), the memo fitted to them.
    func typeWords(_ id: ShapeID, _ text: String) {
        editor.transact { $0.update(id, as: Memo.self) { $0.props.text = MentionText(plain: text); MemoStyle.fit(&$0.props) } }
    }

    /// The person writing the schema.
    func typeSchema(_ id: ShapeID, _ text: String) {
        editor.transact { $0.update(id) { $0[TypeSchemaProperty.self] = SchemaText(text) } }
    }

    func memo(_ id: ShapeID) -> Memo? { editor.memo(id) }
    func schema(_ id: ShapeID) -> String? { editor.schema(id) }
    func words(_ id: ShapeID) -> MentionText? { editor.words(id) }
    func title(_ id: ShapeID) -> String? { editor.title(id) }
    func status(_ id: ShapeID) -> TypeSyncStatus { sync.status(of: id) }

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

/// A schema of three fields, as the prompt asks the model to write one: its title first, the name the
/// sync takes out of what it keeps (`pet`) and names an untitled type by.
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

/// `petSchema` as a type keeps it: without its title, which is its shape's.
let pet = petSchema.replacingOccurrences(of: "  \"title\": \"Pet\",\n", with: "")

/// A count a closure keeps.
@MainActor final class Counter {
    var count = 0
}

@MainActor let syncTests = Suite("Type sync", [
    test("words committed ask for the schema at once; the answer is written, trimmed, its title taken out and the untitled type named by it, as tall as its words") {
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        b.settle()
        expectEqual(b.model.requests.count, 0, "not before the commit, nor before 3 s")
        b.model.queue("\n\(petSchema)\n")
        b.sync.commit(id)
        expectEqual(b.status(id), .updating(.schema))
        spinRunLoop(until: { b.status(id) == .idle })
        let request = try require(b.model.lastRequest)
        expectEqual(request.system, SchemaPrompts.system(.toSchema))
        expectEqual([request.maxTokens], [16_000])
        expectEqual(request.temperature, nil)
        expectEqual([request.model, request.effort], ["claude-haiku-5-5", "medium"])
        expectEqual(request.stopSequences, [])
        expectEqual(request.messages, [.user("<prompt>\na pet in my household\n</prompt>\n\n<schema>\n\(TypeSchemaProperty.starter)\n</schema>")])
        expectEqual(b.schema(id), pet)
        expectEqual(b.title(id), "Pet", "named by the model's title, in the same step")
        expectEqual(b.editor.undoHistory.undoName, "Update Schema")
        expectEqual(b.memo(id)?.frame, CGRect(x: 0, y: 0, width: 240, height: MemoStyle.height(lines: 1)), "its words' line: no schema sizes it")
        expectEqual(b.words(id), "a pet in my household")
    },
    test("a schema is written as the model wrote it, never laid out again: its order and spacing are the model's") {
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        let compact = #"{"type":"object","title":"Pet","properties":{"species":{"enum":["dog","cat"]},"name":{"type":"string"},"birthYear":{"type":"integer"}}}"#
        b.sync(id, answer: compact)
        expectEqual(b.schema(id), #"{"type":"object","properties":{"species":{"enum":["dog","cat"]},"name":{"type":"string"},"birthYear":{"type":"integer"}}}"#,
                    "but its title, which is the type's")
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 1, "and it's in step")
    },
    test("an edit syncs 3 s after the last keystroke, and not before") {
        let b = try SyncBench()
        let id = b.place()
        b.model.queue(petSchema)
        b.typeWords(id, "a pet")
        b.scheduler.advance(by: .seconds(2))
        b.typeWords(id, "a pet in my household")
        b.scheduler.advance(by: .milliseconds(2999))
        b.settle()
        expectEqual(b.model.requests.count, 0)
        b.scheduler.advance(by: .milliseconds(1))
        spinRunLoop(until: { b.model.requests.count == 1 && b.status(id) == .idle })
        expectEqual(b.schema(id), pet)
    },
    test("the sync's own write starts no sync") {
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        expectEqual(b.schema(id), pet)
        b.scheduler.advance(by: .seconds(10))
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 1)
        expectEqual(b.status(id), .idle)
    },
    test("a schema edited by hand asks for the words, with the words and the schema at the last sync") {
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        let edited = petSchema.replacingOccurrences(of: "\"birthYear\"", with: "\"microchipId\"")
        b.typeSchema(id, edited)
        b.sync(id, answer: "a pet in my household, with its microchip ID")
        let request = try require(b.model.lastRequest)
        expectEqual(request.system, SchemaPrompts.system(.toPrompt))
        expectEqual([request.maxTokens], [4096])
        expectEqual(request.temperature, nil)
        expectEqual(request.messages, [.user("<prompt>\na pet in my household\n</prompt>\n\n<previous_schema>\n\(petSchema)\n</previous_schema>\n\n<schema>\n\(edited)\n</schema>")])
        expectEqual(b.words(id), "a pet in my household, with its microchip ID")
        expectEqual(b.schema(id), edited, "the side the person wrote isn't touched")
    },
    test("words edited after a sync tell the model the words they were, as previous_prompt") {
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        b.typeWords(id, "a pet in my household, no birth year")
        b.sync(id, answer: "NO_CHANGE")
        expectEqual(b.message(1), "<previous_prompt>\na pet in my household\n</previous_prompt>\n\n<prompt>\na pet in my household, no birth year\n</prompt>\n\n<schema>\n\(petSchema)\n</schema>")
    },
    test("words written from nothing: empty words are left out of the request") {
        let b = try SyncBench()
        let id = b.place()
        b.typeSchema(id, #"{"type": "object", "properties": {"email": {"type": "string"}}}"#)
        b.sync(id, answer: "A contact: email.")
        expectEqual(b.message(0), "<previous_schema>\n\(TypeSchemaProperty.starter)\n</previous_schema>\n\n<schema>\n{\"type\": \"object\", \"properties\": {\"email\": {\"type\": \"string\"}}}\n</schema>")
        expectEqual(b.words(id), "A contact: email.")
    },
    test("both sides edited before either synced: the schema is asked for, from the edited one") {
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        let edited = petSchema.replacingOccurrences(of: "\"integer\"", with: "\"number\"")
        b.typeSchema(id, edited)
        b.typeWords(id, "a pet in my household, and its weight")
        b.sync(id, answer: "NO_CHANGE")
        expectEqual(b.model.lastRequest?.system, SchemaPrompts.system(.toSchema))
        expectEqual(b.message(1), "<previous_prompt>\na pet in my household\n</previous_prompt>\n\n<prompt>\na pet in my household, and its weight\n</prompt>\n\n<schema>\n\(edited)\n</schema>")
    },
    test("text that isn't a JSON object never syncs, either way") {
        let b = try SyncBench()
        let id = b.place()
        for text in [#"{"type": "object", "properties": {"#, "[1, 2]", ""] {
            b.typeSchema(id, text)
            b.sync.commit(id)
            b.scheduler.advance(by: .seconds(5))
            b.typeWords(id, "a pet \(text.count)")
            b.sync.commit(id)
            b.scheduler.advance(by: .seconds(5))
        }
        b.settle()
        expectEqual(b.model.requests.count, 0)
        expectEqual(b.status(id), .idle)
    },
    test("a read-only (locked) type never syncs; an answer landing on one writes nothing, is refused nothing, and its edit syncs once it's thawed") {
        let log = RefusalLog()
        let b = try SyncBench(more: [FreezingPlugin(log: log)])
        let id = b.place()
        b.typeWords(id, "a pet in my household")
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
        expectEqual(b.schema(id), TypeSchemaProperty.starter)
        expectEqual(log.refusals, [], "no write is tried, so nothing is refused (no shake)")
        // Its last sync is where it was: thawed, its prompt still asks for the schema, from nothing.
        b.editor.freeze([id], false)
        b.model.holdsAnswers = false
        b.sync(id, answer: petSchema)
        expectEqual(b.model.lastRequest?.system, SchemaPrompts.system(.toSchema))
        expectEqual(b.message(1), "<prompt>\na pet in my household\n</prompt>\n\n<schema>\n\(TypeSchemaProperty.starter)\n</schema>")
        expectEqual(b.schema(id), pet)
    },
    test("a type in a read-only container (a locked frame) is read-only too: it never syncs, nor takes an answer that lands once its container is frozen") {
        let log = RefusalLog()
        let b = try SyncBench(more: [FreezingPlugin(log: log), CorralsPlugin()])
        let corral = b.editor.add(Corral(CGRect(x: -100, y: -100, width: 800, height: 600)))
        let id = b.place()
        b.editor.put([id], in: corral)
        b.typeWords(id, "a pet in my household")
        b.editor.freeze([corral])
        b.sync.commit(id)
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 0, "frozen with its corral")
        b.editor.freeze([corral], false)
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.editor.freeze([corral])
        b.model.release()
        spinRunLoop(until: { b.status(id) == .idle })
        expectEqual(b.schema(id), TypeSchemaProperty.starter)
        expectEqual(log.refusals, [], "no write is tried, so nothing is refused (no shake)")
        b.editor.freeze([corral], false)
        b.model.holdsAnswers = false
        b.sync(id, answer: petSchema)
        expectEqual(b.schema(id), pet, "thawed, its edit syncs")
    },
    test("a type in a frame locked on a board that isn't shown takes no answer either") {
        let log = RefusalLog()
        let pocket = ShapeRecord(Pocket(CGRect(x: 2000, y: 0, width: 100, height: 100)))
        let b = try SyncBench(file: CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket)])),
                              more: [FreezingPlugin(log: log), CorralsPlugin(), PocketsPlugin()])
        let corral = b.editor.add(Corral(CGRect(x: -100, y: -100, width: 800, height: 600)))
        let id = b.place()
        b.editor.put([id], in: corral)
        b.typeWords(id, "a pet in my household")
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        expect(b.editor.showBoard(BoardID(owner: pocket.id)))
        b.editor.transact(on: .root, "Freeze") { $0.update(corral) { $0[Frozen.self] = true } }
        b.model.release()
        spinRunLoop(until: { b.status(id) == .idle })
        @MainActor func schema() -> String? { b.editor.file.record(id)?[TypeSchemaProperty.self]?.text }
        expectEqual(schema(), TypeSchemaProperty.starter)
        expectEqual(log.refusals, [], "no write is tried")
        // Its last sync is where it was: thawed, its prompt still asks for the schema.
        b.editor.transact(on: .root, "Thaw") { $0.update(corral) { $0[Frozen.self] = nil } }
        b.model.holdsAnswers = false
        b.sync(id, answer: petSchema)
        expectEqual(b.model.lastRequest?.system, SchemaPrompts.system(.toSchema))
        expectEqual(schema(), pet)
    },
    test("a type on a locked subboard's board is read-only too, shown or not: its model isn't asked, an answer that lands once the lock does writes nothing, and its edit syncs once it's thawed") {
        let log = RefusalLog()
        let pocket = ShapeRecord(Pocket(CGRect(x: 2000, y: 0, width: 100, height: 100)))
        let b = try SyncBench(file: CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket)]), children: [pocket.id: CanvasDocument()]),
                              more: [FreezingPlugin(log: log), PocketsPlugin()])
        expect(b.editor.showBoard(BoardID(owner: pocket.id)))
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        @MainActor func freeze(_ frozen: Bool) {
            b.editor.transact(on: .root, frozen ? "Freeze" : "Thaw") { $0.update(pocket.id) { $0[Frozen.self] = frozen ? true : nil } }
        }
        @MainActor func schema() -> String? { b.editor.file.record(id)?[TypeSchemaProperty.self]?.text }
        freeze(true)
        expect(b.editor.isBoardReadOnly)
        b.sync.commit(id)
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 0, "the board it's on can't change")
        expectEqual(b.status(id), .idle)
        expect(b.editor.showBoard(.root))
        b.sync.commit(id)
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 0, "nor with the board not shown")
        freeze(false)
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        freeze(true)
        b.model.release()
        spinRunLoop(until: { b.status(id) == .idle })
        expectEqual(schema(), TypeSchemaProperty.starter, "the answer wrote nothing")
        expectEqual(log.refusals, [], "no write is tried, so nothing is refused (no shake)")
        freeze(false)
        b.model.holdsAnswers = false
        b.sync(id, answer: petSchema)
        expectEqual(schema(), pet, "thawed, its edit syncs")
    },
    test("a type seen for the first time is in step: on a board opened, and pasted") {
        let loaded = typeRecord(petSchema, words: "a pet in my household", at: .zero)
        let b = try SyncBench(document: CanvasDocument(shapes: [loaded]))
        b.sync.commit(loaded.id)
        let pasted = b.editor.addType(petSchema, at: CGPoint(x: 400, y: 0))
        b.typeWords(pasted, "a pet")
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1, "the pasted type's words, changed after they came, sync")
        b.sync.commit(loaded.id)
        b.settle()
        expectEqual(b.model.requests.count, 1, "the opened type doesn't")
        // What the opened card said is its last sync: a field taken out of its prompt is taken out.
        b.typeWords(loaded.id, "a pet in my household, no birth year")
        b.sync(loaded.id, answer: "NO_CHANGE")
        expectEqual(b.message(1), "<previous_prompt>\na pet in my household\n</previous_prompt>\n\n<prompt>\na pet in my household, no birth year\n</prompt>\n\n<schema>\n\(petSchema)\n</schema>")
    },
    test("a type opened with words over a schema with no fields was never answered: nothing syncs by itself, and a commit asks for the schema") {
        let loaded = typeRecord(TypeSchemaProperty.starter, words: "a pet in my household", at: .zero)
        let b = try SyncBench(document: CanvasDocument(shapes: [loaded]))
        let pasted = b.editor.addType(TypeSchemaProperty.starter, words: "a book", at: CGPoint(x: 400, y: 0))
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 0, "not on opening, nor on a paste")
        expectEqual(b.status(loaded.id), .idle)
        b.sync(loaded.id, answer: petSchema)
        expectEqual(b.model.lastRequest?.system, SchemaPrompts.system(.toSchema))
        expectEqual(b.message(0), "<prompt>\na pet in my household\n</prompt>\n\n<schema>\n\(TypeSchemaProperty.starter)\n</schema>", "from nothing")
        expectEqual(b.schema(loaded.id), pet)
        b.sync(pasted, answer: "NO_CHANGE")
        expectEqual(b.model.requests.count, 2, "the pasted one too")
    },
    test("a board read again (a revert, a reload) isn't an edit: a call out for a type it changes is dropped, unwritten") {
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        let saved = b.editor.document
        b.model.holdsAnswers = true
        b.model.queue(petSchema.replacingOccurrences(of: "\"birthYear\"", with: "\"weight\""))
        b.typeWords(id, "a pet in my household, and its weight")
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        let edits = Counter()
        b.editor.undoHistory.didChange = { event in if event != .cleared { edits.count += 1 } }
        b.editor.replaceDocument(with: saved)
        expectEqual(b.status(id), .idle)
        spinRunLoop(until: { b.model.answered == 2 })
        b.settle()
        expectEqual(b.words(id), "a pet in my household")
        expectEqual(b.schema(id), pet, "the answer isn't written onto the type read again")
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
        b.typeWords(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        let saved = b.editor.document
        let weighed = petSchema.replacingOccurrences(of: "\"birthYear\"", with: "\"weight\"")
        b.typeWords(id, "a pet in my household, and its weight")
        b.sync(id, answer: weighed)
        b.typeWords(id, "a pet in my household, and its weight in kilograms")
        b.editor.replaceDocument(with: saved)
        b.scheduler.advance(by: .seconds(5))
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 2)
        b.typeWords(id, "a pet in my household, no birth year")
        b.sync(id, answer: "NO_CHANGE")
        expectEqual(b.message(2), "<previous_prompt>\na pet in my household\n</previous_prompt>\n\n<prompt>\na pet in my household, no birth year\n</prompt>\n\n<schema>\n\(petSchema)\n</schema>")
    },
    test("an answer that lands while the type is dragged stays when Escape puts the type back, and no sync follows") {
        let b = try SyncBench()
        let id = b.place()
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        b.typeWords(id, "a pet in my household")
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.harness.move(to: CGPoint(x: 100, y: 40))
        b.harness.press()
        b.harness.drag(to: CGPoint(x: 160, y: 80))
        expect(b.editor.session is TranslatingSession)
        expectEqual(b.memo(id)?.frame.origin, CGPoint(x: 60, y: 40))
        b.model.release()
        spinRunLoop(until: { !b.isUpdating(id) })
        expectEqual(b.schema(id), pet)
        b.editor.cancel()
        expectEqual(b.memo(id)?.frame, CGRect(x: 0, y: 0, width: 240, height: MemoStyle.height(lines: 1)), "back where it was")
        expectEqual(b.schema(id), pet, "Escape takes back the move, not the answer")
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1)
    },
    test("only the two sides are edits: a move, a lock and a restack start no sync, and leave a failure as it was") {
        let b = try SyncBench(more: [FreezingPlugin()])
        let id = b.place()
        _ = b.place()
        b.typeWords(id, "a pet in my household")
        b.model.queue(.overloaded)
        b.sync.commit(id)
        spinRunLoop(until: { !b.isUpdating(id) })
        let failed = TypeSyncStatus.failed(TypeSyncFailure(writing: .schema, LanguageModelError.overloaded.message))
        expectEqual(b.status(id), failed)
        b.editor.transact { $0.update(id, as: Memo.self) { $0.props.frame.origin.x += 50 } }
        b.editor.freeze([id])
        b.editor.freeze([id], false)
        b.editor.transact { $0.bringToFront(id) }
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1)
        expectEqual(b.status(id), failed)
    },
    test("a type that failed for want of a key tries again once one is saved in Settings; one that failed otherwise waits for Retry") {
        let b = try SyncBench()
        let id = b.place(), other = b.place()
        b.typeWords(id, "a pet in my household")
        b.typeWords(other, "a book")
        b.model.queue(.noKey)
        b.sync.commit(id)
        spinRunLoop(until: { !b.isUpdating(id) })
        b.model.queue(.overloaded)
        b.sync.commit(other)
        spinRunLoop(until: { !b.isUpdating(other) })
        expectEqual(b.status(id), .failed(TypeSyncFailure(writing: .schema, LanguageModelError.noKey.message, remedy: .key)))
        let directory = FileManager.default.temporaryDirectory.appending(path: "schema-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AnthropicKeySettings(keys: AnthropicKeyStore(url: directory.appending(path: "key")), model: ScriptedLanguageModel())
        settings.draft = "sk-ant-test"
        b.model.queue(petSchema)
        settings.save()
        spinRunLoop(until: { b.model.requests.count == 3 && b.status(id) == .idle })
        expectEqual(b.schema(id), pet)
        b.settle()
        expectEqual(b.model.requests.count, 3)
        expectEqual(b.status(other), .failed(TypeSyncFailure(writing: .schema, LanguageModelError.overloaded.message)))
    },
    test("a schema too long to write whole isn't asked for: the status says to edit it by hand, and a hand edit writes the words") {
        let b = try SyncBench()
        let fields = (0..<700).map { "\"field\($0)\": {\"type\": \"string\", \"description\": \"Field number \($0).\"}" }
        let long = "{\"title\": \"Big\", \"type\": \"object\", \"properties\": {\(fields.joined(separator: ", "))}}"
        expect(long.utf8.count > SchemaPrompts.toSchemaMaxLength)
        let id = b.editor.addType(long)
        b.typeWords(id, "a big record")
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 0)
        expectEqual(b.status(id), .failed(TypeSyncFailure(writing: .schema, TypeSyncFailure.tooLongMessage, remedy: .editByHand)))
        let edited = long.replacingOccurrences(of: "\"field0\"", with: "\"name\"")
        b.typeSchema(id, edited)
        b.sync(id, answer: "a big record, with a name")
        expectEqual(b.model.lastRequest?.system, SchemaPrompts.system(.toPrompt))
        expectEqual(b.words(id), "a big record, with a name")
        expectEqual(b.schema(id), edited)
    },
    test("an answer is dropped if the side it writes changed while it was out, and the change syncs after") {
        let b = try SyncBench()
        let id = b.place()
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        b.typeWords(id, "a pet in my household")
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        let renamed = #"{"type": "object", "properties": {}, "description": "Mine"}"#
        b.typeSchema(id, renamed)
        b.model.release()
        spinRunLoop(until: { b.status(id) == .idle })
        expectEqual(b.schema(id), renamed)
        b.scheduler.advance(by: .seconds(3))
        spinRunLoop(until: { b.model.requests.count == 2 })
        expectEqual(b.message(1), "<prompt>\na pet in my household\n</prompt>\n\n<schema>\n\(renamed)\n</schema>")
    },
    test("edits to the words while its call is out wait, and sync once it lands, from what it wrote") {
        let b = try SyncBench()
        let id = b.place()
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        b.typeWords(id, "a pet in my household")
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.typeWords(id, "a pet in my household, and its weight")
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 1)
        b.model.holdsAnswers = false
        b.model.queue("NO_CHANGE")
        b.model.release()
        spinRunLoop(until: { b.model.requests.count == 2 && b.status(id) == .idle })
        expectEqual(b.schema(id), pet)
        expectEqual(b.message(1), "<previous_prompt>\na pet in my household\n</previous_prompt>\n\n<prompt>\na pet in my household, and its weight\n</prompt>\n\n<schema>\n\(petSchema)\n</schema>")
    },
    test("a type deleted while its call is out drops the answer") {
        let b = try SyncBench()
        let id = b.place()
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        b.typeWords(id, "a pet in my household")
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
        b.typeWords(id, "a pet in my household")
        b.model.queue(.overloaded)
        b.sync.commit(id)
        spinRunLoop(until: { b.status(id) != .updating(.schema) })
        expectEqual(b.status(id), .failed(TypeSyncFailure(writing: .schema, "Anthropic overloaded")))
        expectEqual(b.words(id), "a pet in my household")
        expectEqual(b.schema(id), TypeSchemaProperty.starter)
        b.model.queue(petSchema)
        b.sync.retry(id)
        spinRunLoop(until: { b.status(id) == .idle })
        expectEqual(b.model.requests.count, 2)
        expectEqual(b.model.requests[1], b.model.requests[0])
        expectEqual(b.schema(id), pet)
    },
    test("with no key saved, or one refused, the failure says so, and its remedy is Settings") {
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        for error in [LanguageModelError.noKey, .unauthorized] {
            b.model.queue(error)
            b.sync.commit(id)
            spinRunLoop(until: { !b.isUpdating(id) })
            expectEqual(b.status(id), .failed(TypeSyncFailure(writing: .schema, error.message, remedy: .key)))
        }
        expectEqual(b.status(id), .failed(TypeSyncFailure(writing: .schema, "API key rejected", remedy: .key)))
    },
    test("a cancelled call says nothing, changes nothing, and the edit still syncs on the next commit") {
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        b.model.queue(.cancelled)
        b.sync.commit(id)
        spinRunLoop(until: { b.model.answered == 1 && !b.isUpdating(id) })
        expectEqual(b.status(id), .idle)
        expectEqual(b.schema(id), TypeSchemaProperty.starter)
        b.sync(id, answer: petSchema)
        expectEqual(b.model.requests.count, 2)
        expectEqual(b.schema(id), pet)
    },
    test("an answer that can't be used is a failure, and changes nothing: a schema cut off (too long to rewrite, by hand), not a schema (retry)") {
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        b.model.queue(ModelResponse(text: String(petSchema.prefix(40)), stopReason: .maxTokens))
        b.sync.commit(id)
        spinRunLoop(until: { !b.isUpdating(id) })
        expectEqual(b.status(id), .failed(TypeSyncFailure(writing: .schema, TypeSyncFailure.tooLongMessage, remedy: .editByHand)))
        expectEqual(TypeSyncFailure.tooLongMessage, "Schema too long to rewrite")
        b.model.queue("Sure! Here's a schema for a pet.")
        b.sync.retry(id)
        spinRunLoop(until: { !b.isUpdating(id) })
        expectEqual(b.status(id), .failed(TypeSyncFailure(writing: .schema, "Unusable answer")))
        expectEqual(b.schema(id), TypeSchemaProperty.starter)
        b.typeSchema(id, petSchema)
        b.typeWords(id, "")
        b.model.queue(ModelResponse(text: "Here's the updated prompt: a pet", stopReason: .endTurn))
        b.sync.commit(id)
        spinRunLoop(until: { !b.isUpdating(id) })
        expectEqual(b.status(id), .failed(TypeSyncFailure(writing: .words, "Unusable answer")))
        expectEqual(b.words(id), "", "never written over the person's prompt")
    },
    test("a refusal is a failure with nothing to retry, either way (asked again, it would decline again); rewording syncs") {
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        b.model.queue(ModelResponse(text: "", stopReason: .refusal))
        b.sync.commit(id)
        spinRunLoop(until: { !b.isUpdating(id) })
        expectEqual(b.status(id), .failed(TypeSyncFailure(writing: .schema, "Claude declined", remedy: .editByHand)))
        expectEqual(b.schema(id), TypeSchemaProperty.starter)
        b.typeWords(id, "a pet")
        b.sync(id, answer: petSchema)
        expectEqual(b.schema(id), pet, "the next commit syncs")
        b.typeSchema(id, petSchema.replacingOccurrences(of: "\"name\"", with: "\"nickname\""))
        b.model.queue(ModelResponse(text: "", stopReason: .refusal))
        b.sync.commit(id)
        spinRunLoop(until: { !b.isUpdating(id) })
        expectEqual(b.status(id), .failed(TypeSyncFailure(writing: .words, "Claude declined", remedy: .editByHand)))
    },
    test("NO_CHANGE writes nothing, and the sync is done") {
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "asdf")
        let revision = b.editor.revision
        b.sync(id, answer: "  NO_CHANGE\n")
        expectEqual(b.editor.revision, revision)
        expectEqual(b.status(id), .idle)
        b.sync.commit(id)
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1)
    },
    test("a schema laid out anew, an empty type named, and words cleared ask nothing") {
        let b = try SyncBench()
        let id = b.place()
        b.typeSchema(id, #"{"type":"object","properties":{}}"#)
        b.sync.commit(id)
        b.typeSchema(id, #"{"title": "Pet", "type": "object", "properties": {}}"#)
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 0)
        b.typeWords(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        b.typeWords(id, "  ")
        b.sync.commit(id)
        b.typeSchema(id, #"{"title":"Pet","type":"object","properties":{"name":{"type":"string"},"species":{"enum":["dog","cat"],"type":"string"},"birthYear":{"type":"integer"}}}"#)
        b.sync.commit(id)
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1)
    },
    test("each type's status is observed alone") {
        let b = try SyncBench()
        let a = b.place(), other = b.place()
        b.typeWords(a, "a pet")
        b.typeWords(other, "a book")
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
    // A type's name is its title: put in for the model, taken out of what it writes.
    test("a titled type's name goes to the model as its schema's root title, and comes out of the answer; the type keeps its own name") {
        let b = try SyncBench()
        let id = b.place()
        b.editor.transact { $0.update(id) { $0[TitleProperty.self] = "Animal" } }
        b.typeWords(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        expectEqual(b.message(0), "<prompt>\na pet in my household\n</prompt>\n\n<schema>\n{\n  \"title\": \"Animal\",\n  \"type\": \"object\",\n  \"properties\": {}\n}\n</schema>")
        expectEqual(b.schema(id), pet)
        expectEqual(b.title(id), "Animal", "the model's title doesn't rename a type that has a name")
        // Told it again next time, by its name now.
        b.editor.transact { $0.update(id) { $0[TitleProperty.self] = "Pet" } }
        b.typeWords(id, "a pet in my household, no birth year")
        b.sync(id, answer: "NO_CHANGE")
        expectEqual(b.message(1), "<previous_prompt>\na pet in my household\n</previous_prompt>\n\n<prompt>\na pet in my household, no birth year\n</prompt>\n\n<schema>\n\(petSchema)\n</schema>")
    },
    test("a rename alone asks nothing: the name isn't a side") {
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        b.editor.transact { $0.update(id) { $0[TitleProperty.self] = "Animal" } }
        b.sync.commit(id)
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1)
    },
    test("a root title the person typed is kept as typed: sent as it is, the answer's written back with it, and it's never the type's name") {
        let b = try SyncBench()
        let id = b.place()
        b.editor.transact { $0.update(id) { $0[TitleProperty.self] = "Animal" } }
        let typed = #"{"title": "Mine", "type": "object", "properties": {}}"#
        b.typeSchema(id, typed)
        b.typeWords(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        expectEqual(b.message(0), "<prompt>\na pet in my household\n</prompt>\n\n<schema>\n\(typed)\n</schema>")
        expectEqual(b.schema(id), petSchema, "its title the model's, as it wrote it")
        expectEqual(b.title(id), "Animal")
        // On an untitled type it isn't the name either.
        let other = b.place()
        b.typeSchema(other, typed)
        b.typeWords(other, "a pet")
        b.sync(other, answer: petSchema)
        expectEqual(b.title(other), nil)
    },
    test("the words written from a schema are told the type's name in both schemas; a schema whose root title alone changed says what it said") {
        let b = try SyncBench()
        let id = b.place()
        b.editor.transact { $0.update(id) { $0[TitleProperty.self] = "Pet" } }
        b.typeWords(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        let edited = pet.replacingOccurrences(of: "\"birthYear\"", with: "\"microchipId\"")
        b.typeSchema(id, edited)
        b.sync(id, answer: "a pet in my household, with its microchip ID")
        let titled = petSchema.replacingOccurrences(of: "\"birthYear\"", with: "\"microchipId\"")
        expectEqual(b.message(1), "<prompt>\na pet in my household\n</prompt>\n\n<previous_schema>\n\(petSchema)\n</previous_schema>\n\n<schema>\n\(titled)\n</schema>")
        b.typeSchema(id, titled)
        b.sync.commit(id)
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 2, "a title typed in the JSON is no change of meaning")
    },
    // Becoming a type, and stopping.
    test("a shape the person makes a type (/is-a type) is read on the scheduler's next turn, with no wait: its words are ahead of the starter") {
        let b = try SyncBench()
        let id = b.editor.add(memo("a pet in my household", at: .zero))
        b.model.queue(petSchema)
        b.editor.makeType(id)
        expectEqual(b.schema(id), TypeSchemaProperty.starter)
        expectEqual(b.editor.undoHistory.undoName, "Make Type")
        b.settle()
        expectEqual(b.model.requests.count, 0, "not within the turn of the make")
        expectEqual(b.status(id), .idle)
        expect(b.sync.isWaiting(id), "an edit waits until the next turn")
        b.scheduler.advance(by: .zero)
        expectEqual(b.status(id), .updating(.schema), "the call is out at once")
        expect(!b.sync.isWaiting(id))
        spinRunLoop(until: { b.model.requests.count == 1 && b.status(id) == .idle })
        expectEqual(b.message(0), "<prompt>\na pet in my household\n</prompt>\n\n<schema>\n\(TypeSchemaProperty.starter)\n</schema>")
        expectEqual(b.schema(id), pet)
        expectEqual(b.title(id), "Pet")
        expectEqual(b.editor.undoHistory.undoName, "Update Schema", "the read is a step of its own")
    },
    test("words that are JSON made a type are the schema: nothing is asked at the make, and the next turn asks for the words, with no schema ahead of them") {
        let b = try SyncBench()
        let id = b.editor.add(memo(pet, at: .zero))
        b.editor.makeType(id)
        expectEqual(b.schema(id), pet)
        expectEqual(b.editor.undoHistory.undoName, "Make Type")
        b.settle()
        expectEqual(b.model.requests.count, 0, "nothing at the make")
        b.model.queue("A pet: a name, a species and a birth year.")
        b.scheduler.advance(by: .zero)
        spinRunLoop(until: { b.model.requests.count == 1 && b.status(id) == .idle })
        expectEqual(b.model.requests.count, 1)
        let request = try require(b.model.lastRequest)
        expectEqual(request.system, SchemaPrompts.system(.toPrompt), "the direction of the words")
        let message = try require(b.message(0))
        expect(message.contains("<schema>\n\(pet)\n</schema>"), message)
        expect(!message.contains("<prompt>"), "the JSON is the schema, never the prompt: " + message)
        expectEqual(b.words(id), "A pet: a name, a species and a birth year.")
        expectEqual(b.schema(id), pet, "the schema is as the words said")
        expectEqual(b.editor.undoHistory.undoName, "Update Text")
        b.editor.undo()
        expectEqual(b.words(id)?.stored, pet)
        expectEqual(b.schema(id), pet)
        b.editor.undo()
        expectEqual(b.schema(id), nil, "undo of the make takes the schema back")
    },
    test("words typed over a type's that are a JSON object are its schema, as typed, in one step; the words are then written from it, with no prompt") {
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        let typed = #"{"type": "object", "properties": {"email": {"type": "string"}}}"#
        b.typeWords(id, typed)
        b.sync(id, answer: "A contact: email.")
        expectEqual(b.model.requests.count, 2, "no schema was asked for: one request, for the words")
        let request = try require(b.model.lastRequest)
        expectEqual(request.system, SchemaPrompts.system(.toPrompt))
        let message = try require(b.message(1))
        expect(message.hasPrefix("<previous_schema>\n{ \"title\": \"Pet\" }\n</previous_schema>\n\n<schema>\n"), "the name alone, then the schema: " + message)
        expect(message.contains(#""type": "object", "properties": {"email": {"type": "string"}}}"#) && !message.contains("<prompt>"), message)
        expectEqual(b.schema(id), typed, "the schema is the JSON as typed")
        expectEqual(b.words(id), "A contact: email.")
        expectEqual(b.editor.undoHistory.undoName, "Update Text")
        b.editor.undo()
        expectEqual(b.words(id)?.stored, typed)
        expectEqual(b.editor.undoHistory.undoName, "Update Schema", "the adoption is a step of its own")
        b.editor.undo()
        expectEqual(b.schema(id), pet, "undo puts the schema back")
        b.settle()
        expectEqual(b.model.requests.count, 2, "and asks nothing until the next commit")
    },
    test("words written from a schema are what's inside the answer's tags: a remark before them is never the type's words") {
        let b = try SyncBench()
        // From nothing, the path JSON words take: the answer opens with a remark, as Haiku's sometimes does.
        let id = b.editor.add(memo(pet, at: .zero))
        b.editor.makeType(id)
        b.settle()
        b.model.queue("There is no <prompt>, so I write one. Fields: name (string), species (dog or cat), birthYear (integer). None are listed as required...\n\n<answer>\nA pet: a name, a species (dog or cat) and a birth year.\n</answer>")
        b.scheduler.advance(by: .zero)
        spinRunLoop(until: { b.model.requests.count == 1 && b.status(id) == .idle })
        expectEqual(b.words(id), "A pet: a name, a species (dog or cat) and a birth year.")
        expectEqual(b.editor.undoHistory.undoName, "Update Text")
        // A schema edited by hand: the words edited, in tags; then nothing to change, said in them.
        let edited = pet.replacingOccurrences(of: "\"birthYear\"", with: "\"microchipId\"")
        b.typeSchema(id, edited)
        b.sync(id, answer: "<answer>A pet: a name, a species (dog or cat) and a microchip ID.</answer>")
        expectEqual(b.words(id), "A pet: a name, a species (dog or cat) and a microchip ID.")
        let revision = b.editor.revision
        b.typeSchema(id, edited.replacingOccurrences(of: "\"microchipId\": {\n      \"type\": \"integer\"", with: "\"microchipId\": {\n      \"type\": \"integer\",\n      \"description\": \"15 digits\""))
        b.sync(id, answer: "The prompt never went into that.\n\n<answer>NO_CHANGE</answer>")
        expectEqual(b.model.requests.count, 3)
        expectEqual(b.words(id), "A pet: a name, a species (dog or cat) and a microchip ID.")
        expectEqual(b.editor.revision, revision + 1, "the person's edit alone")
        expectEqual(b.status(id), .idle)
        // Tags with nothing in them write nothing, and say so.
        b.typeSchema(id, pet)
        b.sync(id, answer: "Here is the prompt.\n<answer>\n</answer>")
        expectEqual(b.words(id), "A pet: a name, a species (dog or cat) and a microchip ID.")
        expectEqual(b.status(id), .failed(TypeSyncFailure(writing: .words, "Unusable answer", remedy: .retry)))
    },
    test("JSON words that say what the schema already says write nothing but their words") {
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        b.typeWords(id, pet)
        let steps = b.editor.undoHistory.undoName
        b.sync(id, answer: "A pet: a name, a species and a birth year.")
        expectEqual(b.model.requests.count, 2)
        expectEqual(b.schema(id), pet)
        expect(b.message(1)?.contains("<prompt>") == false, b.message(1) ?? "")
        expectEqual(b.editor.undoHistory.undoName, "Update Text")
        b.editor.undo()
        expectEqual(b.editor.undoHistory.undoName, steps, "no schema step between: nothing was written to it")
    },
    test("JSON still being typed asks nothing; words in braces that aren't JSON are a prompt") {
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        for partial in [#"{"a":"#, "{", #"{ "#, "{}"] {
            b.typeWords(id, partial)
            b.sync.commit(id)
            b.settle()
        }
        expectEqual(b.model.requests.count, 1, "nothing was asked")
        expectEqual(b.status(id), .idle)
        b.typeWords(id, "{name, age} for each guest")
        b.sync(id, answer: "NO_CHANGE")
        expectEqual(b.model.requests.count, 2)
        expectEqual(b.model.lastRequest?.system, SchemaPrompts.system(.toSchema))
        expect(b.message(1)?.contains("<prompt>\n{name, age} for each guest\n</prompt>") == true, b.message(1) ?? "")
    },
    test("JSON words with no key: the schema is the JSON and the rows show, the status asks for a key, and one saved asks again") {
        let b = try SyncBench()
        let id = b.place()
        let typed = #"{"type": "object", "properties": {"email": {"type": "string"}}}"#
        b.typeWords(id, typed)
        b.model.queue(.noKey)
        b.sync.commit(id)
        spinRunLoop(until: { b.model.requests.count == 1 && !b.isUpdating(id) })
        expectEqual(b.model.requests.first?.system, SchemaPrompts.system(.toPrompt), "only the words were asked for")
        expectEqual(b.schema(id), typed)
        expectEqual(b.words(id)?.stored, typed, "the JSON stays as the words")
        expectEqual(b.status(id), .failed(TypeSyncFailure(writing: .words, LanguageModelError.noKey.message, remedy: .key)))
        let directory = FileManager.default.temporaryDirectory.appending(path: "schema-sync-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let settings = AnthropicKeySettings(keys: AnthropicKeyStore(url: directory.appending(path: "key")), model: ScriptedLanguageModel())
        settings.draft = "sk-ant-test"
        b.model.queue("A contact: email.")
        settings.save()
        spinRunLoop(until: { b.model.requests.count == 2 && b.status(id) == .idle })
        expectEqual(b.words(id), "A contact: email.")
        expectEqual(b.schema(id), typed)
    },
    test("JSON words with a mention in them are a prompt, as ever") {
        let b = try SyncBench()
        let id = b.place(), target = b.place()
        b.editor.transact { $0.update(id, as: Memo.self) {
            $0.props.text = MentionText([.text("{\"title\": \""), .mention(target, label: "Pet"), .text("\"}")])
            MemoStyle.fit(&$0.props)
        } }
        b.model.queue("NO_CHANGE")
        b.sync.commit(id)
        spinRunLoop(until: { b.model.requests.count == 1 && !b.isUpdating(id) })
        expectEqual(b.model.lastRequest?.system, SchemaPrompts.system(.toSchema, schemas: "@Pet"))
        expect(b.message(0)?.contains("<prompt>\n{\"title\": \"@Pet\"}\n</prompt>") == true, b.message(0) ?? "")
    },
    test("an undo in the turn of the make asks nothing: the shape is no type, and its wait is gone") {
        let b = try SyncBench()
        let id = b.editor.add(memo("a pet in my household", at: .zero))
        b.editor.makeType(id)
        b.editor.undo()
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 0)
        expectEqual(b.status(id), .idle)
        expect(!b.sync.isWaiting(id))
    },
    test("a type that is placed, brought by a paste or drawn by an agent is in step and asks nothing, on the next turn or after") {
        let b = try SyncBench()
        let placed = b.place()
        b.typeWords(placed, "a pet in my household")
        b.editor.transact { $0.insert(typeRecord(pet, words: "a pet in my household", at: CGPoint(x: 400, y: 0))) }
        b.editor.transact { transaction in
            transaction.byAgent = true
            transaction.insert(typeRecord(pet, words: "a pet in my household", at: CGPoint(x: 800, y: 0)))
        }
        b.scheduler.advance(by: .zero)
        b.settle()
        expectEqual(b.model.requests.count, 0, "the one whose words were typed waits for its 3 s, the others are in step")
        b.scheduler.advance(by: .seconds(3))
        spinRunLoop(until: { b.model.requests.count == 1 })
        expectEqual(b.model.requests.count, 1)
    },
    test("the spot is told for each status change and each flip of the wait, and says whether a read has answered") {
        let b = try SyncBench()
        var told: [ShapeID] = []
        b.sync.onSpotChange { told.append($0) }
        let id = b.place()
        expect(!b.sync.isWaiting(id) && !b.sync.hasAnswered(id))
        b.typeWords(id, "a pet in my household")
        expect(b.sync.isWaiting(id))
        expectEqual(told, [id], "the wait began")
        b.model.queue(petSchema)
        told = []
        b.sync.commit(id)
        expectEqual(b.status(id), .updating(.schema))
        expectEqual(told, [id, id], "the wait ended, and the call went out")
        expect(!b.sync.hasAnswered(id), "not before the answer")
        told = []
        spinRunLoop(until: { b.status(id) == .idle })
        expect(told.contains(id), "the answer landed")
        expect(b.sync.hasAnswered(id))
        told = []
        b.typeWords(id, "a pet")
        b.editor.undo()
        expectEqual(told.count >= 2, true, "a wait begun and stopped by an undo")
        expect(!b.sync.isWaiting(id))
        told = []
        b.model.queue(.overloaded)
        b.typeWords(id, "a pet in my home")
        b.sync.commit(id)
        spinRunLoop(until: { !b.isUpdating(id) })
        expect(told.contains(id))
        expectEqual(b.status(id), .failed(TypeSyncFailure(writing: .schema, LanguageModelError.overloaded.message)))
    },
    test("with no language model at all, a side to write fails saying so, with nothing to try again; a type in step says nothing") {
        let plugins = typePlugins().filter { !($0 is LanguageModelsPlugin) }
        let harness = try EditorHarness { scheduler in CanvasEditor(registry: try Registry(plugins: plugins), file: CanvasFile(root: CanvasDocument()), scheduler: scheduler) }
        let editor = harness.editor, sync = try require(editor.typeSync)
        expect(editor.languageModel == nil)
        let inStep = typeRecord(pet, words: "a pet in my household")
        editor.transact { $0.insert(inStep) }
        sync.commit(inStep.id)
        expectEqual(sync.status(of: inStep.id), .idle, "in step: nothing to write")
        let id = editor.add(memo("a pet in my household", at: .zero))
        editor.makeType(id)
        harness.scheduler.advance(by: .zero)
        expectEqual(sync.status(of: id), .failed(TypeSyncFailure(writing: .schema, "No language model", remedy: .editByHand)))
        expectEqual(TypeSyncFailure.noModelMessage, "No language model")
        sync.retry(id)
        expectEqual(sync.status(of: id), .failed(TypeSyncFailure(writing: .schema, "No language model", remedy: .editByHand)))
    },
    test("JSON words made a type with no model: the schema stays and nothing is asked; empty-object words ask nothing") {
        let b = try SyncBench()
        let id = b.editor.add(memo("{}", at: .zero))
        b.editor.makeType(id)
        expectEqual(b.schema(id), "{}")
        b.sync.commit(id)
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 0)
        expectEqual(b.schema(id), "{}")
    },
    test("a shape an agent makes a type (draw's schema:) is in step, and one undo or redo makes a type asks nothing") {
        let b = try SyncBench()
        let id = b.editor.add(memo("a pet in my household", at: .zero))
        b.editor.transact { transaction in
            transaction.byAgent = true
            transaction.update(id) { $0[TypeSchemaProperty.self] = SchemaText(pet) }
        }
        let other = b.editor.add(memo("a book", at: CGPoint(x: 400, y: 0)))
        b.editor.makeType(other)
        b.editor.undo()
        b.editor.redo()
        b.sync.commit(id)
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 0)
        // The type undo brought back still has its words ahead: a commit asks.
        b.sync(other, answer: "NO_CHANGE")
        expectEqual(b.model.requests.count, 1)
    },
    test("a shape that stops being a type (Remove Type) drops its wait and its call, and its words stay") {
        let b = try SyncBench()
        let id = b.place()
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        b.typeWords(id, "a pet in my household")
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.editor.removeType(id)
        expectEqual(b.status(id), .idle)
        expectEqual(b.editor.undoHistory.undoName, "Remove Type")
        spinRunLoop(until: { b.model.answered == 1 })
        b.settle()
        expectEqual(b.schema(id), nil)
        expectEqual(b.words(id), "a pet in my household")
        expectEqual(b.model.queued.count, 1, "the call was cancelled, and took no answer")
        b.model.holdsAnswers = false
        b.typeWords(id, "a pet")
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1, "not a type: its words sync nothing")
        b.editor.undo()
        b.editor.undo()
        expectEqual(b.schema(id), TypeSchemaProperty.starter, "undo brings the schema back")
    },
    test("a relationship type whose words are empty is never synced: a field added to its schema asks nothing; with words it syncs as any type") {
        let b = try SyncBench()
        var record = typeRecord(TypeSchemaProperty.starter, title: "Owner", at: .zero)
        record[RelationshipProperty.self] = true
        let id = record.id
        b.editor.transact { $0.insert(record) }
        b.typeSchema(id, #"{"type": "object", "properties": {"since": {"type": "string", "format": "date"}}}"#)
        b.sync.commit(id)
        b.scheduler.advance(by: .seconds(10))
        b.settle()
        expectEqual(b.model.requests.count, 0, "no call: the schema is written by the card's list and the words are not drawn")
        expectEqual(b.status(id), .idle)
        expectEqual(b.words(id), "", "and the words stay empty")
        b.typeWords(id, "who owns a car")
        b.sync(id, answer: petSchema)
        expectEqual(b.model.requests.count, 1, "with words it asks")
        expectEqual(b.status(id), .idle)
    },
    test("a relationship type's first words wait as an edit does (its panel's box writes each keystroke): nothing is asked on the next turn, and they are read once typing pauses") {
        let b = try SyncBench()
        var record = typeRecord(TypeSchemaProperty.starter, title: "Owner", at: .zero)
        record[RelationshipProperty.self] = true
        let id = record.id
        b.editor.transact { $0.insert(record) }
        b.typeWords(id, "w")
        b.scheduler.advance(by: .zero)
        b.settle()
        expectEqual(b.model.requests.count, 0, "not after the first letter")
        b.typeWords(id, "who owns a car")
        b.scheduler.advance(by: .seconds(1))
        b.settle()
        expectEqual(b.model.requests.count, 0, "nor while typing goes on")
        b.model.queue(petSchema)
        b.scheduler.advance(by: .seconds(5))
        spinRunLoop(until: { b.model.requests.count == 1 && !b.isUpdating(id) })
        expectEqual(b.model.requests.count, 1, "read once typing paused")
        expect(b.model.lastRequest?.system?.contains("A relationship type\n") == true)
    },
    test("a call out when the file closes is cancelled, and an edit's wait with it: nothing is left holding or armed") {
        var b: SyncBench? = try SyncBench()
        let model = try require(b?.model), scheduler = try require(b?.scheduler)
        weak var closing = b?.editor
        let calling = try require(b?.place()), waiting = try require(b?.place())
        model.holdsAnswers = true
        b?.typeWords(calling, "a pet in my household")
        b?.sync.commit(calling)
        spinRunLoop(until: { model.waiting == 1 })
        expectEqual(model.waiting, 1, "the call is out")
        let before = scheduler.pendingCount
        b?.typeWords(waiting, "a car and who owns it")
        expectEqual(scheduler.pendingCount, before + 1, "the edit waits 3 s")
        b = nil
        spinRunLoop(until: { model.waiting == 0 })
        expect(closing == nil, "the editor went as its file closed")
        expectEqual(model.waiting, 0, "the call isn't left holding")
        expectEqual(model.answered, 1, "it ended: cancelled")
        expectEqual(scheduler.pendingCount, before, "the wait went with it")
        expectEqual(model.requests.count, 1, "and asked nothing")
    },
])

@MainActor let promptTests = Suite("Schema prompts", [
    test("a request is blocks of trimmed text, the empty ones left out") {
        let toSchema = SchemaPrompts.toSchema(previousPrompt: nil, prompt: "  email required \n", schema: "{}")
        expectEqual(toSchema.messages, [.user("<prompt>\nemail required\n</prompt>\n\n<schema>\n{}\n</schema>")])
        expectEqual(SchemaPrompts.toSchema(previousPrompt: " ", prompt: "a", schema: "{}").messages.first?.text.hasPrefix("<prompt>"), true)
        let toPrompt = SchemaPrompts.toPrompt(prompt: "", previousSchema: nil, schema: "{\"a\": 1}")
        expectEqual(toPrompt.messages, [.user("<schema>\n{\"a\": 1}\n</schema>")])
        expectEqual([toSchema.maxTokens, toPrompt.maxTokens], [16_000, 4096])
        // Haiku 5.5 takes no temperature but its default, and has no fallback to ask for; it thinks as much as its effort says.
        expectEqual([toSchema.temperature, toPrompt.temperature], [nil, nil])
        expectEqual([toSchema.model, toPrompt.model], ["claude-haiku-5-5", "claude-haiku-5-5"], "named on every request, not the editor's own")
        expectEqual([toSchema.effort, toPrompt.effort], ["medium", "medium"])
        expectEqual([toSchema.fallbacks, toPrompt.fallbacks], [nil, nil])
    },
    test("a request with no prompt is never to be answered NO_CHANGE: the prompt says so where it lists the blocks and where it offers the answer") {
        // With either sentence alone Haiku still answers NO_CHANGE for a schema sent alone (scripts/schema-prompts/README.md).
        let system = SchemaPrompts.toPromptSystem
        expect(system.contains("When it's missing there is no prompt yet: you write the first one, whatever else you get."))
        expect(system.contains("Never when there is no <prompt>: there are no words yet, so the answer is a prompt, never \(SchemaPrompts.noChange)."))
    },
    test("a system prompt is its base, what it says of titles, and, only in a request that names other schemas, what it says of those, a blank line apart; the user message is as it was") {
        let toSchemaTitles = SchemaPrompts.toSchemaSystem + "\n" + SchemaPrompts.toSchemaTitle + "\n" + SchemaPrompts.toSchemaNewTitle
        let toPromptTitles = SchemaPrompts.toPromptSystem + "\n" + SchemaPrompts.toPromptTitle
        expectEqual(SchemaPrompts.system(.toSchema), toSchemaTitles)
        expectEqual(SchemaPrompts.system(.toPrompt), toPromptTitles)
        expectEqual(SchemaPrompts.system(.toSchema, schemas: " \n"), toSchemaTitles)
        expectEqual(SchemaPrompts.system(.toPrompt, schemas: ""), toPromptTitles)
        expectEqual(SchemaPrompts.toSchema(previousPrompt: nil, prompt: "a pet", schema: "{}").system, toSchemaTitles)
        expectEqual(SchemaPrompts.toSchema(previousPrompt: nil, prompt: "a pet", schema: "{}", schemas: " \n").system, toSchemaTitles)
        let toSchema = SchemaPrompts.toSchema(previousPrompt: nil, prompt: "a pet at an @Address", schema: "{}", schemas: "@Address")
        expectEqual(toSchema.system, toSchemaTitles + "\n" + SchemaPrompts.toSchemaReferences)
        expectEqual(toSchema.system, SchemaPrompts.system(.toSchema, schemas: "@Address"))
        expectEqual(toSchema.messages, [.user("<schemas>\n@Address\n</schemas>\n\n<prompt>\na pet at an @Address\n</prompt>\n\n<schema>\n{}\n</schema>")])
        expectEqual(SchemaPrompts.toPrompt(prompt: "", previousSchema: nil, schema: "{}").system, toPromptTitles)
        let toPrompt = SchemaPrompts.toPrompt(prompt: "", previousSchema: nil, schema: #"{"a": {"$ref": "@Address"}}"#, schemas: "@Address")
        expectEqual(toPrompt.system, toPromptTitles + "\n" + SchemaPrompts.toPromptReferences)
        expect(toPrompt.messages.first?.text.hasPrefix("<schemas>\n@Address\n</schemas>\n\n<schema>") == true)
        expectEqual(ProseMapPrompt.request(SchemaTarget.self, prose: "a pet", target: "{}").system, ProseMapPrompt.system(for: SchemaTarget.self), "highlights get no titles")
        expectEqual(ProseMapPrompt.request(SchemaTarget.self, prose: "a pet at an @Address", target: "{}", context: SchemaPrompts.highlightsReferences).system,
                    ProseMapPrompt.system(for: SchemaTarget.self) + "\n" + SchemaPrompts.highlightsReferences)
        expect(SchemaPrompts.toSchemaSystem.hasSuffix("\n\n") == false && SchemaPrompts.toSchemaReferences.hasPrefix("Other schemas\n"),
               "a blank line apart, as the prompts' own sections are")
        for (text, heading) in [(SchemaPrompts.toSchemaTitle, "A title from a field\n"), (SchemaPrompts.toSchemaNewTitle, "A new type's title\n"),
                                (SchemaPrompts.toPromptTitle, "A title from a field\n"), (SchemaPrompts.toSchemaReferences, "Other schemas\n"),
                                (SchemaPrompts.toPromptReferences, "Other schemas\n"), (SchemaPrompts.highlightsReferences, "Other schemas\n")] {
            expect(text.hasPrefix(heading) && text.hasSuffix(".\n") && !text.hasSuffix("\n\n"), heading)
        }
    },
    test("a relationship type's words are sent one literal more, after the titles and before the references, in the to-schema direction alone") {
        let titles = SchemaPrompts.toSchemaSystem + "\n" + SchemaPrompts.toSchemaTitle + "\n" + SchemaPrompts.toSchemaNewTitle
        let relationship = SchemaPrompts.toSchemaRelationshipType
        expectEqual(SchemaPrompts.system(.toSchema, relationship: true), titles + "\n" + relationship)
        expectEqual(SchemaPrompts.system(.toSchema, schemas: " ", relationship: true), titles + "\n" + relationship)
        expectEqual(SchemaPrompts.system(.toSchema, schemas: "@Person", relationship: true), titles + "\n" + relationship + "\n" + SchemaPrompts.toSchemaReferences)
        expectEqual(SchemaPrompts.system(.toSchema), titles, "a plain type's words are sent what they always were")
        expectEqual(SchemaPrompts.system(.toPrompt, relationship: true), SchemaPrompts.system(.toPrompt), "the words are written from the schema as for any type")
        let request = SchemaPrompts.toSchema(previousPrompt: nil, prompt: "employment", schema: "{}", relationship: true)
        expectEqual(request.system, SchemaPrompts.system(.toSchema, relationship: true))
        expectEqual(request.messages, SchemaPrompts.toSchema(previousPrompt: nil, prompt: "employment", schema: "{}").messages, "the user message is as it was")
        expectEqual(SchemaPrompts.toSchema(previousPrompt: nil, prompt: "a pet", schema: "{}").system, titles)
    },
    test("the relationship type's literal says what the schema holds and what it never does, in the app's words") {
        let text = SchemaPrompts.toSchemaRelationshipType
        expect(text.hasPrefix("A relationship type\n") && text.hasSuffix(".\n") && !text.hasSuffix("\n\n"))
        expect(text.contains("never who or what it relates"))
        expect(text.contains("Write no property for either end"))
        expect(text.contains(#"no "$ref" to the type of either"#))
        expect(text.contains(#"("employment" relates an employee and an employer"#), "the one-word case the lite eval missed")
        expect(text.contains("only what the relationship itself holds: a role, a start date"))
        expect(text.contains("a property the schema has stays unless the prompt takes it out"))
        for word in ["x-canvas-link", "contentSchema", "contentMediaType", "pointer", "edge type", "link"] { expect(!text.contains(word), word) }
        expect((try? JSONReader.read(text)) == nil, "it has no JSON example to parse")
    },
    test("the sync of a relationship type's words is sent the literal, a plain type's is not") {
        let b = try SyncBench()
        let plain = b.place()
        b.typeWords(plain, "a pet in my household")
        b.sync(plain, answer: petSchema)
        expectEqual(b.model.lastRequest?.system, SchemaPrompts.system(.toSchema))
        let id = b.place()
        b.editor.transact { $0.update(id) { $0[RelationshipProperty.self] = true } }
        b.typeWords(id, "employment")
        b.sync(id, answer: petSchema)
        expectEqual(b.model.lastRequest?.system, SchemaPrompts.system(.toSchema, relationship: true))
        expect(b.model.lastRequest?.system?.contains("A relationship type\n") == true)
        // Its words written from its schema are asked as any type's are.
        b.typeSchema(id, pet.replacingOccurrences(of: "\"species\"", with: "\"kind\""))
        b.sync(id, answer: "a pet, its kind")
        expectEqual(b.model.lastRequest?.system, SchemaPrompts.system(.toPrompt))
    },
    test("the rename: a renamed field keeps its key and gets a title, and the words say it by that title") {
        let toSchema = SchemaPrompts.toSchemaSystem, toPrompt = SchemaPrompts.toPromptSystem
        expect(toSchema.contains("keeps its key") && toSchema.contains(#"its "title""#))
        expect(!toSchema.contains("a renamed property keeps its constraints and its position"))
        expect(toSchema.contains("a renamed field's key never changes"))
        expect(toPrompt.contains(#"A field with a "title" is called by it"#) && toPrompt.contains(#"its "title" when it has one"#))
        expect(!toPrompt.contains("a title the prompt doesn't name"))
        expect(toSchema.contains(#""if": {"properties": {"method": {"const": "delivery"}}}"#) && toSchema.contains(#"never with "required" alone"#))
    },
    test("the references wording: a part is a $ref and a bare word is a part, a phrase that relates the thing to a word writes no property, and no literal holds the old pointer") {
        let toSchema = SchemaPrompts.toSchemaReferences
        expect(toSchema.contains(#"{"$ref": "@Customer"}"#) && toSchema.contains("A bare @ word"))
        for phrase in ["is in a @Layer", "belongs to a @Team", "links to", "points to", "refers to"] { expect(toSchema.contains(phrase), phrase) }
        expect(toSchema.contains("write no property for it at all"))
        expect(toSchema.contains("When it is unclear whether the prompt means a part or a relationship, it is the part."))
        expect(toSchema.contains("A schema holds what the thing has, never what it is related to."))
        let toPrompt = SchemaPrompts.toPromptReferences
        expect(toPrompt.contains("is in a @Layer") && toPrompt.contains("stay word for word") && toPrompt.contains("never a reason to change the prompt"))
        expect(toPrompt.contains("Never say link, points to or reference for a type."))
        expect(SchemaPrompts.highlightsReferences.contains("An @ word that nothing in the schema points to gets no link"))
        for text in [toSchema, toPrompt, SchemaPrompts.highlightsReferences, SchemaPrompts.toSchemaTitle, SchemaPrompts.toSchemaNewTitle, SchemaPrompts.toPromptTitle] {
            for word in ["x-canvas-link", "contentSchema", "contentMediaType", "pointer"] { expect(!text.contains(word), word) }
        }
        expect(!SchemaPrompts.toSchemaTitle.contains("link"), "the title literal is sent on every request, and says nothing of links")
    },
    test("the $ref the prompt shows is one the app reads, and writes back as the prompt shows it") {
        let example = try require(promptExamples(in: SchemaPrompts.toSchemaReferences).first { $0.contains(#""$ref": "@Customer""#) })
        let customer = FieldFixtures.personID
        let holder = #"{"properties": {"c": {"$ref": "\#(FieldFixtures.uri(of: customer))"}}}"#
        let names = SchemaReferenceNames(words: [], schemas: [holder], name: { $0 == customer ? "Customer" : nil })
        let stored = names.schema(fromModel: #"{"properties": {"customer": \#(example)}}"#)
        expect(stored.contains(FieldFixtures.uri(of: customer)) && !stored.contains("@Customer"), "the word is the type's id again")
        expect(names.modelSchema(stored).contains(#"{"$ref": "@Customer"}"#), "and the model sees it as the prompt shows it")
    },
    test("the title's example is one the app reads: a setting among the properties, no field") {
        let level = try require(ChainLevel(schema: #"{"type": "object", "properties": {"name": {"type": "string"}, "$title": {"x-canvas-from": "name"}}}"#))
        expectEqual(level.fields.map(\.name), ["name"])
        expectEqual(level.directives.map(\.key), ["title"])
        // A `$title` added by hand is a change the words never said: the sync asks for them.
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        let added = pet.replacingOccurrences(of: "\"birthYear\": {\n      \"type\": \"integer\"\n    }", with: "\"birthYear\": {\n      \"type\": \"integer\"\n    },\n    \"$title\": {\"x-canvas-from\": \"name\"}")
        expect(added != pet)
        b.typeSchema(id, added)
        b.sync(id, answer: "NO_CHANGE")
        expectEqual(b.model.requests.count, 2, "one request for the words")
        expectEqual(b.model.lastRequest?.system, SchemaPrompts.system(.toPrompt))
        // An answer with a root title and a `$title`: the root title is the shape's and comes out, the `$title` stays.
        let c = try SyncBench()
        let other = c.place()
        c.typeWords(other, "a pet in my household, called by its name")
        c.sync(other, answer: petSchema.replacingOccurrences(of: "\"birthYear\": {\n      \"type\": \"integer\"\n    }", with: "\"birthYear\": {\n      \"type\": \"integer\"\n    },\n    \"$title\": {\"x-canvas-from\": \"name\"}"))
        expectEqual(c.schema(other), added)
        expectEqual(c.title(other), "Pet")
    },
    test("every JSON example in the new text parses") {
        let texts = [SchemaPrompts.toSchemaSystem, SchemaPrompts.toSchemaTitle, SchemaPrompts.toSchemaNewTitle, SchemaPrompts.toPromptTitle,
                     SchemaPrompts.toSchemaReferences, SchemaPrompts.toPromptReferences, SchemaPrompts.highlightsReferences]
        var seen = 0
        for text in texts {
            for example in promptExamples(in: text) {
                seen += 1
                expect((try? JSONReader.read(example))?.isObject == true, example)
            }
        }
        expect(seen >= 10, "the examples are found: \(seen)")
    },
    test("the highlights' guide: a title is what the words call a field, and a setting is linked to nothing") {
        expect(SchemaPrompts.highlightsGuide.contains(#"a leading "$""#))
        expect(SchemaPrompts.highlightsGuide.contains(#""title", that is what the words call it"#))
        let context = SchemaPrompts.highlightsReferences
        expect(ProseMapPrompt.request(SchemaTarget.self, prose: "a pet at an @Address", target: "{}", context: context).system?.hasSuffix(context) == true)
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
        expectEqual(parse("NO_CHANGES"), .failure("Unusable answer"))
        expectEqual(parse("NO_CHANGE_X", .toPrompt), .failure("Unusable answer"))
        // A prompt loses one pair of quotes around it, and isn't written if it reads as something else.
        expectEqual(parse("\"email required, phone\"", .toPrompt), .text("email required, phone"))
        expectEqual(parse("“a pet, with its weight”", .toPrompt), .text("a pet, with its weight"))
        expectEqual(parse("\"a\" and \"b\"", .toPrompt), .text("\"a\" and \"b\""))
        for answer in ["Here's the updated prompt: a pet", "Updated prompt: a pet", "Sure! a pet", "a pet (NO_CHANGE to the rest)", "a pet ```"] {
            expectEqual(parse(answer, .toPrompt), .failure("Unusable answer"), answer)
        }
        expectEqual(parse("Heretic saints: name, feast day", .toPrompt), .text("Heretic saints: name, feast day"))
        // Words that read so themselves are words, and so is their rewrite (a note that begins "Here are the fields").
        func parsing(_ answer: String, words: String) -> SchemaPrompts.Answer {
            SchemaPrompts.parse(ModelResponse(text: answer, stopReason: .endTurn), .toPrompt, words: words)
        }
        expectEqual(parsing("Here are the fields: name, email, role, phone.", words: "Here are the fields: name, email, role."),
                    .text("Here are the fields: name, email, role, phone."))
        expectEqual(parsing("Prompt: a pet, ```json for its fields```", words: "Prompt: a pet"), .text("Prompt: a pet, ```json for its fields```"))
        expectEqual(parsing("Sure! Here is a pet", words: "a pet in my household"), .failure("Unusable answer"), "ordinary words still refuse a preamble")
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
        expectEqual(parse("<prompt>{}</prompt>"), .failure("Unusable answer"))
        expectEqual(parse("```\n```", .toPrompt), .failure("Unusable answer"))
        expectEqual(parse("Here it is: {\"type\": \"object\"}"), .failure("Unusable answer"))
        expectEqual(parse("[{}]"), .failure("Unusable answer"))
        expectEqual(parse("{\"type\": }"), .failure("Unusable answer"))
        expectEqual(parse("{}", stop: .refusal), .failure("Claude declined"))
        expectEqual(parse("a pet", .toPrompt, stop: .maxTokens), .failure("Unusable answer"), "a description cut off")
        expectEqual(parse("{", stop: .maxTokens), .failure(TypeSyncFailure.tooLongMessage), "a schema cut off")
        expectEqual(parse("{}", stop: StopReason(rawValue: "pause_turn")), .failure("Unusable answer"), "no stop reason a person has to read")
        expectEqual(LanguageModelError.malformedResponse.message, "Unusable answer", "the same words, whatever made it so")
        expectEqual(parse("  email required, phone \n", .toPrompt), .text("email required, phone"))
        expectEqual(parse(" \n", .toPrompt), .failure("Unusable answer"))
    },
    test("a prompt is what's inside its answer's tags, whatever is said around them; an answer without them is read whole") {
        func parse(_ text: String, words: String = "", stop: StopReason = .endTurn) -> SchemaPrompts.Answer {
            SchemaPrompts.parse(ModelResponse(text: text, stopReason: stop), .toPrompt, words: words)
        }
        let unusable = SchemaPrompts.Answer.failure("Unusable answer")
        // What Haiku 5.5 sometimes answers when there are no words yet, as the evals recorded it.
        let remark = "There is no <prompt>, so I write one. Fields: number (string), customer (@Customer), total (number). None are listed as required..."
        let order = "An order: number, customer (a @Customer), total"
        expectEqual(parse(remark + "\n\n<answer>\n" + order + "\n</answer>"), .text(order), "the remark is no part of the words")
        expectEqual(parse(remark + "\n\n<answer>" + order + "</answer>"), .text(order), "on a line or not")
        expectEqual(parse(remark + "\n\n" + order), .text(remark + "\n\n" + order), "with no tags the whole answer is read, as before")
        expectEqual(parse("<answer>\n" + order + "\n</answer>"), .text(order))
        expectEqual(parse("<answer>\n" + order + "\n</answer>\n\nI kept it to one line."), .text(order), "a remark after")
        expectEqual(parse("  <answer>  a pet,\nwith its weight \n</answer> "), .text("a pet,\nwith its weight"), "trimmed, its own line breaks kept")
        // The last complete pair.
        expectEqual(parse("<answer>a pet</answer>\nOr, shorter:\n<answer>pet</answer>"), .text("pet"))
        expectEqual(parse("I put it in <answer> tags.\n<answer>a pet</answer>"), .text("a pet"), "the last opening tag before the closing one")
        expectEqual(parse("<answer>a pet</answer>\nThen, cut off: <answer>a p"), .text("a pet"), "a pair before a tag that's never closed")
        // A tag that's never closed takes what follows it; a closing tag alone is a wrapper's line, as before.
        expectEqual(parse(remark + "\n\n<answer>\n" + order), .text(order))
        expectEqual(parse("<answer>a <answer>pet"), .text("pet"))
        expectEqual(parse(order + "\n</answer>"), .text(order))
        // NO_CHANGE: outside the tags, its first word or its last line, as for an answer without them; and inside them.
        expectEqual(parse("NO_CHANGE"), .noChange)
        expectEqual(parse("<answer>NO_CHANGE</answer>"), .noChange)
        expectEqual(parse("<answer>\nNO_CHANGE\n</answer>"), .noChange)
        expectEqual(parse("The prompt still says it.\n\n<answer>NO_CHANGE.</answer>"), .noChange)
        expectEqual(parse("NO_CHANGE: the prompt never named the title.\n<answer>a pet</answer>"), .noChange, "the first word, whatever follows")
        expectEqual(parse("<answer>a pet</answer>\n\nNO_CHANGE"), .noChange, "the last line")
        expectEqual(parse("A $title alone would be NO_CHANGE, but there is no <prompt>, so I write one.\n\n<answer>A pet: name</answer>"), .text("A pet: name"),
                    "a remark that mentions it is no NO_CHANGE, and is no part of the words")
        expectEqual(parse("A $title alone would be NO_CHANGE, but there is no <prompt>, so I write one.\n\nA pet: name"), unusable, "untagged, it is in the words")
        // Tags with nothing in them: a failure, as an empty answer is, whatever is around them.
        expectEqual(parse("<answer></answer>"), unusable)
        expectEqual(parse("<answer>\n \n</answer>"), unusable)
        expectEqual(parse(order + "\n<answer></answer>"), unusable, "what's around them is never the words")
        expectEqual(parse(remark + "\n<answer>"), unusable, "nothing after a tag that's never closed")
        // What's inside is read as an answer always was: fences and its block's tags off, one pair of quotes off, no preamble.
        expectEqual(parse("```\n<answer>\na pet\n</answer>\n```"), .text("a pet"))
        expectEqual(parse("<answer>\n```\na pet\n```\n</answer>"), .text("a pet"))
        expectEqual(parse("<answer><prompt>a pet</prompt></answer>"), .text("a pet"))
        expectEqual(parse("<answer>\"a pet, with its weight\"</answer>"), .text("a pet, with its weight"))
        expectEqual(parse("<answer>Here's the updated prompt: a pet</answer>"), unusable)
        expectEqual(parse("<answer>Here are the fields: name, email, role, phone.</answer>", words: "Here are the fields: name, email, role."),
                    .text("Here are the fields: name, email, role, phone."), "words that read so themselves")
        expectEqual(parse(remark + "\n\n<answer>" + order + "</answer>", stop: .maxTokens), unusable, "a stop before the end is a failure, tags or none")
        // Only this direction's answer has the tags: a schema is read as it was.
        expectEqual(SchemaPrompts.parse(ModelResponse(text: "Sure.\n<answer>{}</answer>", stopReason: .endTurn), .toSchema), unusable)
        expectEqual(SchemaPrompts.parse(ModelResponse(text: "<answer>\n{}\n</answer>", stopReason: .endTurn), .toSchema), .text("{}"), "a wrapper's lines, as before")
    },
    test("the system prompts name the blocks the requests send and the no-change answer, and end in one line break") {
        for (system, tags) in [(SchemaPrompts.toSchemaSystem, ["<previous_prompt>", "<prompt>", "<schema>"]),
                               (SchemaPrompts.toPromptSystem, ["<prompt>", "<previous_schema>", "<schema>"])] {
            for tag in tags { expect(system.contains(tag), tag) }
            expect(system.contains(SchemaPrompts.noChange))
            // Only the prompt is answered in tags, the ones `parse` reads.
            let answer = "<\(SchemaPrompts.answerTag)>", end = "</\(SchemaPrompts.answerTag)>"
            expectEqual(system.contains(answer) && system.contains(end), system == SchemaPrompts.toPromptSystem)
            expect(!system.contains(answer) || system.contains("inside \(answer) and \(end)"))
            // Each is its .txt byte for byte, final line break included (evals.py reads them out).
            expect(system.hasSuffix(".\n") && !system.hasSuffix("\n\n"))
        }
    },
])

/// Each outermost `{"…}` of `text`, balanced (a brace in a string isn't counted): the JSON the prompts show.
private func promptExamples(in text: String) -> [String] {
    var examples: [String] = []
    var depth = 0, start = text.startIndex, inString = false, escaped = false
    var index = text.startIndex
    while index < text.endIndex {
        let character = text[index]
        let next = text.index(after: index)
        if depth == 0 {
            if character == "{", next < text.endIndex, text[next] == "\"" { depth = 1; start = index; inString = false; escaped = false }
        } else if inString {
            if escaped { escaped = false } else if character == "\\" { escaped = true } else if character == "\"" { inString = false }
        } else if character == "\"" {
            inString = true
        } else if character == "{" {
            depth += 1
        } else if character == "}" {
            depth -= 1
            if depth == 0 { examples.append(String(text[start...index])) }
        }
        index = next
    }
    return examples
}
