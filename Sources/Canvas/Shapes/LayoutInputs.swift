import CoreGraphics
import Foundation

/// A name for something a shape's geometry reads that isn't in its record or in the shapes it looks
/// up: a layout input, set by the plugin that knows it (`editor.setLayoutInput`), read by the
/// definition (`context.layoutInput`). Mentions' names for an arrow's pills are one (a geometry
/// can't read another board, and a rename writes nothing to the shapes that mention it).
public struct LayoutInputKey<Value: Hashable & Sendable>: Sendable {
    public let name: String
    public init(_ name: String) { self.name = name }
}

/// The layout inputs of an editor's file, by shape: what `ShapeContext.layoutInput` reads. Set only
/// through the editor, which tells its index that the shape's geometry is out of date when one
/// changes.
@MainActor
final class LayoutInputs {
    private var values: [ShapeID: [String: AnyHashable]] = [:]

    func value(_ name: String, for id: ShapeID) -> AnyHashable? { values[id]?[name] }

    /// Whether it changed.
    func set(_ name: String, _ value: AnyHashable?, for id: ShapeID) -> Bool {
        if values[id]?[name] == value { return false }
        if let value {
            values[id, default: [:]][name] = value
        } else {
            values[id]?[name] = nil
            if values[id]?.isEmpty == true { values[id] = nil }
        }
        return true
    }
}

/// What a context lays shapes out with: the values set for them (`inputs`), the sizes laid out,
/// the editor's services, and the file as whoever lays them out sees it. A class, so a context
/// copies one reference, as it copied `LayoutInputs` before.
@MainActor
final class LayoutSource {
    /// Values set (`editor.setLayoutInput`).
    let inputs: LayoutInputs
    /// The laid-out sizes the editor keeps, by shape id, for the whole file.
    let sizes: LaidOutSizes
    let lend: @MainActor (ObjectIdentifier) -> (any EditorService)?
    /// A shape on any board of the file, as this source's reader sees the file.
    let shape: @MainActor (ShapeID) -> AnyShapeRecord?
    /// Whether a shape isn't as the editor keeps it; nil for the editor's own committed reading.
    let isChanged: (@MainActor (ShapeID) -> Bool)?
    var isCommitted: Bool { isChanged == nil }
    /// What this source asked afresh, for as long as it lives: nil for the editor's, which keeps in
    /// `sizes`. A context is a snapshot, so what it asked holds for it.
    let fresh: LaidOutSizes?

    init(inputs: LayoutInputs, sizes: LaidOutSizes, lend: @escaping @MainActor (ObjectIdentifier) -> (any EditorService)?,
         shape: @escaping @MainActor (ShapeID) -> AnyShapeRecord?, isChanged: (@MainActor (ShapeID) -> Bool)? = nil) {
        self.inputs = inputs
        self.sizes = sizes
        self.lend = lend
        self.shape = shape
        self.isChanged = isChanged
        fresh = isChanged == nil ? nil : LaidOutSizes()
    }

    /// The value set for a shape, nil for one this source's reader changed: the value was made from
    /// the record as it was, and nil means "as the record says".
    func value(_ name: String, for id: ShapeID) -> AnyHashable? {
        isChanged?(id) == true ? nil : inputs.value(name, for: id)
    }

    /// The size kept for a shape, if it is as kept: the editor's, for a shape this source's reader
    /// hasn't changed (then what this source asked since), else only what this source asked.
    func keptSize(of id: ShapeID) -> CGSize? {
        guard let isChanged else { return sizes.size(of: id) }
        if !isChanged(id), let size = sizes.size(of: id) { return size }
        return fresh?.size(of: id)
    }

    /// Keeps a size just worked out: in the editor's, for its committed reading of a shape in the file
    /// (so it holds until a commit changes the shape), else in what this source keeps for itself.
    func keep(_ size: CGSize, for id: ShapeID) {
        if isChanged == nil {
            if shape(id) != nil { sizes.keep(size, for: id) }
        } else {
            fresh?.keep(size, for: id)
        }
    }
}

/// The sizes shapes are laid out at (`LaidOutBox`), by shape id, for the whole file: worked out when
/// first asked and let go when a commit changes the shape other than by moving it, when the owner of
/// a layout input says the layout changed, and when a file is put in place. A size doesn't depend on
/// where the shape is, so a drag, an undo of a move and a board switch keep it.
@MainActor
final class LaidOutSizes {
    private var sizes: [ShapeID: CGSize] = [:]

    func size(of id: ShapeID) -> CGSize? { sizes[id] }
    func keep(_ size: CGSize, for id: ShapeID) { sizes[id] = size }

    func forget(_ ids: some Sequence<ShapeID>) {
        guard !sizes.isEmpty else { return }
        for id in ids { sizes[id] = nil }
    }

    func forgetAll() { sizes.removeAll() }

    /// How many are kept (tests).
    var count: Int { sizes.count }
}

/// What a layout provider reads besides the shape (`registrar.layoutInput`).
@MainActor
public struct LayoutReading {
    public let registry: Registry
    private let source: LayoutSource

    init(registry: Registry, source: LayoutSource) {
        self.registry = registry
        self.source = source
    }

    /// A shape on any board of the file, as whoever is laying the shape out sees the file: the
    /// editor's, or mid-transaction as the transaction leaves it (what it inserted, changed and
    /// moved; nil for what it deleted).
    public func shape(inFile id: ShapeID) -> AnyShapeRecord? { source.shape(id) }

    /// One of the editor's services.
    public func service<S: EditorService>(_: S.Type) -> S? { source.lend(ObjectIdentifier(S.self)) as? S }

    /// Whether the file read is the editor's as committed. False mid-transaction: what a service
    /// keeps is of the file before, so answer from `shape(inFile:)` there.
    public var isCommitted: Bool { source.isCommitted }
}

extension ShapeContext {
    /// A layout input of a shape: a value set for it (`editor.setLayoutInput`), else what the key's
    /// provider answers (`registrar.layoutInput`), else nil. Nil in a context that isn't the
    /// editor's or a transaction's. Whoever sets or provides it also says when it changes, so a
    /// geometry that reads it is worked out again.
    public func layoutInput<V>(_ key: LayoutInputKey<V>, for id: ShapeID) -> V? {
        guard let layout else { return nil }
        if let value = layout.value(key.name, for: id) as? V { return value }
        guard registry.layoutProviders[key.name] != nil, let record = storedDocument[id] else { return nil }
        return provided(key, of: record)
    }

    /// The same, by the shape's record: this context's own, or one being made.
    public func layoutInput<V>(_ key: LayoutInputKey<V>, of record: AnyShapeRecord) -> V? {
        guard let layout else { return nil }
        if let value = layout.value(key.name, for: record.id) as? V { return value }
        return provided(key, of: record)
    }

    /// The same, of a typed record. The record is erased only once there is a provider to hand it to.
    public func layoutInput<V, P: ShapeProps>(_ key: LayoutInputKey<V>, of shape: ShapeRecord<P>) -> V? {
        guard let layout else { return nil }
        if let value = layout.value(key.name, for: shape.id) as? V { return value }
        guard registry.layoutProviders[key.name] != nil else { return nil }
        return provided(key, of: AnyShapeRecord(shape))
    }

    private func provided<V>(_ key: LayoutInputKey<V>, of record: AnyShapeRecord) -> V? {
        guard let layout, let provider = registry.layoutProviders[key.name] else { return nil }
        return provider.provide(record, LayoutReading(registry: registry, source: layout)) as? V
    }
}

extension ShapeContext {
    /// The frame a shape of this context's document is laid out in, in world units: its box, or,
    /// for a `LaidOutBox` kind, its box grown to what the kind says. Nil for a shape without a box,
    /// or not there. What anything that asks how much room a shape takes reads, in place of
    /// `record.box`; `record.box` is what is stored, and what a write changes.
    public func frame(of id: ShapeID) -> CGRect? {
        shape(id).flatMap { frame(of: $0) }
    }

    /// The same, of a record: this context's own (what a definition is handed, what a loop over
    /// `document.shapes` has), or a shape being made that is in no document yet (`layingOut(with:)`).
    /// A caller with a changed copy of a shape that is on the board reads through `layingOut(with:)`,
    /// which never reads that id from what is kept.
    public func frame(of record: AnyShapeRecord) -> CGRect? {
        guard let box = record.box else { return nil }
        guard let layout, !record.isOpaque, let definition = registry.laidOutBoxes[record.kind] else { return box }
        return laidOut(box, id: record.id, in: layout) {
            definition.erasedLaidOutSize(of: record, in: self)
        }
    }

    public func frame<P: BoxShapeProps>(of shape: ShapeRecord<P>) -> CGRect {
        guard let layout, registry.laidOutBoxes[P.kind] != nil else { return shape.frame }
        return laidOut(shape.frame, id: shape.id, in: layout) {
            registry.laidOutBoxes[P.kind]?.erasedLaidOutSize(of: AnyShapeRecord(shape), in: self)
        }
    }

    /// `frame(of:)` for a definition that is asked: a kept size is read by id with nothing erased.
    /// What a `LaidOutBox` kind's default geometry is, every shape of a board on its first frame.
    func frame<D: LaidOutBox>(of shape: ShapeRecord<D.Props>, laidOutBy definition: D) -> CGRect {
        guard let layout else { return shape.frame }
        return laidOut(shape.frame, id: shape.id, in: layout) {
            definition.laidOutSize(of: shape, in: self)
        }
    }

    /// The kept size at the box's origin, else the kind's, grown to hold the box, kept.
    private func laidOut(_ box: CGRect, id: ShapeID, in layout: LayoutSource, asking ask: () -> CGSize?) -> CGRect {
        if let size = layout.keptSize(of: id) { return CGRect(origin: box.origin, size: size) }
        var size = box.size
        if let asked = ask(), asked.width.isFinite, asked.height.isFinite {
            size = CGSize(width: max(asked.width, box.width), height: max(asked.height, box.height))
        }
        layout.keep(size, for: id)
        return CGRect(origin: box.origin, size: size)
    }

    /// This context, for sizing shapes that aren't in the file yet: `records` are read by layout
    /// providers as shapes of the file, in place of any the file has under their ids, and are laid out
    /// afresh whatever the editor keeps for those ids. It keeps no geometry and no size, and never
    /// touches what the editor keeps. Draw's, for a script's shapes. A context that lays nothing out
    /// (a plain one) gives one that lays nothing out.
    public func layingOut(with records: [AnyShapeRecord]) -> ShapeContext {
        guard let layout else { return ShapeContext(document: storedDocument, registry: registry, camera: storedCamera) }
        let byID = Dictionary(records.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let source = LayoutSource(inputs: layout.inputs, sizes: layout.sizes, lend: layout.lend,
                                  shape: { byID[$0] ?? layout.shape($0) }, isChanged: { byID[$0] != nil })
        return ShapeContext(document: storedDocument, registry: registry, camera: storedCamera, index: nil, layout: source)
    }
}
