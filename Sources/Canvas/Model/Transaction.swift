import Geometry

/// The only way to change a document: `editor.transact { tx in ... }`. Everything in one
/// transaction commits together. (Undo, when it comes, will group every commit from a press to its
/// release, and every commit while a shape is being edited, into one step.)
///
/// A board must always save, so a shape's frame stays finite: a shape inserted with a frame that
/// isn't (a NaN, an infinity) isn't inserted, and a change that would make one so is dropped.
@MainActor
public struct Transaction {
    public private(set) var document: CanvasDocument
    let registry: Registry
    let camera: Camera
    let keys: StackingKeyGenerator
    private(set) var didChange = false
    /// Shapes whose willDelete handlers have run in this transaction; removed together at the end
    /// of the outermost `delete`.
    private var deleting: Set<ShapeID> = []

    init(document: CanvasDocument, registry: Registry, camera: Camera, keys: StackingKeyGenerator) {
        self.document = document
        self.registry = registry
        self.camera = camera
        self.keys = keys
    }

    /// Geometry lookups against the document as it is mid-transaction.
    public var shapes: ShapeContext { ShapeContext(document: document, registry: registry, camera: camera) }

    public mutating func insert<P: ShapeProps>(_ shape: ShapeRecord<P>) { insert(AnyShapeRecord(shape)) }

    /// Adds on top. The shape's kind must be installed.
    public mutating func insert(_ record: AnyShapeRecord) {
        precondition(document[record.id] == nil, "a shape with id \(record.id) already exists")
        precondition(registry.definition(for: record.kind)?.erasedAccepts(record) == true,
                     "no installed plugin defines \(record.kind) shapes with these props")
        guard record.box?.isFinite ?? true else { return }
        var record = record
        record.stackingKey = keys.key(between: document.shapes.last?.stackingKey, and: nil)
        document.append(record)
        didChange = true
    }

    /// Changes one shape. Its id and stacking key stay as they were, whatever `body` does.
    public mutating func update(_ id: ShapeID, _ body: (inout AnyShapeRecord) -> Void) {
        guard let index = document.index(of: id) else { return }
        let old = document.shapes[index]
        var record = old
        body(&record)
        precondition(record.id == id, "a shape's id can't change")
        record.stackingKey = old.stackingKey
        guard record != old, record.box?.isFinite ?? true else { return }
        document.replace(at: index, with: record)
        didChange = true
    }

    public mutating func update<P: ShapeProps>(_ id: ShapeID, as _: P.Type, _ body: (inout ShapeRecord<P>) -> Void) {
        update(id) { $0.modify(as: P.self, body) }
    }

    /// Paints the shape above every other. Does nothing if it's already on top.
    public mutating func bringToFront(_ id: ShapeID) {
        guard let index = document.index(of: id), index != document.shapes.count - 1 else { return }
        document.moveToEnd(from: index, key: keys.key(between: document.shapes.last?.stackingKey, and: nil))
        didChange = true
    }

    /// Paints the shape below every other. Does nothing if it's already at the bottom.
    public mutating func sendToBack(_ id: ShapeID) {
        guard let index = document.index(of: id), index != 0 else { return }
        document.moveToStart(from: index, key: keys.key(between: nil, and: document.shapes.first?.stackingKey))
        didChange = true
    }

    /// Puts a shape just above another in document order (a step forward, past `other`): a key
    /// between `other`'s and the next shape's. Does nothing if it's there already.
    public mutating func move(_ id: ShapeID, above other: ShapeID) {
        guard id != other, let from = document.index(of: id), let target = document.index(of: other), from != target + 1 else { return }
        let shapes = document.shapes
        let next = target + 1 < shapes.count ? shapes[target + 1].stackingKey : nil
        move(from: from, to: from < target ? target : target + 1, key: keys.key(between: shapes[target].stackingKey, and: next))
    }

    /// Puts a shape just below another in document order (a step back, past `other`): a key
    /// between the previous shape's and `other`'s. Does nothing if it's there already.
    public mutating func move(_ id: ShapeID, below other: ShapeID) {
        guard id != other, let from = document.index(of: id), let target = document.index(of: other), from != target - 1 else { return }
        let shapes = document.shapes
        let previous = target > 0 ? shapes[target - 1].stackingKey : nil
        move(from: from, to: from < target ? target - 1 : target, key: keys.key(between: previous, and: shapes[target].stackingKey))
    }

    private mutating func move(from: Int, to: Int, key: StackingKey) {
        document.move(from: from, to: to, key: key)
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
