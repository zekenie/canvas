import Automation
import Canvas
import CanvasRPC
import CanvasTesting
import Foundation
import LanguageModels
import Queries
import QueryCommands
import QueryLanguage
import TestKit

// `--ask` end to end, with a scripted model: the answer and what it says it asked; a query refused
// twice; each of the model's failures as the command line reports it; no model; the command's 55 s
// deadline in a model call (a timeout) and in a query run (too slow), and the 40 s mark past which
// a refusal isn't sent back, both on the editor's scheduler; and the caller's cancellation while
// the model's answer is held.

/// Why an `--ask` was refused, with `model` answering `answer` (a failure, or a response).
@MainActor func askRefusal(_ answer: Result<ModelResponse, LanguageModelError>, file: StaticString = #fileID, line: UInt = #line) throws -> RPCError {
    let model = ScriptedLanguageModel()
    switch answer {
    case .success(let response): model.queue(response)
    case .failure(let error): model.queue(error)
    }
    let h = try askHarness(model)
    let error = try refused(["query", "--ask", "which chores?"], on: h, file: file, line: line)
    expectEqual(h.scheduler.pendingCount, 0, "the deadline and the mark go with the command", file: file, line: line)
    return error
}

@MainActor let askTests = Suite("--ask", [
    test("the answer to the query the model wrote, the question it asked, and nothing left armed") {
        let model = ScriptedLanguageModel()
        model.queue(ModelResponse(text: "```\n\"Pantry\" chore\n```", inputTokens: 900, outputTokens: 12))
        let h = try askHarness(model)
        let json = try answered(["query", "--ask", "chores in the pantry", "--limit", "2"], on: h)
        expectEqual(json["query"], #""Pantry" chore"#)
        expectEqual(json["asked"], "chores in the pantry")
        expectEqual(json["count"], 3)
        expectEqual(rowIDs(json), [uuid(11), uuid(21)])
        expectEqual(json["warnings"]?.arrayValue?.map { $0["reason"] }, ["limited"])
        expectEqual(h.scheduler.pendingCount, 0)

        model.queue(#""Pantry" chore"#)
        let counted = try answered(["query", "--ask", "-", "--count"], on: h, input: "how many chores in the pantry?\n")
        expectEqual(counted, ["board": ["shows": "root", "showsPath": ["root"]], "query": #""Pantry" chore"#, "asked": "how many chores in the pantry?",
                              "count": 3])
        let error = try refused(["query", "--ask", "chores", "--brief", "--fields", "note"], on: h)
        expectEqual(error.reason, "invalid_params")
    },
    test("QueryAsking answers with what the model wrote each time, and the tokens") {
        let model = ScriptedLanguageModel()
        model.queue(ModelResponse(text: "chore:nope", inputTokens: 1_000, outputTokens: 5))
        model.queue(ModelResponse(text: "chore:top-level", inputTokens: 1_100, outputTokens: 6))
        let h = try askHarness(model)
        let asking = QueryAsking(system: systemPrompt)
        let editor = h.editor
        let outcome = try awaitResult { () async throws -> AskOutcome in try await asking.ask("top chores", in: editor) }
        expectEqual(outcome.answers, ["chore:nope", "chore:top-level"])
        expectEqual(outcome.inputTokens, 2_100)
        expectEqual(outcome.outputTokens, 11)
        expect(outcome.isRepaired)
        expectEqual(outcome.question, "top chores")
        expectEqual(outcome.result.rows.map(\.id), [id(1)])

        // Reasoning, then the query: what it wrote is all of it, and the query what it read.
        let reasoned = ScriptedLanguageModel(answers: ["```\nThe question is about what's on top.\n\nchore:top-level\n```"])
        let second = try askHarness(reasoned)
        let secondEditor = second.editor
        let read = try awaitResult { () async throws -> AskOutcome in try await asking.ask("top chores", in: secondEditor) }
        expectEqual(read.answers, ["The question is about what's on top.\n\nchore:top-level"])
        expectEqual(read.result.query, "chore:top-level")
        expect(!read.isRepaired)
    },
    test("refused twice: an unusable answer, where in the last query, which it holds") {
        let model = ScriptedLanguageModel(answers: ["chore:nope", "  chore[capton=1]"])
        let h = try askHarness(model)
        let error = try refused(["query", "--ask", "which chores?"], on: h)
        expectEqual(model.requests.count, 2)
        expectEqual(error.reason, "unusable_answer")
        expectEqual(error.hint, "Ask more specifically, or write the query yourself.")
        expectEqual(error.data?["query"], "chore[capton=1]")
        let problem = try require(checked("chore[capton=1]", on: h))
        expectEqual(error.message, "Claude's query didn't work: " + ([problem.message] + (problem.hint.map { [$0] } ?? [])).joined(separator: " "))
        let span = try require(problem.span)
        expectEqual(error.data?["line"], 1)
        expectEqual(error.data?["column"], .number(Double(span.offset + 1)))
        expectEqual(error.data?["length"], .number(Double(span.length)))
        expectEqual(error.data?["statement"], "chore[capton=1]")

        let twice = ScriptedLanguageModel(answers: ["One.\nTwo.", "Three.\nFour."])
        let second = try refused(["query", "--ask", "which chores?"], on: try askHarness(twice))
        expectEqual(second.reason, "unusable_answer")
        expectEqual(second.message, "Claude's query didn't work: it wrote several lines, and the last isn't a query.")
        expectEqual(second.data?["query"], "Three.\nFour.")
        expectEqual(second.data?["line"], nil)
    },
    test("each of the model's answers and failures as the command line reports it") {
        let keyHint = "Save an Anthropic API key in Infinite Canvas › Settings… (⌘,), or write the query yourself: the canvas skill's query-prompt.md."
        let transient = "Try again in a moment, or write the query yourself."
        let cases: [(Result<ModelResponse, LanguageModelError>, reason: String, message: String, hint: String?, isTransient: Bool?)] = [
            (.failure(.noKey), "no_key", "No API key", keyHint, nil),
            (.failure(.unauthorized), "key_rejected", "API key rejected", keyHint, nil),
            (.failure(.rateLimited), "model_failed", "Rate limited", transient, true),
            (.failure(.overloaded), "model_failed", "Anthropic overloaded", transient, true),
            (.failure(.server(status: 500, message: "")), "model_failed", "Anthropic error 500", transient, true),
            (.failure(.server(status: 400, message: "Your credit balance is too low. Buy more.")), "model_failed",
             "Your credit balance is too low", "Write the query yourself.", false),
            (.failure(.network("The Internet connection appears to be offline.")), "model_failed", "Can’t reach Anthropic", transient, true),
            (.failure(.timedOut), "model_failed", "Timed out", transient, true),
            (.failure(.malformedResponse), "model_failed", "Unusable answer", "Write the query yourself.", false),
            (.success(ModelResponse(text: "chore", stopReason: .refusal)), "declined", "Claude declined", nil, nil),
            (.success(ModelResponse(text: "UNANSWERABLE: where shapes sit isn't in the language")), "unanswerable",
             "A query can't ask that: where shapes sit isn't in the language.",
             "Queries find shapes by what they are, what's inside what and what connects to what; not where they are, how they look, or sums.", nil),
            (.success(ModelResponse(text: "UNANSWERABLE")), "unanswerable", "A query can't ask that.",
             "Queries find shapes by what they are, what's inside what and what connects to what; not where they are, how they look, or sums.", nil),
            (.success(ModelResponse(text: "chore", stopReason: .maxTokens)), "unusable_answer", "Claude's query didn't work: its answer was cut off.",
             "Ask more specifically, or write the query yourself.", nil),
            (.success(ModelResponse(text: "")), "unusable_answer", "Claude's query didn't work: it answered nothing.",
             "Ask more specifically, or write the query yourself.", nil),
        ]
        for (answer, reason, message, hint, isTransient) in cases {
            let error = try askRefusal(answer)
            expectEqual(error.reason, reason, message)
            expectEqual(error.message, message)
            expectEqual(error.hint, hint, message)
            expectEqual(error.code, RPCError.failed, message)
            expectEqual(error.data?["transient"], isTransient.map(JSON.bool), message)
        }
    },
    test("no model: no_model, and a query written out still runs") {
        let h = try shelfHarness(commandPlugins(model: nil))
        let error = try refused(["query", "--ask", "which chores?"], on: h)
        expectEqual(error.reason, "no_model")
        expectEqual(error.message, "This app has no language model.")
        expectEqual(error.hint, "Write the query yourself: the canvas skill's query-prompt.md is the guidance the app gives Claude.")
        expectEqual(try answered(["query", "--count", "chore"], on: h)["count"], 4)
    },
    test("the command's 55 s deadline, in a model call: the model timed out, which may work again") {
        let model = ScriptedLanguageModel()
        model.holdsAnswers = true
        model.queue("chore")
        let h = try askHarness(model)
        let pending = try start(["query", "--ask", "which chores?"], on: h)
        spinRunLoop(until: { model.waiting == 1 })
        h.wait(54_999)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        expect(pending.result == nil, "a millisecond short of it, still waiting")
        h.wait(1)
        let error = try refused(finish(pending))
        expectEqual(error.reason, "model_failed")
        expectEqual(error.message, "Timed out")
        expectEqual(error.hint, "Try again in a moment, or write the query yourself.")
        expectEqual(error.data?["transient"], true)
        expectEqual(model.waiting, 0)
        expectEqual(h.scheduler.pendingCount, 0)
        expectEqual(model.queued.count, 1, "the answer held was never given")
    },
    test("the command's 55 s deadline, in a query run: too slow, the query stopped") {
        let model = ScriptedLanguageModel()
        model.holdsAnswers = true
        let desk = Desk()
        let h = try askHarness(model, desk: desk)
        let pending = try start(["query", "--ask", "the slow chores"], on: h)
        spinRunLoop(until: { model.waiting == 1 })
        h.wait(50_000)
        model.queue("chore:slow")
        // The first chore asked takes the command past its deadline (and not the query's own 8 s).
        desk.onSlow = { if desk.slowCalls == 1 { h.wait(5_000) } }
        model.release()
        let error = try refused(finish(pending))
        expectEqual(error.reason, "too_slow")
        expectEqual(error.message, "Answering the question took more than 55 seconds.")
        expectEqual(error.hint, "Ask again, or write the query yourself.")
        expect(desk.slowCalls < 4, "it stopped: \(desk.slowCalls) asked")
        expectEqual(h.scheduler.pendingCount, 0)
        expectEqual(try require(h.editor.queries).liveSnapshots, 0)
    },
    test("the 40 s mark: a refusal before it is sent back for a second try; one after it is the answer's end") {
        for (wait, tries) in [(39_999, 2), (40_000, 1)] {
            let model = ScriptedLanguageModel()
            model.holdsAnswers = true
            model.queue("chore:nope")
            model.queue("chore:top-level")
            let h = try askHarness(model)
            let pending = try start(["query", "--ask", "top chores"], on: h)
            spinRunLoop(until: { model.waiting == 1 })
            h.wait(wait)
            model.release()
            if tries == 2 {
                spinRunLoop(until: { model.waiting == 1 && model.requests.count == 2 })
                model.release()
            }
            let result = try finish(pending)
            expectEqual(model.requests.count, tries, "\(wait) ms")
            if tries == 2 {
                expectEqual(rowIDs(try result.get()), [uuid(1)])
            } else {
                let error = try refused(result)
                expectEqual(error.reason, "unusable_answer")
                expectEqual(error.data?["query"], "chore:nope")
            }
            expectEqual(h.scheduler.pendingCount, 0)
        }
    },
    test("the 40 s mark counts when the query is refused, not when it was written: one refused past it isn't sent back") {
        let model = ScriptedLanguageModel()
        model.holdsAnswers = true
        model.queue("chore:slow")
        model.queue("chore:top-level")
        let desk = Desk()
        let h = try askHarness(model, desk: desk)
        let pending = try start(["query", "--ask", "the slow chores"], on: h)
        spinRunLoop(until: { model.waiting == 1 })
        h.wait(35_000)
        // Written at 35 s; its run takes it past the query's own 8 s, refused at 43 s.
        desk.onSlow = { if desk.slowCalls == 1 { h.wait(8_000) } }
        model.release()
        spinRunLoop(until: { pending.result != nil || model.waiting == 1 })
        expectEqual(model.requests.count, 1, "no second try past the mark")
        model.release()
        let error = try refused(finish(pending))
        expectEqual(error.reason, "unusable_answer")
        expectEqual(error.data?["query"], "chore:slow")
        expectEqual(h.scheduler.pendingCount, 0)
    },
    test("the command's 55 s deadline, in the request's assembly: too slow, and the model never asked") {
        let model = ScriptedLanguageModel(answers: ["chore"])
        let desk = Desk()
        let h = try askHarness(model, desk: desk)
        // Where the person is is the first thing read; saying what's picked takes the command past its deadline.
        desk.onPicked = { h.wait(55_000) }
        let error = try refused(["query", "--ask", "which chores?"], on: h)
        expectEqual(error.reason, "too_slow")
        expectEqual(error.message, "Answering the question took more than 55 seconds.")
        expectEqual(model.requests.count, 0)
        expectEqual(h.scheduler.pendingCount, 0)
        expectEqual(try require(h.editor.queries).liveSnapshots, 0)
    },
    test("cancelled while the model's answer is held: the call stops, and nothing is left armed") {
        let model = ScriptedLanguageModel()
        model.holdsAnswers = true
        model.queue("chore")
        let h = try askHarness(model)
        let pending = try start(["query", "--ask", "which chores?"], on: h)
        spinRunLoop(until: { model.waiting == 1 })
        pending.task?.cancel()
        let error = try refused(finish(pending))
        expectEqual(error.reason, "cancelled")
        expectEqual(model.waiting, 0)
        expectEqual(model.requests.count, 1)
        expectEqual(h.scheduler.pendingCount, 0)
        expectEqual(try require(h.editor.queries).liveSnapshots, 0)
    },
])
