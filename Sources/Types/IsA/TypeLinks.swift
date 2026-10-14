import Canvas
import Draw
import SlashCommands
import Titles

/// What a shape is, and what makes a shape a type, in the calls every way in goes through (`/is-a`,
/// a chip's menu, the panel's Types, a shape's menu), so what a later slice settles when a type is
/// given or taken back is settled in these, inside the person's own step. The plural forms are one
/// transaction (so one step for a selection), the singular ones call them. Each leaves out a shape
/// that cannot take the change (not typeable, already what is asked) before it transacts, and
/// transacts nothing when none is left; a read-only shape stays in, so the core refuses it and it
/// shakes while the rest change in the one step.
extension CanvasEditor {
    /// Makes `shape` an instance of `type`, in one step ("Add Type"): the type goes at the end of its
    /// list, where a later one wins. Nothing for a type it is already, one `TypeIndex.admits` refuses
    /// (itself, what is it in turn, what isn't a type), or a shape that isn't there or can't be an
    /// instance; a read-only shape is refused by the core, and shakes.
    public func addTypeLink(_ type: ShapeID, to shape: ShapeID) { addTypeLink(type, to: [shape]) }

    /// The same for several shapes, in one step.
    public func addTypeLink(_ type: ShapeID, to shapes: [ShapeID]) {
        guard let types else { return }
        let taking = shapes.filter { shape in
            types.admits(type, for: shape) && (self.shape(inFile: shape).map { registry.isTypeable($0.kind) } ?? false)
        }
        guard !taking.isEmpty else { return }
        transact(TypesStyle.addType) { transaction in
            for shape in taking {
                transaction.update(inFile: shape) { record in
                    var list = record[IsAProperty.self] ?? []
                    list.append(TypeLink(type))
                    record[IsAProperty.self] = list
                    // A note with no title and a value already there is titled once, as the field titles it.
                    if TitleProperty.folded(record[TitleProperty.self]) == nil, record[TypeSchemaProperty.self] == nil,
                       registry.properties(for: record.kind).contains(TitleProperty.key),
                       let source = fieldBook?.titleSource(types: list.map(\.shape)),
                       let title = FieldTitling.firstTitle(values: record[FieldValuesProperty.self] ?? FieldValues(), source) {
                        record[TitleProperty.self] = title
                    }
                }
            }
        }
    }

    /// Makes `shape` no longer an instance of `type`, in one step ("Remove Type"): the entry goes from
    /// its list, and the property with the last. Nothing for a shape that isn't one; a read-only
    /// shape is refused by the core, and shakes.
    public func removeTypeLink(_ type: ShapeID, from shape: ShapeID) { removeTypeLink(type, from: [shape]) }

    /// The same for several shapes, in one step.
    public func removeTypeLink(_ type: ShapeID, from shapes: [ShapeID]) {
        let taking = shapes.filter { self.shape(inFile: $0)?[IsAProperty.self]?.contains(TypeLink(type)) == true }
        guard !taking.isEmpty else { return }
        transact(TypesStyle.removeType) { transaction in
            for shape in taking {
                transaction.update(inFile: shape) { record in
                    record[IsAProperty.self] = (record[IsAProperty.self] ?? []).filter { $0 != TypeLink(type) }
                }
            }
        }
    }

    /// Makes the shape a type, in one step ("Make Type", unless it's part of another). Its words are
    /// the schema when they are a JSON object (`TypeWordsSchema`), as written, and the sync then
    /// writes the words from the schema; else it gets the starter schema, an object with no fields,
    /// which its words are then ahead of (the sync asks the model for the schema they say once the
    /// person is done with them, as for an edit of them). It is not made public: a type is found by
    /// `/is-a` and by its title, and `/public` is the person's to say. Nothing for a shape that's
    /// already one, or whose kind can't be one; a read-only shape is refused by the core, and shakes.
    public func makeType(_ id: ShapeID) { makeTypes([id]) }

    /// The same for several shapes, in one step.
    public func makeTypes(_ ids: [ShapeID]) {
        var schemas: [(id: ShapeID, schema: String)] = []
        for id in ids {
            guard let record = document[id], record[TypeSchemaProperty.self] == nil, registry.canBeType(record.kind) else { continue }
            let words = registry.typeWords(of: record.kind)?.words(record)
            schemas.append((id, words.flatMap(TypeWordsSchema.schema(fromWords:)) ?? TypeSchemaProperty.starter))
        }
        guard !schemas.isEmpty else { return }
        transact(TypesStyle.makeType) { transaction in
            for (id, schema) in schemas {
                transaction.update(id) { $0[TypeSchemaProperty.self] = SchemaText(schema) }
            }
        }
    }

    /// Makes the shape a relationship type, in one step ("Make Relationship Type"): a plain note first becomes a
    /// type, as `makeType` makes one, and the type is marked. Nothing for a shape that is one already or whose kind
    /// cannot hold the mark; a read-only shape is refused by the core, and shakes.
    public func makeRelationshipType(_ id: ShapeID) { makeRelationshipTypes([id]) }

    /// The same for several shapes, in one step.
    public func makeRelationshipTypes(_ ids: [ShapeID]) {
        var taking: [(id: ShapeID, schema: String?)] = []
        for id in ids {
            guard let record = document[id], registry.canBeRelationshipType(record.kind) else { continue }
            if record[TypeSchemaProperty.self] == nil {
                guard registry.canBeType(record.kind) else { continue }
                let words = registry.typeWords(of: record.kind)?.words(record)
                taking.append((id, words.flatMap(TypeWordsSchema.schema(fromWords:)) ?? TypeSchemaProperty.starter))
            } else if record[RelationshipProperty.self] != true {
                taking.append((id, nil))
            }
        }
        guard !taking.isEmpty else { return }
        transact(TypesStyle.makeRelationshipType) { transaction in
            for (id, schema) in taking {
                transaction.update(id) { record in
                    if let schema { record[TypeSchemaProperty.self] = SchemaText(schema) }
                    record[RelationshipProperty.self] = true
                }
            }
        }
    }

    /// Takes the mark off a relationship type, in one step ("Make Plain Type"): it is still a type, with its words,
    /// rows and instances. Nothing for a shape that isn't marked; a read-only shape is refused by the core, and shakes.
    public func makePlainType(_ id: ShapeID) { makePlainTypes([id]) }

    /// The same for several shapes, in one step.
    public func makePlainTypes(_ ids: [ShapeID]) {
        let taking = ids.filter { document[$0]?[RelationshipProperty.self] == true }
        guard !taking.isEmpty else { return }
        transact(TypesStyle.makePlainType) { transaction in
            for id in taking { transaction.update(id) { $0[RelationshipProperty.self] = nil } }
        }
    }

    /// Gives each arrow the relationship type, in the place of the one it has, in one step ("Add Type"): the entry
    /// goes and the new one comes, so an arrow is of one relationship type at a time. The writer for outside a
    /// press (a port's release gives its one type by `addTypeLink` alone, inside its own step). Nothing for a
    /// shape that is no arrow of a relating kind; `addTypeLink` is still the one way a type is given.
    public func setRelationshipType(_ type: ShapeID, of connections: [ShapeID]) {
        let taking = connections.filter { id in shape(inFile: id).map { registry.relates($0.kind) } ?? false }
        guard !taking.isEmpty else { return }
        undoHistory.group(TypesStyle.addType) {
            let marked = types?.graph.relationshipTypes ?? []
            for id in taking {
                for old in shape(inFile: id)?[IsAProperty.self]?.map(\.shape) ?? [] where old != type && marked.contains(old) { removeTypeLink(old, from: id) }
                addTypeLink(type, to: id)
            }
        }
    }

    /// Gives the type the way a person asks for it, from `/is-a` and Is a ▸: an arrow given a relationship type
    /// has it replace the one it has; any other shape has the type added. One step, "Add Type".
    func giveType(_ type: ShapeID, to ids: [ShapeID]) {
        // The role partition: an arrow is given relationship types only, and no other shape is.
        let isRelationship = types?.graph.relationshipTypes.contains(type) == true
        let arrows = ids.filter { id in shape(inFile: id).map { registry.relates($0.kind) } ?? false }
        let replacing = isRelationship ? arrows : []
        let rest = isRelationship ? [] : ids.filter { !arrows.contains($0) }
        undoHistory.group(TypesStyle.addType) {
            if !replacing.isEmpty { setRelationshipType(type, of: replacing) }
            if !rest.isEmpty { addTypeLink(type, to: rest) }
        }
    }

    /// Makes the shape no longer a type, in one step ("Remove Type"): its schema goes, and its words
    /// stay, as does whether it's public. Undo brings the schema back. Nothing for a shape that isn't
    /// one; a read-only shape is refused by the core, and shakes.
    public func removeType(_ id: ShapeID) { removeTypes([id]) }

    /// The same for several shapes, in one step.
    public func removeTypes(_ ids: [ShapeID]) {
        let taking = ids.filter { document[$0]?[TypeSchemaProperty.self] != nil }
        guard !taking.isEmpty else { return }
        transact(TypesStyle.removeType) { transaction in
            for id in taking {
                transaction.update(id) {
                    $0[TypeSchemaProperty.self] = nil
                    $0[RelationshipProperty.self] = nil
                }
            }
        }
    }
}

extension CanvasEditor {
    /// A new type titled `name`, put down beside `owner` as `/move-near` puts a shape beside another
    /// (`Surroundings.near`), with the starter schema and no words, and `owner` made an instance of
    /// it: one step, "New Type", which stays open while the new note is edited, as a placed note's
    /// does. For an owner that is an arrow (a kind that relates) it is a relationship type, with no ends,
    /// in the step "New Relationship Type", and it replaces the relationship type the arrow had. Nil, with nothing changed, when nothing could be put down: `owner` is not on the board
    /// shown, no kind can be a type or has a tool to place it, `owner` has no box, or the board or
    /// the container it lands in is read-only (the core refuses it, and it shakes).
    @discardableResult
    public func newType(named name: String, besides owner: ShapeID) -> ShapeID? {
        guard file.board(containing: owner) == board, let kind = newTypeKind(for: owner), let base = registry.placement(for: kind) else { return nil }
        // Told which shape it made by the transform each record goes through.
        final class Made { var id: ShapeID? }
        let made = Made()
        let marks = ownerRelates(owner) && registry.canBeRelationshipType(kind)
        var placement = base.setting(TitleProperty.self, to: name)
            .setting(TypeSchemaProperty.self, to: SchemaText(TypeSchemaProperty.starter))
        if marks { placement = placement.setting(RelationshipProperty.self, to: true) }
        placement = placement.mapping { record in made.id = record.id; return record }
        guard let landing = Surroundings(on: board, moving: placement.size, in: self)?.near(owner) else { return nil }
        return undoHistory.group(marks ? TypesStyle.newRelationshipType : TypesStyle.newType) {
            place(placement, in: landing.rect)
            guard let id = made.id, document[id] != nil else { return nil }
            giveType(id, to: [owner])
            return id
        }
    }

    /// Whether the owner is an arrow of a kind that relates, whose new type is a relationship type.
    private func ownerRelates(_ owner: ShapeID) -> Bool { document[owner].map { registry.relates($0.kind) } ?? false }

    /// The kind a new type beside `owner` is: the owner's, if it can be a type; for an owner that relates, the first
    /// kind that can hold the mark as well; else the first that can be a type.
    func newTypeKind(for owner: ShapeID) -> ShapeKind? {
        func usable(_ kind: ShapeKind) -> Bool { registry.canBeType(kind) && registry.placement(for: kind) != nil }
        if let record = document[owner], registry.canBeType(record.kind) { return record.kind }
        if ownerRelates(owner), let kind = registry.kinds.first(where: { usable($0) && registry.canBeRelationshipType($0) }) { return kind }
        return registry.kinds.first(where: usable)
    }
}

/// `/is-a`: typed on a line of a shape's words, lists `Type` (while the shape can be one and isn't), `Relationship
/// Type` (while it can be one and isn't) and the types it may be (`editor.typeChoices(for:)`: of the kinds that can
/// be types, across the file, never the shape itself, a type it is already, one that is it in turn, or a pill; an
/// arrow is offered relationship types, any other shape plain types), and a pick runs at once: `Type` makes the
/// shape one ("Make Type"), `Relationship Type` one that relates ("Make Relationship Type"), a type adds it to the
/// shape's types ("Add Type"; an arrow's relationship type is replaced). On any kind that holds `is`: a note, and an
/// arrow in its label.
@MainActor
func registerIsACommand(into registrar: inout PluginRegistrar) {
    registrar.slashCommandsForEveryShape(where: { $0.holds(IsAProperty.self) }) {
        SlashCommand("is-a", argument: TypesStyle.isAArgument,
                     choices: { owner, editor in TypeChoices.rows(for: owner, in: editor) },
                     otherwise: { typed, owner, editor in TypeChoices.newRow(typed: typed, owner: owner, editor: editor) },
                     step: TypesStyle.addType) { owner, choice, editor in
            // Asked again: the line was run as it was found.
            switch TypeChoice(choice) {
            case .type: editor.makeType(owner)
            case .relationshipType: editor.makeRelationshipType(owner)
            case .existing(let type): editor.giveType(type, to: [owner])
            case .new(let name): editor.newType(named: name, besides: owner)
            case .none: break
            }
        }
    }
}
