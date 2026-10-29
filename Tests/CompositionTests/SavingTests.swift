import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Foundation
import Geometry
import Mentions
import os
import ShippedTesting
import StickyNotes
import TestKit

// A board saves off the main thread: the main actor takes the file, a value, as it takes the change count a
// save marks saved, and the encoding and the write are NSDocument's other thread's, the main thread let go as
// soon as the file is taken (`unblockUserInteraction`). The board goes on being edited meanwhile.

/// Whether the writing thread has begun encoding, and the gate it waits at until the test lets it go.
private final class Gate: Sendable {
    private let reached = OSAllocatedUnfairLock(initialState: false)
    private let semaphore = DispatchSemaphore(value: 0)

    var hasReached: Bool { reached.withLock { $0 } }
    /// On the writing thread: says it's here, and waits for `open`.
    func hold() {
        reached.withLock { $0 = true }
        semaphore.wait()
    }
    func open() { semaphore.signal() }
}

@MainActor let savingTests = Suite("Saving, off the main thread", [
    test("a save writes what the codec writes, encoded off the main thread, and leaves the board unedited") {
        try configureBoards()
        let board = BoardDocument()
        defer { board.close() }
        board.start(with: SampleBoard.document())
        board.editor.add(StickyNote(frame: CGRect(x: 0, y: 700, width: 200, height: 200), text: "New"))
        expect(board.isDocumentEdited)
        let url = scratchURL("off-main.canvasboard")
        defer { try? FileManager.default.removeItem(at: url) }
        let expected = try BoardCodec(registry: board.editor.registry).encode(board.editor.file)
        try save(board, to: url)
        expectEqual(try Data(contentsOf: url), expected)
        expectEqual(BoardDocument.lastEncodedOnMainThread, false, "the file was encoded on the thread NSDocument writes on")
        expect(!board.isDocumentEdited)
        // The bytes asked for on the main thread are encoded there, from the board as it is.
        _ = try board.data(ofType: boardType)
        expectEqual(BoardDocument.lastEncodedOnMainThread, true)
    },
    test("the main thread is let go before the file is encoded: a board edited meanwhile is saved as it was, and left edited") {
        try configureBoards()
        let board = BoardDocument()
        defer { board.close() }
        board.start(with: SampleBoard.document())
        board.editor.add(StickyNote(frame: CGRect(x: 0, y: 700, width: 200, height: 200), text: "First"))
        let url = scratchURL("meanwhile.canvasboard")
        defer { try? FileManager.default.removeItem(at: url) }
        let codec = BoardCodec(registry: board.editor.registry)
        let before = try codec.encode(board.editor.file)
        let gate = Gate()
        BoardDocument.beforeEncoding.withLock { $0 = { gate.hold() } }
        defer { BoardDocument.beforeEncoding.withLock { $0 = nil } }
        var finished = false
        var failure: (any Error)?
        board.save(to: url, ofType: boardType, for: .saveOperation) { error in
            failure = error
            finished = true
        }
        runLoop { gate.hasReached }
        expect(gate.hasReached, "the writing thread has the file and waits to encode it")
        expect(!finished)
        // The main thread is free: the board is edited, and a timer on its run loop fires.
        let ticked = OSAllocatedUnfairLock(initialState: false)
        let timer = Timer(timeInterval: 0, repeats: false) { _ in ticked.withLock { $0 = true } }
        RunLoop.main.add(timer, forMode: .default)
        runLoop { ticked.withLock { $0 } }
        expect(ticked.withLock { $0 }, "the main run loop turns while the file is being encoded")
        board.editor.add(StickyNote(frame: CGRect(x: 300, y: 700, width: 200, height: 200), text: "Second"))
        gate.open()
        runLoop { finished }
        expect(finished, "the save finished")
        expect(failure == nil, "\(String(describing: failure))")
        expectEqual(try Data(contentsOf: url), before, "the file is the board as the save took it")
        expect(board.isDocumentEdited, "what was changed after is not in the file, and the board says so")
        // Saved again, it has the second note and reads unedited.
        BoardDocument.beforeEncoding.withLock { $0 = nil }
        try save(board, to: url)
        expectEqual(try Data(contentsOf: url), try codec.encode(board.editor.file))
        expect(!board.isDocumentEdited)
    },
    test("an autosave that can wait gives way to a press through NSDocument's own flow: it writes nothing, the board stays edited, and it's scheduled again once the press is over") {
        let b = try UndoBoard()
        defer { b.close() }
        let url = scratchURL("waits.canvasboard")
        defer { try? FileManager.default.removeItem(at: url) }
        try save(b.board, to: url)
        let saved = try Data(contentsOf: url)
        b.window.makeFirstResponder(b.canvas)
        b.canvas.mouseDown(with: b.event(.leftMouseDown, at: sampleNotes[2]))
        b.canvas.mouseDragged(with: b.event(.leftMouseDragged, at: CGPoint(x: 980, y: 200)))
        expect(b.editor.undoHistory.isPressing)
        expect(b.board.isDocumentEdited)
        var outcome: (any Error)??
        b.board.autosave(withImplicitCancellability: true) { error in outcome = .some(error) }
        runLoop { outcome != nil }
        let error = try require(outcome ?? nil, "an autosave during a press gives way")
        expectEqual((error as NSError).code, NSUserCancelledError)
        expectEqual(try Data(contentsOf: url), saved, "nothing was written")
        expect(b.board.isDocumentEdited)
        let scheduled = b.board.autosavesScheduled
        b.canvas.mouseUp(with: b.event(.leftMouseUp, at: CGPoint(x: 980, y: 200)))
        expectEqual(b.board.autosavesScheduled, scheduled + 1, "scheduled again once the press is over")
        // With nothing to wait for it writes the file in place.
        var wrote = false
        b.board.autosave(withImplicitCancellability: true) { error in wrote = error == nil }
        runLoop { wrote }
        expect(wrote)
        expectEqual(try Data(contentsOf: url), try BoardCodec(registry: b.editor.registry).encode(b.editor.file), "the board as it is")
        expectEqual(BoardDocument.lastEncodedOnMainThread, false)
    },
    test("asked for its bytes on another thread with no save under way, a board gives itself as it is") {
        try configureBoards()
        let board = BoardDocument()
        defer { board.close() }
        board.start(with: SampleBoard.document())
        let expected = try BoardCodec(registry: board.editor.registry).encode(board.editor.file)
        nonisolated(unsafe) let unchecked = board
        let task = Task.detached { try unchecked.data(ofType: boardType) }
        let data = try awaitResult { try await task.value }
        expectEqual(data, expected)
        expectEqual(BoardDocument.lastEncodedOnMainThread, false)
    },
])
