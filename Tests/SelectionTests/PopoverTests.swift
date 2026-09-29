@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Foundation
import Keyboard
import Selection
import TestKit

// Popovers (`ShapePopovers`): a plugin's popover on every shape with a box, about the 20-unit square
// 10 in from its top-left corner (a face's place, `face(of:)`), which the pointer resting there shows.

/// The shapes a popovers plugin was asked about.
@MainActor final class PopoverLog {
    var asked: [ShapeID] = []
}

/// A plugin with a popover on every shape with a box, about its square, known by its shape.
@MainActor func popoversPlugin(_ log: PopoverLog) -> Contributor {
    Contributor(id: "popovers") { r in
        r.shapePopovers { _, shape, point in
            log.asked.append(shape.id)
            guard let square = shape.box.map(face(of:)), square.contains(point) else { return nil }
            return CanvasPopover(id: shape.id, anchor: square, text: NSAttributedString(string: "about \(shape.id)"))
        }
    }
}

/// What the popover showing is about.
@MainActor private func shown(_ h: EditorHarness) -> ShapeID? { h.editor.popover?.id.base as? ShapeID }

@MainActor let popoverTests = Suite("Popovers", [
    test("the pointer resting on part of a shape that has a popover shows it after 500 ms, beside that part; off it, it goes; a press there is the shape's") {
        let log = PopoverLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), popoversPlugin(log)])
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))     // its square: 110 to 130, 110 to 130
        h.move(to: CGPoint(x: 120, y: 120))
        h.move(to: CGPoint(x: 125, y: 118), after: 250)
        h.wait(249)
        expectEqual(shown(h), nil, "499 ms after the pointer came")
        h.wait(1)
        expectEqual(shown(h), box)
        expectEqual(h.editor.popover?.anchor, CGRect(x: 110, y: 110, width: 20, height: 20))
        expectEqual(h.editor.hovered, box, "the shape is hovered as ever")
        h.move(to: CGPoint(x: 200, y: 150))
        expectEqual(shown(h), nil, "off it")
        h.move(to: CGPoint(x: 120, y: 120))
        expectEqual(shown(h), box, "back on it at once: one went a moment ago")
        h.press()
        expectEqual(shown(h), nil, "a press takes it down")
        h.release()
        expectEqual(h.editor.selection, box, "and is the shape's")
        h.wait(500)
        expectEqual(shown(h), box, "released there, the pointer rests on it again")
        let popovers = h.editor.registry.report.split(separator: "\n").first { $0.hasPrefix("popovers ") }
        expectEqual(popovers?.split(separator: " ").last, "ShapePopovers")
    },
    test("none on what's drawn for a shape outside it, under a handle, on a shape drawn as a skeleton, or once the pointer has left the canvas") {
        let log = PopoverLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), KnobsPlugin(), cornersPlugin(), popoversPlugin(log)])
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))
        h.move(to: CGPoint(x: 112, y: 112))                                    // the corner drawn over the box's square
        h.wait(500)
        expectEqual(shown(h), nil, "on what's drawn for it")
        expectEqual(h.editor.hovered, box)
        let knob = h.add(Knob(CGRect(x: 400, y: 100, width: 40, height: 40)))  // its square: 410 to 430; its handle at 420, 120
        h.editor.selection = knob
        h.move(to: CGPoint(x: 420, y: 120))
        h.wait(500)
        expectEqual(shown(h), nil, "under a handle")
        h.move(to: CGPoint(x: 125, y: 125))
        h.wait(500)
        expectEqual(shown(h), box)
        h.editor.pointerExited()
        expectEqual(shown(h), nil, "the pointer left the canvas")
        h.editor.skeletonZoom = 2                                              // skeletons at 100%
        h.move(to: CGPoint(x: 120, y: 120))
        h.wait(500)
        expectEqual(shown(h), nil, "a skeleton shows none of its content")
        expect(!log.asked.isEmpty)
    },
    test("the canvas starting to draw skeletons under a still pointer takes it down, and drawing in full again shows it after its delay") {
        let log = PopoverLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), popoversPlugin(log)])
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))
        h.move(to: CGPoint(x: 120, y: 120))
        h.wait(500)
        expectEqual(shown(h), box)
        h.editor.skeletonZoom = 2
        expectEqual(shown(h), nil)
        h.wait(600)
        h.editor.skeletonZoom = 0.35
        expectEqual(shown(h), nil, "not at once")
        h.wait(500)
        expectEqual(shown(h), box)
    },
])
