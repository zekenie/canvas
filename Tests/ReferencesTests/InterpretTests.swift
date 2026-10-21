import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import DetailPanel
import LanguageModels
import QueryTranslation
import References
import Selection
import TestKit
import Topology

// Words become a query by the model, with a scripted one and never the network: typed into a pill
// whose list has only the words row left, they rest 600 ms and then are asked; the answer is a draft
// the panel shows (the query, its status, its matches) and the document never has until the editing
// step writes it; a call that outlives editing lands as its own step, "Interpret". Every keystroke
// starts over; undo, redo, a file opened and a locked reference ask nothing and write nothing; a
// failure says what to do; a key saved in Settings asks again what wanted one.

/// The shipped Reference over boxes (two public ones far below, "Plan B" and "Cellar") and a translator
/// whose model is `model`, the words that read the editor (`:picked`) and a freezing plugin.
@MainActor private func interpretHarness(_ model: ScriptedLanguageModel, log: RefusalLog = RefusalLog(), file: CanvasFile = CanvasFile()) throws -> EditorHarness {
    let h = try referenceHarness([FreezingPlugin(log: log), pickedWord, LanguageModelsPlugin(model: model),
                                  QueryTranslationPlugin(prompt: "You write one query.", referenceRule: "Stored.")], file: file)
    h.addBox("Plan B", at: CGRect(x: 100, y: 2_000, width: 100, height: 60))
    h.addBox("Cellar", at: CGRect(x: 300, y: 2_000, width: 100, height: 60))
    return h
}

/// What the Query section says of the reference.
@MainActor private func content(_ h: EditorHarness, _ id: ShapeID) throws -> ReferenceQueryContent {
    try require(h.editor.references).queryContent(of: try require(h.reference(id)), id: id)
}

@MainActor private func header(_ h: EditorHarness, _ id: ShapeID) throws -> ReferenceHeaderContent {
    try require(h.editor.references).header(of: try require(h.reference(id)), id: id)
}

/// The sections the panel lays out for the reference, in its tab.
@MainActor private func sections(_ h: EditorHarness, _ id: ShapeID) throws -> [String] {
    let shown = try require(h.editor.detailPanel).layout(for: try require(h.editor.document[id]))
    return shown.sections(in: try require(shown.tabs.first)).map(\.section)
}

/// Lets the main run loop turn until `done`.
@MainActor private func spin(_ done: @autoclosure () -> Bool, file: StaticString = #fileID, line: UInt = #line) {
    _ = spinRunLoop(until: { done() }, file: file, line: line)
}

/// Turns the main run loop a little, so what would have come by now has: a task that should not have
/// run shows.
@MainActor private func breathe() {
    RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
}

/// Whether the reference's status is an answer.
@MainActor private func isAnswered(_ h: EditorHarness, _ id: ShapeID) -> Bool {
    if case .answered? = h.status(id) { true } else { false }
}

/// Types words nothing public matches into a new pill, and lets the 600 ms pass: the model has been asked.
@MainActor private func typeAndRest(_ h: EditorHarness, _ model: ScriptedLanguageModel, words: String = "blocked work") throws -> Field {
    let field = try h.placeReference()
    field.type(words)
    h.wait(600)
    spin(model.requests.count >= 1)
    return field
}

@MainActor let interpretTests = Suite("Interpreting words", [
    test("typed words nothing public matches rest 600 ms, then the model is asked; the pill is interpreting meanwhile") {
        let model = ScriptedLanguageModel(answers: ["box"])
        let h = try interpretHarness(model)
        let field = try h.placeReference()
        defer { field.close() }
        field.type("blocked work")
        expectEqual(field.titles, ["blocked work"], "only the words row is left")
        expectEqual(h.status(field.id), .interpreting)
        expectEqual(try content(h, field.id).status, ReferenceStatusLine(text: "Interpreting…", isWarning: false, isBusy: true, action: nil))
        expect(try content(h, field.id).isInterpreting, "the checkbox is disabled meanwhile")
        h.wait(599)
        breathe()
        expect(model.requests.isEmpty, "not yet: 599 ms")
        h.wait(1)
        spin(model.requests.count == 1)
        let request = try require(model.requests.first)
        expect(request.messages.first?.text.contains("<question>\nblocked work\n</question>") == true)
        expect(request.system?.hasSuffix("Stored.") == true, "the reference's rule line")
    },

    test("a keystroke starts the wait again, and cancels a call that's out: only the last words are asked, once rested") {
        let model = ScriptedLanguageModel(answers: ["box"])
        model.holdsAnswers = true
        let h = try interpretHarness(model)
        let field = try h.placeReference()
        defer { field.close() }
        field.type("blocked wor")
        h.wait(400)
        field.type("k")
        h.wait(400)
        breathe()
        expect(model.requests.isEmpty, "each keystroke waits 600 ms again")
        h.wait(200)
        spin(model.waiting == 1)
        field.type("s")
        expectEqual(h.status(field.id), .interpreting, "the call out is let go of, and the words rest again")
        spin(model.waiting == 0)
        model.release()
        breathe()
        expectEqual(model.requests.count, 1)
        expect(!isAnswered(h, field.id), "no draft from the cancelled call")
        expectEqual(try content(h, field.id).query, nil)
        h.wait(600)
        spin(model.requests.count == 2)
        expect(model.requests.last?.messages.first?.text.contains("blocked works") == true)
        model.release()
        spin(isAnswered(h, field.id))
    },

    test("the draft is shown in the panel as it arrives, the words, the query, its status and its matches, and is never in the document") {
        let model = ScriptedLanguageModel(answers: ["box"])
        let h = try interpretHarness(model)
        let field = try typeAndRest(h, model)
        defer { field.close() }
        spin(isAnswered(h, field.id))
        let props = try require(h.reference(field.id))
        expectEqual(props.words, "blocked work")
        expectEqual(props.query, nil, "the document never has a draft")
        expectEqual(try header(h, field.id), ReferenceHeaderContent(symbol: "magnifyingglass", title: "blocked work", subtitle: "First of 2"))
        let shown = try content(h, field.id)
        expectEqual(shown.query, "box")
        expectEqual(shown.status, nil)
        expect(!shown.offersInterpret, "typing: no Interpret row")
        let rows = try require(h.editor.references).matchRows(of: field.id)
        expectEqual(rows.rows.map(\.name).sorted(), ["Cellar", "Plan B"])
        expectEqual(try sections(h, field.id), ["reference.query", "reference.matches"], "the panel lists them while the words are typed")
        expect(h.editor.topology?.forwards(of: field.id).isEmpty ?? true, "a draft forwards nothing")
        expectEqual(h.editor.undoHistory.undoName, "Add Reference", "no step of its own")
    },

    test("Return on the words row writes the landed draft in the editing step: no second call, one step") {
        let model = ScriptedLanguageModel(answers: ["box"])
        let h = try interpretHarness(model)
        let field = try typeAndRest(h, model)
        defer { field.close() }
        spin(isAnswered(h, field.id))
        field.returnKey()
        let props = try require(h.reference(field.id))
        expectEqual(props.query, "box")
        expectEqual(props.words, "blocked work")
        expectEqual(h.editor.editingShapeID, nil)
        h.answer()
        expectEqual(model.requests.count, 1, "no second call")
        expectEqual(h.editor.undoHistory.undoName, "Add Reference")
        expect(h.standsFor(field.id).count == 1, "it stands for what the query finds")
        h.editor.undo()
        expectEqual(h.editor.document[field.id], nil, "placing, typing and the query are one step")
        h.answer()
        expectEqual(model.requests.count, 1)
    },

    test("words that read as a query are one at once: no model, the panel shows its code and matches as they're typed") {
        let model = ScriptedLanguageModel()
        let h = try interpretHarness(model)
        let field = try h.placeReference()
        defer { field.close() }
        field.type("box")
        expectEqual(field.titles, ["box"])
        spin(isAnswered(h, field.id))
        expectEqual(try content(h, field.id).query, "box")
        expectEqual(try require(h.editor.references).matchRows(of: field.id).rows.count, 2)
        expectEqual(try sections(h, field.id), ["reference.query", "reference.matches"])
        h.wait(600)
        breathe()
        field.returnKey()
        expectEqual(h.reference(field.id)?.query, "box")
        expect(model.requests.isEmpty, "no model was asked")
    },

    test("a wrong title is repaired before it's shown, and a :picked answer too: the draft is the second query") {
        let wrong = ScriptedLanguageModel(answers: [#""Plan C""#, #""Plan B""#])
        let h = try interpretHarness(wrong)
        let field = try typeAndRest(h, wrong)
        defer { field.close() }
        spin(isAnswered(h, field.id))
        expectEqual(try content(h, field.id).query, #""Plan B""#)
        expectEqual(wrong.requests.count, 2, "one second try")
        expect(wrong.requests.last?.messages.last?.text.contains("unknown_title") == true)

        let picked = ScriptedLanguageModel(answers: ["box:picked", "box"])
        let there = try interpretHarness(picked)
        let again = try typeAndRest(there, picked)
        defer { again.close() }
        spin(isAnswered(there, again.id))
        expectEqual(try content(there, again.id).query, "box")
        expect(picked.requests.last?.messages.last?.text.contains("“:picked” can’t be used here.") == true)
        let first = try require(picked.requests.first)
        expect(first.system?.hasSuffix("Stored.") == true && !(first.messages.first?.text.contains(":picked") ?? true), "the rule line, and the vocabulary without the word")
    },

    test("no key, and unanswerable: the status line says so, with Open Settings… or Retry; the pill says failed") {
        let model = ScriptedLanguageModel()
        model.queue(.noKey)
        let h = try interpretHarness(model)
        let field = try typeAndRest(h, model)
        defer { field.close() }
        spin({ if case .failed? = h.status(field.id) { true } else { false } }())
        expectEqual(h.status(field.id), .failed(.noKey))
        expectEqual(try content(h, field.id).status, ReferenceStatusLine(text: "No API key", isWarning: true, isBusy: false, action: .openSettings))
        expectEqual(h.state(of: field.id), .failed(text: "blocked work", .noKey))
        expectEqual(try header(h, field.id).subtitle, nil)

        let other = ScriptedLanguageModel(answers: ["UNANSWERABLE: where shapes sit"])
        let there = try interpretHarness(other)
        let words = try typeAndRest(there, other)
        defer { words.close() }
        spin({ if case .failed? = there.status(words.id) { true } else { false } }())
        expectEqual(try content(there, words.id).status, ReferenceStatusLine(text: "No query for these words", isWarning: true, isBusy: false, action: .retry))

        let failures: [(LanguageModelError, String, ReferenceStatusLine.Action)] = [
            (.unauthorized, "Key rejected", .openSettings), (.rateLimited, "Rate limited", .retry), (.timedOut, "Timed out", .retry),
            (.network("offline"), "Can’t reach Anthropic", .retry),
        ]
        for (error, text, action) in failures {
            let scripted = ScriptedLanguageModel()
            scripted.queue(error)
            let h = try interpretHarness(scripted)
            let id = h.addReference(words: "blocked work")
            try require(h.editor.references).interpret(id)
            spin({ if case .failed? = h.status(id) { true } else { false } }())
            expectEqual(try content(h, id).status, ReferenceStatusLine(text: text, isWarning: true, isBusy: false, action: action), "\(error)")
        }
    },

    test("a repair that still refuses is an unusable answer, to try again") {
        let model = ScriptedLanguageModel(answers: [#""Plan C""#, #""Plan D""#])
        let h = try interpretHarness(model)
        let id = h.addReference(words: "blocked work")
        try require(h.editor.references).interpret(id)
        spin({ if case .failed? = h.status(id) { true } else { false } }())
        expectEqual(try content(h, id).status, ReferenceStatusLine(text: "Unusable answer", isWarning: true, isBusy: false, action: .retry))
    },

    test("a call that outlives editing, the words unchanged, lands as its own step, \"Interpret\"; undo leaves the words and asks nothing") {
        let model = ScriptedLanguageModel(answers: ["box"])
        model.holdsAnswers = true
        let h = try interpretHarness(model)
        let field = try typeAndRest(h, model)
        defer { field.close() }
        spin(model.waiting == 1)
        field.returnKey()
        expectEqual(h.editor.editingShapeID, nil)
        expectEqual(h.reference(field.id)?.query, nil)
        h.wait(0)
        expectEqual(h.status(field.id), .interpreting, "the call is not cancelled by the end of editing")
        expectEqual(h.state(of: field.id), .interpreting(text: "blocked work"))
        model.release()
        spin(h.reference(field.id)?.query != nil)
        expectEqual(h.reference(field.id)?.query, "box")
        expectEqual(h.editor.undoHistory.undoName, "Interpret")
        h.answer()
        expect(h.standsFor(field.id).count == 1)

        h.editor.undo()
        h.answer()
        expectEqual(h.reference(field.id)?.words, "blocked work")
        expectEqual(h.reference(field.id)?.query, nil)
        expectEqual(h.state(of: field.id), .notInterpreted(text: "blocked work"))
        expect(try content(h, field.id).offersInterpret, "Interpret is offered")
        expectEqual(h.editor.undoHistory.undoName, "Add Reference")
        h.editor.redo()
        h.answer()
        expectEqual(h.reference(field.id)?.query, "box")
        h.editor.undo()
        breathe()
        expectEqual(model.requests.count, 1, "undo and redo ask nothing")
    },

    test("a call out when editing begins again is cancelled, and lands nothing") {
        let model = ScriptedLanguageModel(answers: ["box"])
        model.holdsAnswers = true
        let h = try interpretHarness(model)
        let field = try typeAndRest(h, model)
        field.returnKey()
        field.close()
        spin(model.waiting == 1)
        let again = try h.editReference(field.id)
        defer { again.close() }
        spin(model.waiting == 0)
        model.release()
        breathe()
        expectEqual(h.reference(field.id)?.query, nil)
        expectEqual(h.status(field.id), nil)
    },

    test("deleting the reference, or undoing past its words, cancels the call: nothing lands") {
        let model = ScriptedLanguageModel(answers: ["box"])
        model.holdsAnswers = true
        let h = try interpretHarness(model)
        let field = try typeAndRest(h, model)
        field.returnKey()
        field.close()
        spin(model.waiting == 1)
        h.editor.undo()
        expectEqual(h.editor.document[field.id], nil)
        spin(model.waiting == 0)
        model.release()
        breathe()
        expectEqual(h.editor.document[field.id], nil)
        expectEqual(h.status(field.id), nil)
        expectEqual(model.requests.count, 1)
    },

    test("a landing on a reference locked while the call was out is dropped: no step, no shake, not interpreted, Interpret after unlocking") {
        let model = ScriptedLanguageModel(answers: ["box", "box"])
        model.holdsAnswers = true
        let log = RefusalLog()
        let h = try interpretHarness(model, log: log)
        let field = try typeAndRest(h, model)
        field.returnKey()
        field.close()
        spin(model.waiting == 1)
        h.editor.freeze([field.id])
        let stepsBefore = h.editor.undoHistory.undoName
        model.release()
        spin(model.answered == 1)
        breathe()
        expectEqual(h.reference(field.id)?.query, nil)
        expectEqual(h.editor.undoHistory.undoName, stepsBefore, "no step")
        expect(log.refusals.isEmpty, "nothing shook: \(log.refusals)")
        expectEqual(h.status(field.id), nil, "idle")
        expectEqual(h.state(of: field.id), .notInterpreted(text: "blocked work"))
        expect(try content(h, field.id).offersInterpret, "the row stays, dimmed with the command")
        h.editor.selectedShapeIDs = [field.id]
        expect(!h.editor.canPerform(.interpretReference), "the command is dimmed")
        h.editor.freeze([field.id], false)
        expect(try content(h, field.id).offersInterpret, "Interpret once unlocked")
        expect(h.editor.canPerform(.interpretReference))
        model.holdsAnswers = false
        h.editor.perform(.interpretReference)
        spin(h.reference(field.id)?.query != nil)
        expectEqual(h.editor.undoHistory.undoName, "Interpret")
    },

    test("a reference on a locked subboard's board can't be interpreted: the command is dimmed, Interpret asks nothing and writes nothing, and the row stays for words nobody asked about; unlocked, it asks") {
        let model = ScriptedLanguageModel(answers: ["box"])
        let pocket = ShapeRecord(Pocket(CGRect(x: 2_000, y: 0, width: 100, height: 100)))
        let h = try referenceHarness([FreezingPlugin(), PocketsPlugin(), LanguageModelsPlugin(model: model),
                                      QueryTranslationPlugin(prompt: "You write one query.", referenceRule: "Stored.")],
                                     file: CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(pocket)]), children: [pocket.id: CanvasDocument()]))
        expect(h.enter(pocket.id))
        let id = h.addReference(words: "blocked work")
        h.editor.selectedShapeIDs = [id]
        expect(h.editor.canPerform(.interpretReference), "its board takes shapes")
        h.editor.transact(on: .root, "Freeze") { $0.update(pocket.id) { $0[Frozen.self] = true } }
        expect(h.editor.isBoardReadOnly)
        expect(!h.editor.canPerform(.interpretReference), "the command is dimmed")
        expect(try content(h, id).offersInterpret, "the row stays, dimmed with the command")
        let before = h.file
        h.editor.perform(.interpretReference)
        breathe()
        expect(model.requests.isEmpty, "nothing asked")
        expectEqual(h.file, before)
        expectEqual(h.state(of: id), .notInterpreted(text: "blocked work"))
        h.editor.transact(on: .root, "Thaw") { $0.update(pocket.id) { $0[Frozen.self] = nil } }
        expect(!h.editor.isBoardReadOnly)
        expect(h.editor.canPerform(.interpretReference))
        h.editor.perform(.interpretReference)
        spin(h.reference(id)?.query != nil)
        expectEqual(h.editor.undoHistory.undoName, "Interpret")
    },

    test("the 55 s deadline is a timeout, with Retry; retrying asks again, and lands as Interpret") {
        let model = ScriptedLanguageModel(answers: ["box"])
        model.holdsAnswers = true
        let h = try interpretHarness(model)
        let field = try typeAndRest(h, model)
        defer { field.close() }
        spin(model.waiting == 1)
        h.wait(55_000)
        spin({ if case .failed? = h.status(field.id) { true } else { false } }())
        expectEqual(try content(h, field.id).status, ReferenceStatusLine(text: "Timed out", isWarning: true, isBusy: false, action: .retry))
        model.holdsAnswers = false
        try require(h.editor.references).retry(field.id)
        spin(isAnswered(h, field.id))
        expectEqual(model.requests.count, 2)
    },

    test("a key saved in Settings asks again the words that failed for want of one") {
        let model = ScriptedLanguageModel()
        model.queue(.noKey)
        model.queue("box")
        let h = try interpretHarness(model)
        let id = h.addReference(words: "blocked work")
        try require(h.editor.references).interpret(id)
        spin({ if case .failed(.noKey)? = h.status(id) { true } else { false } }())
        NotificationCenter.default.post(name: .languageModelKeyDidChange, object: nil)
        spin(h.reference(id)?.query != nil)
        expectEqual(h.reference(id)?.query, "box")
        expectEqual(model.requests.count, 2)
        expectEqual(h.editor.undoHistory.undoName, "Interpret")

        // Other failures wait for the person.
        let rate = ScriptedLanguageModel()
        rate.queue(.rateLimited)
        let there = try interpretHarness(rate)
        let limited = there.addReference(words: "blocked work")
        try require(there.editor.references).interpret(limited)
        spin({ if case .failed? = there.status(limited) { true } else { false } }())
        NotificationCenter.default.post(name: .languageModelKeyDidChange, object: nil)
        breathe()
        expectEqual(rate.requests.count, 1)
    },

    test("Interpret in the panel asks, and lands as a step; the row is where the status line would be, and only for words nobody asked about") {
        let model = ScriptedLanguageModel(answers: ["box"])
        let h = try interpretHarness(model)
        let id = h.addReference(words: "blocked work")
        expect(try content(h, id).offersInterpret)
        expectEqual(try content(h, id).status, nil)
        let direct = h.addReference(to: h.addBox("Target"), label: "Target", at: CGPoint(x: 400, y: 500))
        h.editor.selectedShapeIDs = [direct]
        expect(!h.editor.canPerform(.interpretReference), "a pill for a shape")
        h.editor.selectedShapeIDs = [id]
        expect(h.editor.canPerform(.interpretReference))
        h.editor.perform(.interpretReference)
        expectEqual(h.status(id), .interpreting)
        expect(!(try content(h, id).offersInterpret), "asked: the status line has it")
        spin(h.reference(id)?.query != nil)
        expectEqual(h.reference(id)?.query, "box")
        expectEqual(h.editor.undoHistory.undoName, "Interpret")
        expect(!(try content(h, id).offersInterpret))

        let bare = try referenceHarness()
        let words = bare.addReference(words: "blocked work")
        expect(!(try content(bare, words).offersInterpret), "no translator: nothing to ask with")
    },

    test("words nobody typed are never asked about: undo, redo, a file opened, a drawn pill, an empty pill") {
        let model = ScriptedLanguageModel()
        let h = try interpretHarness(model)
        let id = h.addReference(words: "blocked work")
        h.editor.undo()
        h.editor.redo()
        h.answer(after: 1_000)
        expect(h.editor.document[id] != nil)
        let opened = try interpretHarness(model, file: h.editor.file)
        opened.answer(after: 1_000)
        _ = opened.addEmptyReference()
        opened.answer(after: 1_000)
        breathe()
        expect(model.requests.isEmpty, "nothing asked")
        expectEqual(opened.state(of: id), .notInterpreted(text: "blocked work"))
    },

    test("typed words the list still has shapes for, committed (⌥Return or leaving), are asked about when editing ends") {
        let model = ScriptedLanguageModel(answers: ["box", "box"])
        let h = try interpretHarness(model)
        let field = try h.placeReference()
        field.type("Plan")
        expect(field.titles.contains("Plan B"), "a shape matches")
        h.wait(600)
        breathe()
        expect(model.requests.isEmpty, "no wait while shapes are listed")
        field.returnKey(.option)
        field.close()
        expectEqual(h.reference(field.id)?.words, "Plan")
        h.wait(0)
        spin(model.requests.count == 1)
        spin(h.reference(field.id)?.query != nil)
        expectEqual(h.editor.undoHistory.undoName, "Interpret")

        let leave = try h.placeReference(at: CGPoint(x: 600, y: 300))
        leave.type("Cell")
        leave.escape()
        leave.escape()
        leave.close()
        h.wait(0)
        spin(model.requests.count == 2)
        spin(h.reference(leave.id)?.query != nil)
    },

    test("text back to what it was, or a pick, asks nothing") {
        let model = ScriptedLanguageModel(answers: ["box"])
        let h = try interpretHarness(model)
        let id = h.addReference(words: "blocked work")
        let field = try h.editReference(id)
        defer { field.close() }
        field.type("x")
        field.press("\u{7f}", code: 51)
        expectEqual(h.reference(id)?.words, "blocked work")
        field.escape()
        field.escape()
        h.wait(1_000)
        breathe()
        expect(model.requests.isEmpty, "unchanged words: nothing asked")
        expectEqual(h.state(of: id), .notInterpreted(text: "blocked work"))
    },

    test("the pill: interpreting is solid with its words dimmed, failed is dashed with the warning") {
        let model = ScriptedLanguageModel()
        model.queue(.rateLimited)
        model.holdsAnswers = true
        let h = try interpretHarness(model)
        let canvas = render(h.editor)
        let id = h.addReference(words: "blocked work")
        try require(h.editor.references).interpret(id)
        spin(model.waiting == 1)
        let frame = try require(h.editor.document[id]?.box)
        let inside = CGPoint(x: frame.minX + 48, y: frame.minY + 4)
        let drawn = render(h.editor)
        expectColor(pixel(drawn, at: inside), [255, 255, 255], "interpreting: its surface", within: 2)
        model.release()
        spin({ if case .failed? = h.status(id) { true } else { false } }())
        let failed = render(h.editor)
        expectEqual(pixel(failed, at: inside), pixel(canvas, at: inside), "failed: no fill")
        var orange = 0
        for y in Int(frame.minY)..<Int(frame.maxY) {
            for x in Int(frame.maxX) - 44..<Int(frame.maxX) - 14 {
                let p = pixel(failed, at: CGPoint(x: x, y: y))
                if p[0] > p[2] + 60 { orange += 1 }
            }
        }
        expect(orange > 6, "the warning")
    },
])
