import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import LanguageModels
import Queries
import QueryLanguage
import QueryTranslation
import TestKit
import Topology

// `translate`, the translator's other call: English into a query that is stored and run later, not
// run now. It validates as `--ask` does and one thing more (the check, in a reference's context the
// gate on the words that read the editor, and the names), each refusal going into the one second
// try; the `.reference` context leaves the selection and the editor's words out of what the model
// is told and adds one rule line. Fixtures only: captioned chores, a selection word `:picked` (it
// reads the editor), a scripted model.

/// What names a chore for queries.
enum Label {}
extension Label: ShapeProperty {
    static let key: PropertyKey = "label"
    static var defaultValue: String? { nil }
    static func isNone(_ value: String) -> Bool { value.allSatisfy(\.isWhitespace) }
}

/// The chores picked, which `:picked` says.
@MainActor final class Picked {
    var ids: [ShapeID] = []
}

@MainActor func translateHarness(_ model: ScriptedLanguageModel?, picked: Picked = Picked(), queries: Bool = true) throws -> EditorHarness {
    var plugins: [any CanvasPlugin] = [ChoresPlugin(), TopologyPlugin()]
    if queries {
        plugins.append(QueriesPlugin())
        plugins.append(Contributor(id: "label-names") { registrar in
            registrar.declare(Label.self)
            registrar.optIn(Chore.self, to: Label.self)
            registrar.queryNames(attribute: Label.key.rawValue,
                                 source: { kind, registry in registry.properties(for: kind).contains(Label.key) ? .named : .none },
                                 named: { $0[Label.self] }, derived: { _, _ in nil }, fold: { $0 })
            registrar.querySelection("picked", "the person picked it", example: ":picked", selected: { _ in picked.ids })
        })
    }
    if let model { plugins.append(LanguageModelsPlugin(model: model)) }
    plugins.append(QueryTranslationPlugin(prompt: systemPrompt, referenceRule: referenceRule))
    let shapes = ["Pantry", "Cellar", "Attic"].map { name -> AnyShapeRecord in
        var record = AnyShapeRecord(ShapeRecord(id: ShapeID(), Chore(CGRect(x: 0, y: 0, width: 100, height: 60))))
        record[Label.self] = name
        return record
    }
    picked.ids = [shapes[0].id]
    return try EditorHarness(plugins: plugins, document: CanvasDocument(shapes: shapes))
}

/// What `translate` came to, with the context: the query, or the refusal.
@MainActor func translated(_ words: String, on h: EditorHarness, about context: TranslationContext = .reference) throws -> Result<TranslatedQuery, QueryTranslationError> {
    let translator = try require(h.editor.queryTranslator)
    return try awaitResult { () async -> Result<TranslatedQuery, QueryTranslationError> in
        do throws(QueryTranslationError) { return .success(try await translator.translate(words, about: context)) } catch { return .failure(error) }
    }
}

/// The user message of a request, and its block of the tag.
func message(_ request: ModelRequest) -> String { request.messages.first?.text ?? "" }

@MainActor let translateTests = Suite("Translating", [
    test("words become a query, canonical and checked, and nothing is run: the tokens, what the model wrote, and no second try") {
        let model = ScriptedLanguageModel()
        model.queue(ModelResponse(text: "  ```\nchore\"Pantry\"\n```", inputTokens: 700, outputTokens: 9))
        let h = try translateHarness(model)
        let result = try translated("  the pantry chores ", on: h)
        let query = try require(try? result.get())
        expectEqual(query.query, #"chore"Pantry""#)
        expectEqual(query.answers, [#"chore"Pantry""#])
        expectEqual(query.inputTokens, 700)
        expectEqual(query.outputTokens, 9)
        expect(!query.repaired)
        expectEqual(model.requests.count, 1)
        expectEqual(h.scheduler.pendingCount, 0, "the deadline and the mark go with it")
        expectEqual(try require(h.editor.queries).liveSnapshots, 0)
        let text = message(try require(model.requests.first))
        expect(text.contains("<question>\nthe pantry chores\n</question>"), "the words, trimmed")
    },

    test("a canonical form is what's returned, whatever was written") {
        let model = ScriptedLanguageModel(answers: ["chore[status='todo']"])
        let h = try translateHarness(model)
        let query = try require(try? translated("todo", on: h).get())
        expectEqual(query.query, try require(h.editor.queries).check("chore[status='todo']").canonical)
        expect(query.query != "chore[status='todo']", "not as written: \(query.query)")
    },

    test("a wrong title is repaired, never returned: the second try is told the refusal") {
        let model = ScriptedLanguageModel(answers: [#""Pantri""#, #""Pantry""#])
        let h = try translateHarness(model)
        let query = try require(try? translated("the pantry", on: h).get())
        expectEqual(query.query, #""Pantry""#)
        expect(query.repaired)
        expectEqual(query.answers, [#""Pantri""#, #""Pantry""#])
        expectEqual(model.requests.count, 2)
        let second = try require(model.requests.last)
        expect(second.messages.count == 3, "the request, the first answer, the error")
        expect((second.messages.last?.text ?? "").contains("unknown_title"), "the refusal is the error block")
    },

    test("a title wrong twice is an unusable answer holding the last query and the engine's refusal") {
        let model = ScriptedLanguageModel(answers: [#""Pantri""#, #""Pantrie""#])
        let h = try translateHarness(model)
        guard case .failure(.unusable(_, let query, let refusal?)) = try translated("the pantry", on: h) else { return expect(false, "refused") }
        expectEqual(query, #""Pantrie""#)
        expectEqual(refusal.reason, .unknownTitle)
        expectEqual(model.requests.count, 2)
    },

    test("a query the check refuses is repaired too") {
        let model = ScriptedLanguageModel(answers: ["chore[nope=1]", "chore"])
        let h = try translateHarness(model)
        let query = try require(try? translated("chores", on: h).get())
        expect(query.repaired)
        expectEqual(query.query, "chore")
    },

    test("in a reference's context a word that reads the editor is refused, naming it, and repaired; for a person it's fine") {
        let model = ScriptedLanguageModel(answers: ["chore:picked", "chore"])
        let h = try translateHarness(model)
        let query = try require(try? translated("what's picked", on: h).get())
        expectEqual(query.query, "chore")
        expect(query.repaired)
        let error = try require(model.requests.last?.messages.last?.text)
        expect(error.contains(QueryTranslator.cantBeUsed(":picked")), "the one message the reference's own gate says: \(error)")

        let twice = ScriptedLanguageModel(answers: ["chore:picked", ":picked"])
        let again = try translateHarness(twice)
        guard case .failure(.unusable(_, let last, let refusal?)) = try translated("what's picked", on: again) else { return expect(false, "refused twice") }
        expectEqual(last, ":picked")
        expectEqual(refusal.message, QueryTranslator.cantBeUsed(":picked"))

        let person = ScriptedLanguageModel(answers: ["chore:picked"])
        let there = try translateHarness(person)
        let ok = try require(try? translated("what's picked", on: there, about: .person).get())
        expectEqual(ok.query, "chore:picked")
        expect(!ok.repaired)
    },

    test("a reference's context leaves the selection out of <board>, and every word that reads the editor out of <vocabulary>, and adds the rule line") {
        let reference = ScriptedLanguageModel(answers: ["chore"])
        let h = try translateHarness(reference)
        _ = try translated("chores", on: h)
        let sent = try require(reference.requests.first)
        let text = message(sent)
        expect(!text.contains("Selected"), "no selection: \(text)")
        expect(text.contains("<board>\nThe person is looking at the top board.\n</board>"))
        expect(!text.contains(":picked"), "no word that reads the editor")
        expect(sent.system?.hasSuffix(referenceRule) == true, "the rule line")

        let person = ScriptedLanguageModel(answers: ["chore"])
        let there = try translateHarness(person)
        _ = try translated("chores", on: there, about: .person)
        let asked = try require(person.requests.first)
        let said = message(asked)
        expect(said.contains("Selected: \"Pantry\" (chore)."), "the selection: \(said)")
        expect(said.contains(":picked"), "the word that reads the editor")
        expectEqual(asked.system, systemPrompt, "no rule line")
        expectEqual(sent.model, asked.model, "the same model and settings")
        expectEqual(sent.maxTokens, asked.maxTokens)
    },

    test("the language's own words are the gate's too, and a stored query's names are the file's") {
        let model = ScriptedLanguageModel(answers: ["chore:current-board", "chore"])
        let h = try translateHarness(model)
        let query = try require(try? translated("here", on: h).get())
        expect(query.repaired)
        expectEqual(query.query, "chore")
    },

    test("each failure is `ask`'s: no key, unanswerable, declined, cut off") {
        let cases: [(Result<ModelResponse, LanguageModelError>, QueryTranslationError)] = [
            (.failure(.noKey), .model(.noKey, timedOut: false)),
            (.failure(.unauthorized), .model(.unauthorized, timedOut: false)),
            (.failure(.rateLimited), .model(.rateLimited, timedOut: false)),
            (.success(ModelResponse(text: "UNANSWERABLE: where shapes sit")), .unanswerable("where shapes sit")),
            (.success(ModelResponse(text: "chore", stopReason: .refusal)), .declined),
        ]
        for (answer, expected) in cases {
            let model = ScriptedLanguageModel()
            switch answer {
            case .success(let response): model.queue(response)
            case .failure(let error): model.queue(error)
            }
            let h = try translateHarness(model)
            guard case .failure(let error) = try translated("chores", on: h) else { return expect(false, "answered") }
            expectEqual(error, expected)
            expectEqual(h.scheduler.pendingCount, 0)
        }
    },

    test("no model and no queries") {
        let h = try translateHarness(nil)
        guard case .failure(let none) = try translated("chores", on: h) else { return expect(false, "answered") }
        expectEqual(none, .noModel)
        let bare = try translateHarness(ScriptedLanguageModel(), queries: false)
        guard case .failure(let nothing) = try translated("chores", on: bare) else { return expect(false, "answered") }
        expectEqual(nothing, .noQueries)
    },

    test("the 40 s mark: a refusal before it is sent back; one after it is the answer's end") {
        for (wait, tries) in [(39_999, 2), (40_000, 1)] {
            let model = ScriptedLanguageModel()
            model.holdsAnswers = true
            model.queue(#""Pantri""#)
            model.queue(#""Pantry""#)
            let h = try translateHarness(model)
            let box = ResultBox()
            let translator = try require(h.editor.queryTranslator)
            let task = Task { @MainActor in
                do throws(QueryTranslationError) { box.result = .success(try await translator.translate("pantry", about: .reference)) } catch { box.result = .failure(error) }
            }
            spinRunLoop(until: { model.waiting == 1 })
            h.wait(wait)
            model.release()
            if tries == 2 {
                spinRunLoop(until: { model.waiting == 1 && model.requests.count == 2 })
                model.release()
            }
            spinRunLoop(until: { box.result != nil })
            expectEqual(model.requests.count, tries, "after \(wait) ms")
            if tries == 2 { expect((try? box.result?.get()) != nil, "repaired") } else {
                guard case .failure(.unusable(_, _, let refusal?))? = box.result else { return expect(false, "\(String(describing: box.result))") }
                expectEqual(refusal.reason, .unknownTitle)
            }
            expectEqual(h.scheduler.pendingCount, 0)
            _ = task
        }
    },

    test("the 55 s deadline in a model call is a timeout, and nothing is left armed") {
        let model = ScriptedLanguageModel()
        model.holdsAnswers = true
        model.queue("chore")
        let h = try translateHarness(model)
        let box = ResultBox()
        let translator = try require(h.editor.queryTranslator)
        let task = Task { @MainActor in
            do throws(QueryTranslationError) { box.result = .success(try await translator.translate("chores", about: .reference)) } catch { box.result = .failure(error) }
        }
        spinRunLoop(until: { model.waiting == 1 })
        h.wait(55_000)
        spinRunLoop(until: { box.result != nil })
        guard case .failure(let error)? = box.result else { return expect(false, "answered") }
        expectEqual(error, .model(.timedOut, timedOut: true))
        expectEqual(h.scheduler.pendingCount, 0)
        _ = task
    },

    test("a question in flight doesn't keep its editor alive: the file closes under a held call, and cancelling the caller ends it, nothing left armed") {
        // Each call, and how it ended: nil when it answered.
        let calls: [(String, @MainActor (QueryTranslator) async -> QueryTranslationError?)] = [
            ("translate", { translator in
                do throws(QueryTranslationError) { _ = try await translator.translate("chores", about: .reference); return nil } catch { return error }
            }),
            ("ask", { translator in
                do throws(QueryTranslationError) { _ = try await translator.ask("chores"); return nil } catch { return error }
            }),
        ]
        for (name, call) in calls {
            let model = ScriptedLanguageModel()
            model.holdsAnswers = true
            model.queue("chore")
            var h: EditorHarness? = try translateHarness(model)
            let scheduler = try require(h?.scheduler)
            weak var closing = h?.editor
            let translator = try require(h?.editor.queryTranslator)
            let ended = Ended()
            let task = Task { @MainActor in
                ended.error = await call(translator)
                ended.done = true
            }
            spinRunLoop(until: { model.waiting == 1 })
            h = nil
            expect(closing == nil, "\(name): a call out leaves the editor to go with its file")
            task.cancel()
            spinRunLoop(until: { ended.done })
            expectEqual(ended.error, .cancelled, name)
            expectEqual(model.waiting, 0, name)
            expectEqual(scheduler.pendingCount, 0, "\(name): nothing left armed")
        }
    },

    test("cancelling the task cancels the call: `cancelled`, and nothing left armed") {
        let model = ScriptedLanguageModel()
        model.holdsAnswers = true
        model.queue("chore")
        let h = try translateHarness(model)
        let box = ResultBox()
        let translator = try require(h.editor.queryTranslator)
        let task = Task { @MainActor in
            do throws(QueryTranslationError) { box.result = .success(try await translator.translate("chores", about: .reference)) } catch { box.result = .failure(error) }
        }
        spinRunLoop(until: { model.waiting == 1 })
        task.cancel()
        spinRunLoop(until: { box.result != nil })
        guard case .failure(let error)? = box.result else { return expect(false, "answered") }
        expectEqual(error, .cancelled)
        expectEqual(h.scheduler.pendingCount, 0)
    },
])

/// How a call that returns nothing ended.
@MainActor final class Ended {
    var error: QueryTranslationError?
    var done = false
}

@MainActor final class ResultBox {
    var result: Result<TranslatedQuery, QueryTranslationError>?
}
