@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Selection

/// Cards that claim the double-click on empty canvas.
@MainActor func doubleClickCards() -> CardsPlugin {
    CardsPlugin { card, place in card.createOnDoubleClick(place) }
}

/// A box with one handle, at its center.
struct Knob: BoxShapeProps {
    static let kind: ShapeKind = "knob"
    static let properties = Properties<Knob> {
        Property("frame", \.frame).required()
    }
    var frame: CGRect
    init(_ frame: CGRect) { self.frame = frame }
}
extension Knob {
    init() { self.init(.zero) }
}

struct KnobDefinition {}

extension KnobDefinition: ShapeDefinition, HandleProviding {
    func render(_ shape: ShapeRecord<Knob>, in context: RenderContext) {}
    func handles(of shape: ShapeRecord<Knob>, in context: ShapeContext) -> [HandleLocation<Int>] {
        [HandleLocation(0, at: CGPoint(x: shape.frame.midX, y: shape.frame.midY))]
    }
    func pressHandle(_ handle: Int, of shape: ShapeRecord<Knob>, at pointer: Pointer, in editor: CanvasEditor) -> HandlePress { .drag }
    func dragSession(for handle: Int, of shape: ShapeRecord<Knob>, from origin: CGPoint, in editor: CanvasEditor) -> any Session { IdleSession() }
}

struct KnobsPlugin: CanvasPlugin {
    var id: PluginID { "knobs" }
    func register(into registrar: inout PluginRegistrar) { registrar.shape(KnobDefinition()) }
}

/// Counts what the editor tells its view. (Its delegate protocol is the host's, so it can't be
/// public in CanvasTesting.)
final class DisplayCounter: CanvasEditorDelegate {
    var redraws = 0
    func editorNeedsDisplay(_ editor: CanvasEditor) { redraws += 1 }
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {}
}
