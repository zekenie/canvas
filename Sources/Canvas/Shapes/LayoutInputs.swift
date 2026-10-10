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

/// What a context lays shapes out with: the values set for them (`inputs`), the editor's services,
/// and the file as whoever lays them out sees it. A class, so a context copies one reference, as it
/// copied `LayoutInputs` before.
@MainActor
final class LayoutSource {
    /// Values set (`editor.setLayoutInput`).
    let inputs: LayoutInputs
    let lend: @MainActor (ObjectIdentifier) -> (any EditorService)?
    /// A shape on any board of the file, as this source's reader sees the file.
    let shape: @MainActor (ShapeID) -> AnyShapeRecord?
    /// Whether a shape isn't as the editor keeps it; nil for the editor's own committed reading.
    let isChanged: (@MainActor (ShapeID) -> Bool)?
    var isCommitted: Bool { isChanged == nil }

    init(inputs: LayoutInputs, lend: @escaping @MainActor (ObjectIdentifier) -> (any EditorService)?,
         shape: @escaping @MainActor (ShapeID) -> AnyShapeRecord?, isChanged: (@MainActor (ShapeID) -> Bool)? = nil) {
        self.inputs = inputs
        self.lend = lend
        self.shape = shape
        self.isChanged = isChanged
    }

    /// The value set for a shape, nil for one this source's reader changed: the value was made from
    /// the record as it was, and nil means "as the record says".
    func value(_ name: String, for id: ShapeID) -> AnyHashable? {
        isChanged?(id) == true ? nil : inputs.value(name, for: id)
    }
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
