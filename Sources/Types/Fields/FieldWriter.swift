import Canvas
import Titles

// The one writer of a shape's `fieldValues`: every surface that changes a value (a row, a card, the fold,
// the panel) goes through it, so a field is changed one way and its undo step is named one way. It is a
// door and no more: it asks whether the shape can change, names the step, and makes one `update`.

/// The run of commits one top-level field of one shape makes while it is typed in: one undo step.
public struct FieldRunKey: Hashable, Sendable {
    public var shape: ShapeID
    public var field: String

    public init(shape: ShapeID, field: String) {
        self.shape = shape
        self.field = field
    }
}

// `@unchecked`: the key is a hashable value that stands for a card (`AnyHashable` is not `Sendable` in this SDK).
public enum FieldWriteStep: @unchecked Sendable {
    /// Rows, the panel and the fold's card. Named `FieldName.stepName`; one step a top-level field:
    /// each keystroke is a commit and typing in one field is one step. A different field, a pause that
    /// seals the run, or a commit from elsewhere ends it.
    case ownRun
    /// Inside an open card: joined to the card's held step, named and held by the core. The key is the
    /// card's `id`.
    case card(key: AnyHashable)
}

/// Called from a key or mouse handler, never inside a transaction or while an undo is applied (`transact`
/// refuses both).
@MainActor
public final class FieldWriter {
    /// Internal: the panel builds a form's context and asks `isReadOnly` through it.
    weak var editor: CanvasEditor?

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    /// What the shape holds, on whichever board it is; nothing for a shape that is on none.
    public func values(of shape: ShapeID) -> FieldValues {
        editor?.shape(inFile: shape)?[FieldValuesProperty.self] ?? FieldValues()
    }

    /// True once the value stands: written, or already there (a write that changes nothing makes no commit
    /// and no step). False, and nothing changed, for a shape that can't change (the core shakes it), a shape
    /// on no board of the file, a kind that holds no values, and a path that starts with no key (the root
    /// included). A shape on another board than the one shown is written there, in the same step as any other
    /// write of the card it comes from (a far arrow's values, edited in a row's card).
    @discardableResult
    public func set(_ value: JSONValue?, at path: FieldPath, of shape: ShapeID, step: FieldWriteStep = .ownRun) -> Bool {
        guard let field = path.field else { return false }
        return apply(shape, field: field, step: step) { $0 = $0.setting(value, at: path) }
    }

    /// `set(FieldText.value(from: typed, as: kind), …)`.
    @discardableResult
    public func setTyped(_ typed: String, as kind: PlainKind, at path: FieldPath, of shape: ShapeID, step: FieldWriteStep = .ownRun) -> Bool {
        set(FieldText.value(from: typed, as: kind), at: path, of: shape, step: step)
    }

    /// Takes the element at an index out (the rest shift up), or the member at a key.
    @discardableResult
    public func remove(at path: FieldPath, of shape: ShapeID, step: FieldWriteStep = .ownRun) -> Bool {
        set(nil, at: path, of: shape, step: step)
    }

    /// A pair's name: moves the value to the new key in the same commit. False when there is no pair of
    /// that name, when `new` is empty, equal to `key` or taken, and for the root (a field's own key is
    /// never renamed); nothing changed then.
    @discardableResult
    public func rename(_ key: String, to new: String, under parent: FieldPath, of shape: ShapeID, step: FieldWriteStep = .ownRun) -> Bool {
        guard let field = parent.field, !new.isEmpty, new != key else { return false }
        let current = values(of: shape)
        guard let held = current.value(at: parent.key(key)), current.value(at: parent.key(new)) == nil else { return false }
        return apply(shape, field: field, step: step) { $0 = $0.setting(held, at: parent.key(new)).setting(nil, at: parent.key(key)) }
    }

    /// A value no field names: the step `Remove <key>`, never coalesced. It does not ask whether a field
    /// names the key (its caller lists only the keys none does).
    @discardableResult
    public func removeUnnamed(_ key: String, of shape: ShapeID) -> Bool {
        apply(shape, name: TypesStyle.removeValue(key), key: nil) { $0 = $0.setting(nil, at: FieldPath(field: key)) }
    }

    private func apply(_ shape: ShapeID, field: String, step: FieldWriteStep, _ change: (inout FieldValues) -> Void) -> Bool {
        switch step {
        case .ownRun: apply(shape, name: stepName(of: field, on: shape), key: AnyHashable(FieldRunKey(shape: shape, field: field)), change)
        case .card(let card): apply(shape, name: nil, key: card, change)
        }
    }

    /// The one door: a shape that can't change is refused before a transaction (the core shakes it, and
    /// there is no empty step); else one `update` of the shape's record, which keeps it only if it differs.
    private func apply(_ shape: ShapeID, name: String?, key: AnyHashable?, _ change: (inout FieldValues) -> Void) -> Bool {
        guard let editor, let record = editor.shape(inFile: shape), editor.registry.isTypeable(record.kind) else { return false }
        if editor.isReadOnly(inFile: shape) {
            editor.refuseChanges(to: [shape])
            return false
        }
        editor.transact(name, coalescing: key) { transaction in
            transaction.update(inFile: shape) { record in
                let old = record[FieldValuesProperty.self] ?? FieldValues()
                var values = old
                change(&values)
                record[FieldValuesProperty.self] = values.isEmpty ? nil : values
                // The title, if a field titles this note, is written in the same update, so one step holds both.
                if let title = titling(record, old: old, new: values) { record[TitleProperty.self] = title }
            }
        }
        return true
    }

    /// What the title becomes when the values go from `old` to `new` (`FieldTitling.retitle`); nil leaves it.
    /// Only a kind that holds a title is asked (a set on another kind is dropped silently), and only a note
    /// that is one with a `$title` that works (never a type's own note).
    private func titling(_ record: AnyShapeRecord, old: FieldValues, new: FieldValues) -> String?? {
        guard let editor, editor.registry.properties(for: record.kind).contains(TitleProperty.key),
              let source = editor.fieldBook?.titleSource(of: record) else { return nil }
        return FieldTitling.retitle(held: TitleProperty.folded(record[TitleProperty.self]), old: old, new: new, source)
    }

    /// `Change Shipping Address`: of the field the key names on this shape's types, else of the key as it is.
    private func stepName(of key: String, on shape: ShapeID) -> String {
        let field = editor?.shape(inFile: shape).flatMap { editor?.fieldBook?.fields(of: $0).field(named: key)?.field }
        return FieldName.stepName(of: field ?? ChainField(name: key, schema: .null))
    }
}

extension FieldWriter: EditorService {}

extension CanvasEditor {
    /// The one writer of a shape's field values (`FieldWriter`); nil without TypesPlugin.
    public var fieldWriter: FieldWriter? { service(FieldWriter.self) }
}

extension TypesStyle {
    /// `Remove Nickname`: the step of taking a value no field names out, and its minus's label.
    static func removeValue(_ key: String) -> String {
        let words = FieldName.words(of: ChainField(name: key, schema: .null)).split(whereSeparator: \.isWhitespace)
        return (["Remove"] + words.map { $0.prefix(1).uppercased() + $0.dropFirst() }).joined(separator: " ")
    }
}
