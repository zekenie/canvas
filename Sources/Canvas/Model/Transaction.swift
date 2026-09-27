import Geometry

/// The only way to change a document: `editor.transact { tx in ... }`. Everything in one
/// transaction commits together. (Undo, when it comes, will group every commit from a press to its
/// release, and every commit while a shape is being edited, into one step.)
@MainActor
public struct Transaction {
    public private(set) var document: CanvasDocument
    let registry: Registry
    let camera: Camera
    private(set) var didChange = false
    /// Shapes whose willDelete handlers have run in this transaction; removed together at the end
    /// of the outermost `delete`.
    private var deleting: Set<ShapeID> = []

    init(document: CanvasDocument, registry: Registry, camera: Camera) {
        self.document = document
        self.registry = registry
        self.camera = camera
    }

    /// Geometry lookups against the document as it is mid-transaction.
    public var shapes: ShapeContext { ShapeContext(document: document, registry: registry, camera: camera) }

    public mutating func insert<P: ShapeProps>(_ shape: ShapeRecord<P>) { insert(AnyShapeRecord(shape)) }

    /// Adds on top. The shape's kind must be installed.
    public mutating func insert(_ record: AnyShapeRecord) {
        precondition(document[record.id] == nil, "a shape with id \(record.id) already exists")
        precondition(registry.definition(for: record.kind)?.erasedAccepts(record) == true,
                     "no installed plugin defines \(record.kind) shapes with these props")
        document.append(record)
        didChange = true
    }

    public mutating func update(_ id: ShapeID, _ body: (inout AnyShapeRecord) -> Void) {
        guard let index = document.index(of: id) else { return }
        var record = document.shapes[index]
        body(&record)
        precondition(record.id == id, "a shape's id can't change")
        guard record != document.shapes[index] else { return }
        document.replace(at: index, with: record)
        didChange = true
    }

    public mutating func update<P: ShapeProps>(_ id: ShapeID, as _: P.Type, _ body: (inout ShapeRecord<P>) -> Void) {
        update(id) { $0.modify(as: P.self, body) }
    }

    public mutating func bringToFront(_ id: ShapeID) {
        guard let index = document.index(of: id), index != document.shapes.count - 1 else { return }
        document.moveToEnd(from: index)
        didChange = true
    }

    public mutating func sendToBack(_ id: ShapeID) {
        guard let index = document.index(of: id), index != 0 else { return }
        document.moveToStart(from: index)
        didChange = true
    }

    /// Runs every plugin's `willDelete` handlers first, in this transaction, while the shapes still
    /// exist. Handlers may delete more shapes: each shape's handlers run once, and everything is
    /// removed together when the outermost `delete` returns.
    public mutating func delete(_ ids: Set<ShapeID>) {
        let ids = ids.filter { document[$0] != nil }.subtracting(deleting)
        guard !ids.isEmpty else { return }
        let isOutermost = deleting.isEmpty
        deleting.formUnion(ids)
        for handler in registry.willDeleteHandlers { handler(ids, &self) }
        guard isOutermost else { return }
        document.remove(deleting)
        deleting = []
        didChange = true
    }
}
