import Canvas
import Foundation

// The one writer of a type's field definitions: a field's name and kind, and a choice's options. The
// relationship type's card defines fields through it; any type's could. It is a door and no more, shaped like
// `FieldWriter` (which writes values): it asks whether the type can change, names the step, and makes one
// `update` of the type's `schema` text, edited as `SchemaFields` edits it. No model is asked: the sync hears
// the new schema as it hears one typed in the Schema tab.

/// Called from a key or mouse handler, never inside a transaction or while an undo is applied (`transact`
/// refuses both). Each call is one undo step, named for what it does; a call that changes nothing makes none.
@MainActor
public final class FieldDefiner {
    weak var editor: CanvasEditor?

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    /// The step names, in one place.
    public enum Step {
        public static let addField = "Add Field"
        public static let renameField = "Rename Field"
        public static let changeKind = "Change Kind"
        public static let removeField = "Remove Field"
        public static let addOption = "Add Option"
        public static let renameOption = "Rename Option"
        public static let removeOption = "Remove Option"
    }

    /// The type's fields, in the order its `properties` hold them. Empty for a shape that is no type and a
    /// schema that is not JSON (or not an object).
    public func fields(of type: ShapeID) -> [DefinedField] {
        guard let root = schema(of: type) else { return [] }
        return SchemaFields.fields(of: root)
    }

    /// Adds a field named `name` of `kind` after the type's last property, and answers its key (the name in
    /// camelCase, `since`, made unique: `since2`). Nil, and nothing written, for a name with no letter or
    /// digit in it, a schema that is not a JSON object, a `properties` that is not one, a shape that is no
    /// type and a type that can't change (the core shakes it).
    @discardableResult
    public func addField(named name: String, kind: DefinedKind, to type: ShapeID) -> String? {
        var key: String?
        let written = write(type, Step.addField) { root in
            guard let added = SchemaFields.adding(name, kind: kind, to: root) else { return nil }
            key = added.key
            return added.schema
        }
        return written ? key : nil
    }

    /// Names the field `key` `name` (its key stays; its `title` says the name, or is taken off when the key's
    /// own words say it). True when the type now says it; false and nothing written for an empty name, a field
    /// that is not there and the refusals of `addField`.
    @discardableResult
    public func renameField(_ key: String, to name: String, in type: ShapeID) -> Bool {
        write(type, Step.renameField) { SchemaFields.renaming(key, to: name, in: $0) }
    }

    /// Makes the field `key` a `kind`, keeping its title and description; a choice that becomes another kind
    /// loses its options.
    @discardableResult
    public func changeKind(of key: String, to kind: DefinedKind, in type: ShapeID) -> Bool {
        write(type, Step.changeKind) { SchemaFields.changing(key, to: kind, in: $0) }
    }

    /// Takes the field out of the type, and its name out of `required`. Values notes hold under its key stay
    /// where they are, as a value no field names (the panel lists them and takes them out).
    @discardableResult
    public func removeField(_ key: String, from type: ShapeID) -> Bool {
        write(type, Step.removeField) { SchemaFields.removing(key, from: $0) }
    }

    /// Adds an option after the last of a choice's options (an option it has, or an empty one, changes nothing).
    @discardableResult
    public func addOption(_ option: String, to key: String, in type: ShapeID) -> Bool {
        write(type, Step.addOption) { SchemaFields.addingOption(option, to: key, in: $0) }
    }

    /// Words the option at `place`, counted as `DefinedField.options` lists them. A note holding the old
    /// option keeps it as a value no option has (the check says so).
    @discardableResult
    public func renameOption(at place: Int, to option: String, of key: String, in type: ShapeID) -> Bool {
        write(type, Step.renameOption) { SchemaFields.renamingOption(at: place, to: option, of: key, in: $0) }
    }

    /// Takes the option at `place` out; the field stays a choice when it was the last.
    @discardableResult
    public func removeOption(at place: Int, of key: String, in type: ShapeID) -> Bool {
        write(type, Step.removeOption) { SchemaFields.removingOption(at: place, of: key, in: $0) }
    }

    // MARK: The door

    /// The type's schema, read; nil for a shape that holds none or a text that is not a JSON object.
    private func schema(of type: ShapeID) -> SchemaValue? {
        guard let text = editor?.shape(inFile: type)?[TypeSchemaProperty.self]?.text,
              let node = try? JSONReader.read(text), node.isObject else { return nil }
        return SchemaValue(node)
    }

    /// True once the new schema stands. A shape that holds no schema is false; one that can't change is
    /// `editor.refuseChanges(to:)` (services hear it, Selection shakes it) and false, before any transaction; a
    /// schema that is not a JSON object is false and no shake (broken mid-edit: a no); an edit that is refused
    /// or changes nothing is false, with no commit and no step. Else one `update` of the type's record, in one
    /// step, the schema written as `SchemaValue.pretty` lays it out.
    private func write(_ type: ShapeID, _ name: String, _ edit: (SchemaValue) -> SchemaValue?) -> Bool {
        guard let editor, editor.shape(inFile: type)?[TypeSchemaProperty.self] != nil else { return false }
        if editor.isReadOnly(inFile: type) {
            editor.refuseChanges(to: [type])
            return false
        }
        guard let old = schema(of: type), let new = edit(old), new != old else { return false }
        let text = new.pretty
        editor.transact(name) { transaction in
            transaction.update(inFile: type) { $0[TypeSchemaProperty.self] = SchemaText(text) }
        }
        return true
    }
}

extension FieldDefiner: EditorService {
    /// It keeps nothing per shape or per board, so a switch needs no change set (the default works one out).
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}
}

extension CanvasEditor {
    /// The one writer of a type's field definitions (`FieldDefiner`); nil without TypesPlugin.
    public var fieldDefiner: FieldDefiner? { service(FieldDefiner.self) }
}
