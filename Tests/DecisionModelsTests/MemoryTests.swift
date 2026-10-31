import Canvas
import CanvasRPC
import CanvasTesting
import DecisionModels
import Foundation
import TestKit

/// A day a test says: what `DecisionMemory` dates its answers by.
final class Day: @unchecked Sendable {
    var today = "2026-10-29"
}

@MainActor let memoryTests = Suite("Answers kept", [
    test("the same request of the same model is answered from memory; another request, or another model, isn't") {
        let memory = DecisionMemory(url: nil)
        let jev = JevModel(keys: TypeSafeKeyStore(url: URL(fileURLWithPath: "/dev/null")))
        memory.keep(DecisionAnswers(model: "jev-1.14.0", yes: ["all": 0.9]), to: carRequest, from: jev)
        expectEqual(memory.answers(to: carRequest, from: jev), DecisionAnswers(model: "jev-1.14.0", yes: ["all": 0.9]))
        var other = carRequest
        other.state = ["shape": ["title": "1991 Mercedes-Benz 300D"]]
        expectEqual(memory.answers(to: other, from: jev), nil, "another state")
        var reworded = carRequest
        reworded.questions[0].asks = "Does it meet them?"
        expectEqual(memory.answers(to: reworded, from: jev), nil, "another question")
        expectEqual(memory.answers(to: carRequest, from: ScriptedDecisionModel()), nil, "another model")
    },
    test("an answer is kept the day it was given: the next day it's gone, and keeping another lets go of it") {
        let day = Day()
        let directory = FileManager.default.temporaryDirectory.appending(path: "MemoryTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "decision-answers.json", directoryHint: .notDirectory)
        let model = ScriptedDecisionModel()
        let memory = DecisionMemory(url: url, today: { day.today })
        memory.keep(DecisionAnswers(model: "scripted", yes: ["all": 0.2]), to: carRequest, from: model)
        memory.save()
        let reopened = DecisionMemory(url: url, today: { day.today })
        expectEqual(reopened.answers(to: carRequest, from: model)?.yes, ["all": 0.2], "read back from its file")
        day.today = "2026-10-30"
        expectEqual(reopened.answers(to: carRequest, from: model), nil, "kept a day")
        var other = carRequest
        other.preface = nil
        reopened.keep(DecisionAnswers(model: "scripted", yes: ["all": 1]), to: other, from: model)
        reopened.save()
        day.today = "2026-10-29"
        expectEqual(DecisionMemory(url: url, today: { day.today }).answers(to: carRequest, from: model), nil, "let go when the next was kept")
    },
    test("a memory with no file writes none") {
        let memory = DecisionMemory(url: nil)
        memory.keep(DecisionAnswers(model: "scripted", yes: [:]), to: carRequest, from: ScriptedDecisionModel())
        memory.save()
        expectEqual(memory.url, nil)
    },
    test("an editor asks the model only what it hasn't answered today, and the plugin's own memory keeps nothing on disk") {
        let model = ScriptedDecisionModel()
        model.answerAll(0.8)
        let editor = CanvasEditor(registry: try Registry(plugins: [DecisionModelsPlugin(model: model)]), document: CanvasDocument(),
                                  scheduler: ManualScheduler())
        let decisions = try require(editor.decisions)
        expectEqual(decisions.memory.url, nil)
        expect(editor.decisionModel as? ScriptedDecisionModel === model)
        for _ in 0..<3 {
            let answers = try awaitResult { () async throws -> DecisionAnswers in try await decisions.decide(carRequest) }
            expectEqual(answers.yes, ["all": 0.8, "r0": 0.8])
        }
        expectEqual(model.requests.count, 1, "asked once")
        model.queue(.rateLimited)
        var other = carRequest
        other.preface = "Another."
        let failed = try awaitResult { () async -> DecisionModelError? in
            do throws(DecisionModelError) { _ = try await decisions.decide(other); return nil } catch { return error }
        }
        expectEqual(failed?.message, "Rate limited")
        expectEqual(model.requests.count, 2, "a failure is kept by nothing: asked again next time")
    },
])
