import Canvas
import SlashCommands

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
                transaction.update(id) { $0[TypeSchemaProperty.self] = nil }
            }
        }
    }
}

/// `/is-a`: typed on a line of a shape's words, lists `Type` (while the shape can be one and isn't)
/// and the types it may be (`TypeIndex.choices(for:)`: of the kinds that can be types, across the
/// file, never the shape itself, a type it is already, one that is it in turn, or a pill), and a
/// pick runs at once: `Type` makes the shape one ("Make Type"), a type adds it to the shape's types
/// ("Add Type"). On any kind that holds `is`: a note, and an arrow in its label.
@MainActor
func registerIsACommand(into registrar: inout PluginRegistrar) {
    registrar.slashCommandsForEveryShape(where: { $0.holds(IsAProperty.self) }) {
        SlashCommand("is-a", argument: TypesStyle.isAArgument,
                     choices: { owner, editor in TypeChoices.rows(for: owner, in: editor) },
                     step: TypesStyle.addType) { owner, choice, editor in
            // Asked again: the line was run as it was found.
            switch TypeChoice(choice) {
            case .type: editor.makeType(owner)
            case .existing(let type): editor.addTypeLink(type, to: owner)
            case .none: break
            }
        }
    }
}
