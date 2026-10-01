import Canvas
import CoreGraphics

/// A kind with a label: text set on part of the shape, not over all of it (an arrow's, as tldraw's
/// arrow labels are). A click on the only selected shape edits it only on its label (elsewhere it's
/// a click on the shape), and a drag from its label moves the label, not the selection: the shape
/// is selected alone first (⇧ adds it), and the drag is `labelDragSession`'s. A read-only shape's
/// label moves no more than the shape does: a drag from it is the selection's, refused as ever.
public protocol LabeledShape: Editable {
    /// Where its label is, in world units; nil while it has none (no text).
    func labelFrame(of shape: ShapeRecord<Props>, in context: ShapeContext) -> CGRect?
    /// What a drag from the label does, pressed at `origin` (world units), once it's past the drag
    /// threshold; nil moves the selection.
    func labelDragSession(of shape: ShapeRecord<Props>, from origin: CGPoint, in editor: CanvasEditor) -> (any Session)?
}

// Callable on `any LabeledShape`: the signatures don't mention `Props`.
extension LabeledShape {
    func erasedLabelFrame(of record: AnyShapeRecord, in context: ShapeContext) -> CGRect? {
        record.typed(as: Props.self).flatMap { labelFrame(of: $0, in: context) }
    }
    func erasedLabelDragSession(of record: AnyShapeRecord, from origin: CGPoint, in editor: CanvasEditor) -> (any Session)? {
        record.typed(as: Props.self).flatMap { labelDragSession(of: $0, from: origin, in: editor) }
    }
}

extension CanvasEditor {
    /// Whether a world point is on a shape's label (`LabeledShape`).
    func isOnLabel(_ id: ShapeID, at point: CGPoint) -> Bool {
        guard let record = document[id], let definition = registry.definition(for: record.kind) as? any LabeledShape,
              let frame = definition.erasedLabelFrame(of: record, in: shapeContext) else { return false }
        return frame.contains(point)
    }

    /// The session a drag from a shape's label starts, pressed at `origin`; nil for one that's
    /// read-only, or whose kind moves the selection.
    func labelDragSession(of id: ShapeID, from origin: CGPoint) -> (any Session)? {
        guard let record = document[id], !registry.isReadOnly(record),
              let definition = registry.definition(for: record.kind) as? any LabeledShape else { return nil }
        return definition.erasedLabelDragSession(of: record, from: origin, in: self)
    }
}
