import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Selection
import TestKit

// A kit's double-click (Kits.swift): what a double-click on empty canvas places is a way in, so while the kit of
// the plugin that claims it is off in the file, a double-click there places nothing; turned on, it places again.

/// A dowel: a box of the test's own, which a double-click on empty canvas places while its kit is on.
private struct Dowel: BoxShapeProps {
    static let kind: ShapeKind = "dowel"
    static let properties = Properties<Dowel> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
    init() { self.init(.zero) }
}

private struct DowelDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Dowel>, in context: RenderContext) {}
}

/// The workshop's double-click, from a plugin in the kit: a 40 × 40 dowel.
@MainActor private let dowels = Contributor(id: "dowels") { r in
    r.join(Workshop.self)
    r.shape(DowelDefinition()) { dowel in dowel.createOnDoubleClick(dowel.placement(size: CGSize(width: 40, height: 40)) { Dowel() }) }
}

@MainActor let selectionKitTests = Suite("A kit's double-click", [
    test("while the kit is off a double-click on empty canvas places nothing; turned on, it places the kit's shape") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), dowels])
        h.press(at: CGPoint(x: 300, y: 200), clickCount: 2)
        h.release()
        expectEqual(h.editor.document.shapes.count, 0, "nothing placed")
        h.editor.turn(Workshop.self, on: true)
        h.wait(1000)
        h.press(at: CGPoint(x: 300, y: 200), clickCount: 2)
        h.release()
        expectEqual(h.editor.document.shapes.map(\.kind), [Dowel.kind])
    },
])
