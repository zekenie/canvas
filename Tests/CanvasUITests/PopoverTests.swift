import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import TestKit

// The canvas shows the editor's popover over everything it hosts, beside its anchor, and it takes
// no clicks.

/// A popover beside `anchor` (view points, at the harness's camera), shown after its delay.
@MainActor private func showPopover(_ h: EditorHarness, at anchor: CGRect, text: String = "{\n  \"type\": \"string\"\n}") {
    h.editor.hoverPopover(CanvasPopover(id: "p", anchor: anchor, text: NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 11)])))
    h.wait(500)
}

/// The bubble's frame: the view's, less its shadow's room (12 points all round).
@MainActor private func bubble(_ canvas: CanvasView) -> CGRect? { canvas.popoverView.map { $0.frame.insetBy(dx: 12, dy: 12) } }

@MainActor let popoverTests = Suite("Popover", [
    test("it shows over the editing view, 4 points below its anchor, its text starting under the anchor's, and takes no clicks; gone, it's taken down") {
        let (h, canvas, card, _) = try cardCanvas()
        expect(h.editor.beginEditing(card))
        let anchor = CGRect(x: 140, y: 120, width: 60, height: 19)
        showPopover(h, at: anchor)
        let view = try require(canvas.popoverView)
        expect(canvas.subviews.last === view, "over the rest")
        let frame = try require(bubble(canvas))
        expectEqual(frame.minY, anchor.maxY + 4)
        expectEqual(frame.minX, anchor.minX - 8, "its padding before its text")
        expect(frame.width > 16 && frame.height > 12, "\(frame)")
        let inside = CGPoint(x: frame.midX, y: frame.midY)
        let hit = canvas.hitTest(canvas.convert(inside, to: canvas.superview))
        expect(hit != nil && hit !== view, "clicks go to what's under it")
        h.editor.hoverPopover(nil)
        expect(canvas.popoverView == nil)
        expect(!canvas.subviews.contains { $0.frame == view.frame }, "taken down")
    },
    test("with no room below its anchor it shows above it; at the view's edge it stays 8 points in; it follows its anchor") {
        let (h, canvas, _, _) = try cardCanvas()
        showPopover(h, at: CGRect(x: 760, y: 560, width: 30, height: 19))
        var frame = try require(bubble(canvas))
        expectEqual(frame.maxY, 556, "4 points above it")
        expectEqual(frame.maxX, 792, "8 points in")
        h.editor.hoverPopover(CanvasPopover(id: "p", anchor: CGRect(x: 100, y: 100, width: 30, height: 19), text: NSAttributedString(string: "moved")))
        frame = try require(bubble(canvas))
        expectEqual(frame.minY, 123, "below it where it's gone")
        expectEqual(frame.minX, 92)
    },
    test("text taller than the room either side is cut to the room on the side with more") {
        let (h, canvas, _, _) = try cardCanvas()
        let tall = (1...60).map { "line \($0)" }.joined(separator: "\n")
        showPopover(h, at: CGRect(x: 100, y: 200, width: 30, height: 19), text: tall)
        let frame = try require(bubble(canvas))
        expectEqual(frame.minY, 223, "below, where there's more room")
        expect(frame.maxY <= 592, "within the view: \(frame)")
    },
])
