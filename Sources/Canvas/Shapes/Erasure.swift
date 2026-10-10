import AppKit

// The core calls definitions through these. Their signatures don't mention `Props`, so they're
// callable on `any ShapeDefinition`. Inserting a record checks that its kind's definition accepts
// it (`erasedAccepts`), so the casts below only fail for records that bypassed that.
extension ShapeDefinition {
    var kind: ShapeKind { Props.kind }
    var kindCodec: KindCodec { KindCodec(Props.self) }
    var propsType: any ShapeProps.Type { Props.self }
    var ownPropertyNames: [String] { Props.properties.names }
    /// Whether its props have a member that names shapes (`ShapeNaming`).
    var propsNameShapes: Bool { !Props.properties.namingProperties.isEmpty }

    /// The kind's own properties, as an object schema.
    func propsSchema(in definitions: inout SchemaDefinitions) -> JSONObject {
        Props.properties.objectSchema(in: &definitions)
    }

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
        record.typed(as: Props.self).map {
            makeEditingView(for: $0, context: EditContext(shapeID: record.id, startPoint: editor.editingStartPoint,
                                                          startClickCount: editor.editingStartClickCount, editor: editor))
        }
    }
    func erasedDiscardsWhenEditingEnds(_ record: AnyShapeRecord) -> Bool {
        record.typed(as: Props.self).map { discardsWhenEditingEnds($0.props) } ?? false
    }
    func erasedEditingFrame(of record: AnyShapeRecord, in context: ShapeContext) -> CGRect? {
        record.typed(as: Props.self).flatMap { editingFrame(of: $0, in: context) }
    }
}

extension LaidOutBox {
    func erasedLaidOutSize(of record: AnyShapeRecord, in context: ShapeContext) -> CGSize? {
        record.typed(as: Props.self).map { laidOutSize(of: $0, in: context) }
    }
}

extension CustomSkeleton {
    func erasedRenderSkeleton(_ record: AnyShapeRecord, in context: RenderContext) {
        record.typed(as: Props.self).map { renderSkeleton($0, in: context) }
    }
}

extension CustomSkeletonOutline {
    func erasedSkeletonIndicatorPath(of record: AnyShapeRecord, in context: ShapeContext) -> CGPath? {
        record.typed(as: Props.self).flatMap { skeletonIndicatorPath(of: $0, in: context) }
    }
}

extension StrokedShape {
    func erasedLineWidth(of record: AnyShapeRecord, in context: ShapeContext) -> CGFloat? {
        record.typed(as: Props.self).map { lineWidth(of: $0, in: context) }
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

extension DerivedProps {
    func erasedDerive(_ record: inout AnyShapeRecord) {
        guard var shape = record.typed(as: Props.self) else { return }
        derive(&shape.props)
        record.props = shape.props
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
    /// This shape with every shape it names passed through `map`: what a copy of it should be, once
    /// `map` gives each copied shape its copy's id and nil for the rest. First what its kind binds
    /// (`ShapeReferencing`), as the kind says: nil lets a binding go. Then every name in its props
    /// and added values (`ShapeNaming`, for `registry.namingKinds`): nil keeps a name as it is, since
    /// a name may outlive its shape. Itself for a kind that names no shape, one no installed plugin
    /// defines, or a shape kept aside. Nil if its kind can't let go of a shape `map` drops, one
    /// `context` doesn't have.
    @MainActor
    public func remappingReferences(_ map: (ShapeID) -> ShapeID?, in context: ShapeContext) -> AnyShapeRecord? {
        remappingReferences(map, naming: map, in: context)
    }

    /// As `remappingReferences(_:in:)`, with bindings passed through `bind` and names through
    /// `name`: what a copy of a shape on one board of a copied tree should be, whose bindings are
    /// to shapes on its own board (copied with it, or let go) and whose names may be of shapes
    /// copied with it on any board of the tree (renamed) or anywhere else (kept).
    @MainActor
    public func remappingReferences(_ bind: (ShapeID) -> ShapeID?, naming name: (ShapeID) -> ShapeID?,
                                    in context: ShapeContext) -> AnyShapeRecord? {
        let names = context.registry.namingKinds.contains(kind) && !isOpaque
        var record = self
        if let definition = context.registry.definition(for: kind) as? any ShapeReferencing,
           let remapped = definition.erasedRemappingReferences(of: self, bind, in: context) {
            guard let props = remapped else { return nil }
            record.props = props
        }
        if names { record.renameNamedShapes(name, in: context.registry) }
        return record
    }

    /// The shapes it's bound to (`ShapeReferencing`): those that must be on its board, as an
    /// arrow's ends must. Not those it only names (`ShapeNaming`), which may be gone. Each once, in
    /// the order its kind meets them; none for a kind that binds nothing, or a shape kept aside.
    @MainActor
    public func boundShapes(in context: ShapeContext) -> [ShapeID] {
        guard let definition = context.registry.definition(for: kind) as? any ShapeReferencing else { return [] }
        var bound: [ShapeID] = []
        _ = definition.erasedRemappingReferences(of: self, { id in
            if !bound.contains(id) { bound.append(id) }
            return id
        }, in: context)
        return bound
    }

    /// Whether it's bound to some of `shapes` and to nothing else (`boundShapes(in:)`): what goes with
    /// them, as an arrow between two of a container's shapes does. False for a shape bound to nothing.
    @MainActor
    public func isBound(onlyTo shapes: Set<ShapeID>, in context: ShapeContext) -> Bool {
        let bound = boundShapes(in: context)
        return !bound.isEmpty && bound.allSatisfy(shapes.contains)
    }
}
