@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import LanguageModels
import Mentions
import TestKit
import Titles
import Types

// A note of a type filling its fields from its words (`FieldFill`): when it asks, what it asks, what it writes and in
// which step, and what it leaves the person's.

/// A Feature: three fields, as a type's sync writes them.
let fillFeatureSchema = """
{
  "type": "object",
  "properties": {
    "purpose": {
      "type": "string"
    },
    "status": {
      "type": "string",
      "enum": ["todo", "doing", "done"]
    },
    "estimate": {
      "type": "integer"
    }
  }
}
"""

/// An editor with the type plugins, a scripted model, a fixed today, and time that moves only when the test says.
@MainActor
final class FillBench {
    let model: ScriptedLanguageModel
    let harness: EditorHarness
    let fill: FieldFill
    var editor: CanvasEditor { harness.editor }
    var scheduler: ManualScheduler { harness.scheduler }

    /// Noon on Wednesday 21 October 2026, UTC.
    static let today = Date(timeIntervalSince1970: 1_792_584_000)

    init(more: [any CanvasPlugin] = []) throws {
        let model = ScriptedLanguageModel()
        self.model = model
        harness = try EditorHarness { scheduler in try typeEditor(scheduler: scheduler, model: model, more: more) }
        fill = try require(harness.editor.fieldFill)
        let clock = FieldFill.now
        FieldFill.now = { FillBench.today }
        afterThisTest { FieldFill.now = clock }
    }

    func addFeature(_ schema: String = fillFeatureSchema, title: String = "Feature") -> ShapeID {
        editor.addType(schema, title: title, at: CGPoint(x: 600, y: 40))
    }

    /// The person writing a shape's words (a keystroke, or the lot).
    func typeWords(_ id: ShapeID, _ text: String) {
        editor.transact { $0.update(id, as: Memo.self) { $0.props.text = MentionText(plain: text); MemoStyle.fit(&$0.props) } }
    }

    /// The person done with a shape's words: editing them ends, and the scheduler's next turn comes.
    func endEditing(_ id: ShapeID) {
        fill.editingDidEnd(id, in: editor)
        scheduler.advance(by: .zero)
    }

    /// Ends editing with `answer` queued and waits for it to land.
    func fillNow(_ id: ShapeID, answer: String) {
        model.queue(answer)
        let asked = model.requests.count
        endEditing(id)
        spinRunLoop(until: { self.model.requests.count > asked && self.fill.status(of: id) != .filling })
    }

    func values(_ id: ShapeID) -> FieldValues? { editor.document[id]?[FieldValuesProperty.self] }
    func value(_ id: ShapeID, _ key: String) -> JSONValue? { values(id)?[key] }

    /// Runs the main run loop a few turns, for what isn't expected to happen.
    func settle() {
        for _ in 0..<10 { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002)) }
    }

    /// The user message of the last request.
    var message: String { model.lastRequest?.messages.first?.text ?? "" }
}

@MainActor let fillTests = Suite("Filling fields from words", [
    test("words done ask for the changes they say: the fields, what they hold, today and the words; written in one step, the fields alone") {
        let b = try FillBench()
        let note = b.editor.addInstance(of: [b.addFeature()])
        b.typeWords(note, "purpose is to sort the mail, already started")
        b.settle()
        expectEqual(b.model.requests.count, 0, "not before the words are done, nor before 3 s")
        b.model.holdsAnswers = true
        b.model.queue(#"{"purpose": "to sort the mail", "status": "doing", "owner": "Sam"}"#)
        b.endEditing(note)
        spinRunLoop(until: { b.model.waiting == 1 })
        expectEqual(b.fill.status(of: note), .filling)
        expect(b.fill.isFilling(note))
        let request = try require(b.model.lastRequest)
        expectEqual(request.system, FillPrompts.system)
        expectEqual([request.model, request.effort], [FillPrompts.model, FillPrompts.effort])
        expectEqual(request.maxTokens, FillPrompts.maxTokens)
        expectEqual(request.temperature, nil)
        expectEqual(b.message, """
        <fields>
        {
          "type": "object",
          "properties": {
            "purpose": {
              "type": "string"
            },
            "status": {
              "type": "string",
              "enum": ["todo", "doing", "done"]
            },
            "estimate": {
              "type": "integer"
            }
          }
        }
        </fields>

        <values>
        {}
        </values>

        <today>
        \(FillPrompts.day(of: FillBench.today))
        </today>

        <words>
        purpose is to sort the mail, already started
        </words>
        """, "no words before: the note was empty when it was first edited")
        b.model.release()
        spinRunLoop(until: { b.fill.status(of: note) == .idle })
        expectEqual(b.value(note, "purpose"), "to sort the mail")
        expectEqual(b.value(note, "status"), "doing")
        expectEqual(b.value(note, "owner"), nil, "a key no field names is passed over")
        expectEqual(b.editor.undoHistory.undoName, FieldFill.step)
        expectEqual(b.editor.words(note), "purpose is to sort the mail, already started", "the words are the person's")
    },
    test("an edit fills 3 s after the last keystroke, a keystroke starting the wait again") {
        let b = try FillBench()
        let note = b.editor.addInstance(of: [b.addFeature()])
        b.model.queue(#"{"estimate": 4}"#)
        b.typeWords(note, "about 4")
        b.scheduler.advance(by: .seconds(2))
        b.typeWords(note, "about 4 days")
        b.scheduler.advance(by: .seconds(2))
        b.settle()
        expectEqual(b.model.requests.count, 0)
        b.scheduler.advance(by: .seconds(1))
        spinRunLoop(until: { b.model.requests.count == 1 && b.fill.status(of: note) == .idle })
        expect(b.message.contains("<words>\nabout 4 days\n</words>"))
        expectEqual(b.value(note, "estimate"), 4)
    },
    test("the next edit is read against the words it was filled from: they go as previous words, and a value taken away is null") {
        let b = try FillBench()
        let note = b.editor.addInstance(of: [b.addFeature()])
        b.typeWords(note, "purpose is to sort the mail, already started")
        b.fillNow(note, answer: #"{"purpose": "to sort the mail", "status": "doing"}"#)
        b.typeWords(note, "purpose is to sort the mail")
        b.fillNow(note, answer: #"{"status": null}"#)
        expect(b.message.contains("<previous_words>\npurpose is to sort the mail, already started\n</previous_words>\n\n<words>\npurpose is to sort the mail\n</words>"),
               b.message)
        expect(b.message.contains(#""status": "doing""#), "what the fields hold")
        expectEqual(b.value(note, "status"), nil)
        expectEqual(b.value(note, "purpose"), "to sort the mail")
        b.endEditing(note)
        b.settle()
        expectEqual(b.model.requests.count, 2, "in step: done again asks nothing")
    },
    test("a value the person changes while the call is out stays theirs; the rest of the answer is written") {
        let b = try FillBench()
        let note = b.editor.addInstance(of: [b.addFeature()])
        b.typeWords(note, "purpose is to sort the mail, done")
        b.model.holdsAnswers = true
        b.model.queue(#"{"purpose": "to sort the mail", "status": "done"}"#)
        b.endEditing(note)
        spinRunLoop(until: { b.model.waiting == 1 })
        try require(b.editor.fieldWriter).set("todo", at: FieldPath(field: "status"), of: note)
        b.model.release()
        spinRunLoop(until: { b.fill.status(of: note) == .idle })
        expectEqual(b.value(note, "status"), "todo")
        expectEqual(b.value(note, "purpose"), "to sort the mail")
    },
    test("words typed while the call is out wait, and are read once it lands, against the words it was asked about") {
        let b = try FillBench()
        let note = b.editor.addInstance(of: [b.addFeature()])
        b.typeWords(note, "purpose is to sort the mail")
        b.model.holdsAnswers = true
        b.model.queue(#"{"purpose": "to sort the mail"}"#)
        b.model.queue(#"{"estimate": 2}"#)
        b.endEditing(note)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.typeWords(note, "purpose is to sort the mail, 2 days")
        b.endEditing(note)
        b.settle()
        expectEqual(b.model.requests.count, 1, "one at a time")
        b.model.release()
        spinRunLoop(until: { b.model.waiting == 1 })
        expect(b.message.contains("<previous_words>\npurpose is to sort the mail\n</previous_words>"), b.message)
        b.model.release()
        spinRunLoop(until: { b.fill.status(of: note) == .idle && b.value(note, "estimate") != nil })
        expectEqual(b.values(note), FieldValues(["purpose": "to sort the mail", "estimate": 2]))
    },
    test("undo takes a fill back and asks nothing; redo puts it back") {
        let b = try FillBench()
        let note = b.editor.addInstance(of: [b.addFeature()])
        b.typeWords(note, "purpose is to sort the mail")
        b.fillNow(note, answer: #"{"purpose": "to sort the mail"}"#)
        b.editor.undo()
        expectEqual(b.values(note), nil)
        expectEqual(b.editor.words(note), "purpose is to sort the mail")
        b.scheduler.advance(by: .seconds(5))
        b.endEditing(note)
        b.settle()
        expectEqual(b.model.requests.count, 1, "the words are ahead, and wait for the person")
        b.editor.redo()
        expectEqual(b.value(note, "purpose"), "to sort the mail")
        b.endEditing(note)
        b.settle()
        expectEqual(b.model.requests.count, 1)
    },
    test("given a type, a note's words are read at once and whole: no words before, nothing taken away") {
        let b = try FillBench()
        let feature = b.addFeature()
        let note = b.editor.addInstance("purpose is to sort the mail", of: [])
        b.model.queue(#"{"purpose": "to sort the mail"}"#)
        b.editor.addTypeLink(feature, to: note)
        b.scheduler.advance(by: .zero)
        spinRunLoop(until: { b.model.requests.count == 1 && b.fill.status(of: note) == .idle })
        expect(!b.message.contains("<previous_words>"), b.message)
        expectEqual(b.value(note, "purpose"), "to sort the mail")
    },
    test("words never read, over fields none of which holds a value, are read whole once editing them ends; then not again") {
        let b = try FillBench()
        let feature = b.addFeature()
        let note = b.editor.addInstance("purpose is to sort the mail", of: [feature])
        let held = b.editor.addInstance("estimate 3", of: [feature], at: CGPoint(x: 40, y: 600))
        try require(b.editor.fieldWriter).set(3, at: FieldPath(field: "estimate"), of: held)
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 0, "a note that came is filled from what it says")
        b.fillNow(note, answer: "{}")
        expect(!b.message.contains("<previous_words>"))
        expectEqual(b.values(note), nil)
        b.endEditing(note)
        b.endEditing(held)
        b.settle()
        expectEqual(b.model.requests.count, 1, "read once; a note that holds a value was read")
    },
    test("an agent's write, a type's own note, a note whose types give no fields and empty words ask nothing") {
        let b = try FillBench()
        let feature = b.addFeature()
        let empty = b.editor.addType(TypeSchemaProperty.starter, title: "Empty")
        let byAgent = b.editor.addInstance(of: [feature])
        b.editor.transact { transaction in
            transaction.byAgent = true
            transaction.update(byAgent, as: Memo.self) { $0.props.text = MentionText(plain: "purpose is to sort the mail") }
        }
        b.endEditing(byAgent)
        b.typeWords(feature, "a feature: its purpose, status and estimate")
        let bare = b.editor.addInstance(of: [empty], at: CGPoint(x: 40, y: 600))
        b.typeWords(bare, "purpose is to sort the mail")
        let blank = b.editor.addInstance("purpose", of: [feature], at: CGPoint(x: 40, y: 800))
        b.typeWords(blank, "  ")
        b.scheduler.advance(by: .seconds(5))
        for id in [bare, blank] { b.endEditing(id) }
        b.settle()
        expectEqual(b.model.requests.filter { $0.system == FillPrompts.system }.count, 0)
    },
    test("a shape that doesn't fill asks nothing: its own say off, or its type's; its own say on over its type's fills") {
        let b = try FillBench()
        let feature = b.addFeature()
        let off = b.editor.addInstance(of: [feature])
        b.fill.setAutofill(false, of: off)
        b.typeWords(off, "purpose is to sort the mail")
        b.scheduler.advance(by: .seconds(5))
        b.endEditing(off)
        b.settle()
        expectEqual(b.model.requests.count, 0)
        let quiet = b.addFeature(fillFeatureSchema.replacingOccurrences(of: "\"properties\": {\n", with: "\"properties\": {\n    \"$autofill\": {\"const\": false},\n"),
                                 title: "Quiet")
        let ofQuiet = b.editor.addInstance(of: [quiet], at: CGPoint(x: 40, y: 600))
        b.typeWords(ofQuiet, "purpose is to sort the mail")
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 0, "its type says false")
        b.model.queue(#"{"purpose": "to sort the mail"}"#)
        b.fill.setAutofill(true, of: ofQuiet)
        b.scheduler.advance(by: .zero)
        spinRunLoop(until: { b.model.requests.count == 1 && b.fill.status(of: ofQuiet) == .idle })
        expect(!b.message.contains("<previous_words>"), "turned on, the words are read whole")
        expectEqual(b.value(ofQuiet, "purpose"), "to sort the mail")
    },
    test("a read-only note asks nothing; an answer landing on one writes nothing and shakes nothing") {
        let log = RefusalLog()
        let b = try FillBench(more: [FreezingPlugin(log: log)])
        let note = b.editor.addInstance(of: [b.addFeature()])
        b.typeWords(note, "purpose is to sort the mail")
        b.editor.freeze([note])
        b.endEditing(note)
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 0)
        b.editor.freeze([note], false)
        b.model.holdsAnswers = true
        b.model.queue(#"{"purpose": "to sort the mail"}"#)
        b.typeWords(note, "purpose is to sort the mail!")
        b.endEditing(note)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.editor.freeze([note])
        b.model.release()
        spinRunLoop(until: { b.fill.status(of: note) == .idle })
        expectEqual(b.values(note), nil)
        expectEqual(log.refusals, [], "nothing tried, so nothing refused")
    },
    test("failures say why and what can be done: Settings, Retry, nothing for Claude declining; a sign-in asks again") {
        let b = try FillBench()
        let note = b.editor.addInstance(of: [b.addFeature()])
        b.typeWords(note, "purpose is to sort the mail")
        b.model.queue(LanguageModelError.notSignedIn)
        b.endEditing(note)
        spinRunLoop(until: { b.fill.status(of: note) != .filling && b.model.requests.count == 1 })
        expectEqual(b.fill.status(of: note), .failed(FieldFillFailure(LanguageModelError.notSignedIn.message, remedy: .signIn)))
        b.model.queue("I'm not sure what you mean.")
        NotificationCenter.default.post(name: .languageModelSignInDidChange, object: nil)
        spinRunLoop(until: { b.model.requests.count == 2 && b.fill.status(of: note) != .filling })
        expectEqual(b.fill.status(of: note), .failed(FieldFillFailure(LanguageModelError.malformedResponse.message, remedy: .retry)))
        b.model.queue(ModelResponse(text: "", stopReason: .refusal))
        b.fill.retry(note)
        spinRunLoop(until: { b.model.requests.count == 3 && b.fill.status(of: note) != .filling })
        expectEqual(b.fill.status(of: note), .failed(FieldFillFailure("Claude declined", remedy: .editByHand)))
        b.model.queue(#"{"purpose": "to sort the mail"}"#)
        b.fill.retry(note)
        spinRunLoop(until: { b.model.requests.count == 4 && b.fill.status(of: note) == .idle })
        expectEqual(b.value(note, "purpose"), "to sort the mail")
    },
    test("with no language model at all, a fill fails saying so") {
        let plugins = typePlugins().filter { !($0 is LanguageModelsPlugin) }
        let harness = try EditorHarness { scheduler in CanvasEditor(registry: try Registry(plugins: plugins), file: CanvasFile(root: CanvasDocument()), scheduler: scheduler) }
        let editor = harness.editor, fill = try require(editor.fieldFill)
        let feature = editor.addType(fillFeatureSchema, title: "Feature")
        let note = editor.addInstance(of: [feature])
        editor.transact { $0.update(note, as: Memo.self) { $0.props.text = MentionText(plain: "purpose is to sort the mail") } }
        fill.editingDidEnd(note, in: editor)
        harness.scheduler.advance(by: .zero)
        expectEqual(fill.status(of: note), .failed(FieldFillFailure(TypeSyncFailure.noModelMessage, remedy: .editByHand)))
    },
    test("a call out when the file closes is cancelled, and an edit's wait with it") {
        var b: FillBench? = try FillBench()
        let model = try require(b?.model), scheduler = try require(b?.scheduler)
        weak var closing = b?.editor
        let feature = try require(b?.addFeature())
        let calling = try require(b?.editor.addInstance(of: [feature])), waiting = try require(b?.editor.addInstance(of: [feature], at: CGPoint(x: 40, y: 600)))
        model.holdsAnswers = true
        b?.typeWords(calling, "purpose is to sort the mail")
        b?.endEditing(calling)
        spinRunLoop(until: { model.waiting == 1 })
        let before = scheduler.pendingCount
        b?.typeWords(waiting, "about 3 days")
        expectEqual(scheduler.pendingCount, before + 1, "the edit waits 3 s")
        b = nil
        spinRunLoop(until: { model.waiting == 0 && model.answered == 1 })
        expect(closing == nil, "the editor went as its file closed")
        expectEqual(model.answered, 1, "it ended: cancelled")
        expectEqual(scheduler.pendingCount, before, "the wait went with it")
    },
    test("the fields the model is told are in the rows' order, another type's fields written out in place of its reference") {
        let b = try FillBench()
        let address = b.editor.addType(#"{"type": "object", "properties": {"street": {"type": "string"}, "city": {"type": "string"}}}"#, title: "Address",
                                       at: CGPoint(x: 900, y: 40))
        let person = b.addFeature(#"{"type": "object", "properties": {"name": {"type": "string"}, "home": {"title": "Home", "$ref": "\#(SchemaReferences.uri(of: address))"}}}"#,
                                  title: "Person")
        let ann = b.editor.addInstance(of: [person])
        b.typeWords(ann, "Ann, lives on Elm St in Leeds")
        b.fillNow(ann, answer: #"{"name": "Ann", "home": {"street": "Elm St", "city": "Leeds"}}"#)
        expect(b.message.contains("""
            "home": {
              "title": "Home",
              "type": "object",
              "properties": {
                "street": {
        """), b.message)
        expect(!b.message.contains("urn:uuid"), "no id goes to the model")
        expectEqual(b.value(ann, "home")?["city"], "Leeds")
    },
])

@MainActor let fillPromptTests = Suite("What a fill asks", [
    test("the request: the blocks in order, each trimmed, one with nothing left out") {
        let request = FillPrompts.request(fields: "{}", values: " {} ", today: "Wednesday 2026-10-21", previousWords: "", words: "a\n")
        expectEqual(request.messages, [.user("<fields>\n{}\n</fields>\n\n<values>\n{}\n</values>\n\n<today>\nWednesday 2026-10-21\n</today>\n\n<words>\na\n</words>")])
        let again = FillPrompts.request(fields: "{}", values: "{}", today: "t", previousWords: "b", words: "a")
        expect(again.messages.first?.text.contains("<previous_words>\nb\n</previous_words>\n\n<words>") == true)
    },
    test("today is its weekday and its day, in the calendar given") {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        expectEqual(FillPrompts.day(of: FillBench.today, in: calendar), "Wednesday 2026-10-21")
        calendar.timeZone = TimeZone(identifier: "Pacific/Kiritimati")!
        expectEqual(FillPrompts.day(of: FillBench.today, in: calendar), "Thursday 2026-10-22", "the person's day")
    },
    test("an answer is a JSON object of the changes, fenced or not; NO_CHANGE and {} are none; anything else is unusable, a refusal declined") {
        expectEqual(FillPrompts.parse(ModelResponse(text: #"{"a": 1, "b": null}"#)), .changes(["a": 1, "b": .null]))
        expectEqual(FillPrompts.parse(ModelResponse(text: "```json\n{\"a\": \"x\"}\n```")), .changes(["a": "x"]))
        expectEqual(FillPrompts.parse(ModelResponse(text: "{}")), .changes([:]))
        expectEqual(FillPrompts.parse(ModelResponse(text: "NO_CHANGE")), .changes([:]))
        let unusable = FillPrompts.Answer.failure(LanguageModelError.malformedResponse.message)
        expectEqual(FillPrompts.parse(ModelResponse(text: "Here you go: {\"a\": 1}")), unusable)
        expectEqual(FillPrompts.parse(ModelResponse(text: "[1]")), unusable)
        expectEqual(FillPrompts.parse(ModelResponse(text: #"{"a": 1"#, stopReason: .maxTokens)), unusable)
        expectEqual(FillPrompts.parse(ModelResponse(text: "", stopReason: .refusal)), .failure("Claude declined"))
    },
    test("the prompt's example is JSON as the request and the answer would be") {
        let lines = FillPrompts.system.split(separator: "\n").map(String.init)
        let example = try require(lines.firstIndex(of: "Example"))
        let json = lines[example...].filter { $0.hasPrefix("{") }
        expectEqual(json.count, 3, "the fields, the values and the reply")
        for line in json { expect((try? JSONReader.read(line))?.isObject == true, line) }
    },
])
