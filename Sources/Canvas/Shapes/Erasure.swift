import AppKit

// The core calls definitions through these. Their signatures don't mention `Props`, so they're
// callable on `any ShapeDefinition`. Inserting a record checks that its kind's definition accepts
// it (`erasedAccepts`), so the casts below only fail for records that bypassed that.
extension ShapeDefinition {
    var kind: ShapeKind { Props.kind }

    func erasedAccepts(_ record: AnyShapeRecord) -> Bool {
        record.kind == Props.kind && record.props is Props
    }
    func erasedRender(_ record: AnyShapeRecord, in context: RenderContext) {
        record.typed(as: Props.self).map { render($0, in: context) }
    }
    func erasedGeometry(of record: AnyShapeRecord, in context: ShapeContext) -> ShapeGeometry? {
        record.typed(as: Props.self).map { geometry(of: $0, in: context) }
    }
    func erasedHitTest(_ point: CGPoint, on record: AnyShapeRecord, in context: ShapeContext) -> Bool {
        record.typed(as: Props.self).map { hitTest(point, on: $0, in: context) } ?? false
    }
    func erasedIndicatorPath(of record: AnyShapeRecord, in context: ShapeContext) -> CGPath? {
        record.typed(as: Props.self).map { indicatorPath(of: $0, in: context) }
    }
}

extension Editable {
    func erasedEditingView(for record: AnyShapeRecord, editor: CanvasEditor) -> EditingView? {
        record.typed(as: Props.self).map { makeEditingView(for: $0, context: EditContext(shapeID: record.id, editor: editor)) }
    }
}

extension HandleProviding {
    func erasedHandles(of record: AnyShapeRecord, in context: ShapeContext) -> [(handle: AnyHashable, point: CGPoint)] {
        guard let shape = record.typed(as: Props.self) else { return [] }
        return handles(of: shape, in: context).map { (AnyHashable($0.handle), $0.point) }
    }
    func erasedPressHandle(_ handle: AnyHashable, of record: AnyShapeRecord, at pointer: Pointer, in editor: CanvasEditor) -> HandlePress {
        guard let handle = handle.base as? Handle, let shape = record.typed(as: Props.self) else { return .consumed }
        return pressHandle(handle, of: shape, at: pointer, in: editor)
    }
    func erasedDragSession(for handle: AnyHashable, of record: AnyShapeRecord, from origin: CGPoint, in editor: CanvasEditor) -> (any Session)? {
        guard let handle = handle.base as? Handle, let shape = record.typed(as: Props.self) else { return nil }
        return dragSession(for: handle, of: shape, from: origin, in: editor)
    }
}

extension CustomTranslation {
    func erasedTranslationSession(for record: AnyShapeRecord, at pointer: Pointer, in editor: CanvasEditor) -> (any Session)? {
        record.typed(as: Props.self).map { translationSession(for: $0, at: pointer, in: editor) }
    }
}

extension PaintOrderAnchored {
    func erasedPaintAnchor(of record: AnyShapeRecord, in document: CanvasDocument) -> ShapeID? {
        record.typed(as: Props.self).flatMap { paintAnchor(of: $0, in: document) }
    }
}
