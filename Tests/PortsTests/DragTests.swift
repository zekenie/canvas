import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Ports
import Selection
import TestKit

// A press on a dot, dragged past the drag threshold (4 points), hands the drag to the connector's
// session for a connection from the dot's shape and side, on the dot's channels, from where it was
// pressed. The test connector records what it's asked to draw (`Connections`).

@MainActor let dragTests = Suite("Dragging from a port", [
    test("past the drag threshold, a drag from a dot begins a connection from where it was pressed, and its session gets the drag") {
        let connections = Connections()
        let h = try portsHarness(connections)
        h.editor.camera = Camera(zoom: 2)
        let box = h.add(Box(world(boxFrame, zoom: 2)))       // shown where boxFrame is
        let press = CGPoint(x: 314, y: 153)                  // on the right dot, off its middle
        h.hoverDot(press)
        h.press()
        h.drag(to: press + CGPoint(x: 4, y: 0))              // at the threshold, not past it
        expect(connections.begun.isEmpty)
        expectEqual(h.editor.pressedButton, AnyHashable(PortDot(shape: box, side: .right)))
        h.drag(to: CGPoint(x: 340, y: 160))
        let connection = try require(connections.begun.first)
        expectEqual(connections.begun.count, 1)
        expectEqual(connection.shape, box)
        expectEqual(connection.side, .right)
        expectEqual(connection.channels, [Wire.id])
        expectClose(connection.origin, CGPoint(x: 157, y: 76.5))          // the press, in world units
        expectEqual(connections.drags, [CGPoint(x: 340, y: 160)], "the drag that crossed the threshold, at once")
        expect(h.editor.session is RecordingSession)
        expectEqual(h.editor.pressedButton, nil)
        expectEqual(h.editor.hoveredButton, nil)
        h.drag(to: CGPoint(x: 400, y: 200))
        expectEqual(connections.drags, [CGPoint(x: 340, y: 160), CGPoint(x: 400, y: 200)])
        h.release()
        expect(h.editor.session == nil)
        expectEqual(connections.begun.count, 1)
        expectEqual(h.editor.document[box]?.box, world(boxFrame, zoom: 2), "the shape stays where it is")
    },
    test("each side's dot begins a connection from its side") {
        let connections = Connections()
        let h = try portsHarness(connections)
        let box = h.add(Box(boxFrame))
        for (side, center) in boxDots {
            let outward = CGPoint(x: (center.x - boxMiddle.x) / 2, y: (center.y - boxMiddle.y) / 2)
            h.connect(from: center, to: center + outward)
            expectEqual(connections.begun.last?.side, side)
            expectEqual(connections.begun.last?.shape, box)
            expectClose(try require(connections.begun.last).origin, center)
        }
        expectEqual(connections.begun.count, 4)
    },
    test("released without a drag, a press on a dot does nothing: nothing begins, and the selection stays") {
        let connections = Connections()
        let h = try portsHarness(connections)
        let box = h.add(Box(boxFrame))
        let other = h.add(Box(CGRect(x: 400, y: 250, width: 100, height: 100)))
        h.editor.selection = other
        h.hoverDot(rightDot)
        h.press()
        h.drag(to: rightDot + CGPoint(x: 3, y: 0))
        h.release()
        expect(connections.begun.isEmpty)
        expectEqual(h.editor.selectedShapeIDs, [other])
        expectEqual(h.editor.pressedButton, nil)
        expectEqual(h.editor.document[box]?.box, boxFrame)
        h.editor.selection = nil
        h.click(at: leftDot)
        expectEqual(h.editor.selectedShapeIDs, [], "its shape isn't selected either")
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: box, side: .left)), "still on the dot")
    },
    test("Escape lets go of a pressed dot, and the drag that follows does nothing") {
        let connections = Connections()
        let h = try portsHarness(connections)
        let box = h.add(Box(boxFrame))
        h.hoverDot(rightDot)
        h.press()
        h.escape()
        expectEqual(h.editor.pressedButton, nil)
        expect(h.editor.session == nil)
        h.drag(to: CGPoint(x: 400, y: 300))
        h.release()
        expect(connections.begun.isEmpty)
        expectEqual(h.editor.selectedShapeIDs, [])
        expectEqual(h.editor.document[box]?.box, boxFrame)
    },
    test("a connector that draws nothing from a dot ends the press: the rest of the drag does nothing") {
        let connections = Connections()
        connections.draws = false
        let h = try portsHarness(connections)
        let box = h.add(Box(boxFrame))
        h.hoverDot(rightDot)
        h.press()
        h.drag(to: CGPoint(x: 330, y: 150))
        expect(h.editor.session == nil)
        expectEqual(h.editor.pressedButton, nil)
        h.drag(to: CGPoint(x: 400, y: 300))
        expectEqual(h.editor.brush, nil, "no marquee")
        h.release()
        expect(connections.begun.isEmpty)
        expectEqual(connections.drags, [])
        expectEqual(h.editor.selectedShapeIDs, [])
        expectEqual(h.editor.document[box]?.box, boxFrame)
    },
    test("a pressed dot draws lit, as a hovered one does, with the closed hand while it's pressed") {
        let h = try portsHarness()
        let box = h.add(Box(boxFrame))
        h.move(to: boxMiddle)
        let resting = render(h)
        h.move(to: rightDot)
        expectEqual(h.editor.cursor, .openHand)
        let hovered = render(h)
        h.press()
        expectEqual(h.editor.cursor, .closedHand)
        h.drag(to: rightDot + CGPoint(x: 2, y: 2))
        expectEqual(h.editor.cursor, .closedHand)
        h.release()
        expectEqual(h.editor.cursor, .openHand, "released on it, it's hovered again")
        // Pressed without the pointer having moved onto it: pressed, not hovered.
        h.move(to: boxMiddle)
        h.press(at: rightDot)
        expectEqual(h.editor.hoveredButton, nil)
        expectEqual(h.editor.pressedButton, AnyHashable(PortDot(shape: box, side: .right)))
        let pressed = render(h)
        let dot = CGRect(x: rightDot.x - 10, y: rightDot.y - 10, width: 20, height: 20)
        expect(changedPixels(resting, hovered, in: dot) > 100, "hovered, it's lit")
        expectEqual(changedPixels(hovered, pressed, in: dot), 0, "pressed, it's lit the same")
    },
    test("once the drag is handed over, the dots go") {
        let h = try portsHarness()
        h.add(Box(boxFrame))
        let plain = render(h)
        h.connect(from: rightDot, to: CGPoint(x: 400, y: 300), releasing: false)
        let drawing = render(h)
        for (side, center) in boxDots { expectEqual(dotPixels(plain, drawing, at: center), 0, "\(side)") }
        h.release()
        expectEqual(dotPixels(plain, render(h), at: leftDot), 0, "released away from the shape")
    },
    test("a double-click on a dot is no double-click on the canvas: nothing is made") {
        let connections = Connections()
        let h = try portsHarness(connections, more: [CardsPlugin { card, place in card.createOnDoubleClick(place) }])
        h.add(Box(boxFrame))
        h.hoverDot(rightDot)
        h.click()
        h.click(clickCount: 2)
        expectEqual(h.editor.document.shapes.count, 1)
        expect(connections.begun.isEmpty)
        expectEqual(h.editor.selectedShapeIDs, [])
    },
    test("a drag from a dot in a view zoomed out to a quarter still connects") {
        let connections = Connections()
        let h = try portsHarness(connections)
        h.editor.camera = Camera(zoom: 0.25)
        let box = h.add(Box(world(boxFrame, zoom: 0.25)))
        h.connect(from: rightDot, to: CGPoint(x: 400, y: 150))
        expectEqual(connections.begun.map(\.shape), [box])
        expectClose(try require(connections.begun.first).origin, CGPoint(x: 1248, y: 600))
    },
])
