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

extension ShapeContext {
    /// A layout input of a shape, nil when none is set (or this context isn't the editor's).
    /// Whoever sets it also says when it changes, so a geometry that reads it is worked out again.
    public func layoutInput<V>(_ key: LayoutInputKey<V>, for id: ShapeID) -> V? {
        layout?.value(key.name, for: id) as? V
    }
}
