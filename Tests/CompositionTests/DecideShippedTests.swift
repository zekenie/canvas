import AppKit
import Automation
import Canvas
import CanvasRPC
import CanvasTesting
import DecisionModels
import Draw
import Foundation
import LanguageModels
import ShippedTesting
import TestKit
import Titles

// `canvas decide` as shipped: one yes-or-no question of every shape a query finds, each asked with its state as a rule
// sees it, the rows highest yes first; nothing written, no step; the refusals in the command line's words.

/// Notes of a type drawn on a board, and a scripted model that answers by the title of the shape in each state.
@MainActor private func listings(_ yes: [String: Double]) throws -> (editor: CanvasEditor, decisions: ScriptedDecisionModel) {
    let decisions = ScriptedDecisionModel()
    decisions.fallback = { request in
        let title = request.state["shape"]?["title"]?.stringValue ?? ""
        return .success(DecisionAnswers(model: "scripted", yes: ["q": yes[title] ?? 0.5]))
    }
    let editor = ShippedPlugins.makeEditor(document: CanvasDocument(), scheduler: ManualScheduler(), model: ScriptedLanguageModel(), decisionModel: decisions)
    _ = try draw(script: """
        sticky-note "Listing" schema: "{\\"type\\": \\"object\\"}" text: "A car for sale."
        sticky-note "2010 Toyota Prius" is: "Listing" text: "New brakes and tires last month." right of "Listing"
        sticky-note "2019 Toyota Camry SE" is: "Listing" text: "Runs great." right of "2010 Toyota Prius"
        sticky-note "1972 Volkswagen Beetle" is: "Listing" text: "Engine rebuilt in 2020." right of "2019 Toyota Camry SE"
        """, dryRun: false, reveal: false, program: "test", in: editor)
    return (editor, decisions)
}

private extension Result {
    /// Why it failed, if it did.
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}

/// What `canvas decide` answers, or why it can't: run as the app's server runs it.
@MainActor private func decide(_ params: [String: JSON], in editor: CanvasEditor) throws -> Result<JSON, RPCError> {
    try awaitResult { () async -> Result<JSON, RPCError> in
        do throws(RPCError) {
            return .success(try await editor.registry.runAutomationCommand("decide", params: .object(params), editor: editor))
        } catch {
            return .failure(error)
        }
    }
}

@MainActor let decideShippedTests = Suite("canvas decide, shipped", [
    test("each shape the query finds is asked the question on its own, with its state, framed as the prototype framed it; the rows highest yes first; nothing written") {
        let (editor, decisions) = try listings(["2010 Toyota Prius": 0.99, "1972 Volkswagen Beetle": 0.98, "2019 Toyota Camry SE": 0.22])
        let file = editor.file
        let steps = editor.undoHistory.undoName
        let answer = try decide(["query": #":is-a("Listing")"#, "question": "Does the seller say what work was done on the car?"], in: editor).get()
        expectEqual(answer["query"], #":is-a("Listing")"#)
        expectEqual(answer["question"], "Does the seller say what work was done on the car?")
        expectEqual(answer["count"], 3)
        expectEqual(answer["model"], "scripted")
        expectEqual(answer["rows"]?.arrayValue?.compactMap { $0["title"]?.stringValue }, ["2010 Toyota Prius", "1972 Volkswagen Beetle", "2019 Toyota Camry SE"])
        expectEqual(answer["rows"]?.arrayValue?.compactMap { $0["yes"]?.numberValue }, [0.99, 0.98, 0.22])
        expect(answer["rows"]?.arrayValue?.allSatisfy { $0["id"]?.stringValue?.count == 36 } ?? false, "each row's id")
        let asked = try require(decisions.requests.first { $0.state["shape"]?["title"] == "2010 Toyota Prius" })
        expectEqual(asked.questions.map(\.asks), ["Judging from the state, does the seller say what work was done on the car?"])
        expectEqual(asked.state["shape"]?["words"], "New brakes and tires last month.", "the shape in full")
        expectEqual(asked.state["its types"]?.arrayValue?.first?["type"], "Listing", "and what's around it")
        expectEqual(decisions.requests.count, 3)
        expect(editor.file == file, "nothing written")
        expectEqual(editor.undoHistory.undoName, steps, "no step")
        _ = try decide(["query": #":is-a("Listing")"#, "question": "Does the seller say what work was done on the car?"], in: editor).get()
        expectEqual(decisions.requests.count, 3, "asked again the same day: answered from memory")
        _ = try decide(["query": #":is-a("Listing")"#, "question": "Toyota made it?"], in: editor).get()
        expectEqual(decisions.requests.last?.questions.first?.asks, "Judging from the state, Toyota made it?", "a name keeps its capital")
    },
    test("at most --limit shapes are asked about, the first the query finds, and a warning says how many it found") {
        let (editor, decisions) = try listings([:])
        let answer = try decide(["query": #":is-a("Listing")"#, "question": "Is it a Toyota?", "limit": 2], in: editor).get()
        expectEqual(answer["count"], 2)
        expectEqual(decisions.requests.count, 2)
        expectEqual(answer["warnings"]?.arrayValue?.first?["reason"], "limited")
        expectEqual(answer["warnings"]?.arrayValue?.first?["message"], "Asked about 2 of the 3 shapes the query found: --limit asks about more.")
    },
    test("refused: a query the engine can't read, where in it; a blank question; a model that wants a key, with where to save it") {
        let (editor, decisions) = try listings([:])
        let bad = try require(decide(["query": "sticky-note:glows", "question": "Is it a Toyota?"], in: editor).failure)
        expectEqual(bad.reason, "unknown_pseudo_class")
        expectEqual(bad.data?["column"], 12)
        let blank = try require(decide(["query": "sticky-note", "question": "  "], in: editor).failure)
        expectEqual(blank.reason, "invalid_params")
        decisions.fallback = { _ in .failure(DecisionModelError(.noKey, provider: "TypeSafe")) }
        let key = try require(decide(["query": #":is-a("Listing")"#, "question": "Is it a Toyota?"], in: editor).failure)
        expectEqual(key.reason, "no_key")
        expectEqual(key.message, "No TypeSafe key")
        expect(key.data?["hint"]?.stringValue?.contains("Settings") ?? false)
        let scope = try require(decide(["query": ":scope", "question": "Is it a Toyota?"], in: editor).failure)
        expectEqual(scope.reason, "unsupported", "a query of its own is bound to no shape")
    },
])
