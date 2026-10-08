import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import TestKit

// A render may read a service (`RenderContext.service(_:)`), which tells the editor to draw again
// when what it lends changes.

struct Bulb: BoxShapeProps {
    static let kind: ShapeKind = "bulb"
    static let properties = Properties<Bulb> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}

extension Bulb {
    init() { self.init(.zero) }
}

/// What a bulb shows: black while on, else nothing.
@MainActor final class Lamp {
    private(set) var isOn = false
    func set(_ isOn: Bool, in editor: CanvasEditor) {
        self.isOn = isOn
        editor.setNeedsDisplay()
    }
}

extension Lamp: EditorService {}

struct BulbDefinition {}

extension BulbDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Bulb>, in context: RenderContext) {
        guard context.service(Lamp.self)?.isOn == true else { return }
        context.cg.setFillColor(CGColor(gray: 0, alpha: 1))
        context.cg.fill(shape.frame)
    }
}

@MainActor let renderLendTests = Suite("Render lend", [
    test("a render reads a service, and flipping its state with setNeedsDisplay redraws what it shows") {
        let h = try EditorHarness(plugins: [Contributor(id: "bulbs") { r in
            r.shape(BulbDefinition())
            r.service { _ in Lamp() }
        }])
        h.add(Bulb(CGRect(x: 20, y: 20, width: 60, height: 60)))
        let host = DisplayCounter()
        h.editor.delegate = host
        let lamp = try require(h.editor.service(Lamp.self))
        let size = CGSize(width: 100, height: 100)
        expectEqual(pixel(renderBitmap(h.editor, size: size), at: CGPoint(x: 50, y: 50)), [246, 246, 246, 255])
        lamp.set(true, in: h.editor)
        expectEqual(host.redraws, 1, "the service told the editor")
        expectEqual(pixel(renderBitmap(h.editor, size: size), at: CGPoint(x: 50, y: 50)), [0, 0, 0, 255])
        lamp.set(false, in: h.editor)
        expectEqual(pixel(renderBitmap(h.editor, size: size), at: CGPoint(x: 50, y: 50)), [246, 246, 246, 255])
    },
    test("a render asks for a service no plugin registers and gets nil") {
        let h = try EditorHarness(plugins: [Contributor(id: "bulbs") { $0.shape(BulbDefinition()) }])
        h.add(Bulb(CGRect(x: 20, y: 20, width: 60, height: 60)))
        expectEqual(pixel(renderBitmap(h.editor, size: CGSize(width: 100, height: 100)), at: CGPoint(x: 50, y: 50)), [246, 246, 246, 255])
    },
])
