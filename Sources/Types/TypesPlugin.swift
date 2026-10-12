import AppKit
import Canvas
import DetailPanel
import ProseMaps
import Selection
import Titles
import Topology
import Validation

/// Types, as a plugin: a shape whose kind can be a type (`canBeType()`, a note) is one while it holds
/// a JSON Schema (`TypeSchemaProperty`), named by its title. Its words say what the type holds, and
/// the sync keeps the two saying the same thing through the editor's language model (`TypeSync`);
/// its words are highlighted where they say a part of its schema (a prose map, `SchemaTarget`, which
/// ProseMaps asks for: without `ProseMapsPlugin` there are none), each part shown in a popover on its
/// words; a mention of another type in its words is a `$ref` to that type's schema
/// (`SchemaReferences`). `/is-a type` makes a shape one, and Remove Type
/// (`removeType`) one no longer. The file's types are `editor.types` (`TypeIndex`). Its rules
/// (`TypeValidationPlugin`) and its panel (`TypeDetailsPlugin`) are plugin values of their own, so a
/// list without Validation or the panel can install Types. It knows no kind: a kind hands it its
/// words (`typeWords`).
public struct TypesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .types }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(TypeSchemaProperty.self)
        // What a shape is: the types it names (`typeable()` kinds), and the edge each is; and the values it
        // holds for their fields.
        registrar.declare(IsAProperty.self)
        registrar.declare(FieldValuesProperty.self)
        registrar.edgeType(IsAEdge.self)
        registrar.edges(in: IsAProperty.self, as: IsAEdge.self)
        // A pointer in a value (a mention token in a string), the edge it is.
        registerFieldLinkEdges(into: &registrar)
        // The index first: the sync and what reads types hear each commit after it.
        registrar.service { TypeIndex(editor: $0) }
        // What the types of a list give, resolved once and kept; it reads nothing as it is made.
        registrar.service { FieldBook(editor: $0) }
        registrar.service { TypeSync<TypeSchemaProperty>(editor: $0) }
        // What changes a shape's field values (one writer for every surface), what is said of them (the check),
        // and the card a row with more in it opens.
        registrar.service { FieldWriter(editor: $0) }
        registrar.service { FieldChecks(editor: $0) }
        registrar.service { FieldCards(editor: $0) }
        // What a shape's rows are made of and the room they take, announced as a type changes: last, so it
        // hears each commit after the index, the field book and the sync.
        registrar.service { RowBook(editor: $0) }
        registrar.layoutInput(TypeRows.extent) { record, reading in RowBook.provide(record, reading) }
        // A click on a row that answers a click, on the canvas and under the editor.
        registerRowFaces(into: &registrar)
        // Resting the pointer on a highlight's words shows the part of the schema they say; in the
        // editor, its own view asks (`TypeIndex.popover(at:on:)`).
        registrar.shapePopovers { editor, record, point in
            guard editor.editingShapeID != record.id else { return nil }
            return TypeHighlights.popover(at: point, on: record, in: editor)
        }
        registerIsACommand(into: &registrar)
        registerTypeMenus(into: &registrar)
        registerTypeChips(into: &registrar)
        // A type's pill is its title in its color, after the mark of a type; untitled, gray and dimmed.
        // Asked of the kinds that hold a schema, a note's, and a plain note's pill is as it was.
        registrar.titlePillLook(forShapesHolding: TypeSchemaProperty.self) { record, title in
            guard record[TypeSchemaProperty.self] != nil else { return nil }
            return TitlePillLook(symbol: TypesStyle.typeSymbol, tint: title == nil ? nil : TypeColors.solid(record.id),
                                 placeholder: TypesStyle.untitledType)
        }
        // A note that is one of a kind that draws rows shows no pill for a title copied from its field: the
        // name is already in its row, folded or not, and the chip above says what it is. Asked where the
        // pill's label is made and where Find reads the title, never for a cover.
        registrar.titlePillLook(forShapesHolding: IsAProperty.self) { record, title, context in
            // The cheap guards first: Find's build asks this of every titled shape in the file.
            guard let title, record[TypeSchemaProperty.self] == nil, record[IsAProperty.self]?.isEmpty == false,
                  let rows = context.service(RowBook.self), rows.kinds.contains(record.kind),
                  let book = context.service(FieldBook.self), book.fieldTitled(record, title: title) != nil else { return nil }
            return TitlePillLook(hidesPill: true)
        }
    }

    #if DEBUG
    /// How many times a type's schema has been read (parsed) in this process, debug builds only:
    /// tests hold what reads a type to reading only the types whose text changed.
    public static var schemasRead: Int { SchemaReadings.made }
    #endif
}

/// Validation's rules for types: a type's schema (`SchemaReadings.issues`): not JSON, or not an object,
/// is an error; `required` naming no property, or a `type` that isn't JSON Schema's, a warning. A
/// note's values against its types' fields (`FieldChecks`): each wrong value is an error (a needed
/// field with no value is no issue), and a type whose JSON refers to a type that is gone, or whose `$title`
/// titles nothing, carries a warning. Neither has an `affected:`: a type's change reaches the notes through the service
/// (`TypeIndex.onChange`, then `ValidationEngine.recheck`), since a rule's `affected:` hears a commit
/// before the index does. After `TypesPlugin` and `ValidationPlugin`.
public struct TypeValidationPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "type-validation" }

    public func register(into registrar: inout PluginRegistrar) {
        // Only the schema's text matters, never where the shape is: a drag of a thousand notes
        // checks none of them again for this.
        registrar.validateEveryShape(ignoringMoves: true) { shape, _ in SchemaReadings.reading(of: shape)?.issues ?? [] }
        // The values of a note are a function of the values and the file's types, never of where it is.
        // Without an editor (draw's check, before it commits) it asks the service through the reading its shapes
        // have, so a type the run writes is read as it stands; with none, it says nothing.
        registrar.validateEveryShape(ignoringMoves: true) { shape, context in
            let check: FieldCheck
            if let checks = context.service(FieldChecks.self) {
                check = checks.check(of: shape)
            } else if let reading = context.reading, let checks = reading.service(FieldChecks.self) {
                check = checks.check(of: shape, reading: reading)
            } else {
                return []
            }
            guard check.isWrong || check.hasWarnings else { return [] }
            return check.problems.compactMap { problem in
                let path = problem.path.isRoot ? nil : problem.path.pointer
                switch problem.kind {
                case .wrong: return ValidationIssue.error(problem.message, field: problem.path.field, path: path)
                case .warning: return ValidationIssue.warning(problem.message, field: problem.path.field, path: path)
                case .needed: return nil
                }
            }
        }
        // A type's own warnings, not the notes' of either: a type it refers to that is gone, and a `$title` that
        // titles nothing (only the type that wrote it: an Employee inheriting Person's says nothing).
        registrar.validateEveryShape(ignoringMoves: true) { shape, context in
            guard shape[TypeSchemaProperty.self] != nil, let checks = context.service(FieldChecks.self) else { return [] }
            var issues = checks.goneReferences(of: shape.id).map { ValidationIssue.warning(FieldCheckWords.refersToGone($0), field: "schema") }
            if let book = context.service(FieldBook.self),
               let problem = TitleSource.problem(book.fields(types: [shape.id]), writtenBy: shape.id) {
                issues.append(.warning(FieldCheckWords.title(problem), field: "schema"))
            }
            return issues
        }
    }
}

/// A type's Schema tab in the detail panel: its JSON, its issues and the sync's status. After
/// `TypesPlugin` and `DetailPanelPlugin`.
public struct TypeDetailsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "type-details" }

    public func register(into registrar: inout PluginRegistrar) {
        registerTypePanel(into: &registrar)
        // The Types rows' fields and values, after them.
        registerFieldsPanel(into: &registrar)
    }
}
