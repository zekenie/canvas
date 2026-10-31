import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import LanguageModels
import Queries
import QueryLanguage
import QueryTranslation
import TestKit
import Topology

// The one lifecycle every host of words shares (`editor.interpretations`), held with a host of its own, `Jotter`
// (a card's words, landed as a list it keeps), over captioned chores and a scripted model: words rest 600 ms, then
// the model is asked, a keystroke starting the rest again; words that read as a query are a draft at once with no
// model; while the card is edited an answer is a draft with what it finds, and editing ending lands it as the
// host's own; an answer after editing lands at once; words the host had something else for are asked about once
// editing ends; a failure in the words every host says, Retry and a key saved asking again through the host; a
// drop, a file put in place and the editor going letting go of a call out. References' InterpretTests hold a
// pill to it with its own words and steps.

/// A host of words: the words each card holds with no query yet, and what was landed.
@MainActor final class Jotter: InterpretationHost {
    unowned let editor: CanvasEditor
    var words: [ShapeID: String] = [:]
    var landed: [String] = []
    var told = 0
    var askedAgain = 0

    init(_ editor: CanvasEditor) {
        self.editor = editor
    }

    func context(of _: InterpretationKey) -> TranslationContext { .stored() }

    func holdsWords(_ words: String, at key: InterpretationKey) -> Bool { self.words[key.shape] == words }

    func request(for query: String, at _: InterpretationKey) -> QueryMatchRequest? { QueryMatchRequest(query) }

    func land(_ query: String, words: String, at key: InterpretationKey) {
        guard holdsWords(words, at: key) else { return }
        self.words[key.shape] = nil
        landed.append(query)
    }

    func interpretAgain(at key: InterpretationKey) {
        askedAgain += 1
        if let words = words[key.shape] { editor.interpretations?.interpret(words, at: key, host: self) }
    }

    func interpretationDidChange(at _: InterpretationKey) { told += 1 }
}

/// A card to type words into, beside the chores, with the lifecycle and its host.
@MainActor struct WordsRig {
    let h: EditorHarness
    let card: ShapeID
    let key: InterpretationKey
    let host: Jotter

    init(_ model: ScriptedLanguageModel?) throws {
        let card = AnyShapeRecord(ShapeRecord(id: ShapeID(), Card(CGRect(x: 0, y: 200, width: 160, height: 40))))
        h = try translateHarness(model, adding: [CardsPlugin()], shapes: [card])
        self.card = card.id
        key = InterpretationKey(shape: card.id, slot: "jot")
        host = Jotter(h.editor)
    }

    var interpretations: Interpretations { get throws { try require(h.editor.interpretations) } }

    /// What's asked of the card's words, said shortly.
    var said: String {
        get throws {
            switch try interpretations.state(at: key) {
            case nil: "nothing"
            case .waiting?: "waiting"
            case .interpreting?: "interpreting"
            case .drafted(let query, nil)?: "\(query), finding"
            case .drafted(let query, .success(let found))?: "\(query), \(found.count) found"
            case .drafted(let query, .failure(let error))?: "\(query), \(error.reason)"
            case .failed(let status)?: "failed: \(status.words)"
            }
        }
    }

    func type(_ words: String, interprets: Bool = true) throws {
        try interpretations.typed(words, at: key, interprets: interprets, host: host)
    }

    /// Turns the run loop a little, for what would come if anything were going to.
    func settle() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05)) }

    func spin(_ done: @autoclosure () throws -> Bool, file: StaticString = #fileID, line: UInt = #line) {
        _ = spinRunLoop(until: { (try? done()) ?? false }, file: file, line: line)
    }
}

@MainActor let interpretationsTests = Suite("Interpretations", [
    test("words rest 600 ms before the model is asked, and a keystroke starts the rest again and lets go of what was asked") {
        let model = ScriptedLanguageModel(answers: [#"chore"Pantry""#])
        let rig = try WordsRig(model)
        rig.h.editor.beginEditing(rig.card)
        try rig.type("the pantr")
        expectEqual(try rig.said, "interpreting", "resting reads as interpreting")
        rig.h.wait(400)
        try rig.type("the pantry")
        rig.h.wait(599)
        rig.settle()
        expectEqual(model.requests.count, 0, "599 ms after the last keystroke")
        rig.h.wait(1)
        rig.spin(try rig.said == #"chore"Pantry", 1 found"#)
        expectEqual(model.requests.count, 1)
        expect(message(try require(model.requests.first)).contains("the pantry"), "the words as they rested")
        expectEqual(try rig.interpretations.draftQuery(at: rig.key, words: "the pantry"), #"chore"Pantry""#, "the draft, for exactly these words")
        expectEqual(try rig.interpretations.draftQuery(at: rig.key, words: "the pantr"), nil)
        expectEqual(rig.host.landed, [], "nothing lands while the card is edited")
        try rig.type("the cellar", interprets: false)
        expectEqual(try rig.said, "waiting", "a keystroke lets go of the draft")
        rig.h.wait(600)
        expectEqual(model.requests.count, 1, "words the host has something else for don't rest")
    },
    test("words that read as a query are a draft at once, no model asked, with what it finds; one that only names a shape too") {
        let model = ScriptedLanguageModel()
        let rig = try WordsRig(model)
        rig.h.editor.beginEditing(rig.card)
        try rig.type(#"  chore"Cellar"  "#)
        expectEqual(try rig.said, #"chore"Cellar", finding"#)
        rig.spin(try rig.said == #"chore"Cellar", 1 found"#)
        expectEqual(model.requests.count, 0)
        rig.h.wait(600)
        expectEqual(model.requests.count, 0, "no rest either")
    },
    test("editing ending lands the draft as the host's own, with no second call; an answer after editing lands at once") {
        let model = ScriptedLanguageModel(answers: [#"chore"Pantry""#, #"chore"Cellar""#])
        let rig = try WordsRig(model)
        rig.h.editor.beginEditing(rig.card)
        try rig.type("the pantry")
        rig.host.words[rig.card] = "the pantry"
        rig.h.wait(600)
        rig.spin(try rig.said == #"chore"Pantry", 1 found"#)
        rig.h.editor.endEditing()
        try rig.interpretations.editingEnded(at: rig.key)
        expectEqual(rig.host.landed, [], "not inside the end of editing")
        rig.h.wait(0)
        expectEqual(rig.host.landed, [#"chore"Pantry""#])
        expectEqual(try rig.said, "nothing")
        expectEqual(model.requests.count, 1, "the draft was the answer")
        rig.host.words[rig.card] = "the cellar"
        try rig.interpretations.interpret("the cellar", at: rig.key, host: rig.host)
        expectEqual(try rig.said, "interpreting")
        rig.spin(rig.host.landed.count == 2)
        expectEqual(rig.host.landed.last, #"chore"Cellar""#)
        expectEqual(try rig.said, "nothing")
    },
    test("words the host had something else for are asked about once editing ends, typed or committed, and only if it still holds them") {
        let model = ScriptedLanguageModel(answers: [#"chore"Attic""#, #"chore"Attic""#])
        let rig = try WordsRig(model)
        rig.h.editor.beginEditing(rig.card)
        try rig.type("the attic", interprets: false)
        rig.host.words[rig.card] = "the attic"
        rig.h.editor.endEditing()
        try rig.interpretations.editingEnded(at: rig.key)
        rig.h.wait(0)
        rig.spin(rig.host.landed.count == 1)
        expectEqual(rig.host.landed, [#"chore"Attic""#])
        rig.h.editor.beginEditing(rig.card)
        try rig.interpretations.committed(words: "the attic", at: rig.key, host: rig.host)
        expectEqual(try rig.said, "nothing", "words the host doesn't hold aren't noted")
        rig.host.words[rig.card] = "the attic"
        try rig.interpretations.committed(words: "the attic", at: rig.key, host: rig.host)
        expectEqual(try rig.said, "waiting")
        rig.host.words[rig.card] = "something else"
        rig.h.editor.endEditing()
        try rig.interpretations.editingEnded(at: rig.key)
        rig.h.wait(0)
        rig.settle()
        expectEqual(model.requests.count, 1, "the host has other words now: nothing asked")
    },
    test("a failure says the words every host says, with its action; Retry asks again through the host, as does a sign-in") {
        let model = ScriptedLanguageModel()
        model.queue(.notSignedIn)
        let rig = try WordsRig(model)
        rig.host.words[rig.card] = "the pantry"
        try rig.interpretations.interpret("the pantry", at: rig.key, host: rig.host)
        rig.spin(try rig.said == "failed: Not signed in")
        expectEqual(InterpretationStatus.notSignedIn.action, .openSettings)
        model.queue(.rateLimited)
        NotificationCenter.default.post(name: .languageModelSignInDidChange, object: nil)
        expectEqual(rig.host.askedAgain, 1, "a sign-in asks again what wanted one")
        rig.spin(try rig.said == "failed: Rate limited")
        expectEqual(InterpretationStatus.model("Rate limited").action, .retry)
        NotificationCenter.default.post(name: .languageModelSignInDidChange, object: nil)
        expectEqual(rig.host.askedAgain, 1, "not what failed otherwise")
        model.queue(#"chore"Pantry""#)
        try rig.interpretations.retry(at: rig.key)
        expectEqual(rig.host.askedAgain, 2, "Retry, with the card not edited, is the host's Interpret")
        rig.spin(rig.host.landed == [#"chore"Pantry""#])
        expectEqual(model.requests.count, 3)
    },
    test("with no model, interpreting is unavailable, offering nothing") {
        let rig = try WordsRig(nil)
        rig.host.words[rig.card] = "the pantry"
        try rig.interpretations.interpret("the pantry", at: rig.key, host: rig.host)
        rig.spin(try rig.said == "failed: Unavailable")
        expectEqual(InterpretationStatus.unavailable.action, nil)
    },
    test("each way a translation fails is told in the one set of words, with the one action") {
        let cases: [(QueryTranslationError, String?, InterpretationStatus.Action?)] = [
            (.cancelled, nil, nil),
            (.noQueries, "Unavailable", nil),
            (.noModel, "Unavailable", nil),
            (.model(.notSignedIn, timedOut: false), "Not signed in", .openSettings),
            (.model(.unauthorized, timedOut: false), "Key rejected", .openSettings),
            (.model(.rateLimited, timedOut: false), "Rate limited", .retry),
            (.model(.timedOut, timedOut: true), "Timed out", .retry),
            (.declined, "No query for these words", .retry),
            (.unanswerable("where shapes sit"), "No query for these words", .retry),
            (.unusable("no query", query: "chore[", refusal: nil), "Unusable answer", .retry),
            (.tooSlow, "Timed out", .retry),
        ]
        for (error, words, action) in cases {
            let status = InterpretationStatus(error)
            expectEqual(status?.words, words, "\(error)")
            expectEqual(status?.action, action, "\(error)")
            expect(status?.isBusy != true)
        }
        expect(InterpretationStatus.interpreting.isBusy)
        expectEqual(InterpretationStatus.interpreting.words, "Interpreting…")
    },
    test("a drop and a file put in place let go of a call out: its answer lands nothing") {
        let model = ScriptedLanguageModel(answers: [#"chore"Pantry""#, #"chore"Pantry""#])
        model.holdsAnswers = true
        let rig = try WordsRig(model)
        rig.host.words[rig.card] = "the pantry"
        try rig.interpretations.interpret("the pantry", at: rig.key, host: rig.host)
        rig.spin(model.waiting == 1)
        try rig.interpretations.drop(rig.key)
        rig.spin(model.waiting == 0)
        expectEqual(try rig.said, "nothing")
        try rig.interpretations.interpret("the pantry", at: rig.key, host: rig.host)
        rig.spin(model.waiting == 1)
        rig.h.editor.replaceFile(with: rig.h.editor.file)
        expect(try rig.interpretations.isEmpty, "a file put in place")
        rig.spin(model.waiting == 0)
        model.release()
        rig.settle()
        expectEqual(rig.host.landed, [])
    },
    test("the editor going cancels the call it has out: no answer taken, no timer left") {
        let model = ScriptedLanguageModel(answers: [#"chore"Pantry""#])
        model.holdsAnswers = true
        var rig: WordsRig? = try WordsRig(model)
        let scheduler = try require(rig?.h.scheduler)
        weak var closing = rig?.h.editor
        let host = try require(rig?.host)
        let key = try require(rig?.key)
        host.words[key.shape] = "the pantry"
        try require(rig?.interpretations).interpret("the pantry", at: key, host: host)
        _ = spinRunLoop(until: { model.waiting == 1 })
        rig = nil
        _ = spinRunLoop(until: { model.waiting == 0 && scheduler.pendingCount == 0 && closing == nil })
        expect(closing == nil, "the editor went")
        expectEqual(model.answered, 1, "the call ended: cancelled")
        expectEqual(model.queued.count, 1, "and took no answer")
        expectEqual(host.landed, [])
    },
])
