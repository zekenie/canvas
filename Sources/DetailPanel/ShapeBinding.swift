import Canvas
import CoreGraphics
import SwiftUI

/// A shape as a section sees it. Take it as a `$` parameter, as with `ForEach($items) { $item in }`:
/// `task` is the value the panel last drew, and `$task.notes` is a `Binding` whose every write
/// changes that one field of the live shape, in one `editor.transact`, and always on this shape
/// (never on whatever is selected by the time it writes). A write to a shape that's gone does
/// nothing; a write of the value the shape already has commits nothing.
///
/// Reads never touch `editor.document`, so a section isn't re-rendered when other shapes change.
/// For a larger section, write a View with `@ShapeBinding var task: TaskCard` and pass `$task`.
@MainActor @propertyWrapper @dynamicMemberLookup
public struct ShapeBinding<Value> {
    private let value: Value
    /// The whole shape the value was read from, as the panel drew it.
    private let record: AnyShapeRecord
    /// What the binding's `Binding`s read: the snapshot, until a write through them, then what the
    /// shape became. A control reads back what it wrote before the panel draws again, as SwiftUI
    /// expects of a binding (a text field that took Return first would put the old text back).
    private let latest: Latest
    /// The added properties the shape's kind opts into: the only ones it can hold.
    private let properties: [PropertyKey]
    /// Changes the live shape, and returns what it is then; nil if it's gone.
    private let write: @MainActor (_ change: (inout Value) -> Void) -> Value?
    /// The same, for the whole record: what an added property's binding writes through.
    private let edit: @MainActor (_ change: (inout AnyShapeRecord) -> Void) -> AnyShapeRecord?

    private final class Latest {
        var value: Value
        /// The whole shape, likewise: what the added properties' bindings read.
        var record: AnyShapeRecord
        init(_ value: Value, _ record: AnyShapeRecord) {
            self.value = value
            self.record = record
        }
    }

    /// The snapshot the panel drew with.
    public var wrappedValue: Value { value }
    public var projectedValue: ShapeBinding<Value> { self }
    public init(projectedValue: ShapeBinding<Value>) { self = projectedValue }

    private init(value: Value, record: AnyShapeRecord, in editor: CanvasEditor,
                 write: @escaping @MainActor (_ change: (inout Value) -> Void) -> Value?) {
        self.value = value
        self.record = record
        latest = Latest(value, record)
        properties = editor.registry.properties(for: record.kind)
        self.write = write
        let id = record.id
        edit = { [weak editor] change in
            guard let editor else { return nil }
            editor.transact { $0.update(id, change) }
            return editor.document[id]
        }
    }

    /// `$task.notes`: reads the snapshot, or what its last write made of the shape; writes the key
    /// path into the live shape. Bind the narrowest key path: a collection's binding writes the
    /// whole collection.
    public subscript<T>(dynamicMember keyPath: WritableKeyPath<Value, T>) -> Binding<T> {
        let latest = latest, write = write
        return Binding(get: { latest.value[keyPath: keyPath] }, set: { new in
            if let live = write({ $0[keyPath: keyPath] = new }) { latest.value = live }
        })
    }

    /// Whether the shape's kind opts into an added property, so the shape can hold one: a section
    /// for every box, or every shape with some property, may bind another that only some kinds
    /// opt into.
    public func holds<P: ShapeProperty>(_: P.Type) -> Bool { properties.contains(P.key) }

    /// Several changes in one transaction, applied to the live shape (read-modify-write belongs
    /// here, not in a sequence of binding sets): `$items.update { $0.removeDone() }`.
    public func update(_ change: (inout Value) -> Void) {
        if let live = write(change) { latest.value = live }
    }

    /// An added property of the shape, nil while it has none: `$note[TitleProperty.self]`. Each
    /// write sets it on the live shape, in one transaction; nil removes it, for a property whose
    /// default is nil (a property every shape has keeps its value). The added properties' bindings
    /// this makes read what the last write through any of them made of the shape, until the panel
    /// redraws, as the key paths' bindings do. A shape whose kind doesn't opt into the property
    /// never holds it: the binding reads nil, and drops what's written (`holds(_:)` says which).
    public subscript<P: ShapeProperty>(_: P.Type) -> Binding<P.Value?> {
        let latest = latest, edit = edit
        return Binding(get: { latest.record[P.self] }, set: { new in
            if let live = edit({ $0[P.self] = new }) { latest.record = live }
        })
    }
}

extension ShapeBinding where Value: ShapeProps {
    /// The shape as the panel drew it: its props, and the added properties beside them
    /// (`$task.shape[ChecklistProperty.self]`), for what a section or header shows from both.
    public var shape: ShapeRecord<Value> {
        record.typed(as: Value.self) ?? ShapeRecord(id: record.id, value)
    }
}

// The only write paths: every panel edit goes through one of these three, or through the whole
// record (`edit`, for an added property of the shape). (This file imports SwiftUI, whose
// `Transaction` shadows the core's, so the transactions go unnamed.)
extension ShapeBinding where Value: ShapeProps {
    static func props(of record: AnyShapeRecord, in editor: CanvasEditor) -> ShapeBinding? {
        guard let shape = record.typed(as: Value.self) else { return nil }
        let id = record.id
        return ShapeBinding(value: shape.props, record: record, in: editor) { [weak editor] change in
            guard let editor else { return nil }
            editor.transact { $0.update(id, as: Value.self) { change(&$0.props) } }
            return editor.document[id]?.typed(as: Value.self)?.props
        }
    }
}

extension ShapeBinding {
    /// An added property's value; nil if the shape has none.
    static func property<P: ShapeProperty>(_: P.Type, of record: AnyShapeRecord, in editor: CanvasEditor) -> ShapeBinding? where P.Value == Value {
        guard let value = record[P.self] else { return nil }
        let id = record.id
        return ShapeBinding(value: value, record: record, in: editor) { [weak editor] change in
            guard let editor else { return nil }
            editor.transact {
                $0.update(id) { record in
                    guard var value = record[P.self] else { return }
                    change(&value)
                    record[P.self] = value
                }
            }
            return editor.document[id]?[P.self]
        }
    }
}

extension ShapeBinding where Value == CGRect {
    static func box(of record: AnyShapeRecord, in editor: CanvasEditor) -> ShapeBinding? {
        guard let frame = record.box else { return nil }
        let id = record.id
        return ShapeBinding(value: frame, record: record, in: editor) { [weak editor] change in
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

    /// An added property's value as its sections get it; nil if there's no such shape, or it has
    /// no value.
    public func propertyBinding<P: ShapeProperty>(_ id: ShapeID, _ property: P.Type) -> ShapeBinding<P.Value>? {
        document[id].flatMap { ShapeBinding<P.Value>.property(P.self, of: $0, in: self) }
    }
}
