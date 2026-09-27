import Canvas
import CoreGraphics
import SwiftUI

/// A shape as a section sees it. Take it as a `$` parameter, as with `ForEach($items) { $item in }`:
/// `task` is the value the panel last drew, and `$task.title` is a `Binding` whose every write
/// changes that one field of the live shape, in one `editor.transact`, and always on this shape
/// (never on whatever is selected by the time it writes). A write to a shape that's gone does
/// nothing; a write of the value the shape already has commits nothing.
///
/// Reads never touch `editor.document`, so a section isn't re-rendered when other shapes change.
/// For a larger section, write a View with `@ShapeBinding var task: TaskCard` and pass `$task`.
@MainActor @propertyWrapper @dynamicMemberLookup
public struct ShapeBinding<Value> {
    private let value: Value
    /// What the binding's `Binding`s read: the snapshot, until a write through them, then what the
    /// shape became. A control reads back what it wrote before the panel draws again, as SwiftUI
    /// expects of a binding (a text field that took Return first would put the old text back).
    private let latest: Latest
    /// Changes the live shape, and returns what it is then; nil if it's gone.
    private let write: @MainActor (_ change: (inout Value) -> Void) -> Value?

    private final class Latest {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    /// The snapshot the panel drew with.
    public var wrappedValue: Value { value }
    public var projectedValue: ShapeBinding<Value> { self }
    public init(projectedValue: ShapeBinding<Value>) { self = projectedValue }

    private init(value: Value, write: @escaping @MainActor (_ change: (inout Value) -> Void) -> Value?) {
        self.value = value
        latest = Latest(value)
        self.write = write
    }

    /// `$task.title`: reads the snapshot, or what its last write made of the shape; writes the key
    /// path into the live shape. Bind the narrowest key path: a collection's binding writes the
    /// whole collection.
    public subscript<T>(dynamicMember keyPath: WritableKeyPath<Value, T>) -> Binding<T> {
        let latest = latest, write = write
        return Binding(get: { latest.value[keyPath: keyPath] }, set: { new in
            if let live = write({ $0[keyPath: keyPath] = new }) { latest.value = live }
        })
    }

    /// Several changes in one transaction, applied to the live shape (read-modify-write belongs
    /// here, not in a sequence of binding sets): `$task.update { $0.checklist.removeDone() }`.
    public func update(_ change: (inout Value) -> Void) {
        if let live = write(change) { latest.value = live }
    }
}

// The only write paths: every panel edit goes through one of these two. (This file imports
// SwiftUI, whose `Transaction` shadows the core's, so the transactions go unnamed.)
extension ShapeBinding where Value: ShapeProps {
    static func props(of record: AnyShapeRecord, in editor: CanvasEditor) -> ShapeBinding? {
        guard let shape = record.typed(as: Value.self) else { return nil }
        let id = record.id
        return ShapeBinding(value: shape.props) { [weak editor] change in
            guard let editor else { return nil }
            editor.transact { $0.update(id, as: Value.self) { change(&$0.props) } }
            return editor.document[id]?.typed(as: Value.self)?.props
        }
    }
}

extension ShapeBinding where Value == CGRect {
    static func box(of record: AnyShapeRecord, in editor: CanvasEditor) -> ShapeBinding? {
        guard let frame = record.box else { return nil }
        let id = record.id
        return ShapeBinding(value: frame) { [weak editor] change in
            guard let editor else { return nil }
            editor.transact {
                $0.update(id) { record in
                    guard var frame = record.box else { return }
                    change(&frame)
                    record.box = frame
                }
            }
            return editor.document[id]?.box
        }
    }
}

extension CanvasEditor {
    /// A shape's props as its sections get them; nil if there's no such shape of that kind.
    public func shapeBinding<P: ShapeProps>(_ id: ShapeID, as _: P.Type = P.self) -> ShapeBinding<P>? {
        document[id].flatMap { ShapeBinding<P>.props(of: $0, in: self) }
    }

    /// A box shape's frame as every-box sections get it; nil if there's no such shape, or it has
    /// no frame.
    public func frameBinding(_ id: ShapeID) -> ShapeBinding<CGRect>? {
        document[id].flatMap { ShapeBinding<CGRect>.box(of: $0, in: self) }
    }
}
