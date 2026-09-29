import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import LanguageModels
import Mentions
import Schemas
import TestKit

// A schema card on a board that isn't shown: its sync goes on (a commit, its timer, a call out), and
// its answer lands on the card's board without showing it, as a step made there.

/// A root holding pocket P, whose board holds a card, the starter, no prompt.
private struct CardInPocket {
    let p = ShapeID(), card = ShapeID()
    var file: CanvasFile {
        CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))]),
                   children: [p: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: card, SchemaCard(frame: CGRect(x: 0, y: 0, width: 240, height: 89))))])])
    }
    var pBoard: BoardID { BoardID(owner: p) }
}

@MainActor private func bench(_ tree: CardInPocket) throws -> SyncBench {
    let b = try SyncBench(file: tree.file, more: [PocketsPlugin()])
    expect(b.editor.showBoard(tree.pBoard))
    return b
}

/// The card, wherever it is in the file.
@MainActor private func card(_ b: SyncBench, _ id: ShapeID) -> SchemaCard? { b.editor.file.record(id)?.typed(as: SchemaCard.self)?.props }

@MainActor let schemaBoardsTests = Suite("Schema cards on boards that aren't shown", [
    test("an answer that lands after the card's board was left is written there, not shown: a step undo shows the board for") {
        let tree = CardInPocket()
        let b = try bench(tree)
        b.typePrompt(tree.card, "a pet in my household")
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        b.sync.commit(tree.card)
        spinRunLoop(until: { b.model.waiting == 1 })
        expect(b.editor.showBoard(.root))
        let shown = b.editor.document
        b.model.release()
        spinRunLoop(until: { !b.isUpdating(tree.card) })
        expectEqual(b.editor.board, .root, "nothing is shown for it")
        expectEqual(b.editor.document, shown)
        expectEqual(card(b, tree.card)?.schema.text, petSchema, "written on the pocket's board")
        expectEqual(b.status(tree.card), .idle)
        expectEqual(b.editor.undoHistory.undoName, "Update Schema")
        b.editor.undo()
        expectEqual(b.editor.board, tree.pBoard, "undoing it shows the card's board")
        expectEqual(card(b, tree.card)?.schema.text, SchemaCard.starter)
        expectEqual(card(b, tree.card)?.prompt, "a pet in my household")
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1, "undo is no edit: nothing is asked again")
        expect(b.editor.showBoard(.root))
        b.editor.redo()
        expectEqual(b.editor.board, tree.pBoard)
        expectEqual(card(b, tree.card)?.schema.text, petSchema)
        b.sync.commit(tree.card)
        b.settle()
        expectEqual(b.model.requests.count, 1, "redone, it's in step")
    },
    test("an edit whose board is left before it syncs still syncs: after its idle time, or on a commit that comes as the keyboard leaves") {
        let tree = CardInPocket()
        let b = try bench(tree)
        b.typePrompt(tree.card, "a pet in my household")
        expect(b.editor.showBoard(.root))
        b.model.queue(petSchema)
        b.scheduler.advance(by: SchemaSync.idleDelay)
        spinRunLoop(until: { b.model.requests.count == 1 && !b.isUpdating(tree.card) })
        expectEqual(card(b, tree.card)?.schema.text, petSchema)
        expectEqual(b.editor.board, .root)

        expect(b.editor.showBoard(tree.pBoard))
        b.typePrompt(tree.card, "a pet in my household, and its weight")
        expect(b.editor.showBoard(.root))
        b.sync(tree.card, answer: petSchema.replacingOccurrences(of: "\"birthYear\"", with: "\"weight\""))
        expectEqual(b.message(1)?.contains("and its weight"), true)
        expect(card(b, tree.card)?.schema.text.contains("weight") == true)
        expectEqual(b.editor.undoHistory.undoName, "Update Schema")
    },
    test("a card whose board goes with its owner drops its call; undoing that brings back what it last synced") {
        let tree = CardInPocket()
        let b = try bench(tree)
        b.typePrompt(tree.card, "a pet in my household")
        b.sync(tree.card, answer: petSchema)
        b.typePrompt(tree.card, "a pet in my household, and its weight")
        b.model.holdsAnswers = true
        b.sync.commit(tree.card)
        spinRunLoop(until: { b.model.waiting == 1 })
        expect(b.editor.showBoard(.root))
        b.editor.transact("Delete") { $0.delete([tree.p]) }
        expectEqual(b.status(tree.card), .idle, "dropped with its board")
        b.model.release()
        spinRunLoop(until: { b.model.answered == 2 })
        b.settle()
        expect(b.editor.file.record(tree.card) == nil)
        b.model.holdsAnswers = false
        b.editor.undo()
        expectEqual(card(b, tree.card)?.prompt, "a pet in my household, and its weight")
        b.model.queue(petSchema)
        b.sync.commit(tree.card)
        spinRunLoop(until: { b.model.requests.count == 3 && !b.isUpdating(tree.card) })
        expectEqual(b.message(2), b.message(1), "its prompt is still ahead of what it last synced, and asked for as before")
    },
    test("a file put in place over another board takes every card afresh: a call out for one it changed is dropped") {
        let tree = CardInPocket()
        let b = try bench(tree)
        b.typePrompt(tree.card, "a pet in my household")
        b.model.holdsAnswers = true
        b.sync.commit(tree.card)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.editor.replaceFile(with: tree.file, showing: .root)
        expectEqual(b.status(tree.card), .idle)
        b.model.release()
        spinRunLoop(until: { b.model.answered == 1 })
        b.settle()
        expectEqual(card(b, tree.card)?.schema.text, SchemaCard.starter, "the answer to what the file no longer says isn't written")
        expect(!b.editor.canUndo)
    },
])
