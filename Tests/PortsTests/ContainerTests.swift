import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Geometry
import Selection
import TestKit

// Ports on a container hollow as a frame is (CanvasTesting's paddock: hit only on its edge while it
// holds shapes, its inside the canvas), and on what it holds: its dots show from its edge and go as
// the pointer goes in among what it holds; where a press is on its edge a dot takes it only on its
// disc, so the edge moves it right up to the dots; and a connection never ends on a container and
// what it holds, either way round.

/// A paddock filling most of the view, with ports on the wire on its right, bottom and left, as a
/// frame's are.
let paddockFrame = CGRect(x: 100, y: 60, width: 400, height: 300)
let paddockLeftDot = CGPoint(x: 88, y: 210), paddockRightDot = CGPoint(x: 512, y: 210), paddockBottomDot = CGPoint(x: 300, y: 372)
/// A box in it, 12 points in from its left edge, so the box's left dot is on the paddock's edge.
let boxInPaddock = CGRect(x: 112, y: 240, width: 80, height: 60)
let heldLeftDot = CGPoint(x: 100, y: 270), heldRightDot = CGPoint(x: 204, y: 270)

@MainActor func paddockPorts() -> Contributor {
    Contributor(id: "paddock-ports") { $0.ports(Paddock.self, on: Wire.self, sides: [.right, .bottom, .left]) }
}

/// `portsHarness` with paddocks, a paddock and the box in it.
@MainActor func paddockHarness(_ connections: ConnectionLog = ConnectionLog()) throws -> (h: EditorHarness, paddock: ShapeID, box: ShapeID) {
    let h = try portsHarness(connections, more: [PaddocksPlugin(), paddockPorts()])
    let paddock = h.add(Paddock(paddockFrame)), box = h.add(Box(boxInPaddock))
    h.editor.put([box], in: paddock)
    return (h, paddock, box)
}

@MainActor let containerPortTests = Suite("Ports on and in a container", [
    test("a hollow container's dots show from its edge, and go as the pointer goes in among what it holds; an empty one's show from anywhere inside") {
        let (h, paddock, box) = try paddockHarness()
        let plain = render(h)
        h.move(to: CGPoint(x: 200, y: 362))                   // on its bottom edge
        expectEqual(h.editor.hovered, paddock)
        let onEdge = render(h)
        for dot in [paddockLeftDot, paddockRightDot, paddockBottomDot] { expectEqual(dotPixels(plain, onEdge, at: dot), 16, "\(dot) from the edge") }
        expectEqual(dotPixels(plain, onEdge, at: CGPoint(x: 300, y: 48)), 0, "none on its top")
        h.move(to: CGPoint(x: 340, y: 340))                   // inside, within a dot's reach of the edge
        for dot in [paddockLeftDot, paddockRightDot, paddockBottomDot] { expectEqual(dotPixels(plain, render(h), at: dot), 16, "\(dot) near the edge") }
        h.move(to: CGPoint(x: 400, y: 150))                   // deep inside, among what it holds
        expectEqual(h.editor.hovered, nil, "its inside is the canvas")
        let deep = render(h)
        for dot in [paddockLeftDot, paddockRightDot, paddockBottomDot] { expectEqual(dotPixels(plain, deep, at: dot), 0, "\(dot) gone deep inside") }
        h.move(to: CGPoint(x: 150, y: 270))                   // onto the box: its dots
        expectEqual(dotPixels(plain, render(h), at: heldRightDot), 16, "the box's")

        h.editor.transact { $0.delete([box]) }
        h.move(to: CGPoint(x: 200, y: 362))
        h.move(to: CGPoint(x: 400, y: 150))
        expectEqual(h.editor.hovered, paddock, "holding nothing, it's hit inside")
        expectEqual(dotPixels(plain, render(h), at: paddockRightDot), 16, "its dots show from deep inside")
    },
    test("where a press is on a container's edge a dot takes it only on its disc: the edge by its own dot moves it, and by a dot of what it holds too, whose dots stay up") {
        let connections = ConnectionLog()
        let (h, paddock, box) = try paddockHarness(connections)
        let plain = render(h)
        @MainActor func paddockOrigin() -> CGPoint? { h.editor.document[paddock]?.typed(as: Paddock.self)?.props.frame.origin }

        // 4 points out from its left edge, 8 from its left dot: within a dot's reach, on the edge.
        h.move(to: CGPoint(x: 200, y: 362))
        h.move(to: CGPoint(x: 96, y: 210))
        expectEqual(h.editor.hoveredButton, nil, "the edge, not the dot")
        expectEqual(h.editor.hovered, paddock)
        h.press()
        h.drag(to: CGPoint(x: 116, y: 230))
        h.release()
        expectEqual(paddockOrigin(), CGPoint(x: 120, y: 80), "dragged by its edge")
        expect(connections.begun.isEmpty, "no connection")
        h.editor.undo()

        // Off the edge, the dot's reach is whole again.
        h.move(to: CGPoint(x: 200, y: 362))
        h.move(to: CGPoint(x: 92, y: 210))
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: paddock, side: .left)), "8 points out: off the edge")

        // The box's left dot is on the paddock's left edge: from the box toward it, its dots stay up while the
        // pointer crosses the edge, and only its disc takes a press there.
        h.move(to: CGPoint(x: 150, y: 270))
        h.move(to: CGPoint(x: 100, y: 262))
        expectEqual(h.editor.hoveredButton, nil, "8 points from its middle, on the edge")
        expectEqual(dotPixels(plain, render(h), at: heldRightDot), 16, "the box's dots stay up")
        h.press()
        h.drag(to: CGPoint(x: 120, y: 282))
        h.release()
        expectEqual(paddockOrigin(), CGPoint(x: 120, y: 80), "dragged by its edge, the box's dot beside the press")
        expect(connections.begun.isEmpty, "no connection")
        h.editor.undo()

        h.move(to: CGPoint(x: 150, y: 270))
        h.move(to: CGPoint(x: 100, y: 267))
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: box, side: .left)), "on its disc")
        h.press()
        h.drag(to: CGPoint(x: 40, y: 380))
        h.release()
        expectEqual(connections.begun.map(\.shape), [box], "a connection from the box")
    },
    test("a connection never ends on the container that holds its start, nor on a shape inside the container it starts on") {
        let connections = ConnectionLog()
        let (h, paddock, box) = try paddockHarness(connections)
        let outside = h.add(Box(CGRect(x: 520, y: 380, width: 60, height: 40)))
        h.move(to: CGPoint(x: 150, y: 270))
        h.move(to: heldRightDot)
        h.press()
        h.drag(to: CGPoint(x: 400, y: 150))
        let fromBox = try require(connections.begun.last)
        h.release()
        h.move(to: CGPoint(x: 200, y: 362))
        h.move(to: paddockRightDot)
        h.press()
        h.drag(to: CGPoint(x: 560, y: 380))
        let fromPaddock = try require(connections.begun.last)
        h.release()
        let records = (paddock: try require(h.editor.document[paddock]), box: try require(h.editor.document[box]),
                       outside: try require(h.editor.document[outside]))
        expectEqual(h.editor.channel(of: fromBox, endingAt: records.paddock), nil, "the paddock holds the box")
        expectEqual(h.editor.channel(of: fromBox, endingAt: records.outside), Wire.id)
        expectEqual(h.editor.channel(of: fromPaddock, endingAt: records.box), nil, "the box is in the paddock")
        expectEqual(h.editor.channel(of: fromPaddock, endingAt: records.outside), Wire.id)
        let shapes = h.editor.shapeContext
        expect(!shapes.mayConnect(paddock, box) && !shapes.mayConnect(box, paddock), "either way round")
        expect(shapes.mayConnect(paddock, outside) && shapes.mayConnect(box, box), "but beside it, and a shape and itself")
    },
])
