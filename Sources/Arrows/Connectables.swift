import Canvas
import CoreGraphics
import Geometry

/// What arrows know about a shape they bind to, built from the shape's core geometry. Arrows
/// never see shape kinds: any closed shape that isn't an arrow can be bound to.
public struct ConnectableShape: Sendable {
    public let id: ShapeID
    /// The shape's edge as a closed polygon in world coordinates.
    public let outline: [CGPoint]
    /// The rectangle arrow anchors are measured within.
    public let bounds: CGRect
    /// The box the shape has at rest: its stored box, never a layout wider or taller for a moment (a row's line being typed);
    /// the bounds for a shape with no box. What two ends at rows are sided by (`PartSide.sides`).
    public let restBounds: CGRect
    /// Where its parts are (`ShapeGeometry.parts`: a table's rows), which an end bound to a part meets at a side of.
    public let parts: PartFrames
    /// Where a level arrow's end bound to it as a whole meets it (`ShapeGeometry.entries`: a table's first row), else empty.
    public let entries: [ShapeEntry]

    public init(id: ShapeID, outline: [CGPoint], bounds: CGRect, restBounds: CGRect? = nil, parts: PartFrames = PartFrames(),
                entries: [ShapeEntry] = []) {
        self.id = id
        self.outline = outline
        self.bounds = bounds
        self.restBounds = restBounds ?? bounds
        self.parts = parts
        self.entries = entries
    }
}

/// Arrow code's only way to see other shapes.
@MainActor
struct Connectables {
    let shapes: ShapeContext

    subscript(id: ShapeID) -> ConnectableShape? {
        guard let record = shapes.shape(id), record.kind != Arrow.kind,
              let geometry = shapes.geometry(of: id), geometry.isClosed else { return nil }
        return ConnectableShape(id: id, outline: geometry.outline, bounds: geometry.bounds, restBounds: record.box, parts: geometry.parts,
                                entries: geometry.entries)
    }

    /// The front-most shape under `point` that arrows can bind to (in document order, as before:
    /// arrows are skipped, so they never change which shape is in front), of those `accepts` lets
    /// the end bind to: it looks through the rest, to the shapes behind (tldraw's canBind filter).
    /// A container is under it anywhere inside it (`isEnd`). Asked only of the shapes the point may
    /// hit (`ShapeContext.shapes(mayHit:)`), a few however many the board holds.
    func shape(at point: CGPoint, accepting accepts: ((AnyShapeRecord) -> Bool)? = nil) -> ConnectableShape? {
        for record in shapes.shapes(mayHit: point) where record.kind != Arrow.kind && isEnd(record, at: point) {
            guard accepts?(record) ?? true else { continue }
            if let shape = self[record.id] { return shape }
        }
        return nil
    }

    /// Whether an end at `point` is on `record`: where it's hit, and, for a container (the core's: a
    /// frame), anywhere inside its outline, as tldraw's ends look inside frames (`hitFrameInside`).
    /// A frame that holds shapes is hit only on its edge, so an end let go in its empty inside, or
    /// on a shape there that doesn't take it, ends on the frame. What it holds is in front of it, so
    /// found first.
    private func isEnd(_ record: AnyShapeRecord, at point: CGPoint) -> Bool {
        if shapes.hitTest(point, shape: record.id) { return true }
        guard shapes.registry.isContainer(record), let geometry = shapes.geometry(of: record.id), geometry.isClosed else { return false }
        return polygonContains(geometry.outline, point)
    }
}
