import Canvas
import SlashCommands

/// Making a shape an instance of a type, and not: the one way `is` changes, whoever asks (`/is-a`,
/// a chip's menu, the panel's Types), so what a later slice settles when a type is given or taken
/// back is settled in these, inside the person's own step.
extension CanvasEditor {
    /// Makes `shape` an instance of `type`, in one step ("Add Type"): the type goes at the end of its
    /// list, where a later one wins. Nothing for a type it is already, one `TypeIndex.admits` refuses
    /// (itself, what is it in turn, what isn't a type), or a shape that isn't there or can't be an
    /// instance; a read-only shape is refused by the core, and shakes.
    public func addTypeLink(_ type: ShapeID, to shape: ShapeID) {
        guard let types, types.admits(type, for: shape), let record = self.shape(inFile: shape),
              registry.isTypeable(record.kind) else { return }
        transact(TypesStyle.addType) { transaction in
            transaction.update(inFile: shape) { record in
                var list = record[IsAProperty.self] ?? []
                list.append(TypeLink(type))
                record[IsAProperty.self] = list
            }
        }
    }

    /// Makes `shape` no longer an instance of `type`, in one step ("Remove Type"): the entry goes from
    /// its list, and the property with the last. Nothing for a shape that isn't one; a read-only
    /// shape is refused by the core, and shakes.
    public func removeTypeLink(_ type: ShapeID, from shape: ShapeID) {
        guard self.shape(inFile: shape)?[IsAProperty.self]?.contains(TypeLink(type)) == true else { return }
        transact(TypesStyle.removeType) { transaction in
            transaction.update(inFile: shape) { record in
                record[IsAProperty.self] = (record[IsAProperty.self] ?? []).filter { $0 != TypeLink(type) }
            }
        }
    }
}

/// `/is-a @Person`: typed on a line of a shape's words, one shape, a type, appends it to the shape's
/// types. The picker lists the types it admits (`TypeIndex.admits`): of the kinds that can be types,
/// across the file, never the shape itself, a type it is already, one that is it in turn, or a pill.
/// On any kind that holds `is`: a note, and an arrow in its label.
@MainActor
func registerIsACommand(into registrar: inout PluginRegistrar) {
    registrar.slashCommandsForEveryShape(where: { $0.holds(IsAProperty.self) }) {
        SlashCommand("is-a", argument: TypesStyle.isAArgument,
                     kinds: { registry in Set(registry.kinds.filter { registry.canBeType($0) }) },
                     shapes: { target, owner, editor in editor.types?.admits(target, for: owner) ?? false },
                     step: TypesStyle.addType) { id, arguments, editor in
            // Asked again: the line was run as it was found.
            guard let type = arguments.shapes.first else { return }
            editor.addTypeLink(type, to: id)
        }
    }
}
