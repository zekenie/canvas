import Canvas
import CoreGraphics
import SwiftUI

/// A shape as a section sees it. Take it as a `$` parameter, as with `ForEach($items) { $item in }`:
/// `card` is the value the panel last drew, and `$card.schema` is a `Binding` whose every write
/// changes that one field of the live shape, in one `editor.transact`, and always on this shape
/// (never on whatever is selected by the time it writes). A write to a shape that's gone does
/// nothing; a write of the value the shape already has commits nothing.
///
/// Reads never touch `editor.document`, so a section isn't re-rendered when other shapes change.
/// For a larger section, write a View with `@ShapeBinding var card: SchemaCard` and pass `$card`.
///
/// Writes are undo steps named for the section ("Change JSON"; "Change" and the kind's name,
/// "Change Schema", in the header or a section without a title). Writes to one field of one shape, one after
/// another, are one step (a field typed into, a slider or a color dragged), until anything else
/// happens: another field, a click or a key elsewhere (the host seals the run), any other change.
/// `update` is a step of its own; `update(\.field)`, a write to a field through a method, runs
/// together as the field's binding does.
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
    /// Changes the live shape, in a step named `name` (nil: the kind's) that writes to one field run
    /// together under `key` (nil: a step of its own), and returns what it is then; nil if it's gone.
    private let write: @MainActor (_ name: String?, _ key: AnyHashable?, _ change: (inout Value) -> Void) -> Value?
    /// The same, for the whole record: what an added property's binding writes through.
    private let edit: @MainActor (_ name: String?, _ key: AnyHashable?, _ change: (inout AnyShapeRecord) -> Void) -> AnyShapeRecord?
    /// What names its writes' undo steps: its section's "Change Color"; nil for the kind's.
    private var stepName: String?
    /// The added property whose value this binds, if it does: its writes run together under the
    /// property, rather than the key path.
    private let property: PropertyKey?
    /// For `service`.
    private weak var editor: CanvasEditor?

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
    /// The shape the binding reads and writes, whatever its value is (its props, its frame, an
    /// added property's value).
    public var shapeID: ShapeID { record.id }
    public var projectedValue: ShapeBinding<Value> { self }
    public init(projectedValue: ShapeBinding<Value>) { self = projectedValue }

    private init(value: Value, record: AnyShapeRecord, property: PropertyKey? = nil, in editor: CanvasEditor,
                 write: @escaping @MainActor (_ name: String?, _ key: AnyHashable?, _ change: (inout Value) -> Void) -> Value?) {
        self.value = value
        self.record = record
        self.property = property
        latest = Latest(value, record)
        properties = editor.registry.properties(for: record.kind)
        self.write = write
        self.editor = editor
        let id = record.id
        edit = { [weak editor] name, key, change in
            guard let editor else { return nil }
            editor.transact(name ?? editor.changeName(of: id), coalescing: key) { $0.update(id, change) }
            return editor.document[id]
        }
    }

    /// The same binding, its writes named `name` in undo ("Change Color").
    func named(_ name: String?) -> ShapeBinding {
        var named = self
        named.stepName = name
        return named
    }

    /// `$card.schema`: reads the snapshot, or what its last write made of the shape; writes the key
    /// path into the live shape. Bind the narrowest key path: a collection's binding writes the
    /// whole collection. Writes to one key path of one shape, one after another, are one undo step.
    public subscript<T>(dynamicMember keyPath: WritableKeyPath<Value, T>) -> Binding<T> {
        let latest = latest, write = write, name = stepName, key = runKey(keyPath)
        return Binding(get: { latest.value[keyPath: keyPath] }, set: { new in
            if let live = write(name, key, { $0[keyPath: keyPath] = new }) { latest.value = live }
        })
    }

    /// What the writes to one field of the shape run together under: the shape and the key path,
    /// or the property for an added property's value.
    private func runKey(_ keyPath: AnyKeyPath) -> AnyHashable {
        AnyHashable(property.map { [AnyHashable(record.id), AnyHashable($0)] } ?? [AnyHashable(record.id), AnyHashable(keyPath)])
    }

    /// Whether the shape's kind opts into an added property, so the shape can hold one: a section
    /// for every box, or every shape with some property, may bind another that only some kinds
    /// opt into.
    public func holds<P: ShapeProperty>(_: P.Type) -> Bool { properties.contains(P.key) }

    /// Several changes in one transaction, applied to the live shape (read-modify-write belongs
    /// here, not in a sequence of binding sets): `$parts.update { $0.removeAll { $0.text.isEmpty } }`.
    /// An undo step of its own.
    public func update(_ change: (inout Value) -> Void) {
        if let live = write(stepName, nil, change) { latest.value = live }
    }

    /// A write to one field that goes through the value's own method, which may keep what follows
    /// from the field in step too (`$card.update(\.schema) { $0.setTitle(name) }`, which renames a
    /// schema in its text): applied to the live shape, as `update` is, but one after another they run
    /// together into one undo step, with the field's own binding's writes (`$card.schema`), as
    /// typing in a field does.
    public func update<T>(_ field: WritableKeyPath<Value, T>, _ change: (inout Value) -> Void) {
        if let live = write(stepName, runKey(field), change) { latest.value = live }
    }

    /// An added property of the shape, nil while it has none: `$note[TitleProperty.self]`. Each
    /// write sets it on the live shape, in one transaction; nil removes it, for a property whose
    /// default is nil (a property every shape has keeps its value). The added properties' bindings
    /// this makes read what the last write through any of them made of the shape, until the panel
    /// redraws, as the key paths' bindings do. A shape whose kind doesn't opt into the property
    /// never holds it: the binding reads nil, and drops what's written (`holds(_:)` says which).
    /// Writes one after another are one undo step.
    public subscript<P: ShapeProperty>(_: P.Type) -> Binding<P.Value?> {
        let latest = latest, edit = edit, name = stepName
        let key = AnyHashable([AnyHashable(record.id), AnyHashable(P.key)])
        return Binding(get: { latest.record[P.self] }, set: { new in
            if let live = edit(name, key, { $0[P.self] = new }) { latest.record = live }
        })
    }

    /// A service of the editor the panel shows (a plugin's own state for this shape, such as a
    /// sync in progress), as `DetailContext.service` is for status lines; nil if it isn't
    /// installed. A view that reads observable state from it redraws on its own when that changes.
    public func service<S: EditorService>(_: S.Type) -> S? { editor?.service(S.self) }
}

extension CanvasEditor {
    /// What a panel write names its undo step when its section has no title (the header, say):
    /// "Change" and the kind's label ("Change Schema", `registry.label(of:)`).
    func changeName(of id: ShapeID) -> String {
        guard let kind = document[id]?.kind else { return "Change" }
        return "Change \(registry.label(of: kind).name)"
    }
}

extension ShapeBinding where Value: ShapeProps {
    /// The shape as the panel drew it: its props, and the added properties beside them
    /// (`$note.shape[TitleProperty.self]`), for what a section or header shows from both.
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
        return ShapeBinding(value: shape.props, record: record, in: editor) { [weak editor] name, key, change in
            guard let editor else { return nil }
            editor.transact(name ?? editor.changeName(of: id), coalescing: key) { $0.update(id, as: Value.self) { change(&$0.props) } }
            return editor.document[id]?.typed(as: Value.self)?.props
        }
    }
}

extension ShapeBinding {
    /// An added property's value; nil if the shape has none.
    static func property<P: ShapeProperty>(_: P.Type, of record: AnyShapeRecord, in editor: CanvasEditor) -> ShapeBinding? where P.Value == Value {
        guard let value = record[P.self] else { return nil }
        let id = record.id
        return ShapeBinding(value: value, record: record, property: P.key, in: editor) { [weak editor] name, key, change in
            guard let editor else { return nil }
            editor.transact(name ?? editor.changeName(of: id), coalescing: key) {
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
        return ShapeBinding(value: frame, record: record, in: editor) { [weak editor] name, key, change in
            guard let editor else { return nil }
            editor.transact(name ?? editor.changeName(of: id), coalescing: key) {
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
