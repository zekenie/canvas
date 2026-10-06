import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Geometry
import Selection
import TestKit

// A switch of board lets go of what the pointer was doing on the board left: the dots shown and the
// dot hovered. A board that takes no shapes (a locked subboard's) has no dots.

@MainActor let portsBoardTests = Suite("Ports across boards", [
    test("a switch of board lets go of the dots shown and the dot hovered, the board left's") {
        let h = try portsHarness(more: [PocketsPlugin()])
        let box = h.add(Box(boxFrame))
        let pocket = h.add(Pocket(CGRect(x: 400, y: 300, width: 50, height: 50)))
        let plain = render(h)
        h.hoverDot(rightDot)
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: box, side: .right)))
        expect(h.enter(pocket))
        expectEqual(h.editor.hoveredButton, nil)
        expect(h.editor.showBoard(.root))
        h.move(to: CGPoint(x: 150, y: 77))                   // within the dots' reach, off the box
        let near = render(h)
        for (dot, center) in boxDots {
            expectEqual(dotPixels(plain, near, at: center), 0, "\(dot): back on the root, no dots until the box is hovered again")
        }
        h.hoverDot(rightDot)
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: box, side: .right)))
    },
    test("a board that takes no shapes, a frozen pocket's, shows no dots and takes no press on one, so no connection begins; thawed, the dots are back") {
        let connections = ConnectionLog(), pocket = ShapeID(), box = ShapeID()
        var frozen = AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 400, y: 300, width: 50, height: 50))))
        frozen[Frozen.self] = true
        let file = CanvasFile(root: CanvasDocument(shapes: [frozen]),
                              children: [pocket: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: box, Box(boxFrame)))])])
        let h = try portsHarness(connections, more: [PocketsPlugin(), FreezingPlugin()], file: file)
        expect(h.enter(pocket))
        let plain = render(h)
        h.hoverDot(rightDot)
        expectEqual(h.editor.hoveredButton, nil, "no dot under the pointer")
        expectEqual(dotPixels(plain, render(h), at: rightDot), 0, "none drawn")
        h.press()
        h.drag(to: rightDot + CGPoint(x: 30, y: 0))
        h.release()
        expect(connections.begun.isEmpty, "a press by where the dot would be is a press on the canvas")
        expect(!h.editor.canUndo)
        expect(h.editor.showBoard(.root))
        h.editor.freeze([pocket], false)
        expect(h.enter(pocket))
        h.hoverDot(rightDot)
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: box, side: .right)))
        expectEqual(dotPixels(plain, render(h), at: rightDot), 16)
    },
    test("a lock above the board landing while the pointer is on a dot takes the dots away: none is hovered once the pointer moves, and none is drawn") {
        let pocket = ShapeID(), box = ShapeID()
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(CGRect(x: 400, y: 300, width: 50, height: 50))))]),
                              children: [pocket: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: box, Box(boxFrame)))])])
        let h = try portsHarness(more: [PocketsPlugin(), FreezingPlugin()], file: file)
        expect(h.enter(pocket))
        let plain = render(h)
        h.hoverDot(rightDot)
        expectEqual(h.editor.hoveredButton, AnyHashable(PortDot(shape: box, side: .right)))
        expectEqual(dotPixels(plain, render(h), at: rightDot), 16)
        h.editor.transact(on: .root, "Freeze") { $0.update(pocket) { $0[Frozen.self] = true } }
        expectEqual(dotPixels(plain, render(h), at: rightDot), 0, "not drawn, though the pointer hasn't moved")
        h.move(to: rightDot + CGPoint(x: 1, y: 0))
        expectEqual(h.editor.hoveredButton, nil)
    },
])
