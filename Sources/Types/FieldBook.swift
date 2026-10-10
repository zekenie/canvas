import Canvas

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
    private var stamp = -1

    #if DEBUG
    /// How many lists have been resolved (debug builds only): tests hold it to one for each distinct list.
    public private(set) var resolutionsMade = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    /// What `types` (a shape's own `is` list, in the order added) give it: the one resolution for that
    /// list, kept until `revision` moves. The same types in another order are another list, as the order
    /// decides who wins.
    public func fields(types: [ShapeID]) -> Resolved {
        guard let index = editor?.types else { return Resolved() }
        let book = self.book ?? ChainBook(index: index)
        self.book = book
        if stamp != index.chainRevision {
            kept = [:]
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

    /// The fields a group holds, in order: its `properties` (the group's own `required`), or, for a field
    /// that is a `$ref` to a type, that type's fields (`fields(types: [type]).fields`, the chain's,
    /// inherited first; with `properties` beside it, the type's only, the rest still checked). Empty for
    /// anything else, a pointer included, a reference to a part of a type (`urn:uuid:…#/…`) and a type
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

    /// What a list holds: the field for its `items`, named "" ; nil for no `items`, and for a list of tuples.
    public func item(of field: Resolved.Field) -> Resolved.Field? {
        guard let items = field.field.schema["items"], items.isObject else { return nil }
        return inner(ChainField(name: "", schema: items, holdsItself: field.field.holdsItself), of: field)
    }

    /// Moves when a resolution may differ: a type comes, goes, changes its schema or its own types.
    public var revision: Int { editor?.types?.chainRevision ?? 0 }

    private func inner(_ field: ChainField, of outer: Resolved.Field) -> Resolved.Field {
        Resolved.Field(field: field, source: outer.source, introducedBy: outer.introducedBy)
    }
}

extension FieldBook: EditorService {
    /// It keeps nothing per shape or per board, so a switch needs no change set (the default works one out): a
    /// file put in place moves the index's stamp, which is all it follows.
    public func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {}
}

extension CanvasEditor {
    /// The fields of a shape's types (`FieldBook`); nil without TypesPlugin.
    public var fieldBook: FieldBook? { service(FieldBook.self) }
}
