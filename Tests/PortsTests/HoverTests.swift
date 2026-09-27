import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Ports
import Selection
import TestKit

// Whose dots show, and which dot is hovered, as the pointer moves: a shape's dots show from when
// the pointer's on it until it goes further than their reach from it (24 points past its bounds: a
// dot's 12 points out, and 12 more for its hit), or onto another shape with ports.

@MainActor let hoverTests = Suite("Hovering ports", [
    test("from the shape into the space around it, its dots stay, on every side, while the pointer's within their reach") {
        let reached: [(side: String, inside: CGPoint, outside: CGPoint)] = [
            ("above", CGPoint(x: 150, y: 77), CGPoint(x: 150, y: 75)),
            ("right", CGPoint(x: 323, y: 120), CGPoint(x: 325, y: 120)),
            ("below", CGPoint(x: 150, y: 223), CGPoint(x: 150, y: 225)),
            ("left", CGPoint(x: 77, y: 120), CGPoint(x: 75, y: 120)),
        ]
        for (side, inside, outside) in reached {
            let h = try portsHarness()
            h.add(Box(boxFrame))
            let plain = render(h)
            h.move(to: boxMiddle)
            h.move(to: inside)
            expectEqual(h.editor.hovered, nil, side)
            expectEqual(h.editor.hoveredButton, nil, side)
            let near = render(h)
            for (dot, center) in boxDots { expectEqual(dotPixels(plain, near, at: center), 16, "\(side): \(dot) within reach") }
            h.move(to: outside)
            let far = render(h)
            for (dot, center) in boxDots { expectEqual(dotPixels(plain, far, at: center), 0, "\(side): \(dot) past it") }
            h.move(to: inside)
            expectEqual(dotPixels(plain, render(h), at: leftDot), 0, "\(side): back within reach, the shape must be hovered again")
        }
    },
    test("onto a dot, the dot is hovered, not its shape, with the open hand; back onto the shape, the shape") {
        let h = try portsHarness()
        let box = h.add(Box(boxFrame))
        h.move(to: boxMiddle)
        expectEqual(h.editor.hovered, box)
        expectEqual(h.editor.cursor, .standard)
        for (side, center) in boxDots {
            h.move(to: center)
            expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: box, side: side)), "\(side)")
            expectEqual(h.editor.hovered, nil, "\(side)")
            expectEqual(h.editor.cursor, .openHand, "\(side)")
        }
        h.move(to: boxMiddle)
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(h.editor.hovered, box)
        expectEqual(h.editor.cursor, .standard)
    },
    test("a dot is hovered within 12 points of its middle, and not further") {
        let h = try portsHarness()
        let box = h.add(Box(boxFrame))
        h.move(to: boxMiddle)
        h.move(to: rightDot + CGPoint(x: 8, y: 8))           // 11.3 points away
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: box, side: .right)))
        h.move(to: rightDot + CGPoint(x: 9, y: 9))           // 12.7
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(h.editor.cursor, .standard)
    },
    test("zoomed in or out, a dot's reach and the space around its shape are the same on screen") {
        for zoom: CGFloat in [0.5, 2] {
            let h = try portsHarness()
            let box = h.add(Box(world(boxFrame, zoom: zoom)))
            h.editor.camera = Camera(zoom: zoom)
            h.move(to: boxMiddle)
            h.move(to: rightDot + CGPoint(x: 8, y: 8))
            expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: box, side: .right)), "within 12 points at \(zoom)×")
            h.move(to: rightDot + CGPoint(x: 9, y: 9))
            expectEqual(h.editor.hoveredButton, nil, "past 12 points at \(zoom)×")
            let shown = render(h)                                     // its dots, at rest
            h.move(to: CGPoint(x: 323, y: 120))
            expectEqual(dotPixels(shown, render(h), at: leftDot), 0, "23 points past the shape they stay, at \(zoom)×")
            h.move(to: CGPoint(x: 325, y: 120))
            expectEqual(dotPixels(shown, render(h), at: leftDot), 16, "25 points past it they're gone, at \(zoom)×")
        }
    },
    test("a commit that covers a hovered dot, or takes it from under the pointer, lets go of it; uncovered, it's hovered again") {
        let h = try portsHarness(more: [diamondsPlugin()])
        let box = h.add(Box(boxFrame))
        h.hoverDot(rightDot)
        let cover = h.add(Diamond(CGRect(x: 302, y: 135, width: 30, height: 30)))
        expectEqual(h.editor.hoveredButton, nil, "covered")
        h.editor.transact { $0.delete([cover]) }
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: box, side: .right)), "uncovered")
        h.editor.transact { $0.update(box) { $0.box = boxFrame.offsetBy(dx: 0, dy: 100) } }
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(h.editor.cursor, .standard)
    },
    test("a dot the pointer comes to straight from empty canvas is hovered, and shows its shape's dots, as data-canvas's halo does; within reach but off every dot, nothing shows") {
        let h = try portsHarness()
        let box = h.add(Box(boxFrame))
        let plain = render(h)
        h.move(to: CGPoint(x: 400, y: 150))
        h.move(to: CGPoint(x: 312, y: 172))                     // 22 points below the right dot, within reach of the box
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(dotPixels(plain, render(h), at: rightDot), 0)
        h.move(to: rightDot)
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: box, side: .right)))
        let shown = render(h)
        for dot in [topDot, rightDot, bottomDot, leftDot] { expectEqual(dotPixels(plain, shown, at: dot), 16) }
    },
    test("a shape without ports within reach of the dots is hovered, and the dots stay") {
        let h = try portsHarness(more: [diamondsPlugin()])
        h.add(Box(boxFrame))
        let diamond = h.add(Diamond(CGRect(x: 305, y: 160, width: 20, height: 20)))       // clear of the right dot
        let plain = render(h)
        h.move(to: boxMiddle)
        h.move(to: CGPoint(x: 315, y: 170))
        expectEqual(h.editor.hovered, diamond)
        expectEqual(h.editor.hoveredButton, nil)
        for (side, center) in boxDots { expectEqual(dotPixels(plain, render(h), at: center), 16, "\(side)") }
    },
    test("a neighbor with ports under the pointer takes the dots over") {
        let h = try portsHarness()
        let first = h.add(Box(boxFrame))
        let second = h.add(Box(CGRect(x: 340, y: 100, width: 200, height: 100)))     // 40 points right of the first
        let plain = render(h)
        h.move(to: boxMiddle)
        h.move(to: CGPoint(x: 320, y: 120))                  // in the gap: within both's reach
        let gap = render(h)
        expectEqual(dotPixels(plain, gap, at: leftDot), 16, "the first's")
        expectEqual(dotPixels(plain, gap, at: CGPoint(x: 440, y: 88)), 0, "not the second's")
        h.move(to: CGPoint(x: 440, y: 150))
        expectEqual(h.editor.hovered, second)
        let over = render(h)
        expectEqual(dotPixels(plain, over, at: CGPoint(x: 440, y: 88)), 16, "the second's")
        expectEqual(dotPixels(plain, over, at: CGPoint(x: 552, y: 150)), 16, "the second's")
        expectEqual(dotPixels(plain, over, at: leftDot), 0, "not the first's")
        expectEqual(dotPixels(plain, over, at: topDot), 0, "not the first's")
        h.move(to: CGPoint(x: 328, y: 150))                  // the second's left dot
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: second, side: .left)))
        h.move(to: boxMiddle)
        h.move(to: rightDot)
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: first, side: .right)))
    },
    test("two boxes close together: between them, the dot hovered is that of the box the pointer came from") {
        let h = try portsHarness()
        let first = h.add(Box(boxFrame))
        let second = h.add(Box(CGRect(x: 330, y: 100, width: 200, height: 100)))     // its left dot at (318, 150)
        let between = CGPoint(x: 315, y: 150)                                          // 3 points from either dot
        let plain = render(h)
        h.move(to: boxMiddle)
        h.move(to: between)
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: first, side: .right)))
        expectEqual(dotPixels(plain, render(h), at: CGPoint(x: 430, y: 88)), 0, "only the first's dots")
        h.move(to: CGPoint(x: 430, y: 150))
        h.move(to: between)
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: second, side: .left)))
        let fromSecond = render(h)
        expectEqual(dotPixels(plain, fromSecond, at: CGPoint(x: 430, y: 88)), 16, "the second's dots")
        expectEqual(dotPixels(plain, fromSecond, at: leftDot), 0, "not the first's")
    },
    test("a hovered dot whose shape goes is let go of, and so are its dots; one that comes under the still pointer is hovered") {
        let h = try portsHarness()
        let box = h.add(Box(boxFrame))
        let plain = render(h)
        h.hoverDot(rightDot)
        expectEqual(h.editor.cursor, .openHand)
        h.editor.transact { $0.delete([box]) }
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(h.editor.cursor, .standard)
        expectEqual(dotPixels(plain, render(h), at: leftDot), 0)
        let another = h.add(Box(boxFrame))                    // where it was: its right dot's under the pointer
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: another, side: .right)))
        expectEqual(h.editor.cursor, .openHand)
        expectEqual(dotPixels(plain, render(h), at: leftDot), 16)
    },
    test("changing tools lets go of a hovered dot") {
        let h = try portsHarness()
        h.add(Box(boxFrame))
        h.hoverDot(rightDot)
        h.editor.setTool(.hand)
        expectEqual(h.editor.hoveredButton, nil)
        h.editor.setTool(.select)
        expectEqual(h.editor.hoveredButton, nil)
    },
    test("the pointer leaving the canvas lets go of a hovered dot") {
        let h = try portsHarness()
        h.add(Box(boxFrame))
        h.hoverDot(rightDot)
        h.editor.pointerExited()
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(h.editor.cursor, .standard)
    },
])
