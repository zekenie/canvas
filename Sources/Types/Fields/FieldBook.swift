import Canvas
import Mentions
import Titles
import Topology

/// The fields a list of types gives a shape, resolved once for each distinct list and kept until a type
/// changes (`TypeIndex.chainRevision`): ten thousand notes with one list resolve it once. What a row is
/// drawn from and a value is checked against: `Chain.resolve` over the file's types. It reads types
/// through the index and knows no kind. A list is resolved when first asked, never eagerly, so a type's
/// edit costs the lists asked after it, not all of them.
@MainActor
public final class FieldBook {
    private weak var editor: CanvasEditor?
    private var book: ChainBook?
    private var kept: [[ShapeID]: Resolved] = [:]
    private var keptTitleSources: [[ShapeID]: TitleSource?] = [:]
    private var stamp = -1
    /// The levels of types a transaction under way wrote (by id and the text), so a paste of a thousand
    /// instances parses their type once; shared by every reading of the file (`ReadingTypes`).
    private var readLevels: [ShapeID: (text: String, level: ChainLevel)] = [:]
    /// The file's types' members, kept until the chain moves (`fileFields`).
    var fileFieldsKept: (stamp: Int, revision: Int, fields: FileFields)?
    var editorForFileFields: CanvasEditor? { scope == nil ? editor : nil }
    /// What a book over a reading reads types through, and the editor's book it shares levels with; nil
    /// for the editor's own.
    private let scope: (types: ReadingTypes, shared: FieldBook)?

    #if DEBUG
    /// How many lists have been resolved (debug builds only): tests hold it to one for each distinct list.
    public private(set) var resolutionsMade = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        scope = nil
    }

    /// A book over the file as a reading has it (a transaction's, a run's), for a check that must answer
    /// as the file will stand: it resolves each list over `ReadingTypes` and keeps it for the book's own
    /// life, since nothing it reads moves while the reading is held. It shares `shared`'s levels and
    /// reads nothing of the committed index.
    init(reading: LayoutReading, record: AnyShapeRecord?, shared: FieldBook) {
        let root = shared.scope?.shared ?? shared
        editor = root.editor
        scope = (ReadingTypes(book: root, reading: reading, record: record), root)
    }

    /// What `types` (a shape's own `is` list, in the order added) give it: the one resolution for that
    /// list, kept until `revision` moves. The same types in another order are another list, as the order
    /// decides who wins. It answers from the committed index (`editor.types`): a type written in the
    /// same transaction as its instance is not in it until the commit, so the instance has no rows then.
    public func fields(types: [ShapeID]) -> Resolved {
        if let scope {
            if let found = kept[types] { return found }
            #if DEBUG
            resolutionsMade += 1
            #endif
            let resolved = Chain.resolve(types: types, in: scope.types)
            kept[types] = resolved
            return resolved
        }
        guard let index = editor?.types else { return Resolved() }
        let book = self.book ?? ChainBook(index: index)
        self.book = book
        if stamp != index.chainRevision {
            kept = [:]
            keptTitleSources = [:]
            book.prune()
            stamp = index.chainRevision
        }
        if let found = kept[types] { return found }
        #if DEBUG
        resolutionsMade += 1
        #endif
        let resolved = Chain.resolve(types: types, in: book.catalog)
        kept[types] = resolved
        return resolved
    }

    /// The same for a record: its `is` list; a type's own note asks `fields(types: [itsID])`.
    public func fields(of record: AnyShapeRecord) -> Resolved {
        fields(types: record[IsAProperty.self]?.map(\.shape) ?? [])
    }

    /// The field that titles a shape of these types: `TitleSource.of` the list's resolution, kept with it.
    public func titleSource(types: [ShapeID]) -> TitleSource? {
        let resolved = fields(types: types)
        if let found = keptTitleSources[types] { return found }
        let source = TitleSource.of(resolved)
        keptTitleSources[types] = .some(source)
        return source
    }

    /// The same for a record's `is` list; nil for a type's own note (whose `is` list is the types it builds
    /// on, which are not its own) and for a shape with no types.
    public func titleSource(of record: AnyShapeRecord) -> TitleSource? {
        guard record[TypeSchemaProperty.self] == nil, let types = record[IsAProperty.self]?.map(\.shape), !types.isEmpty else { return nil }
        return titleSource(types: types)
    }

    /// The field the record's title was copied from: its title is that field's value as shown. Nil for a title
    /// set by hand, for a type's own note and for a note whose types title from nothing. `title` is the note's
    /// title as the pill has it (folded).
    public func fieldTitled(_ record: AnyShapeRecord, title: String) -> TitleSource? {
        guard let source = titleSource(of: record),
              FieldTitling.shown(record[FieldValuesProperty.self] ?? FieldValues(), source) == title else { return nil }
        return source
    }

    /// The fields a group holds, in order: its `properties` (the group's own `required`), or, for a field
    /// that is a `$ref` to a type, that type's fields (`fields(types: [type]).fields`, the chain's,
    /// inherited first; with `properties` beside it, the type's only, the rest still checked). Empty for
    /// anything else, a reference to a part of a type (`urn:uuid:…#/…`) and a type
    /// that is gone.
    public func members(of field: Resolved.Field) -> [Resolved.Field] {
        let schema = field.field.schema
        if let ref = schema["$ref"]?.string {
            guard let target = SchemaReferences.target(of: ref), target.fragment.isEmpty else { return [] }
            return fields(types: [target.shape]).fields
        }
        let required = Set((schema["required"]?.elements ?? []).compactMap(\.string))
        return (schema["properties"]?.members ?? []).map { member in
            inner(ChainField(name: member.key, schema: member.value, isRequired: required.contains(member.key), holdsItself: field.field.holdsItself), of: field)
        }
    }

    /// The members of `written`, a value a script wrote for a note's values (a JSON object by field key), that
    /// no field of `types` names, in key order at each object, each with the row it sits under: a key no field
    /// has is one and is not looked into; a member written `null` (it clears) never is. It looks into a group,
    /// another type's fields and a list's items, and no further: not into pairs, `Other`, a plain value, an
    /// either, nor a reference to a type that is gone or to a part of one (whose members no field
    /// of the book names, so every one would read as unnamed).
    public func unnamed(in written: JSONObject, types: [ShapeID]) -> [UnnamedMember] {
        let resolved = fields(types: types)
        var found: [UnnamedMember] = []
        for key in written.keys.sorted() {
            guard let value = written[key], value != .null else { continue }
            if let field = resolved.fields.first(where: { $0.field.name == key }) {
                walk(value, in: field, at: FieldPath().key(key), into: &found)
            } else {
                found.append(UnnamedMember(path: FieldPath().key(key), within: nil))
            }
        }
        return found
    }

    /// `row` is the name of the row the value sits under when the field is a list's item (which has none).
    private func walk(_ value: JSONValue, in field: Resolved.Field, row: String? = nil, at path: FieldPath, into found: inout [UnnamedMember]) {
        switch kind(of: field) {
        case .group, .typeFields:
            guard case .object(let written) = value else { return }
            let named = members(of: field)
            if named.isEmpty, field.field.schema["$ref"]?.string != nil { return }
            for key in written.keys.sorted() {
                guard let member = written[key], member != .null else { continue }
                if let inner = named.first(where: { $0.field.name == key }) {
                    walk(member, in: inner, at: path.key(key), into: &found)
                } else {
                    found.append(UnnamedMember(path: path.key(key), within: row ?? FieldName.words(of: field.field)))
                }
            }
        case .listOfGroups, .listOfTypeFields:
            guard case .array(let items) = value, let itemField = item(of: field) else { return }
            let name = FieldName.words(of: field.field)
            for (number, item) in items.enumerated() { walk(item, in: itemField, row: name, at: path.index(number), into: &found) }
        default:
            return
        }
    }

    /// What a list holds: the field for its `items`, named "" ; nil for no `items`, and for a list of tuples.
    public func item(of field: Resolved.Field) -> Resolved.Field? {
        guard let items = field.field.schema["items"], items.isObject else { return nil }
        return inner(ChainField(name: "", schema: items, holdsItself: field.field.holdsItself), of: field)
    }

    /// The level the file's type `id` is read as, as the chain reads it: the schema read once by its text,
    /// and for text that is half typed the shape's last text that was a JSON object. Nil for a shape that
    /// is no type. What a layout under way reads for a type the transaction has not changed.
    func level(of id: ShapeID) -> ChainLevel? {
        if let scope { return scope.types.node(id)?.level }
        guard let index = editor?.types else { return nil }
        let book = self.book ?? ChainBook(index: index)
        self.book = book
        return book.node(id)?.level
    }

    /// The level of the type `id` as a reading holds it, from the text it holds: the book's own while that is
    /// the committed text, else read from the text, once (a type whose JSON is broken mid-edit keeps the
    /// rows of its last good JSON, as after the commit).
    func level(readFrom text: String, of id: ShapeID) -> ChainLevel {
        if let shared = scope?.shared { return shared.level(readFrom: text, of: id) }
        if editor?.types?.schemaText(of: id) == text, let kept = level(of: id) { return kept }
        if let known = readLevels[id], known.text == text { return known.level }
        let level = ChainLevel(schema: text) ?? ChainLevel()
        if readLevels.count >= Self.readLevelsCapacity { readLevels.removeAll() }
        readLevels[id] = (text, level)
        return level
    }

    private static let readLevelsCapacity = 256

    /// A type's name as this book reads it: the index's for the editor's, else the title the reading's
    /// shape has (Titles', as the index reads it); nil for an untitled type and a shape that isn't one.
    func name(of id: ShapeID) -> String? {
        guard let scope else { return editor?.types?.name(of: id) }
        guard let shape = scope.types.shape(id), shape[TypeSchemaProperty.self] != nil else { return nil }
        return scope.types.reading.registry.title(of: shape)
    }

    /// A type's schema text as this book reads it; nil for a shape that isn't a type.
    func schemaText(of id: ShapeID) -> String? {
        guard let scope else { return editor?.types?.schemaText(of: id) }
        return scope.types.shape(id)?[TypeSchemaProperty.self]?.text
    }

    /// Moves when a resolution may differ: a type comes, goes, changes its schema or its own types. Fixed
    /// for a book over a reading.
    public var revision: Int { scope == nil ? editor?.types?.chainRevision ?? 0 : 0 }

    private func inner(_ field: ChainField, of outer: Resolved.Field) -> Resolved.Field {
        Resolved.Field(field: field, source: outer.source, introducedBy: outer.introducedBy)
    }
}

/// A member a script wrote that no field of the shape's types names.
public struct UnnamedMember: Sendable, Equatable {
    public var path: FieldPath
    /// The row it sits under, as the row names it; nil at the top.
    public var within: String?

    public init(path: FieldPath, within: String?) {
        self.path = path
        self.within = within
    }
}

extension FieldBook: EditorService {}

extension CanvasEditor {
    /// The fields of a shape's types (`FieldBook`); nil without TypesPlugin.
    public var fieldBook: FieldBook? { service(FieldBook.self) }
}
