import Canvas
import CoreGraphics

/// What arrows know about a shape they bind to, built from the shape's core geometry. Arrows
/// never see shape kinds: any closed shape that isn't an arrow can be bound to.
public struct ConnectableShape: Sendable {
    public let id: ShapeID
    /// The shape's edge as a closed polygon in world coordinates.
    public let outline: [CGPoint]
    /// The rectangle arrow anchors are measured within.
    public let bounds: CGRect
}

/// Arrow code's only way to see other shapes.
@MainActor
struct Connectables {
    let shapes: ShapeContext

    subscript(id: ShapeID) -> ConnectableShape? {
        guard let record = shapes.shape(id), record.kind != Arrow.kind,
              let geometry = shapes.geometry(of: id), geometry.isClosed else { return nil }
        return ConnectableShape(id: id, outline: geometry.outline, bounds: geometry.bounds)
    }

    /// The front-most shape under `point` that arrows can bind to (in document order, as before:
    /// arrows are skipped, so they never change which shape is in front), of those `accepts` lets
    /// the end bind to: it looks through the rest, to the shapes behind (tldraw's canBind filter).
    /// Asked only of the shapes the point hits.
    func shape(at point: CGPoint, accepting accepts: ((AnyShapeRecord) -> Bool)? = nil) -> ConnectableShape? {
        for record in shapes.document.shapes.reversed() where record.kind != Arrow.kind && shapes.hitTest(point, shape: record.id) {
            guard accepts?(record) ?? true else { continue }
            if let shape = self[record.id] { return shape }
        }
        return nil
    }
}
