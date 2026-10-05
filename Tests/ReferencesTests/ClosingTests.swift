import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import LanguageModels
import Queries
import QueryTranslation
import References
import TestKit
import Titles
import Topology

// A file closed while references are asking: the editor goes, and what it had out stops with it. A
// model call in flight is cancelled (it would otherwise run on, up to a minute, spending the
// person's tokens on an answer nothing lands), and so are the batch, the waits and the draft's
// request. A scripted model holds the call, never the network; the editor is held only here, so
// letting go of it is the file closing.

/// The shipped Reference over boxes, with a translator whose model is `model`.
@MainActor private func closingHarness(_ model: ScriptedLanguageModel) throws -> EditorHarness {
    let h = try referenceHarness([LanguageModelsPlugin(model: model), QueryTranslationPlugin(prompt: "You write one query.", referenceRule: "Stored.")])
    h.addBox("Plan B", at: CGRect(x: 100, y: 2_000, width: 100, height: 60))
    h.addBox("Cellar", at: CGRect(x: 300, y: 2_000, width: 100, height: 60))
    return h
}

@MainActor private func spin(_ done: @autoclosure () -> Bool, file: StaticString = #fileID, line: UInt = #line) {
    _ = spinRunLoop(until: { done() }, file: file, line: line)
}

@MainActor let closingTests = Suite("A file closed while references ask", [
    test("a model call holding a translation is cancelled when the editor goes: its answer is never taken, and no timer is left") {
        let model = ScriptedLanguageModel(answers: ["box"])
        model.holdsAnswers = true
        var h: EditorHarness? = try closingHarness(model)
        let scheduler = try require(h?.scheduler)
        weak var closing = h?.editor
        let id = try require(h?.addReference(words: "blocked work"))
        try require(h?.editor.references).interpret(id)
        spin(model.waiting == 1)
        expect(scheduler.pendingCount > 0, "the call's deadline is armed")
        h = nil
        spin(model.waiting == 0 && scheduler.pendingCount == 0)
        expect(closing == nil, "the editor went as its file closed")
        expectEqual(model.waiting, 0, "the call isn't left holding")
        expectEqual(model.answered, 1, "the call ended: cancelled")
        expectEqual(model.queued.count, 1, "and took no answer")
        expectEqual(scheduler.pendingCount, 0, "its deadline went with it")
    },
    test("closing the editor with a batch out and a wait armed leaves nothing running: no timer, and the engine is let go of") {
        var h: EditorHarness? = try referenceHarness()
        let scheduler = try require(h?.scheduler)
        weak var closing = h?.editor
        weak var engine = h?.editor.queries
        h?.addBox("Alpha", at: CGRect(x: 100, y: 100, width: 100, height: 60))
        _ = try require(h?.addReference(query: "box"))
        h?.wait(0)                                                                       // the hop: asked, the batch is out
        expectEqual(try require(h?.editor.references).batchesAsked, 1)
        expect(try require(h?.editor.references).isFinding, "a batch is out")
        h?.addBox("Beta", at: CGRect(x: 250, y: 100, width: 100, height: 60))           // a commit: the wait for quiet, beside it
        expect(scheduler.pendingCount >= 2, "the wait and the finding timer are armed: \(scheduler.pendingCount)")
        h = nil
        expect(closing == nil, "the editor went as its file closed")
        expectEqual(scheduler.pendingCount, 0, "nothing left to fire")
        spin(engine == nil)
        expect(engine == nil, "the batch ended and let go of the engine")
    },
])
