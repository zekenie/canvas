import AppKit

// The core calls definitions through these. Their signatures don't mention `Props`, so they're
// callable on `any ShapeDefinition`. Inserting a record checks that its kind's definition accepts
// it (`erasedAccepts`), so the casts below only fail for records that bypassed that.
extension ShapeDefinition {
    var kind: ShapeKind { Props.kind }
    var kindCodec: KindCodec { KindCodec(Props.self) }

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

extension CustomTranslation {
    func erasedBeginTranslation(of record: AnyShapeRecord, movingWith moving: Set<ShapeID>,
                                in transaction: inout Transaction) -> (@MainActor (CGPoint, inout Transaction) -> Void)? {
        guard let shape = record.typed(as: Props.self) else { return nil }
        let translation = beginTranslation(of: shape, movingWith: moving, in: &transaction)
        let id = record.id
        return { delta, transaction in
            let shapes = transaction.shapes           // read before update: no overlapping access
            transaction.update(id, as: Props.self) { translation.move(delta, &$0, shapes) }
        }
    }
}

extension PaintOrderAnchored {
    func erasedPaintAnchor(of record: AnyShapeRecord, in document: CanvasDocument) -> ShapeID? {
        record.typed(as: Props.self).flatMap { paintAnchor(of: $0, in: document) }
    }
}

extension ShapeReferencing {
    /// Nil if the kind can't let go of a shape it names; the record's own props, typed, otherwise.
    func erasedRemappingReferences(of record: AnyShapeRecord, _ map: (ShapeID) -> ShapeID?, in context: ShapeContext) -> (any ShapeProps)?? {
        record.typed(as: Props.self).map { remappingReferences(of: $0, map, in: context) }
    }
}

extension AnyShapeRecord {
    /// This shape with every shape its props name passed through `map` (see `ShapeReferencing`):
    /// what a copy of it should be, once `map` gives each copied shape its copy's id and nil for the
    /// rest. Itself for a kind whose props name no shape, or one no installed plugin defines. Nil
    /// if its kind can't let go of a shape `map` drops, one `context` doesn't have.
    @MainActor
    public func remappingReferences(_ map: (ShapeID) -> ShapeID?, in context: ShapeContext) -> AnyShapeRecord? {
        guard let definition = context.registry.definition(for: kind) as? any ShapeReferencing,
              let remapped = definition.erasedRemappingReferences(of: self, map, in: context) else { return self }
        guard let props = remapped else { return nil }
        var record = self
        record.props = props
        return record
    }
}
