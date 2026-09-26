import CoreGraphics

public enum OverlaySpace: Sendable {
    /// Drawn with the camera transform, after the shapes and their outlines. Sizes meant as view
    /// points are divided by `zoom`.
    case world
    /// Drawn in view points, after the handles.
    case view
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
    public var zoom: CGFloat { shapes.zoom }
}
