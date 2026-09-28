import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Ports
import Selection
import TestKit

// A switch of board lets go of what the pointer was doing on the board left: the dots shown and the
// dot hovered.

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
])
