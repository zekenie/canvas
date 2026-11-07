import Canvas
import CanvasTesting
import DecisionModels
import Foundation
import LanguageModels
import TestKit

@MainActor let scriptedDecisionTests = Suite("The scripted decision model", [
    test("keeps every request and answers from its queue, in order, then its fallback, then fails") {
        let model = ScriptedDecisionModel()
        model.queue(yes: ["all": 0.9])
        model.queue(.rateLimited)
        expectEqual(try require(try outcome(of: model).successValue).yes, ["all": 0.9])
        expectEqual(try require(try outcome(of: model).failureValue).message, "Rate limited")
        expectEqual(try require(try outcome(of: model).failureValue).failure, .server(status: 0, message: "ScriptedDecisionModel has no answer queued"))
        model.answerAll(0.2)
        expectEqual(try require(try outcome(of: model).successValue).yes, ["all": 0.2, "r0": 0.2])
        expectEqual(model.requests.count, 4)
        expectEqual(model.lastRequest, carRequest)
        expectEqual(model.answered, 4)
    },
    test("holds each call while it says, until released, and a held call cancelled ends cancelled") {
        let model = ScriptedDecisionModel()
        model.holdsAnswers = true
        model.queue(yes: ["all": 0.8])
        var result: Result<DecisionAnswers, DecisionModelError>?
        let call = Task {
            do throws(DecisionModelError) { result = .success(try await model.decide(carRequest)) } catch { result = .failure(error) }
        }
        spinRunLoop(until: { model.waiting == 1 })
        expect(result == nil, "held")
        model.release()
        spinRunLoop(until: { result != nil })
        expectEqual(result?.successValue?.yes, ["all": 0.8])
        _ = call
        var cancelled: Result<DecisionAnswers, DecisionModelError>?
        let held = Task {
            do throws(DecisionModelError) { cancelled = .success(try await model.decide(carRequest)) } catch { cancelled = .failure(error) }
        }
        spinRunLoop(until: { model.waiting == 1 })
        held.cancel()
        spinRunLoop(until: { cancelled != nil })
        expectEqual(cancelled?.failureValue?.failure, .cancelled)
        expectEqual(model.waiting, 0)
    },
])

@MainActor let cutoffTests = Suite("Cutoffs", [
    test("a yes at 0.7 and above, a no at 0.3 and below, unsure between: every model's, as the prototype's answers separated") {
        let cutoffs = DecisionCutoffs.standard
        expectEqual([0, 0.3, 0.31, 0.5, 0.69, 0.7, 1].map(cutoffs.verdict), [.no, .no, .unsure, .unsure, .unsure, .yes, .yes])
        expectEqual(JevModel().cutoffs, .standard)
        expectEqual(LanguageDecisionModel(model: ScriptedLanguageModel()).cutoffs, .standard)
        expectEqual(ScriptedDecisionModel(cutoffs: DecisionCutoffs(yes: 0.9, no: 0.1)).cutoffs.verdict(0.8), .unsure)
    },
])

@MainActor let pluginTests = Suite("The plugin", [
    test("lends its model to the editor; without it, the editor has none") {
        let model = ScriptedDecisionModel()
        let editor = CanvasEditor(registry: try Registry(plugins: [DecisionModelsPlugin(model: model)]))
        expect(editor.decisionModel as? ScriptedDecisionModel === model)
        expect(CanvasEditor(registry: try Registry(plugins: [])).decisionModel == nil)
    },
    test("its registry line") {
        expectEqual(try Registry(plugins: [DecisionModelsPlugin(model: ScriptedDecisionModel())]).report, """
        core             tool hand · command undo · command redo · command insertBeside first in InsertMenu.Shapes · command zoomIn in ViewMenu.Zoom · command zoomOut in ViewMenu.Zoom · command zoomToActualSize in ViewMenu.Zoom · command zoomToFit in ViewMenu.Zoom · command pageUp · command pageDown · command scrollToStart · command scrollToEnd
        decision-models  service Decisions
        """)
    },
    test("Jev brings the Settings pane that keeps its key; a model that needs none brings no pane") {
        try withTemporaryStore { keys in
            let registry = try Registry(plugins: [DecisionModelsPlugin(model: JevModel(keys: keys))])
            expectEqual(registry.settingsPanes.map(\.title), ["TypeSafe"])
            expect(registry.report.hasSuffix("service Decisions · settings pane TypeSafe"), registry.report)
        }
        expectEqual(try Registry(plugins: [DecisionModelsPlugin(model: ScriptedDecisionModel())]).settingsPanes.count, 0)
        expectEqual(try Registry(plugins: [DecisionModelsPlugin(model: LanguageDecisionModel(model: ScriptedLanguageModel()))]).settingsPanes.count, 0)
    },
])
