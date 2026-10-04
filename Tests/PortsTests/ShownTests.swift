import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// What's drawn is what's pressed: a dot no one can see takes no press, a dot hidden by a shape on
// top is hidden whatever sides its kind has, and dots go as soon as the pointer's away from them.

/// Diamonds the select tool sees through (`unselectable()`).
@MainActor func unselectableDiamondsPlugin() -> Contributor {
    Contributor(id: "diamonds") { registrar in registrar.shape(DiamondDefinition()) { $0.unselectable() } }
}

@MainActor let shownTests = Suite("Dots that show, and only those", [
    test("a kind with ports on one side has that dot hidden by a shape on top, as one with several has") {
        let connections = ConnectionLog()
        let h = try portsHarness(connections, boxSides: [.right], more: [diamondsPlugin()])
        h.add(Box(boxFrame))
        let cover = h.add(Diamond(CGRect(x: 302, y: 135, width: 30, height: 30)))      // over the right dot's middle
        let plain = render(h)
        h.move(to: boxMiddle)
        expectEqual(dotPixels(plain, render(h), at: rightDot), 0, "covered")
        h.move(to: rightDot)
        expectEqual(h.editor.hoveredButton, nil)
        h.press()
        h.drag(to: rightDot + CGPoint(x: 30, y: 0))
        h.release()
        expect(connections.begun.isEmpty)
        expectEqual(h.editor.selectedShapeIDs, [cover])
    },
    test("a box dragged and let go with Space pressed during the drag shows no dots beside the open hand: the hand's press would pan") {
        let h = try portsHarness()
        h.add(Box(boxFrame))
        h.move(to: boxMiddle)
        h.press()
        h.drag(to: boxMiddle + CGPoint(x: 40, y: 0))
        h.key(" ")
        h.drag(to: boxMiddle + CGPoint(x: 60, y: 0))
        h.release()
        let released = render(h)
        expectEqual(h.editor.pointerOverCanvas, nil)
        h.editor.keyUp(KeyStroke(" "))
        h.move(to: CGPoint(x: 580, y: 390))
        expectEqual(dotPixels(render(h), released, at: rightDot + CGPoint(x: 60, y: 0)), 0, "none, as with the pointer away")
    },
    test("a shape the select tool sees through doesn't hide a dot: it shows, and a drag from it connects") {
        let connections = ConnectionLog()
        let h = try portsHarness(connections, more: [unselectableDiamondsPlugin()])
        let box = h.add(Box(boxFrame))
        h.add(Diamond(CGRect(x: 302, y: 135, width: 30, height: 30)))
        let plain = render(h)
        h.hoverDot(rightDot)
        expectEqual(dotPixels(plain, render(h), at: rightDot), 16)
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: box, side: .right)))
        h.press()
        h.drag(to: rightDot + CGPoint(x: 30, y: 0))
        expectEqual(connections.begun.map(\.shape), [box])
    },
    test("just after a tool change, before the pointer moves, a press by a dot presses the canvas: no dot shows there to take it") {
        let connections = ConnectionLog()
        let h = try portsHarness(connections)
        h.add(Box(boxFrame))
        h.hoverDot(rightDot)
        h.key("h")                                            // the hand, and back, with the pointer still
        h.key("v")
        let plain = render(h)
        expectEqual(h.editor.pointerOverCanvas, nil)
        h.press()
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(dotPixels(plain, render(h), at: rightDot), 0, "none drawn at the press")
        h.drag(to: CGPoint(x: 400, y: 300))
        expect(connections.begun.isEmpty)
        expect(h.editor.brush != nil, "a marquee")
        h.release()
        h.move(to: rightDot)
        expectEqual(h.editor.hoveredButton.map { $0.base is PortDot }, true, "once it's moved, the dot's there")
    },
    test("Escape on a pressed dot, then the press held away from the shape: its dots go at once") {
        let h = try portsHarness()
        h.add(Box(boxFrame))
        let plain = render(h)
        h.hoverDot(rightDot)
        h.press()
        h.escape()
        expectEqual(h.editor.pointerOverCanvas, nil, "the select tool won't see the pointer till the release")
        h.drag(to: CGPoint(x: 500, y: 350))
        let held = render(h)
        for (side, center) in boxDots { expectEqual(dotPixels(plain, held, at: center), 0, "\(side)") }
        h.release()
        expectEqual(dotPixels(plain, render(h), at: leftDot), 0, "released away")
    },
    test("the camera moved under a still pointer takes the dots away where the pointer's no longer near them") {
        let h = try portsHarness()
        h.add(Box(boxFrame))
        h.move(to: boxMiddle)
        h.editor.camera = Camera(origin: CGPoint(x: -150, y: 0), zoom: 1)          // the box draws 150 points right
        let moved = render(h)
        h.editor.pointerExited()
        let gone = render(h)
        for (side, center) in boxDots {
            expectEqual(dotPixels(moved, gone, at: center + CGPoint(x: 150, y: 0)), 0, "\(side), where it's drawn now")
        }
    },
    test("once a drag from a dot is handed over, its shape's dots don't come back on a release within their reach but on none") {
        let h = try portsHarness()
        h.add(Box(boxFrame))
        let plain = render(h)
        h.connect(from: rightDot, to: CGPoint(x: 400, y: 150), releasing: false)
        h.drag(to: CGPoint(x: 318, y: 178))                   // within the box's reach, 28.6 points from its right dot
        h.release()
        expectEqual(dotPixels(plain, render(h), at: leftDot), 0)
    },
    test("whose dots show changing asks for a redraw, even when nothing else the pointer's over changes") {
        let h = try portsHarness()
        let counter = DisplayCounter()
        h.editor.delegate = counter
        h.add(Box(boxFrame))
        h.move(to: boxMiddle)
        h.move(to: CGPoint(x: 323, y: 120))                  // over empty canvas, within the box's reach
        let within = counter.redraws
        h.move(to: CGPoint(x: 325, y: 120))                  // past it: the box's dots go
        expect(counter.redraws > within)
        let gone = counter.redraws
        h.move(to: CGPoint(x: 330, y: 120))
        expectEqual(counter.redraws, gone, "nothing changes, nothing redraws")
    },
    test("a shaking shape's dots are pressed where the shape is, not where it's drawn") {
        let h = try portsHarness()
        let box = h.add(Box(boxFrame))
        h.move(to: boxMiddle)
        h.editor.setDrawingOffset(CGPoint(x: 5, y: 0), for: box)
        h.move(to: rightDot)
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: box, side: .right)))
        h.move(to: rightDot + CGPoint(x: 15, y: 0))           // 10 points from where it's drawn, 15 from where it is
        expectEqual(h.editor.hoveredButton, nil)
    },
])

/// Counts what the editor tells its view. (Its delegate protocol is the host's, so it can't be
/// public in CanvasTesting.)
final class DisplayCounter: CanvasEditorDelegate {
    var redraws = 0
    func editorNeedsDisplay(_ editor: CanvasEditor) { redraws += 1 }
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {}
}
