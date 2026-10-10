import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Foundation
import LanguageModels
import Mentions
import TestKit
import Types

// A type on a board that isn't shown: its sync goes on (a commit, its timer, a call out), and its
// answer lands on the type's board without showing it, as a step made there.

/// A root holding pocket P, whose board holds a type, the starter, no words.
@MainActor
private struct CardInPocket {
    let p = ShapeID(), card = ShapeID()
    var file: CanvasFile {
        CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 0, y: 0, width: 100, height: 100))))]),
                   children: [p: CanvasDocument(shapes: [typeRecord(TypeSchemaProperty.starter, at: .zero, id: card)])])
    }
    var pBoard: BoardID { BoardID(owner: p) }
}

@MainActor private func bench(_ tree: CardInPocket) throws -> SyncBench {
    let b = try SyncBench(file: tree.file, more: [PocketsPlugin()])
    expect(b.editor.showBoard(tree.pBoard))
    return b
}

/// The type's schema and words, wherever it is in the file.
@MainActor private func schema(_ b: SyncBench, _ id: ShapeID) -> String? { b.editor.file.record(id)?[TypeSchemaProperty.self]?.text }
@MainActor private func words(_ b: SyncBench, _ id: ShapeID) -> MentionText? { b.editor.file.record(id)?.typed(as: Memo.self)?.props.text }

@MainActor let schemaBoardsTests = Suite("Types on boards that aren't shown", [
    test("an answer that lands after the type's board was left is written there, not shown: a step undo shows the board for") {
        let tree = CardInPocket()
        let b = try bench(tree)
        b.typeWords(tree.card, "a pet in my household")
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
        expectEqual(schema(b, tree.card), pet, "written on the pocket's board")
        expectEqual(b.status(tree.card), .idle)
        expectEqual(b.editor.undoHistory.undoName, "Update Schema")
        b.editor.undo()
        expectEqual(b.editor.board, tree.pBoard, "undoing it shows the type's board")
        expectEqual(schema(b, tree.card), TypeSchemaProperty.starter)
        expectEqual(words(b, tree.card), "a pet in my household")
        b.scheduler.advance(by: .seconds(5))
        b.settle()
        expectEqual(b.model.requests.count, 1, "undo is no edit: nothing is asked again")
        expect(b.editor.showBoard(.root))
        b.editor.redo()
        expectEqual(b.editor.board, tree.pBoard)
        expectEqual(schema(b, tree.card), pet)
        b.sync.commit(tree.card)
        b.settle()
        expectEqual(b.model.requests.count, 1, "redone, it's in step")
    },
    test("an edit whose board is left before it syncs still syncs: after its idle time, or on a commit that comes as the keyboard leaves") {
        let tree = CardInPocket()
        let b = try bench(tree)
        b.typeWords(tree.card, "a pet in my household")
        expect(b.editor.showBoard(.root))
        b.model.queue(petSchema)
        b.scheduler.advance(by: TypeSync<TypeSchemaProperty>.idleDelay)
        spinRunLoop(until: { b.model.requests.count == 1 && !b.isUpdating(tree.card) })
        expectEqual(schema(b, tree.card), pet)
        expectEqual(b.editor.board, .root)

        expect(b.editor.showBoard(tree.pBoard))
        b.typeWords(tree.card, "a pet in my household, and its weight")
        expect(b.editor.showBoard(.root))
        b.sync(tree.card, answer: petSchema.replacingOccurrences(of: "\"birthYear\"", with: "\"weight\""))
        expectEqual(b.message(1)?.contains("and its weight"), true)
        expect(schema(b, tree.card)?.contains("weight") == true)
        expectEqual(b.editor.undoHistory.undoName, "Update Schema")
    },
    test("a type whose board goes with its owner drops its call; undoing that brings back what it last synced") {
        let tree = CardInPocket()
        let b = try bench(tree)
        b.typeWords(tree.card, "a pet in my household")
        b.sync(tree.card, answer: petSchema)
        b.typeWords(tree.card, "a pet in my household, and its weight")
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
        expectEqual(words(b, tree.card), "a pet in my household, and its weight")
        b.model.queue(petSchema)
        b.sync.commit(tree.card)
        spinRunLoop(until: { b.model.requests.count == 3 && !b.isUpdating(tree.card) })
        expectEqual(b.message(2), b.message(1), "its words are still ahead of what it last synced, and asked for as before")
    },
    test("a type moved onto another board while its call is out keeps the call, and the answer is written there") {
        // A frame turned into a subboard takes what it held onto its board: the same types, moved.
        let p = ShapeID(), id = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 0, y: 300, width: 100, height: 100)))),
                                                            typeRecord(TypeSchemaProperty.starter, at: .zero, id: id)]))
        let b = try SyncBench(file: file, more: [PocketsPlugin()])
        b.typeWords(id, "a pet in my household")
        b.model.holdsAnswers = true
        b.model.queue(petSchema)
        b.sync.commit(id)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.editor.transact("Move In") { $0.move([id], toBoardOwnedBy: p) }
        expectEqual(b.editor.file.board(containing: id), BoardID(owner: p))
        expect(b.isUpdating(id), "still waiting for its answer")
        b.model.release()
        spinRunLoop(until: { !b.isUpdating(id) })
        expectEqual(schema(b, id), pet, "written on the pocket's board")
        expectEqual(b.editor.board, .root)
        expectEqual(b.model.requests.count, 1, "asked once")
    },
    test("a file put in place over another board takes every type afresh: a call out for one it changed is dropped") {
        let tree = CardInPocket()
        let b = try bench(tree)
        b.typeWords(tree.card, "a pet in my household")
        b.model.holdsAnswers = true
        b.sync.commit(tree.card)
        spinRunLoop(until: { b.model.waiting == 1 })
        b.editor.replaceFile(with: tree.file, showing: .root)
        expectEqual(b.status(tree.card), .idle)
        b.model.release()
        spinRunLoop(until: { b.model.answered == 1 })
        b.settle()
        expectEqual(schema(b, tree.card), TypeSchemaProperty.starter, "the answer to what the file no longer says isn't written")
        expect(!b.editor.canUndo)
    },
])
