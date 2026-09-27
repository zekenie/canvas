import AppKit
import Canvas
import Geometry

/// A shape without a frame: a freehand line, the points the pointer was dragged through. A box
/// kind gets three things from its frame that this one has to say itself: where it is
/// (`geometry`), what hits it (`hitTest`: an open outline has no inside), and how it moves
/// (`CustomTranslation`). Everything else follows from the geometry: the hover and selection
/// outline, the marquee, the eraser, and arrows leaving it alone (they bind only to closed shapes).

/// The kind: points in world units, in the order they were drawn.
public struct Polyline: ShapeProps {
    public static let kind: ShapeKind = "polyline"
    public var points: [CGPoint]
    public init(points: [CGPoint] = []) { self.points = points }
}

public struct PolylinesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "polylines" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(PolylineDefinition())
        // Named after the kind, as place tools are, so the detail panel calls a line a "Line".
        let line = ToolDescriptor(id: ToolID(placing: Polyline.kind), label: "Line", systemImage: "scribble", shortcut: "l")
        registrar.tool(line) { _ in LineTool() }
    }
}

struct PolylineDefinition {}

extension PolylineDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Polyline>, in context: RenderContext) {
        let cg = context.cg
        cg.addLines(between: shape.props.points)
        cg.setStrokeColor(PolylineStyle.color.cgColor)
        cg.setLineWidth(PolylineStyle.strokeWidth)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.strokePath()
    }

    /// Required: only box kinds have a default. Open, so nothing is inside it.
    func geometry(of shape: ShapeRecord<Polyline>, in context: ShapeContext) -> ShapeGeometry {
        ShapeGeometry(outline: shape.props.points, isClosed: false)
    }

    /// The default hits only inside a closed outline, so an open kind says what hits it: here,
    /// anything within a few view points of the stroke.
    func hitTest(_ point: CGPoint, on shape: ShapeRecord<Polyline>, in context: ShapeContext) -> Bool {
        let margin = PolylineStyle.hitMargin / context.zoom + PolylineStyle.strokeWidth / 2
        let points = shape.props.points
        return zip(points, points.dropFirst()).contains { distanceToSegment(from: point, $0, $1) <= margin }
    }
}

extension PolylineDefinition: CustomTranslation {
    /// Without this, dragging the selection would leave a line where it is: the core moves boxes
    /// by their frame, and this kind has none. Every point follows the pointer.
    func beginTranslation(of shape: ShapeRecord<Polyline>, movingWith _: Set<ShapeID>,
                          in _: inout Transaction) -> ShapeTranslation<Polyline> {
        let start = shape.props.points
        return ShapeTranslation { delta, shape, _ in
            shape.props.points = start.map { $0 + delta }
        }
    }
}

/// Starts a line on each press. The tool stays current after a line, as the eraser does.
final class LineTool {}

extension LineTool: Tool {
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {
        editor.session = DrawingSession(start: pointer.world)
    }
}

/// One line, from press to release. The shape goes in on the first drag, so a click draws nothing.
@MainActor
final class DrawingSession {
    private let start: CGPoint
    private var id: ShapeID?
    init(start: CGPoint) { self.start = start }
}

extension DrawingSession: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        if let id {
            editor.transact { $0.update(id, as: Polyline.self) { $0.props.points.append(pointer.world) } }
        } else {
            let line = ShapeRecord(Polyline(points: [start, pointer.world]))
            editor.transact { $0.insert(line) }
            id = line.id
        }
    }

    /// Escape takes back the line being drawn.
    func cancel(in editor: CanvasEditor) -> Bool {
        if let id { editor.transact { $0.delete([id]) } }
        return true
    }
}

@MainActor
enum PolylineStyle {
    static let color = NSColor.systemIndigo
    static let strokeWidth: CGFloat = 3
    /// How far beyond the stroke a click still hits it, in view points.
    static let hitMargin: CGFloat = 3
}
