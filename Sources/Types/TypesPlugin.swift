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
        // What a note's rows answer (`RowsView`), for the Keyboard Shortcuts window.
        registrar.keyHint("⇥ or ⇧⇥", "Next or Previous Field", while: .text)
        // What a shape is: the types it names (`typeable()` kinds), and the edge each is; and the values it
        // holds for their fields.
        registrar.declare(IsAProperty.self)
        registrar.declare(FieldValuesProperty.self)
        // Whether a shape of a type fills its fields from its words (`FieldFill`), and on a type, whether its shapes do.
        registrar.declare(AutofillProperty.self)
        // A type that says what an arrow between two notes holds (the mark), and an arrow's rule for the end
        // it is (`relating()` kinds).
        registrar.declare(RelationshipProperty.self)
        registrar.declare(RelationshipEndProperty.self)
        registrar.edgeType(IsAEdge.self)
        registrar.edges(in: IsAProperty.self, as: IsAEdge.self)
        // The index first: the sync and what reads types hear each commit after it.
        registrar.service { TypeIndex(editor: $0) }
        // What the file's relationships are: the ends of every relationship type, compiled from the arrows
        // between it and other types; right after the index it hears after, before what reads it.
        registrar.service { RelationshipIndex(editor: $0) }
        // What the types of a list give, resolved once and kept; it reads nothing as it is made.
        registrar.service { FieldBook(editor: $0) }
        registrar.service { TypeSync<TypeSchemaProperty>(editor: $0) }
        // What changes a shape's field values (one writer for every surface), what is said of them (the check),
        // and the card a row with more in it opens.
        registrar.service { FieldWriter(editor: $0) }
        // What fills a shape's fields from its words, through the writer (and the model, as the sync asks it).
        registrar.service { FieldFill(editor: $0) }
        // And what changes the fields a type defines: the one writer of its schema's properties.
        registrar.service { FieldDefiner(editor: $0) }
        registrar.service { editor in
            let registry = editor.registry
            return FieldChecks(editor: editor, endKinds: Set(registry.kinds.filter { registry.isTypeable($0) && !registry.relates($0) }))
        }
        registrar.service { FieldCards(editor: $0) }
        // And the card that defines a relationship type, under its pill.
        registrar.service { DefinitionCards(editor: $0) }
        // What the writers and chips of IsA ask of the parts above it: the arrow's card a chip opens and the card that
        // defines a relationship type (Tab in its pill's name; nothing fills it in yet), which are Form's, and the tone of an
        // arrow's chip, which is the check's.
        registrar.service { editor in
            RelationshipHooks(tone: { [weak editor] id in
                                  // Only a shape of a kind that relates can be a misfit: a note holding `is` is not asked of the check.
                                  guard let editor, let arrow = editor.shape(inFile: id), editor.registry.relates(arrow.kind),
                                        editor.fieldChecks?.check(of: arrow).isMisfit == true else { return .plain }
                                  return .wrong
                              },
                              openCard: { [weak editor] id in editor?.openRelationshipCard(for: id) ?? false },
                              openDefinition: { [weak editor] id in editor?.definitionCards?.open(id, enteredByKey: true) ?? false })
        }
        // What a shape's rows are made of and the room they take, announced as a type changes: last, so it
        // hears each commit after the index, the field book and the sync.
        registrar.service { RowBook(editor: $0) }
        registrar.layoutInput(TypeRows.extent) { record, reading in RowBook.provide(record, reading) }
        // And how a relationship type is drawn: a pill.
        registrar.layoutInput(TypeRows.pill) { record, reading in RowBook.providePill(record, reading) }
        // The line through a relationship type's pill: what its end arrows are told (`TypeRows.endArrow`), after the index it hears.
        registerEndArrows(into: &registrar)
        // And the select tool's: a point on either half is the relationship type, which outlines its halves with it.
        registerEndSelection(into: &registrar)
        // A click on a row that answers a click, on the canvas and under the editor.
        registerRowFaces(into: &registrar)
        // A click on a relationship type's pill opens the card that defines it.
        registerDefinitionFace(into: &registrar)
        // And by keys: Open Fields, the card of the selected arrow's relationship or of the selected relationship type; Retry, the
        // failed read's action.
        registerFieldsCommand(into: &registrar)
        registerRetryCommand(into: &registrar)
        // What VoiceOver says a shape is: its types, or that it is one.
        registerTypeAccessibility(into: &registrar)
        // A click on a pill in a type's words that names a type it is not yet related to: `Relate to Layer`. Asked before
        // Mentions' faces, since Types is listed after Mentions.
        registerRelateOffer(into: &registrar)
        // Deleting a relationship type deletes its end arrows in the same step, but a locked one.
        registerRelationshipDeletes(into: &registrar)
        // Resting the pointer on a highlight's words shows the part of the schema they say; in the
        // editor, its own view asks (`TypeIndex.popover(at:on:)`).
        registrar.shapePopovers { editor, record, point in
            guard editor.editingShapeID != record.id else { return nil }
            return TypeHighlights.popover(at: point, on: record, in: editor)
        }
        registerIsACommand(into: &registrar)
        registerTypeMenus(into: &registrar)
        // Needed and Only one, on the arrow that is an end: its menu (its panel is the details plugin's).
        registerEndRuleMenu(into: &registrar)
        registerTypeChips(into: &registrar)
        // Where an arrow of a relationship type has its label: its pill, and the offer of one on a selected plain arrow.
        registerRelationshipPills(into: &registrar)
        // A type's pill is its title in its color (Colors', else its id's), after the mark of a type; untitled, gray and dimmed. A
        // relationship type has none: it is a pill itself. Asked of the kinds that hold a schema, a note's, and a plain note's pill is as it was.
        registrar.forShapes(holding: TypeSchemaProperty.self) { typeKinds in
            typeKinds.titlePillLook { record, title, context in
                guard record[TypeSchemaProperty.self] != nil else { return nil }
                // A relationship type is a pill itself (`TypeRows.pill`): its name is on it, and no pill shows above it.
                if record[RelationshipProperty.self] == true { return TitlePillLook(hidesPill: true) }
                let symbol = TypesStyle.typeSymbol
                let tint = title == nil ? nil : context.service(TypeIndex.self).map { $0.look(of: record.id).solid }
                return TitlePillLook(symbol: symbol, tint: tint, placeholder: TypesStyle.untitledType)
            }
        }
        // A note that is one of a kind that draws rows shows no pill for a title copied from its field: the
        // name is already in its row, folded or not, and the chip above says what it is. Asked where the
        // pill's label is made and where Find reads the title, never for a cover.
        registrar.forShapes(holding: IsAProperty.self) { typeable in
            typeable.titlePillLook { record, title, context in
                // The cheap guards first: Find's build asks this of every titled shape in the file.
                guard let title, record[TypeSchemaProperty.self] == nil, record[IsAProperty.self]?.isEmpty == false,
                      let rows = context.service(RowBook.self), rows.kinds.contains(record.kind),
                      let book = context.service(FieldBook.self), book.fieldTitled(record, title: title) != nil else { return nil }
                return TitlePillLook(hidesPill: true)
            }
        }
    }

    #if DEBUG
    /// How many times a type's schema has been read (parsed) in this process, debug builds only:
    /// tests hold what reads a type to reading only the types whose text changed.
    public static var schemasRead: Int { SchemaReadings.made }
    /// How many readings are kept now, and the most that are (debug builds only): the open files' types
    /// with room to spare, no fewer than the minimum, which a test may set to a few to see readings go.
    public static var schemaReadingsKept: Int { SchemaReadings.keptCount }
    public static var schemaReadingsCapacity: Int { SchemaReadings.capacity }
    public static var schemaReadingsMinimum: Int {
        get { SchemaReadings.minimumCapacity }
        set { SchemaReadings.minimumCapacity = newValue }
    }
    #endif
}

/// Validation's rules for types: a type's schema (`SchemaReadings.issues`): not JSON, or not an object,
/// is an error; `required` naming no property, or a `type` that isn't JSON Schema's, a warning. A
/// note's values against its types' fields (`FieldChecks`): each wrong value is an error (a needed
/// field with no value, or a Needed relationship row left empty, an issue of Validation's third level, `.incomplete`:
/// the shape stays valid and nothing shows on the board), and a type whose JSON refers to a type that is gone, or whose `$title`
/// titles nothing, carries a warning. What a type's change reaches is the rule over values' `affected:`, asked once
/// every service has the commit (`FieldChecks.affected(by:)`); what moves with no commit of the shapes' own (a
/// relationship's verdict, the caret) the service tells Validation of (`ValidationEngine.recheck`). The rule over values
/// has a `touches:`, the same reach for writes that have not committed (`FieldChecks.touched(by:reading:)`), which a
/// run asks to say what it breaks on shapes it did not write.
/// After `TypesPlugin` and `ValidationPlugin`.
public struct TypeValidationPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "type-validation" }

    public func register(into registrar: inout PluginRegistrar) {
        // Only the schema's text matters, never where the shape is: a drag of a thousand notes
        // checks none of them again for this.
        registrar.forShapes(holding: TypeSchemaProperty.self) { typeKinds in
            typeKinds.validate(ignoringMoves: true) { shape, _ in SchemaReadings.reading(of: shape)?.issues ?? [] }
        }
        // The values of a note are a function of the values and the file's types, never of where it is.
        // Without an editor (draw's check, before it commits) it asks the service through the reading its shapes
        // have, so a type the run writes is read as it stands; with none, it says nothing.
        // What writes that have not committed reach (a run's): the instances of a type they change, the notes at the ends
        // of a relationship they draw or delete, the notes of an end type whose rows they change (`RunTouches`). What a
        // commit reached that it didn't change (a type's instances and the types that refer to it, the arrows that quote a
        // renamed note) is the check's to say, asked once every service has the commit (`FieldChecks.affected(by:)`).
        registrar.forShapes(holding: IsAProperty.self) { typeable in
            typeable.validate(ignoringMoves: true, affected: { changes, editor in
                editor.fieldChecks?.affected(by: changes) ?? []
            }, touches: { changes, shapes in
                shapes.reading.map { FieldChecks.touched(by: changes, reading: $0) } ?? []
            }) { shape, context in
                let check: FieldCheck
                if let checks = context.service(FieldChecks.self) {
                    var shown = checks.check(of: shape)
                    // The field with the caret is left out of what shows, as a value half typed is no error; what a shape
                    // still needs shows nowhere, so it is said whether or not the caret is in that field.
                    if checks.typing?.shape == shape.id {
                        let left = checks.fullCheck(of: shape).problems.filter { $0.kind == .needed && !shown.problems.contains($0) }
                        if !left.isEmpty { shown = FieldCheck(problems: shown.problems + left) }
                    }
                    check = shown
                } else if let reading = context.reading, let checks = reading.service(FieldChecks.self) {
                    check = checks.check(of: shape, reading: reading)
                } else {
                    return []
                }
                guard !check.problems.isEmpty else { return [] }
                // A needed value left empty is the third level: the shape is valid and flagged by nothing, and a query's
                // `:incomplete` and a run's warning of a shape it did not write read it.
                return check.problems.map { problem in
                    switch problem.kind {
                    case .wrong: ValidationIssue.error(problem.message, field: problem.placeName, path: problem.pointer)
                    case .warning: ValidationIssue.warning(problem.message, field: problem.placeName, path: problem.pointer)
                    case .needed: ValidationIssue.incomplete(problem.message, field: problem.placeName, path: problem.pointer)
                    }
                }
            }
        }
        // A type's own warnings, not the notes' of either: a type it refers to that is gone, and a `$title` that
        // titles nothing (only the type that wrote it: an Employee inheriting Person's says nothing).
        // Without an editor (a run's check) it says the same over the reading; the types a run's writes reach are named
        // by the rule above (a type that refers to one written, or builds on one).
        registrar.forShapes(holding: TypeSchemaProperty.self) { typeKinds in
            typeKinds.validate(ignoringMoves: true) { shape, context in
                guard shape[TypeSchemaProperty.self] != nil else { return [] }
                guard let checks = context.service(FieldChecks.self) else {
                    guard let reading = context.reading, let checks = reading.service(FieldChecks.self) else { return [] }
                    return checks.typeWarnings(of: shape, reading: reading).map { ValidationIssue.warning($0, field: "schema") }
                }
                var issues = checks.goneReferences(of: shape.id).map { ValidationIssue.warning(FieldCheckWords.refersToGone($0), field: "schema") }
                if let book = context.service(FieldBook.self),
                   let problem = TitleSource.problem(book.fields(types: [shape.id]), writtenBy: shape.id) {
                    issues.append(.warning(FieldCheckWords.title(problem), field: "schema"))
                }
                return issues
            }
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
        // Whether a shape fills its fields from its words, at the foot of its Types tab (and a type's, of its Schema tab).
        registerAutofillPanel(into: &registrar)
        // Needed and Only one, for an arrow that is an end.
        registerEndRulePanel(into: &registrar)
    }
}
