import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Foundation
import SwiftUI
import TestKit

// Saving a board document (`BoardDocument`, NSDocument): the main thread is held for a snapshot of the file, a value, and
// the encoding of every shape of every board and the write are another thread's (`canAsynchronouslyWrite`). Held in a file of its
// own: with SwiftUI imported, Benchmarks.swift's long literals no longer type-check in a release build.

extension Budget {
    /// A board document's save, from the request to the file's being written, on the main thread: a
    /// snapshot of the file (a value) and NSDocument's own turns, whatever the board's size; the
    /// encoding and the write are another thread's. The thread's CPU time.
    static let saveMain = 10.0
}

@MainActor let saveBenchmarks = Suite("Save benchmarks", [
    test("a board document saves with the main thread held for a snapshot of the file, not for encoding it: the encoding and the write are another thread's") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        BoardDocument.configuration = BoardConfiguration(registry: try Registry(plugins: shippedPlugins(pasteboard)), imagePasteboard: pasteboard) { _ in
            AnyView(EmptyView())
        }
        for size in sizes {
            let board = BoardDocument()
            defer { board.close() }
            board.start(with: generatedBoard(shapes: size))
            let type = BoardConfiguration.typeIdentifier
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("BoardSaveBenchmark-\(UUID().uuidString).canvasboard")
            defer { try? FileManager.default.removeItem(at: url) }
            // What a save used to cost the main thread: the file encoded there, as asking for the bytes there does.
            var data = Data()
            let onMain = try median(runs: 3, onThread: true) { data = try board.data(ofType: type) }
            // A save: what the main thread spends from asking to the file's being written, and what the others do meanwhile.
            var mains: [Double] = [], others: [Double] = []
            for _ in 0..<3 {
                let run = try cpu { () async throws -> Void in
                    try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, any Error>) in
                        board.save(to: url, ofType: type, for: .saveOperation) { error in
                            if let error { done.resume(throwing: error) } else { done.resume() }
                        }
                    }
                }
                mains.append(run.main)
                others.append(run.offMain)
            }
            expectEqual(try Data(contentsOf: url), data, "the file written is the board")
            #if DEBUG
            expectEqual(BoardDocument.lastEncodedOnMainThread, false, "encoded off the main thread")
            #endif
            let main = middle(mains)
            report(String(format: "%6d shapes, %5.1f MB: a save held the main thread %6.2f ms (budget %.0f) and the others %7.1f, where encoding it there took %7.1f ms",
                          size, Double(data.count) / 1e6, main, Budget.saveMain, middle(others), onMain))
            if holdsToBudgets, size >= 10_000 { expect(main < Budget.saveMain, "a save of \(size) shapes held the main thread for \(main) ms") }
        }
    },
])
