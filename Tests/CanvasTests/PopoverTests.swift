import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Geometry
import TestKit

// The popover: text a plugin shows beside part of the board while the pointer rests there, one at a
// time, after a delay (at once while one shows or has just gone), and gone as the person goes on to
// something else.

/// Counts what the editor tells its view of the popover.
@MainActor private final class PopoverHost: CanvasEditorDelegate {
    var changes = 0
    func editorNeedsDisplay(_ editor: CanvasEditor) {}
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {}
    func editorPopoverDidChange(_ editor: CanvasEditor) { changes += 1 }
}

private let line = CGRect(x: 10, y: 10, width: 40, height: 19)

@MainActor private func popover(_ name: String, at anchor: CGRect = line) -> CanvasPopover {
    CanvasPopover(id: name, anchor: anchor, text: NSAttributedString(string: name))
}

/// What the popover showing is about, by its name.
@MainActor private func shown(_ h: EditorHarness) -> String? { h.editor.popover.map { $0.id.base as? String ?? "?" } }

/// A popover about `name`, shown after its delay.
@MainActor private func show(_ name: String, in h: EditorHarness) {
    h.editor.hoverPopover(popover(name))
    h.wait(500)
    expectEqual(shown(h), name)
}

@MainActor let popoverTests = Suite("Popovers", [
    test("a popover shows once the pointer has stayed on what it's about 500 ms; the same one again keeps it, at its anchor now; nil takes it down") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let host = PopoverHost()
        h.editor.delegate = host
        h.editor.hoverPopover(popover("a"))
        h.wait(250)
        h.editor.hoverPopover(popover("a"))
        h.wait(249)
        expectEqual(shown(h), nil, "at 499 ms, from the first")
        h.wait(1)
        expectEqual(shown(h), "a")
        expectEqual(h.editor.popover?.text.string, "a")
        expectEqual(host.changes, 1)
        let moved = CGRect(x: 60, y: 10, width: 40, height: 19)
        h.editor.hoverPopover(popover("a", at: moved))
        expectEqual(h.editor.popover?.anchor, moved, "where its anchor is now")
        expectEqual(host.changes, 2)
        h.editor.hoverPopover(popover("a", at: moved))
        expectEqual(host.changes, 2, "nothing moved: nothing to tell")
        h.editor.hoverPopover(nil)
        expectEqual(shown(h), nil)
        expectEqual(host.changes, 3)
        h.editor.hoverPopover(nil)
        expectEqual(host.changes, 3)
    },
    test("while one shows, or within 500 ms of its going, another shows at once; after that, it waits its delay") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        show("a", in: h)
        h.editor.hoverPopover(popover("b"))
        expectEqual(shown(h), "b", "at once, in its place")
        h.editor.hoverPopover(nil)
        h.wait(499)
        h.editor.hoverPopover(popover("c"))
        expectEqual(shown(h), "c", "499 ms after one went")
        h.editor.hoverPopover(nil)
        h.wait(500)
        h.editor.hoverPopover(popover("d"))
        expectEqual(shown(h), nil, "500 ms after")
        h.wait(500)
        expectEqual(shown(h), "d")
    },
    test("the pointer going on to something else before the delay waits it again from there; to nothing, nothing shows") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        h.editor.hoverPopover(popover("a"))
        h.wait(300)
        h.editor.hoverPopover(popover("b"))
        h.wait(300)
        expectEqual(shown(h), nil, "b's delay is its own")
        h.wait(200)
        expectEqual(shown(h), "b")
        h.editor.hoverPopover(nil)
        h.wait(600)
        h.editor.hoverPopover(popover("c"))
        h.wait(300)
        h.editor.hoverPopover(nil)
        h.wait(600)
        expectEqual(shown(h), nil, "gone from before it showed")
    },
    test("a press, a key on the canvas, the camera moving, editing and another board take it down, and what waits; the next waits its delay") {
        let p = ShapeID(), card = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 400, y: 0, width: 100, height: 100)))),
                                                            AnyShapeRecord(ShapeRecord(id: card, Card(CGRect(x: 0, y: 0, width: 100, height: 60))))]),
                              children: [p: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 10, height: 10))))])])
        let h = try EditorHarness(plugins: [FixturesPlugin(), PocketsPlugin(), CardsPlugin()], file: file)
        // Each: what's so before it (the card edited, for its editing to end), and what happens.
        let goings: [(String, @MainActor () -> Void, @MainActor () -> Void)] = [
            ("a press", {}, { h.press(at: CGPoint(x: 700, y: 500)); h.release() }),
            ("a key", {}, { h.key("x") }),
            ("the camera", {}, { h.editor.camera.pan(by: CGSize(width: 10, height: 0)) }),
            ("editing beginning", { h.editor.endEditing() }, { h.editor.beginEditing(card) }),
            ("editing ending", { h.editor.beginEditing(card) }, { h.editor.endEditing() }),
            ("another board", { h.editor.showBoard(.root) }, { h.enter(p) }),
        ]
        for (going, before, happen) in goings {
            before()
            show("a", in: h)
            happen()
            expectEqual(shown(h), nil, going)
            h.editor.hoverPopover(popover("b"))
            expectEqual(shown(h), nil, "\(going): the next waits")
            h.editor.hoverPopover(nil)
            before()
            h.wait(600)
            h.editor.hoverPopover(popover("c"))
            h.wait(200)
            happen()
            h.wait(300)
            expectEqual(shown(h), nil, "\(going): what waited went")
            h.editor.hoverPopover(nil)
        }
    },
    test("an editing view's popover is anchored in its coordinates, the shape's box at their origin; its session over, it shows none") {
        let h = try EditorHarness(plugins: [FixturesPlugin(), CardsPlugin()])
        let card = h.add(Card(CGRect(x: 100, y: 50, width: 100, height: 60)))
        expect(h.editor.beginEditing(card))
        let field = try require(h.editor.makeEditingView()?.view as? CardField)
        field.context.hoverPopover(popover("words", at: CGRect(x: 5, y: 5, width: 20, height: 19)))
        h.wait(500)
        expectEqual(shown(h), "words")
        expectEqual(h.editor.popover?.anchor, CGRect(x: 105, y: 55, width: 20, height: 19), "in world units")
        field.context.hoverPopover(nil)
        expectEqual(shown(h), nil)
        h.editor.endEditing()
        field.context.hoverPopover(popover("late"))
        h.wait(500)
        expectEqual(shown(h), nil, "from a session that's over")
    },
])
