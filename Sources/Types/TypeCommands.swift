import Canvas
import Publishing
import SlashCommands

/// What makes a shape a type, and what makes it one no longer: `/type`, typed on a line of its words
/// (no argument), on a shape of a kind that can be one (`canBeType()`) that isn't one yet; and
/// Remove Type, which takes its schema away and leaves its words.
@MainActor
func registerTypeCommands(into registrar: inout PluginRegistrar) {
    // A read-only shape's text can't be edited, so it's never offered there.
    registrar.slashCommandsForEveryShape(where: { $0.holds(TypeSchemaProperty.self) }) {
        SlashCommand("type", when: { $0[TypeSchemaProperty.self] == nil }, step: TypesStyle.makeType) { id, _, editor in editor.makeType(id) }
    }
}

extension CanvasEditor {
    /// Makes the shape a type, in one step ("Make Type", unless it's part of another): gives it the
    /// starter schema, an object with no fields, which its words are then ahead of (the sync asks the
    /// model for the schema they say once the person is done with them, as for an edit of them), and
    /// makes it public, so what stands for a type elsewhere can (Publishing's `public`: the person
    /// can make it private after). Nothing for a shape that's already one, or whose kind can't be
    /// one; a read-only shape is refused by the core, and shakes.
    public func makeType(_ id: ShapeID) {
        guard let record = document[id], record[TypeSchemaProperty.self] == nil, registry.canBeType(record.kind) else { return }
        let holdsPublic = registry.properties(for: record.kind).contains(PublicProperty.key)
        transact(TypesStyle.makeType) { transaction in
            transaction.update(id) { shape in
                shape[TypeSchemaProperty.self] = SchemaText(TypeSchemaProperty.starter)
                if holdsPublic { shape[PublicProperty.self] = true }
            }
        }
    }

    /// Makes the shape no longer a type, in one step ("Remove Type"): its schema goes, and its words
    /// stay, as does whether it's public. Undo brings the schema back. Nothing for a shape that isn't
    /// one; a read-only shape is refused by the core, and shakes.
    public func removeType(_ id: ShapeID) {
        guard document[id]?[TypeSchemaProperty.self] != nil else { return }
        transact(TypesStyle.removeType) { transaction in
            transaction.update(id) { $0[TypeSchemaProperty.self] = nil }
        }
    }
}
