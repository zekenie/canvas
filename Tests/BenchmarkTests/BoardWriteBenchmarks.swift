import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Composition
import CoreGraphics
import Foundation
import Locking
import StickyNotes
import TestKit

// Writing to the shapes of another board (`Transaction.update(_:on:_:)`), as a service does in the step it joins
// (a take-back, a restack of rows): each write is a transaction over that board, which must not copy the board
// once for every shape written.

extension Budget {
    /// Writing the 7,800 shapes of another board that can be written (a generated board of 10,000, whose locked
    /// notes refuse), in one step: the board is copied once, not once for each shape written. The thread's CPU: some
    /// 55 ms in release, against 1,650 when each write copied the board.
    static let writeOnAnotherBoard = 200.0
}

@MainActor let boardWriteBenchmarks = Suite("Board write benchmarks", [
    test("writing every shape of another board in one step costs what it does on the step's own board, not a copy of the board for each") {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        for size in sizes {
            let file = generatedFile(root: 10, children: [size])
            let owner = try require(owners(in: file).first)
            let board = BoardID(owner: owner)
            let there = try require(file.children[owner])
            // (A locked note keeps its place: the write is refused there.)
            let ids = there.shapes.filter { $0.box != nil && $0[LockedProperty.self] != true }.map(\.id)
            let editor = CanvasEditor(registry: try Registry(plugins: shippedPlugins(pasteboard)), file: file, scheduler: ManualScheduler())
            let wrote = threadCPUTime {
                editor.transact("Write elsewhere") { transaction in
                    for id in ids { transaction.update(id, on: board) { $0.box = $0.box?.offsetBy(dx: 1, dy: 0) } }
                }
            }.milliseconds
            let probe = try require(ids.last { there[$0]?.kind == StickyNote.kind })
            expectEqual(editor.shape(inFile: probe)?.box, there[probe]?.box?.offsetBy(dx: 1, dy: 0), "written there")
            expectEqual(editor.undoHistory.undoName, "Write elsewhere")
            editor.undo()
            expectEqual(editor.shape(inFile: probe)?.box, there[probe]?.box, "and taken back")
            report(String(format: "%6d shapes of another board written in one step: %7.1f ms (budget %.0f)", ids.count, wrote, Budget.writeOnAnotherBoard))
            if holdsToBudgets, size >= 10_000 { expect(wrote < Budget.writeOnAnotherBoard, "writing \(ids.count) shapes of another board took \(wrote) ms") }
        }
    },
])
