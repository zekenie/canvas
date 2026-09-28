import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import LanguageModels
import Schemas
import TestKit
import Titles

// A schema card and undo: what the person types in its panel is one step a field, the sync's write
// is one of its own, and undo and redo are no edit the sync follows, but put back what it last
// synced with the card.

@MainActor let undoTests = Suite("Schema cards and undo", [
    test("the sync's write is one step, Update Schema; undoing it asks for nothing, and redoing it leaves the card in step") {
        let b = try SyncBench()
        let id = b.place()
        b.typePrompt(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        expectEqual(b.editor.undoHistory.undoName, "Update Schema")
        b.editor.undo()
        expectEqual(b.card(id)?.schema, SchemaCard.starter, "the schema as it was, and the card's height with it")
        expectEqual(b.card(id)?.frame.height, 89)
        expectEqual(b.card(id)?.prompt, "a pet in my household", "the person's prompt stays")
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1, "undo is no edit: nothing is asked again")
        expectEqual(b.status(id), .idle)
        b.editor.redo()
        expectEqual(b.card(id)?.schema, petSchema)
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 1, "redone, it's in step")
        b.editor.undo()
        b.sync(id, answer: petSchema)
        expectEqual(b.message(1), b.message(0), "undone, it's as before the answer: the schema asked for again, from nothing")
        expectEqual(b.card(id)?.schema, petSchema)
    },
    test("the sync's write of the description is one step, Update Description") {
        let b = try SyncBench(document: CanvasDocument())
        let id = b.editor.add(card(petSchema))
        let weighed = petSchema.replacingOccurrences(of: "\"birthYear\"", with: "\"weight\"")
        b.typeSchema(id, weighed)
        b.sync(id, answer: "A pet: its name, species and weight.")
        expectEqual(b.card(id)?.prompt, "A pet: its name, species and weight.")
        expectEqual(b.editor.undoHistory.undoName, "Update Description")
        b.editor.undo()
        expectEqual(b.card(id)?.prompt, "")
        expectEqual(b.card(id)?.schema, weighed)
    },
    test("undo while a call is out drops the call: its answer isn't written, and redo asks nothing either") {
        let b = try SyncBench()
        let id = b.place()
        b.typePrompt(id, "a pet in my household")
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        expectEqual(b.status(id), .updating(.schema))
        b.editor.undo()
        expectEqual(b.card(id)?.prompt, "")
        expectEqual(b.status(id), .idle, "no longer updating")
        spinRunLoop(until: { b.model.answered == 1 })
        b.settle()
        expectEqual(b.card(id)?.schema, SchemaCard.starter, "the answer to the prompt undone isn't written")
        expectEqual(b.model.queued.count, 1, "the call was cancelled, and took no answer")
        b.model.holdsAnswers = false
        b.editor.redo()
        expectEqual(b.card(id)?.prompt, "a pet in my household")
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1, "redo is no edit either")
        expect(!b.editor.canRedo)
    },
    test("undoing a card's deletion brings back what it last synced: a prompt typed since is still ahead") {
        let b = try SyncBench()
        let id = b.place()
        b.typePrompt(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        b.typePrompt(id, "a pet in my household, and its weight")
        b.editor.transact { $0.delete([id]) }
        b.editor.undo()
        expectEqual(b.card(id)?.prompt, "a pet in my household, and its weight")
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1, "undo asks nothing")
        b.sync(id, answer: "NO_CHANGE")
        expectEqual(b.model.requests.count, 2, "the prompt is ahead of what was synced, so a commit asks")
        expectEqual(b.message(1), "<previous_prompt>\na pet in my household\n</previous_prompt>\n\n<prompt>\na pet in my household, and its weight\n</prompt>\n\n<schema>\n\(petSchema)\n</schema>")
    },
    test("undoing a step that didn't touch a card leaves what its sync learned since: a NO_CHANGE that landed meanwhile holds") {
        let b = try SyncBench(document: CanvasDocument())
        let id = b.editor.add(card(petSchema))
        let other = b.editor.add(card(petSchema, at: CGPoint(x: 400, y: 40)))
        let weighed = petSchema.replacingOccurrences(of: "\"birthYear\"", with: "\"weight\"")
        b.typeSchema(id, weighed)
        b.model.holdsAnswers = true
        b.model.queue("NO_CHANGE")
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        // Another card moves while the call is out: a step whose snapshots are from before the answer.
        b.editor.transact("Move") { $0.update(other, as: SchemaCard.self) { $0.props.frame.origin.x += 100 } }
        b.model.release()
        spinRunLoop(until: { b.model.answered == 1 && !b.isUpdating(id) })
        b.model.holdsAnswers = false
        b.editor.undo()
        expectEqual(b.editor.undoHistory.redoName, "Move")
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 1, "the card is in step as the answer left it: undoing the move asks nothing again")
        b.editor.redo()
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 1, "nor does redoing it")
    },
    test("typing the JSON is one step, Change JSON, keystroke after keystroke") {
        let panel = try SchemaPanelWindow()
        let id = panel.show(blankCard)
        let code = try require(panel.code)
        panel.focus(code, caret: (SchemaCard.starter as NSString).range(of: "{}").location + 1)
        panel.window.type(#""a": {}"#)
        let typed = try require(panel.card(id)?.schema)
        expect(typed != SchemaCard.starter)
        expectEqual(panel.editor.undoHistory.undoName, "Change JSON")
        panel.editor.undo()
        expectEqual(panel.card(id)?.schema, SchemaCard.starter, "every keystroke, undone at once")
        panel.editor.redo()
        expectEqual(panel.card(id)?.schema, typed)
    },
    test("typing the description is one step, Change Description; renaming in the header one, Change Schema") {
        let panel = try SchemaPanelWindow()
        let id = panel.show(card(#"{"type": "object", "properties": {"a": {}}}"#))
        let before = try require(panel.card(id)?.schema)
        panel.window.focus(try require(panel.headerField))
        panel.window.type("Pets")
        expectEqual(panel.editor.registry.title(of: try require(panel.editor.document[id])), "Pets")
        expectEqual(panel.editor.undoHistory.undoName, "Change Schema")
        panel.editor.undo()
        expectEqual(panel.card(id)?.schema, before, "the name typed, undone at once")
        panel.editor.undoHistory.seal()     // what the app's window does as the keyboard moves
        panel.focus(try require(panel.prompt))
        panel.window.type("a pet")
        expectEqual(panel.editor.undoHistory.undoName, "Change Description")
        panel.editor.undo()
        expectEqual(panel.card(id)?.prompt, "")
    },
])
