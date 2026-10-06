import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Clipboard
import ContextMenus
import CoreGraphics
import Keyboard
import Selection
import TestKit

// A locked subboard's board takes no shapes (CanvasTesting's frozen pocket stands in for it): Paste is
// off there, and copying still works; cutting copies and deletes nothing, as it does for a locked shape.

/// Box A and a frozen pocket P on the root; P's board holds box B and disc D.
@MainActor private struct Locked {
    let a = ShapeID(), p = ShapeID(), b = ShapeID(), d = ShapeID()

    var file: CanvasFile {
        func record<Props: ShapeProps>(_ id: ShapeID, _ props: Props) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, props)) }
        var pocket = record(p, Pocket(slot(2)))
        pocket[Frozen.self] = true
        return CanvasFile(root: CanvasDocument(shapes: [record(a, Box(slot(0))), pocket]),
                          children: [p: CanvasDocument(shapes: [record(b, Box(slot(0))), record(d, Disc(slot(1)))])])
    }

    func harness(_ pasteboard: NSPasteboard, _ log: RefusalLog) throws -> EditorHarness {
        try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), ContextMenusPlugin(), ClipboardPlugin(pasteboard: pasteboard),
                                    FixturesPlugin(), KindsPlugin(), PocketsPlugin(), FreezingPlugin(log: log)], file: file)
    }
}

@MainActor let readOnlyBoardTests = Suite("Cut, copy and paste on a read-only board", [
    test("Paste is off on a board that takes no shapes: ⌘V passes, Edit › Paste is dimmed, the menus have none, and nothing is pasted; on a board that does take them, it works as ever") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let log = RefusalLog(), f = Locked(), h = try f.harness(pasteboard, log)
        h.editor.selection = f.a
        expect(h.command("c"))
        expect(h.editor.canPaste && h.editor.canPerform(.paste))
        expect(h.enter(f.p))
        expect(!h.editor.canPaste && !h.editor.canPerform(.paste))
        let before = h.file
        expect(!h.command("v"), "⌘V isn't taken")
        h.editor.paste()
        h.editor.paste(centeredAt: CGPoint(x: 100, y: 100))
        expectEqual(h.file, before, "nothing pasted")
        expect(!h.editor.canUndo, "and no step")
        expectEqual(log.refusals, [], "and nothing refused: there was nothing to try")
        expectEqual(try require(h.secondaryClick(at: middle(0))).outline, ["Cut", "Copy", "—", "Delete"], "a shape's menu")
        expectEqual(try require(h.secondaryClick(at: middle(3))).outline, ["Select All"], "empty canvas's")
        expect(h.editor.showBoard(.root))
        expect(h.editor.canPaste && h.editor.canPerform(.paste))
        expect(h.command("v"))
        expectEqual(h.editor.document.shapes.count, 3, "a copy of A on the root")
        h.editor.freeze([f.p], false)
        expect(h.enter(f.p))
        expect(h.editor.canPaste && h.editor.canPerform(.paste), "thawed, its board takes shapes")
        expect(h.command("v"))
        expectEqual(h.editor.document.shapes.count, 3, "a copy of A beside B and D")
    },
    test("Copy goes on working there; Cut copies, deletes nothing and shakes what it tried, leaving no step, and what it copied pastes where shapes go") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let log = RefusalLog(), f = Locked(), h = try f.harness(pasteboard, log)
        expect(h.enter(f.p))
        h.editor.selection = f.b
        expect(h.editor.canCopy && h.editor.canCut)
        let before = h.file
        expect(h.command("c"))
        expectEqual(h.file, before)
        expect(h.editor.showBoard(.root))
        expect(h.command("v"))
        expectEqual(h.editor.selectedShapeIDs.compactMap { h.editor.document[$0]?.copiedFrom }, [f.b], "B, copied from a board that's read-only")
        h.editor.undo()
        expect(h.enter(f.p))
        h.editor.selection = f.b
        expect(h.command("x"))
        expectEqual(h.file, before, "nothing deleted")
        expect(!h.editor.canUndo, "no step")
        expectEqual(log.refusals, [[f.b]], "B was tried")
        h.wait(16)
        expect(h.editor.drawingOffset(of: f.b) != .zero, "and shakes")
        expect(h.editor.showBoard(.root))
        expect(h.command("v"))
        expectEqual(h.editor.selectedShapeIDs.compactMap { h.editor.document[$0]?.copiedFrom }, [f.b], "a copy: B is still there, so its id is in use")
    },
])
