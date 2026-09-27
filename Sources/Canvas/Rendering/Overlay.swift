import CoreGraphics

public enum OverlaySpace: Sendable {
    /// Drawn with the camera transform, after the shapes and their outlines. Sizes meant as view
    /// points are divided by `zoom`.
    case world
    /// Drawn in view points, after everything in world units (and the session's drawing).
    case view
}

/// What a plugin wants outlined, from `registrar.outlines`: shapes by their `indicatorPath`, and
/// world rects. The core strokes every plugin's outlines and the hint in one pass, in the accent
/// color at a constant screen width, just above the shapes. `faintShapes` are stroked first, wider
/// and lighter (a hover beside a selection); a shape outlined in full too is stroked only in full.
public struct Outlines {
    public var shapes: [ShapeID]
    /// World units.
    public var rects: [CGRect]
    public var faintShapes: [ShapeID]
    public init(shapes: [ShapeID] = [], rects: [CGRect] = [], faintShapes: [ShapeID] = []) {
        self.shapes = shapes
        self.rects = rects
        self.faintShapes = faintShapes
    }
}

/// Something a plugin draws above every shape (status outlines, hints). Shapes never
/// know about it. Each overlay draws with a fresh graphics state. If what it draws changes other
/// than through the document or the editor's own state (on a timer, say), call
/// `editor.setNeedsDisplay()`.
@MainActor
public protocol CanvasOverlay {
    var space: OverlaySpace { get }
    func draw(in context: OverlayContext)
}

@MainActor
public struct OverlayContext {
    public let cg: CGContext
    public let editor: CanvasEditor
    public let shapes: ShapeContext
    /// What the view shows, in world units. An overlay that draws for some shapes goes through
    /// `editor.paintOrder(in:)` with this, grown by however far past its shapes it draws (and by
    /// `worldDrawingReach` if it follows drawing offsets), rather than through every shape.
    public let visibleRect: CGRect
    public var zoom: CGFloat { shapes.zoom }

    /// How far from where it is a shape is drawn (`editor.setDrawingOffset`), in world units: an
    /// overlay that decorates a shape moves its decoration by this, so it stays with the shape.
    public func worldDrawingOffset(of id: ShapeID) -> CGPoint {
        let offset = editor.drawingOffset(of: id)
        return offset == .zero ? .zero : CGPoint(x: offset.x / zoom, y: offset.y / zoom)
    }

    /// The farthest any shape is drawn from where it is now, along either axis, in world units:
    /// zero unless a drawing offset is set. An overlay that culls with `visibleRect` and moves its
    /// decorations by `worldDrawingOffset(of:)` grows the rect by this too, so a shape shaken into
    /// view from just outside it is decorated there. It looks at only the shapes drawn away from
    /// where they are.
    public var worldDrawingReach: CGFloat {
        editor.drawingOffsets.values.reduce(0) { max($0, abs($1.x), abs($1.y)) } / zoom
    }
}
