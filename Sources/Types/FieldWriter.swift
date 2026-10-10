import Canvas

// The one writer of a shape's `fieldValues`: every surface that changes a value (a row, a card, the fold,
// the panel) goes through it, so a field is changed one way and its undo step is named one way. This is
// the plain form (K0): a transaction named for the field, coalesced for each field, with no more than the
// core already does for a shape that can't change.

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

@MainActor
public final class FieldWriter {
    private weak var editor: CanvasEditor?

    public init(editor: CanvasEditor) {
        self.editor = editor
    }

    /// What the shape holds; nothing for a shape that is not on the board shown.
    public func values(of shape: ShapeID) -> FieldValues {
        editor?.document[shape]?[FieldValuesProperty.self] ?? FieldValues()
    }

    /// False and nothing changed for a shape that can't change (read-only: the core shakes it), for a shape
    /// not on the board shown, and for a path that starts with no key. A write that changes nothing makes
    /// no step and is true.
    @discardableResult
    public func set(_ value: JSONValue?, at path: FieldPath, of shape: ShapeID, step: FieldWriteStep = .ownRun) -> Bool {
        guard let key = path.field else { return false }
        return commit(values(of: shape).setting(value, at: path), of: shape, field: key, step: step)
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

    /// A pair's name: moves the value to the new key in the same commit. False when `to` is taken, or
    /// when there is no pair of that name.
    @discardableResult
    public func rename(_ key: String, to new: String, under parent: FieldPath, of shape: ShapeID, step: FieldWriteStep = .ownRun) -> Bool {
        guard let field = parent.field else { return false }
        let current = values(of: shape)
        guard let members = current.value(at: parent)?.objectValue, let held = members[key] else { return false }
        if new == key { return true }
        guard members[new] == nil else { return false }
        let moved = current.setting(held, at: parent.key(new)).setting(nil, at: parent.key(key))
        return commit(moved, of: shape, field: field, step: step)
    }

    /// A value no field names: the step `Remove <key>`, never coalesced.
    @discardableResult
    public func removeUnnamed(_ key: String, of shape: ShapeID) -> Bool {
        commit(values(of: shape).setting(nil, at: FieldPath(field: key)), of: shape, name: "Remove \(key)", coalescing: nil)
    }

    private func commit(_ new: FieldValues, of shape: ShapeID, field key: String, step: FieldWriteStep) -> Bool {
        switch step {
        case .ownRun: commit(new, of: shape, name: stepName(of: key, on: shape), coalescing: FieldRunKey(shape: shape, field: key))
        case .card(let card): commit(new, of: shape, name: nil, coalescing: card)
        }
    }

    private func commit(_ new: FieldValues, of shape: ShapeID, name: String?, coalescing key: AnyHashable?) -> Bool {
        guard let editor, let record = editor.document[shape], editor.registry.isTypeable(record.kind) else { return false }
        let isReadOnly = editor.isReadOnly(shape)
        if !isReadOnly, new == values(of: shape) { return true }
        // A shape that can't change refuses the write, and the core shakes it.
        editor.transact(name, coalescing: key) { transaction in
            transaction.update(shape) { $0[FieldValuesProperty.self] = new }
        }
        return !isReadOnly
    }

    /// `Change Shipping Address`: of the field the key names on this shape's types, else of the key as it is.
    private func stepName(of key: String, on shape: ShapeID) -> String {
        let field = editor?.document[shape].flatMap { editor?.fieldBook?.fields(of: $0).field(named: key)?.field }
        return FieldName.stepName(of: field ?? ChainField(name: key, schema: .null))
    }
}

extension FieldWriter: EditorService {
    /// It keeps nothing per shape or per board, so a switch needs no change set (the default works one out).
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}
}

extension CanvasEditor {
    /// The one writer of a shape's field values (`FieldWriter`); nil without TypesPlugin.
    public var fieldWriter: FieldWriter? { service(FieldWriter.self) }
}
