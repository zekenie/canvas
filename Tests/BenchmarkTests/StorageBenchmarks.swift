import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Locking
import Mentions
import StickyNotes
import TestKit
import Types

// What a commit costs a big board (`ShapeStack`, `ShapeMap`; [editor](editor.md)): a commit that changes a few
// shapes costs those, not the board. The generated board, the shipped list's services all listening.

extension Budget {
    /// One commit that changes a few shapes of a board of 10,000: a keystroke in a note, a note put on top, a
    /// drag event of five notes, a keystroke undone and redone, a note near the top brought to the front. The
    /// median of 100, the thread's CPU, release: some 0.02 to 0.07 ms in runs alone (the services' part of it
    /// most; the last is three commits), where the board copied whole by every commit cost 0.25 (and 2.7 at
    /// 100,000).
    static let storageCommit = 0.5
    /// And how many times what it costs on the board a tenth the size it may cost: the board's size is none of
    /// the commit's business. Whatever copies a board (a list of its shapes, a table of where they are) gives
    /// ten times the cost for ten times the shapes.
    static let storageCommitOverSmaller = 3.0
    /// And more, for a timing too short to hold to a ratio (a commit on 1,000 shapes, some 0.03 ms).
    static let storageCommitSlack = 0.1
}

@MainActor let storageBenchmarks = Suite("Storage benchmarks", [
    test("a commit that changes a few shapes costs those, not the board: the same on a board ten times the size") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var smaller: [String: Double] = [:]
        for size in sizes {
            let document = generatedBoard(shapes: size)
            let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), document: document, scheduler: ManualScheduler())
            let notes = document.shapes.filter { $0.kind == StickyNote.kind && $0[TypeSchemaProperty.self] == nil && $0[LockedProperty.self] != true }.map(\.id)
            let note = try require(notes.last), five = Set(notes.suffix(5))
            var n = 0
            let timings: [(String, Double)] = [
                ("a keystroke in a note", median(runs: 100, onThread: true) {
                    n += 1
                    editor.transact { $0.update(note, as: StickyNote.self) { $0.props.text = MentionText(plain: String(repeating: "a", count: n)) } }
                }),
                ("a note put on top", median(runs: 100, onThread: true) {
                    editor.add(StickyNote(frame: CGRect(x: -1000, y: -1000, width: 200, height: 200), text: "Added"))
                }),
                ("a drag event of five notes", median(runs: 100, onThread: true) {
                    n += 1
                    editor.transact { $0.translate(five, by: CGPoint(x: n % 2 == 0 ? 1 : -1, y: 0)) }
                }),
                ("a keystroke undone and redone", median(runs: 100, onThread: true) {
                    n += 1
                    editor.transact("Type") { $0.update(note, as: StickyNote.self) { $0.props.text = MentionText(plain: String(repeating: "b", count: n)) } }
                    editor.undo()
                    editor.redo()
                }),
                ("a note near the top brought to the front", median(runs: 100, prepare: {
                    // Just under the shape below the top, wherever it was.
                    let below = editor.document.shapes[editor.document.shapes.count - 2].id
                    editor.transact("Down") { $0.move(note, below: below) }
                }, onThread: true) {
                    editor.transact("Front") { $0.bringToFront(note) }
                }),
            ]
            for (name, cost) in timings {
                let before = smaller[name]
                report(String(format: "%7d shapes, %@: %6.3f ms (budget %.1f)%@", size, name, cost, Budget.storageCommit,
                              before.map { String(format: ", %.1f times the %.3f ms on the board before", cost / max($0, 0.0001), $0) } ?? ""))
                if holdsToBudgets {
                    expect(cost < Budget.storageCommit, "\(name) over \(size) shapes took \(cost) ms")
                    if let before { expect(cost < before * Budget.storageCommitOverSmaller + Budget.storageCommitSlack, "\(name) took \(cost) ms over \(size) shapes, \(before) on the board before") }
                }
                smaller[name] = cost
            }
            // What the last commit left shared with the board before it: all the chunks but a few.
            let shapes = editor.document.shapes
            editor.add(StickyNote(frame: .zero, text: "One more"))
            let shared = editor.document.shapes.sharedChunkCount(with: shapes)
            report(String(format: "%7d shapes, a note put on top leaves %d of the board's %d chunks shared with the board before", size, shared, shapes.chunkCount))
            expect(shared >= shapes.chunkCount - 1, "a note put on top copied \(shapes.chunkCount - shared) chunks")
        }
    },
])
