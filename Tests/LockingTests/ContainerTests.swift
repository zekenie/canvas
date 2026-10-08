import Adornments
import Canvas
import CanvasTesting
import CoreGraphics
import Locking
import Selection
import TableOfContents
import TestKit

// A locked container (CanvasTesting's corral, as a frame): everything in it is locked with it, at any
// depth, but only the container shows the lock: its chip, and the lock on its row. The menu's Lock
// and Unlock are for the shapes whose own lock can change.

/// A corral at (100, 100), 400 × 300, and a box in it at (150, 150), 100 × 100.
@MainActor private func corralWithBox(_ h: EditorHarness) -> (corral: ShapeID, box: ShapeID) {
    let corral = h.add(Corral(CGRect(x: 100, y: 100, width: 400, height: 300)))
    let box = h.add(Box(CGRect(x: 150, y: 150, width: 100, height: 100)))
    h.editor.put([box], in: corral)
    return (corral, box)
}

extension Array where Element == ContentsEntry {
    /// Each row's text, nested rows indented under theirs.
    @MainActor fileprivate var outline: [String] {
        flatMap { entry -> [String] in [entry.label?.text ?? "<view>"] + (entry.children ?? []).outline.map { "  " + $0 } }
    }

    /// Each row's marks' help, nested rows' after theirs.
    @MainActor fileprivate var marks: [[String]] { flatMap { entry -> [[String]] in [entry.marks.map(\.help)] + (entry.children ?? []).marks } }
}

@MainActor let lockedContainerTests = Suite("Locking a container", [
    test("a locked container tried shakes with what it holds, at any depth, as it moves with it") {
        let h = try lockingHarness([CorralsPlugin()])
        let (corral, box) = corralWithBox(h)
        let inner = h.add(Corral(CGRect(x: 300, y: 150, width: 150, height: 150)))
        let deep = h.add(Box(CGRect(x: 320, y: 170, width: 50, height: 50)))
        h.editor.put([inner], in: corral)
        h.editor.put([deep], in: inner)
        let loose = h.add(Box(CGRect(x: 600, y: 150, width: 100, height: 100)))
        h.editor.lock([corral])
        h.editor.selection = corral
        expect(h.key("\u{7f}"))
        expect(h.editor.document[corral] != nil, "not deleted")
        h.wait(16)
        for (id, name) in [(corral, "the container"), (box, "what it holds"), (inner, "a container in it"), (deep, "what that holds")] {
            expect(h.editor.drawingOffset(of: id) != .zero, "\(name) shakes")
        }
        expectEqual(h.editor.drawingOffset(of: box), h.editor.drawingOffset(of: corral), "together")
        expectEqual(h.editor.drawingOffset(of: loose), .zero, "a shape beside it doesn't")
        h.wait(1000)
        expectEqual(h.editor.drawingOffset(of: deep), .zero, "and stops with it")
    },
    test("a shape in a locked container is locked with it: a drag or Delete changes nothing and shakes it; the container unlocked frees it") {
        let h = try lockingHarness([CorralsPlugin()])
        let (corral, box) = corralWithBox(h)
        h.editor.lock([corral])
        expect(h.editor.isReadOnly(box) && !h.editor.isLocked(box), "read-only, not locked on its own")
        h.press(at: CGPoint(x: 200, y: 200))
        h.drag(to: CGPoint(x: 260, y: 230))
        h.wait(16)
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 150, y: 150))
        expectEqual(h.editor.selection, box, "pressing it selected it")
        expect(h.editor.drawingOffset(of: box) != .zero, "shaking")
        expectEqual(h.editor.drawingOffset(of: corral), .zero, "it was the one tried")
        h.release()
        h.wait(1000)
        expect(h.key("\u{7f}"))
        expect(h.editor.document[box] != nil, "not deleted")
        h.wait(16)
        expect(h.editor.drawingOffset(of: box) != .zero, "shaking")
        h.wait(1000)
        h.editor.unlock([corral])
        expect(!h.editor.isReadOnly(box))
        h.press(at: CGPoint(x: 200, y: 200))
        h.drag(to: CGPoint(x: 260, y: 230))
        h.release()
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 210, y: 180))
        expectEqual(h.editor.holder(of: box), corral, "still in it")
    },
    test("only the container shows the lock, its chip and the lock on its row, at any depth; a shape locked on its own in it shows its own") {
        let h = try lockingHarness([CorralsPlugin()])
        let outer = h.add(Corral(CGRect(x: 100, y: 100, width: 600, height: 500)))
        let inner = h.add(Corral(CGRect(x: 150, y: 150, width: 400, height: 300)))
        let free = h.add(Box(CGRect(x: 200, y: 200, width: 100, height: 100)))
        let own = h.add(Box(CGRect(x: 350, y: 200, width: 100, height: 100)))
        h.editor.put([inner], in: outer)
        h.editor.put([free, own], in: inner)
        h.editor.lock([own])
        h.editor.lock([outer])
        expect([inner, free, own].allSatisfy(h.editor.isReadOnly(_:)))
        @MainActor func chips(_ id: ShapeID) -> [String?] { h.editor.adornmentFrames(of: id).map(\.label.systemImage) }
        expectEqual(chips(outer), ["lock.fill"])
        expectEqual(chips(inner), [])
        expectEqual(chips(free), [])
        expectEqual(chips(own), ["lock.fill"], "its own lock")
        let contents = try require(h.editor.tableOfContents)
        expectEqual(contents.entries.outline, ["corral", "  corral", "    box", "    box"])
        expectEqual(contents.entries.marks, [["Locked"], [], [], ["Locked"]])
        h.editor.unlock([outer])
        expectEqual(chips(outer), ["lock.open.fill"], "open a moment, as any unlocked shape's")
        expectEqual(chips(inner), [])
        expectEqual(contents.entries.marks, [[], [], [], ["Locked"]])
    },
    test("the menu's Lock and Unlock are for shapes whose own lock can change: neither for shapes in a locked container, and with others, theirs") {
        let h = try lockingHarness([CorralsPlugin()])
        let (corral, box) = corralWithBox(h)
        let other = h.add(Box(CGRect(x: 600, y: 100, width: 100, height: 100)))
        h.editor.lock([corral])
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 200, y: 200))).outline, ["Delete"], "the box in it: neither")
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 400, y: 350))).outline, ["Unlock", "—", "Delete"], "the corral")
        h.editor.selectedShapeIDs = [box, other]
        let lock = try require(h.secondaryClick(at: CGPoint(x: 650, y: 150)))
        expectEqual(lock.outline, ["Lock", "—", "Delete"])
        try lock.choose("Lock")
        expect(h.editor.isLocked(other) && !h.editor.isLocked(box), "the other box alone")
        h.wait(16)
        expectEqual(h.editor.drawingOffset(of: box), .zero, "the box in the corral wasn't tried")
        h.editor.selectedShapeIDs = [corral, box]
        let unlock = try require(h.secondaryClick(at: CGPoint(x: 200, y: 200)))
        expectEqual(unlock.outline, ["Unlock", "—", "Delete"], "every one whose lock can change is locked")
        try unlock.choose("Unlock")
        expect(!h.editor.isLocked(corral) && !h.editor.isReadOnly(box), "the corral unlocked, the box with it")
        h.editor.selectedShapeIDs = [box]
        expectEqual(try require(h.secondaryClick(at: CGPoint(x: 200, y: 200))).outline, ["Lock", "—", "Delete"], "free again")
    },
])
