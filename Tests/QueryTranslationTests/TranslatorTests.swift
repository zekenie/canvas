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

// The translator on its own, with fixture chores and a scripted model: what it answers with and
// what it asked, the model's failures by reason, no model, no queries, and nothing left armed.

let systemPrompt = "You write one query."
let referenceRule = "The query is stored and run later."

@MainActor func translatorHarness(_ model: ScriptedLanguageModel?, queries: Bool = true, style: AskStyle = .shipped) throws -> EditorHarness {
    var plugins: [any CanvasPlugin] = [ChoresPlugin(), TopologyPlugin()]
    if queries { plugins.append(QueriesPlugin()) }
    if let model { plugins.append(LanguageModelsPlugin(model: model)) }
    plugins.append(QueryTranslationPlugin(prompt: systemPrompt, referenceRule: referenceRule, style: style))
    let shapes = (1...3).map { _ in AnyShapeRecord(ShapeRecord(id: ShapeID(), Chore(CGRect(x: 0, y: 0, width: 100, height: 60)))) }
    return try EditorHarness(plugins: plugins, document: CanvasDocument(shapes: shapes))
}

/// Why a question was refused, with `model` answering `answer`.
@MainActor func translationFailure(_ answer: Result<ModelResponse, LanguageModelError>) throws -> QueryTranslationError {
    let model = ScriptedLanguageModel()
    switch answer {
    case .success(let response): model.queue(response)
    case .failure(let error): model.queue(error)
    }
    let h = try translatorHarness(model)
    let translator = try require(h.editor.queryTranslator)
    let result = try awaitResult { () async -> Result<AskOutcome, QueryTranslationError> in
        do throws(QueryTranslationError) { return .success(try await translator.ask("which chores?")) } catch { return .failure(error) }
    }
    expectEqual(h.scheduler.pendingCount, 0, "the deadline and the mark go with the question")
    guard case .failure(let error) = result else {
        expect(false, "answered")
        throw RequireFailed()
    }
    return error
}

@MainActor let translatorTests = Suite("The translator", [
    test("answers with what the model wrote each time, and the tokens, a refused first query asked again") {
        let model = ScriptedLanguageModel()
        model.queue(ModelResponse(text: "chore:nope", inputTokens: 1_000, outputTokens: 5))
        model.queue(ModelResponse(text: "chore:top-level", inputTokens: 1_100, outputTokens: 6))
        let h = try translatorHarness(model)
        let translator = try require(h.editor.queryTranslator)
        expectEqual(translator.system, systemPrompt)
        expectEqual(translator.style, .shipped)
        let outcome = try awaitResult { () async throws -> AskOutcome in try await translator.ask("  top chores\n") }
        expectEqual(outcome.question, "top chores")
        expectEqual(outcome.answers, ["chore:nope", "chore:top-level"])
        expectEqual(outcome.inputTokens, 2_100)
        expectEqual(outcome.outputTokens, 11)
        expect(outcome.isRepaired)
        expectEqual(outcome.result.count, 3)
        expectEqual(h.scheduler.pendingCount, 0)
        expectEqual(model.requests.count, 2)
        expectEqual(model.requests.first?.system, systemPrompt)
    },
    test("reasoning, then the query: what it wrote is all of it, and the query what it read") {
        let model = ScriptedLanguageModel(answers: ["```\nThe question is about what's on top.\n\nchore:top-level\n```"])
        let h = try translatorHarness(model)
        let translator = try require(h.editor.queryTranslator)
        let read = try awaitResult { () async throws -> AskOutcome in try await translator.ask("top chores", limit: 2, countOnly: true) }
        expectEqual(read.answers, ["The question is about what's on top.\n\nchore:top-level"])
        expectEqual(read.result.query, "chore:top-level")
        expectEqual(read.result.count, 3)
        expect(read.result.rows.isEmpty, "counted only")
        expect(!read.isRepaired)
    },
    test("each failure, by reason and message") {
        let cases: [(Result<ModelResponse, LanguageModelError>, QueryTranslationError, reason: String, message: String)] = [
            (.failure(.noKey), .model(.noKey, timedOut: false), "no_key", "No API key"),
            (.failure(.unauthorized), .model(.unauthorized, timedOut: false), "key_rejected", "API key rejected"),
            (.failure(.rateLimited), .model(.rateLimited, timedOut: false), "model_failed", "Rate limited"),
            (.failure(.cancelled), .cancelled, "cancelled", "The command was cancelled."),
            (.success(ModelResponse(text: "chore", stopReason: .refusal)), .declined, "declined", "Claude declined"),
            (.success(ModelResponse(text: "UNANSWERABLE: where shapes sit")), .unanswerable("where shapes sit"), "unanswerable",
             "A query can't ask that: where shapes sit."),
            (.success(ModelResponse(text: "UNANSWERABLE")), .unanswerable(""), "unanswerable", "A query can't ask that."),
            (.success(ModelResponse(text: "chore", stopReason: .maxTokens)), .unusable("its answer was cut off.", query: "chore", refusal: nil),
             "unusable_answer", "Claude's query didn't work: its answer was cut off."),
        ]
        for (answer, error, reason, message) in cases {
            let failure = try translationFailure(answer)
            expectEqual(failure, error, message)
            expectEqual(failure.reason, reason, message)
            expectEqual(failure.message, message)
        }
    },
    test("refused twice: an unusable answer holding the last query and the engine's refusal") {
        let model = ScriptedLanguageModel(answers: ["chore:nope", "chore[capton=1]"])
        let h = try translatorHarness(model)
        let translator = try require(h.editor.queryTranslator)
        let result = try awaitResult { () async -> Result<AskOutcome, QueryTranslationError> in
            do throws(QueryTranslationError) { return .success(try await translator.ask("which chores?")) } catch { return .failure(error) }
        }
        guard case .failure(.unusable(_, let query, let refusal?)) = result else { return expect(false, "\(result)") }
        expectEqual(query, "chore[capton=1]")
        expectEqual(refusal.reason, .unknownAttribute)
        expectEqual(model.requests.count, 2)
    },
    test("no model, no queries, no translator") {
        let h = try translatorHarness(nil)
        let translator = try require(h.editor.queryTranslator)
        let result = try awaitResult { () async -> QueryTranslationError? in
            do throws(QueryTranslationError) { _ = try await translator.ask("which chores?"); return nil } catch { return error }
        }
        expectEqual(result, .noModel)
        expectEqual(result?.reason, "no_model")

        let bare = try translatorHarness(ScriptedLanguageModel(), queries: false)
        let second = try require(bare.editor.queryTranslator)
        let none = try awaitResult { () async -> QueryTranslationError? in
            do throws(QueryTranslationError) { _ = try await second.ask("which chores?"); return nil } catch { return error }
        }
        expectEqual(none, .noQueries)
        expectEqual(none?.reason, "no_queries")

        let without = try EditorHarness(plugins: [ChoresPlugin(), TopologyPlugin()])
        expect(without.editor.queryTranslator == nil)
    },
    test("the 55 s deadline in a model call is a timeout, and nothing is left armed") {
        let model = ScriptedLanguageModel()
        model.holdsAnswers = true
        model.queue("chore")
        let h = try translatorHarness(model)
        let translator = try require(h.editor.queryTranslator)
        let box = Box()
        let task = Task { @MainActor in
            do throws(QueryTranslationError) { _ = try await translator.ask("which chores?") } catch { box.error = error }
            box.done = true
        }
        spinRunLoop(until: { model.waiting == 1 })
        h.wait(55_000)
        spinRunLoop(until: { box.done })
        expectEqual(box.error, .model(.timedOut, timedOut: true))
        expectEqual(h.scheduler.pendingCount, 0)
        _ = task
    },
])

@MainActor final class Box {
    var error: QueryTranslationError?
    var done = false
}
