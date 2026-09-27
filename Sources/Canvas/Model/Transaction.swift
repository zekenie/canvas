import CoreGraphics
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
    /// What it did so far, record by record: what the commit hands services.
    private(set) var changes = ChangeSet()
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
        changes.added.insert(record.id)
        changes.reordered = true
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
        noteChanged(id)
    }

    public mutating func update<P: ShapeProps>(_ id: ShapeID, as _: P.Type, _ body: (inout ShapeRecord<P>) -> Void) {
        update(id) { $0.modify(as: P.self, body) }
    }

    /// Moves shapes by `delta`, in world units, as dragging them that far would: a box by its
    /// frame, a `CustomTranslation` kind by its own rules (every `beginTranslation` first, then the
    /// boxes, then the rest, as a drag event does), anything else not at all.
    public mutating func translate(_ ids: Set<ShapeID>, by delta: CGPoint) {
        let records = ids.compactMap { document.index(of: $0) }.sorted().map { document.shapes[$0] }
        var boxes: [ShapeID] = []
        var moves: [@MainActor (CGPoint, inout Transaction) -> Void] = []
        for record in records {
            if let custom = registry.definition(for: record.kind) as? any CustomTranslation {
                if let move = custom.erasedBeginTranslation(of: record, movingWith: ids, in: &self) { moves.append(move) }
            } else if record.box != nil {
                boxes.append(record.id)
            }
        }
        for id in boxes {
            update(id) { record in
                if let box = record.box { record.box = CGRect(origin: box.origin + delta, size: box.size) }
            }
        }
        for move in moves { move(delta, &self) }
    }

    /// Paints the shape above every other. Does nothing if it's already on top.
    public mutating func bringToFront(_ id: ShapeID) {
        guard let index = document.index(of: id), index != document.shapes.count - 1 else { return }
        document.moveToEnd(from: index, key: keys.key(between: document.shapes.last?.stackingKey, and: nil))
        noteChanged(id, reordering: true)
    }

    /// Paints the shape below every other. Does nothing if it's already at the bottom.
    public mutating func sendToBack(_ id: ShapeID) {
        guard let index = document.index(of: id), index != 0 else { return }
        document.moveToStart(from: index, key: keys.key(between: nil, and: document.shapes.first?.stackingKey))
        noteChanged(id, reordering: true)
    }

    /// Puts a shape just above another in document order (a step forward, past `other`): a key
    /// between `other`'s and the next shape's. Does nothing if it's there already.
    public mutating func move(_ id: ShapeID, above other: ShapeID) {
        guard id != other, let from = document.index(of: id), let target = document.index(of: other), from != target + 1 else { return }
        let shapes = document.shapes
        let next = target + 1 < shapes.count ? shapes[target + 1].stackingKey : nil
        move(id, from: from, to: from < target ? target : target + 1, key: keys.key(between: shapes[target].stackingKey, and: next))
    }

    /// Puts a shape just below another in document order (a step back, past `other`): a key
    /// between the previous shape's and `other`'s. Does nothing if it's there already.
    public mutating func move(_ id: ShapeID, below other: ShapeID) {
        guard id != other, let from = document.index(of: id), let target = document.index(of: other), from != target - 1 else { return }
        let shapes = document.shapes
        let previous = target > 0 ? shapes[target - 1].stackingKey : nil
        move(id, from: from, to: from < target ? target - 1 : target, key: keys.key(between: previous, and: shapes[target].stackingKey))
    }

    private mutating func move(_ id: ShapeID, from: Int, to: Int, key: StackingKey) {
        document.move(from: from, to: to, key: key)
        noteChanged(id, reordering: true)
    }

    /// A shape added in this transaction stays added, however it changes after.
    private mutating func noteChanged(_ id: ShapeID, reordering: Bool = false) {
        if !changes.added.contains(id) { changes.changed.insert(id) }
        if reordering { changes.reordered = true }
        didChange = true
    }

    /// First, while the shapes still exist, every plugin's `willDelete` handlers run, in this
    /// transaction, seeing every shape as it was; then every shape that names one of them, and
    /// stays, lets go of it, as its kind says (`ShapeReferencing`: an arrow's end stays where it's
    /// drawn). Handlers may delete more shapes (a shape's dependents): each shape's handlers run and
    /// it's let go of once, and everything is removed together when the outermost `delete` returns.
    public mutating func delete(_ ids: Set<ShapeID>) {
        let ids = ids.filter { document[$0] != nil }.subtracting(deleting)
        guard !ids.isEmpty else { return }
        let isOutermost = deleting.isEmpty
        deleting.formUnion(ids)
        for handler in registry.willDeleteHandlers { handler(ids, &self) }
        letGo(of: ids)
        guard isOutermost else { return }
        document.remove(deleting)
        for id in deleting where changes.added.remove(id) == nil {       // added and removed here: never seen
            changes.changed.remove(id)
            changes.removed.insert(id)
        }
        changes.reordered = true
        deleting = []
        didChange = true
    }

    /// Every shape that names one of `ids`, and isn't being deleted too, lets go of it. One whose
    /// kind can't (it names a shape it can't find) is left as it was.
    private mutating func letGo(of ids: Set<ShapeID>) {
        let kinds = registry.referencingKinds
        guard !kinds.isEmpty else { return }
        let context = shapes
        for record in document.shapes where kinds.contains(record.kind) && !deleting.contains(record.id) {
            guard let released = record.remappingReferences({ ids.contains($0) ? nil : $0 }, in: context), released != record else { continue }
            update(record.id) { $0 = released }
        }
    }
}
