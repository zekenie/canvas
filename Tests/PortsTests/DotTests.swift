import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit
import Topology

// A shape's dots show while the pointer is on it (or near it) in the select tool: a dot of radius 4
// (5 lit), 12 points out from the middle of each side its ports list. Each is checked in its middle,
// which its fill covers (`dotPixels`), against a render with nothing hovered.

@MainActor let dotTests = Suite("Where port dots show", [
    test("hovering a box in the select tool shows a dot just outside the middle of each side, and nothing further out") {
        let h = try portsHarness()
        h.add(Box(boxFrame))
        let plain = render(h)
        h.move(to: boxMiddle)
        let hovered = render(h)
        for (side, center) in boxDots { expectEqual(dotPixels(plain, hovered, at: center), 16, "\(side)") }
        expectEqual(changedPixels(plain, hovered, in: CGRect(x: 0, y: 0, width: 600, height: 80)), 0, "above")
        expectEqual(changedPixels(plain, hovered, in: CGRect(x: 320, y: 0, width: 280, height: 400)), 0, "right")
        expectEqual(changedPixels(plain, hovered, in: CGRect(x: 0, y: 220, width: 600, height: 180)), 0, "below")
        expectEqual(changedPixels(plain, hovered, in: CGRect(x: 0, y: 0, width: 80, height: 400)), 0, "left")
    },
    test("a side the kind's ports don't list has no dot") {
        let h = try portsHarness(boxSides: [.left, .right])
        h.add(Box(boxFrame))
        let plain = render(h)
        h.move(to: boxMiddle)
        let hovered = render(h)
        expectEqual(dotPixels(plain, hovered, at: leftDot), 16)
        expectEqual(dotPixels(plain, hovered, at: rightDot), 16)
        expectEqual(dotPixels(plain, hovered, at: topDot), 0)
        expectEqual(dotPixels(plain, hovered, at: bottomDot), 0)
        h.move(to: topDot)
        expectEqual(h.editor.hoveredButton, nil, "nothing to hover there")
    },
    test("a kind whose ports only take connections has no dots, and none to hover") {
        let h = try portsHarness(boxRole: .target)
        h.add(Box(boxFrame))
        let plain = render(h)
        h.move(to: boxMiddle)
        let hovered = render(h)
        for (side, center) in boxDots { expectEqual(dotPixels(plain, hovered, at: center), 0, "\(side)") }
        h.move(to: rightDot)
        expectEqual(h.editor.hoveredButton, nil)
    },
    test("without a connector no shape has dots") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), PortsPlugin(), channelsPlugin()])
        h.add(Box(boxFrame))
        let plain = render(h)
        h.move(to: boxMiddle)
        let hovered = render(h)
        for (side, center) in boxDots { expectEqual(dotPixels(plain, hovered, at: center), 0, "\(side)") }
        h.move(to: rightDot)
        expectEqual(h.editor.hoveredButton, nil)
    },
    test("a shape the connector can't start from has no dots") {
        let connections = ConnectionLog()
        let h = try portsHarness(connections)
        let box = h.add(Box(boxFrame))
        connections.canConnect = { $0 != box }
        let plain = render(h)
        h.move(to: boxMiddle)
        let hovered = render(h)
        for (side, center) in boxDots { expectEqual(dotPixels(plain, hovered, at: center), 0, "\(side)") }
    },
    test("dots show only in the select tool: changing tools takes them away, and another tool never shows them") {
        let h = try portsHarness()
        h.add(Box(boxFrame))
        let plain = render(h)
        h.move(to: boxMiddle)
        expectEqual(dotPixels(plain, render(h), at: rightDot), 16)
        h.editor.setTool(.hand)
        expectEqual(dotPixels(plain, render(h), at: rightDot), 0, "the hand tool")
        h.move(to: CGPoint(x: 210, y: 150))
        h.move(to: rightDot)
        expectEqual(dotPixels(plain, render(h), at: rightDot), 0, "moved in the hand tool")
        expectEqual(h.editor.button(atViewPoint: rightDot), nil)
        h.editor.setTool(.select)
        h.move(to: boxMiddle)
        expectEqual(dotPixels(plain, render(h), at: rightDot), 16, "back in the select tool, once the pointer moves")
    },
    test("zoomed out past a quarter there are no dots; at a quarter there are") {
        for (zoom, shows) in [(CGFloat(0.25), true), (0.24, false)] {
            let h = try portsHarness()
            h.editor.camera = Camera(zoom: zoom)
            h.add(Box(world(boxFrame, zoom: zoom)))           // shown where boxFrame is
            let plain = render(h)
            h.move(to: boxMiddle)
            let hovered = render(h)
            for (side, center) in boxDots { expectEqual(dotPixels(plain, hovered, at: center), shows ? 16 : 0, "\(side) at \(zoom)") }
            h.move(to: rightDot)
            expectEqual(h.editor.hoveredButton != nil, shows, "a dot to hover at \(zoom)")
        }
    },
    test("zoomed in, dots keep their size and their distance from the shape on screen") {
        /// How far from the right dot's middle it drew, in view points: to the farthest point it changed
        /// on its outer side (the shape's hover outline is on the other).
        @MainActor func dotRadius(zoom: CGFloat) throws -> CGFloat {
            let h = try portsHarness()
            h.editor.camera = Camera(zoom: zoom)
            h.add(Box(world(boxFrame, zoom: zoom)))
            let plain = render(h)
            h.move(to: boxMiddle)
            let hovered = render(h)
            for (side, center) in boxDots { expectEqual(dotPixels(plain, hovered, at: center), 16, "\(side) at \(zoom)") }
            var farthest: CGFloat = 0
            for y in 120..<180 {
                for x in 304..<340 where pixel(plain, at: CGPoint(x: x, y: y)) != pixel(hovered, at: CGPoint(x: x, y: y)) {
                    farthest = max(farthest, CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5).distance(to: rightDot))
                }
            }
            return farthest
        }
        // 4 points, and its ring's 0.75 more, and the edge's antialiasing.
        for zoom: CGFloat in [1, 2, 4] {
            let radius = try dotRadius(zoom: zoom)
            expect(radius > 4 && radius < 6.5, "\(radius) at \(zoom)×")
        }
    },
    test("the pointer leaving the canvas takes the dots away, and coming back onto the shape brings them back") {
        let h = try portsHarness()
        h.add(Box(boxFrame))
        let plain = render(h)
        h.move(to: boxMiddle)
        expectEqual(dotPixels(plain, render(h), at: leftDot), 16)
        h.editor.pointerExited()
        expectEqual(dotPixels(plain, render(h), at: leftDot), 0)
        h.move(to: boxMiddle)
        expectEqual(dotPixels(plain, render(h), at: leftDot), 16)
    },
    test("while the shape is dragged no dots show, and once it's let go they're back, where it is") {
        let h = try portsHarness()
        let moved = boxFrame.offsetBy(dx: 20, dy: 0)
        let box = h.add(Box(moved))
        let plain = render(h)                                                // where the drag leaves it, with nothing hovered
        h.editor.transact { $0.update(box) { $0.box = boxFrame } }
        h.move(to: boxMiddle)
        h.press()
        h.drag(to: boxMiddle + CGPoint(x: 20, y: 0))
        expectEqual(h.editor.document[box]?.box, moved, "it moved")
        let dragged = render(h)
        for (side, center) in boxDots { expectEqual(dotPixels(plain, dragged, at: center + CGPoint(x: 20, y: 0)), 0, "\(side)") }
        h.release()
        let released = render(h)
        for (side, center) in boxDots { expectEqual(dotPixels(plain, released, at: center + CGPoint(x: 20, y: 0)), 16, "\(side)") }
    },
    test("a dot whose middle another shape covers isn't drawn, nor hovered, and a press there presses that shape") {
        let connections = ConnectionLog()
        let h = try portsHarness(connections, more: [diamondsPlugin()])
        h.add(Box(boxFrame))
        let cover = h.add(Diamond(CGRect(x: 302, y: 135, width: 30, height: 30)))      // over the right dot's middle
        let plain = render(h)
        h.move(to: boxMiddle)
        let hovered = render(h)
        expectEqual(dotPixels(plain, hovered, at: rightDot), 0, "covered")
        for (side, center) in boxDots where side != .right { expectEqual(dotPixels(plain, hovered, at: center), 16, "\(side)") }
        h.move(to: rightDot)
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(h.editor.hovered, cover)
        expectEqual(dotPixels(plain, render(h), at: leftDot), 16, "the others stay: the pointer's within their reach")
        h.press()
        h.drag(to: rightDot + CGPoint(x: 30, y: 0))
        h.release()
        expect(connections.begun.isEmpty)
        expectEqual(h.editor.selectedShapeIDs, [cover])
    },
    test("a box close beside another above it doesn't show the dot the other covers") {
        let h = try portsHarness()
        h.add(Box(boxFrame))
        h.add(Box(CGRect(x: 310, y: 100, width: 200, height: 100)))     // 10 points right of the first, above it
        let plain = render(h)
        h.move(to: boxMiddle)
        let first = render(h)
        expectEqual(dotPixels(plain, first, at: rightDot), 0, "the first's right dot, on the second")
        expectEqual(dotPixels(plain, first, at: leftDot), 16)
        h.move(to: rightDot)
        expectEqual(h.editor.hoveredButton, nil, "nor hovered")
        h.move(to: CGPoint(x: 410, y: 150))
        let second = render(h)
        expectEqual(dotPixels(plain, second, at: CGPoint(x: 410, y: 88)), 16, "the second's top dot")
        expectEqual(dotPixels(plain, second, at: leftDot), 0, "the first's are gone")
    },
    test("a shape lying on a bigger one shows its dots over it, and a drag from one there connects") {
        let connections = ConnectionLog()
        let h = try portsHarness(connections, more: [diamondsPlugin()])
        h.add(Diamond(wholeView))                                    // under the box, and under each of its dots
        let box = h.add(Box(boxFrame))
        let plain = render(h)
        h.move(to: boxMiddle)
        let hovered = render(h)
        for (side, center) in boxDots { expectEqual(dotPixels(plain, hovered, at: center), 16, "\(side)") }
        h.move(to: rightDot)
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: box, side: .right)))
        h.press()
        h.drag(to: CGPoint(x: 400, y: 150))
        h.release()
        expectEqual(connections.begun.map(\.shape), [box])
    },
    test("a handle under the pointer takes the dots away, as it takes the hover") {
        let h = try portsHarness(more: [dialsPlugin()])
        let dial = h.add(Dial(boxFrame))
        h.editor.selection = dial
        let plain = render(h)
        h.move(to: CGPoint(x: 150, y: 130))                  // on the dial, off its handle
        expectEqual(dotPixels(plain, render(h), at: rightDot), 16)
        h.move(to: boxMiddle)                                // its handle
        expect(h.editor.hoveredHandle != nil)
        let onHandle = render(h)
        for (side, center) in boxDots { expectEqual(dotPixels(plain, onHandle, at: center), 0, "\(side)") }
        h.move(to: CGPoint(x: 150, y: 130))
        expectEqual(dotPixels(plain, render(h), at: rightDot), 16, "off the handle, back")
    },
    test("a read-only shape keeps its ports: its dots show, and a drag from one connects without trying to change it") {
        let connections = ConnectionLog(), log = RefusalLog()
        let h = try portsHarness(connections, more: [FreezingPlugin(log: log)])
        let box = h.add(Box(boxFrame))
        h.editor.freeze([box])
        let plain = render(h)
        h.move(to: boxMiddle)
        for (side, center) in boxDots { expectEqual(dotPixels(plain, render(h), at: center), 16, "\(side)") }
        h.connect(from: rightDot, to: CGPoint(x: 400, y: 150))
        expectEqual(connections.begun.map(\.shape), [box])
        expectEqual(log.refusals, [])
        expectEqual(h.editor.document[box]?.box, boxFrame)
    },
    test("dots go where their shape is drawn: they follow its drawing offset, as a locked shape's shake") {
        let h = try portsHarness()
        let box = h.add(Box(boxFrame))
        h.hoverDot(rightDot)                                  // lit, so opaque in its middle
        let still = render(h)
        h.editor.setDrawingOffset(CGPoint(x: 5, y: 0), for: box)
        let shaken = render(h)
        for y in -3...3 {
            for x in -3...3 {
                let point = rightDot + CGPoint(x: x, y: y)
                expectEqual(pixel(shaken, at: point + CGPoint(x: 5, y: 0)), pixel(still, at: point), "right, (\(x), \(y))")
            }
        }
        for y in -2...2 {
            for x in -2...2 {
                let point = leftDot + CGPoint(x: x, y: y)
                expectEqual(pixel(shaken, at: point + CGPoint(x: 5, y: 0)), pixel(still, at: point), "left, (\(x), \(y))")
            }
        }
        expect(pixel(shaken, at: rightDot - CGPoint(x: 2, y: 0)) != pixel(still, at: rightDot - CGPoint(x: 2, y: 0)), "not where it was")
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: box, side: .right)), "hit where the shape is")
    },
    test("a dot is its first channel's color, fainter at rest; hovered, it's full, bigger, and haloed") {
        let h = try portsHarness()
        h.add(Box(boxFrame))
        let plain = render(h)
        h.move(to: boxMiddle)
        let resting = render(h)
        h.move(to: rightDot)
        let lit = render(h)
        let rest = pixel(resting, at: rightDot), full = pixel(lit, at: rightDot)
        expect(full[0] > 200 && full[1] < 100 && full[2] < 100, "red: \(full)")
        expect(rest[0] > 200 && rest[1] > full[1] + 40 && rest[1] < 200, "a fainter red: \(rest)")
        let rim = rightDot + CGPoint(x: 0, y: 3.5)                           // inside a lit dot, on a resting one's ring
        expect(pixel(resting, at: rim)[1] > 180, "a resting dot's white ring: \(pixel(resting, at: rim))")
        expect(pixel(lit, at: rim)[1] < 120, "a lit one's red: \(pixel(lit, at: rim))")
        let halo = rightDot + CGPoint(x: 8, y: 0)
        expectEqual(pixel(resting, at: halo), pixel(plain, at: halo), "no halo at rest")
        expect(pixel(lit, at: halo) != pixel(plain, at: halo), "a halo")
        expectEqual(dotPixels(plain, lit, at: leftDot), 16, "the others stay, at rest")
        expectEqual(pixel(lit, at: leftDot), pixel(resting, at: leftDot))
    },
    test("a channel without a color of its own draws gray, and a side on two channels draws in the first's") {
        let pipesFirst = Contributor(id: "pipes-first") { $0.ports(Box.self, on: Pipe.self, sides: [.right]) }
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), FixturesPlugin(), PortsPlugin(), pipesFirst, channelsPlugin(),
                                            connectorPlugin(ConnectionLog())])
        h.add(Box(boxFrame))
        h.hoverDot(rightDot)
        let lit = pixel(render(h), at: rightDot)
        expect(abs(lit[0] - lit[1]) < 16 && abs(lit[1] - lit[2]) < 16, "gray, the pipe's: \(lit)")
        h.hoverDot(leftDot)
        let left = pixel(render(h), at: leftDot)
        expect(left[0] > 200 && left[1] < 100, "red, the wire's: \(left)")
    },
])
