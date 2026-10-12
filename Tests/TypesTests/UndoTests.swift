import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import LanguageModels
import Mentions
import TestKit
import Titles
import Types

// A type and undo: what the person types in its panel is one step a field, the sync's write is one of
// its own, and undo and redo are no edit the sync follows, but put back what it last synced with the
// type.

@MainActor let undoTests = Suite("Types and undo", [
    test("the sync's write is one step, Update Schema; undoing it asks for nothing, and redoing it leaves the type in step") {
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        expectEqual(b.editor.undoHistory.undoName, "Update Schema")
        b.editor.undo()
        expectEqual(b.schema(id), TypeSchemaProperty.starter, "the schema as it was")
        expectEqual(b.title(id), nil, "and the name it was given with it")
        expectEqual(b.words(id), "a pet in my household", "the person's words stay")
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1, "undo is no edit: nothing is asked again")
        expectEqual(b.status(id), .idle)
        b.editor.redo()
        expectEqual(b.schema(id), pet)
        expectEqual(b.title(id), "Pet")
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 1, "redone, it's in step")
        b.editor.undo()
        b.sync(id, answer: petSchema)
        expectEqual(b.message(1), b.message(0), "undone, it's as before the answer: the schema asked for again, from nothing")
        expectEqual(b.schema(id), pet)
    },
    test("the sync's write of the words is one step, Update Text") {
        let b = try SyncBench(document: CanvasDocument())
        let id = b.editor.addType(petSchema)
        let weighed = petSchema.replacingOccurrences(of: "\"birthYear\"", with: "\"weight\"")
        b.typeSchema(id, weighed)
        b.sync(id, answer: "A pet: its name, species and weight.")
        expectEqual(b.words(id), "A pet: its name, species and weight.")
        expectEqual(b.editor.undoHistory.undoName, "Update Text")
        b.editor.undo()
        expectEqual(b.words(id), "")
        expectEqual(b.schema(id), weighed)
    },
    test("words that begin like a preamble are rewritten all the same: the answer that begins so too is the words, not an unusable one") {
        let b = try SyncBench(document: CanvasDocument())
        let id = b.editor.addType(petSchema, words: "Here are the fields: name, species, birth year.")
        let weighed = petSchema.replacingOccurrences(of: "\"birthYear\"", with: "\"weight\"")
        b.typeSchema(id, weighed)
        b.sync(id, answer: "Here are the fields: name, species, weight.")
        expectEqual(b.status(id), .idle)
        expectEqual(b.words(id), "Here are the fields: name, species, weight.")
        expectEqual(b.editor.undoHistory.undoName, "Update Text")
    },
    test("undo while a call is out drops the call: its answer isn't written, and redo asks nothing either") {
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        expectEqual(b.status(id), .updating(.schema))
        b.editor.undo()
        expectEqual(b.words(id), "")
        expectEqual(b.status(id), .idle, "no longer updating")
        spinRunLoop(until: { b.model.answered == 1 })
        b.settle()
        expectEqual(b.schema(id), TypeSchemaProperty.starter, "the answer to the words undone isn't written")
        expectEqual(b.model.queued.count, 1, "the call was cancelled, and took no answer")
        b.model.holdsAnswers = false
        b.editor.redo()
        expectEqual(b.words(id), "a pet in my household")
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1, "redo is no edit either")
        expect(!b.editor.canRedo)
    },
    test("undoing a type's deletion brings back what it last synced: words typed since are still ahead") {
        let b = try SyncBench()
        let id = b.place()
        b.typeWords(id, "a pet in my household")
        b.sync(id, answer: petSchema)
        b.typeWords(id, "a pet in my household, and its weight")
        b.editor.transact { $0.delete([id]) }
        b.editor.undo()
        expectEqual(b.words(id), "a pet in my household, and its weight")
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1, "undo asks nothing")
        b.sync(id, answer: "NO_CHANGE")
        expectEqual(b.model.requests.count, 2, "the words are ahead of what was synced, so a commit asks")
        expectEqual(b.message(1), "<previous_prompt>\na pet in my household\n</previous_prompt>\n\n<prompt>\na pet in my household, and its weight\n</prompt>\n\n<schema>\n\(petSchema)\n</schema>")
    },
    test("undoing a step that didn't touch a type leaves what its sync learned since: a NO_CHANGE that landed meanwhile holds") {
        let b = try SyncBench(document: CanvasDocument())
        let id = b.editor.addType(petSchema)
        let other = b.editor.addType(petSchema, at: CGPoint(x: 400, y: 40))
        let weighed = petSchema.replacingOccurrences(of: "\"birthYear\"", with: "\"weight\"")
        b.typeSchema(id, weighed)
        b.model.holdsAnswers = true
        b.model.queue("NO_CHANGE")
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        // Another type moves while the call is out: a step whose snapshots are from before the answer.
        b.editor.transact("Move") { $0.update(other, as: Memo.self) { $0.props.frame.origin.x += 100 } }
        b.model.release()
        spinRunLoop(until: { b.model.answered == 1 && !b.isUpdating(id) })
        b.model.holdsAnswers = false
        b.editor.undo()
        expectEqual(b.editor.undoHistory.redoName, "Move")
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 1, "the type is in step as the answer left it: undoing the move asks nothing again")
        b.editor.redo()
        b.sync.commit(id)
        b.settle()
        expectEqual(b.model.requests.count, 1, "nor does redoing it")
    },
    test("typing the JSON is one step, Change JSON, keystroke after keystroke") {
        let panel = try TypePanelWindow()
        let id = panel.show(typeRecord(TypeSchemaProperty.starter))
        let code = try require(panel.code)
        panel.focus(code, caret: (TypeSchemaProperty.starter as NSString).range(of: "{}").location + 1)
        panel.window.type(#""a": {}"#)
        let typed = try require(panel.editor.schema(id))
        expect(typed != TypeSchemaProperty.starter)
        expectEqual(panel.editor.undoHistory.undoName, "Change JSON")
        panel.editor.undo()
        expectEqual(panel.editor.schema(id), TypeSchemaProperty.starter, "every keystroke, undone at once")
        panel.editor.redo()
        expectEqual(panel.editor.schema(id), typed)
    },
])
