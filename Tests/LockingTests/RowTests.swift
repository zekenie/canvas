import Canvas
import CanvasTesting
import CoreGraphics
import Locking
import SwiftUI
import TableOfContents
import TestKit

// The lock at the end of a locked shape's row in the table of contents: an overview of what's
// locked, which otherwise shows only as a chip on the canvas.

@MainActor let lockRowTests = Suite("A locked shape's row", [
    test("a locked shape's row ends in a lock, said as Locked; unlocking takes it away, and undo puts it back") {
        let h = try lockingHarness()
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        let contents = try require(h.editor.tableOfContents)
        @MainActor func marks() -> [ShapeID: [ContentsMark]] { Dictionary(uniqueKeysWithValues: contents.entries.map { ($0.id, $0.marks) }) }
        expectEqual(marks()[a], [])
        h.editor.lock([a])
        expectEqual(marks()[a], [ContentsMark(symbol: "lock.fill", color: .secondary, help: "Locked")])
        expectEqual(marks()[b], [], "only the locked one")
        h.editor.unlock([a])
        expectEqual(marks()[a], [])
        h.editor.undo()
        expectEqual(marks()[a]?.map(\.help), ["Locked"], "undoing Unlock locks it, and its row says so")
    },
])
