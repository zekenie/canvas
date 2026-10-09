import Automation
import Canvas
import Publishing
import Types

/// Types in draw, in DrawLexicon: `is: "Employee card"` on a shape, and on an edge
/// (`edge "A" -> "B" is: "Friendship"`, an edge's attributes being the arrow's), names the types a
/// shape is by their titles, as the rest of a script names shapes (`context.shape(called:)`: a
/// shape the script draws, else the board it draws on, the window's, or elsewhere in the file), and
/// the shape keeps their ids (`TypeLink.mediaType`, a string of an entry). What a script may name
/// there is `TypeIndex.canBeNamed`, the one function over a record and the registry that says which
/// shapes are types (and, later, custom shapes); any other shape named is refused: `"Ann" is a
/// sticky-note, which isn't a type or a shape`. A quoted title for a list is a one-item list
/// (Automation's), several are JSON: `is: ["Person", "Employee card"]`.
///
/// And a shape a script gives a schema, a note made a type, is public in the same step, as `/type`
/// makes one (Types' `makeType`): a type starts public, so what stands for a type elsewhere can;
/// `public: false` beside it is the script's own say, and a shape that was a type already keeps
/// whether it's public.
public struct TypeNamesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "type-names" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.drawTextFormat(mediaType: TypeLink.mediaType, describes: "<Title> of a type or shape") { text, context throws(AutomationError) in
            let registry = context.registry
            let found = try context.shape(called: text) { record, writing in
                TypeIndex.canBeNamed(record, registry: registry, writing: writing) ? nil : "which isn't a type or a shape"
            }
            return found.id.description
        }
        registrar.drawImplies { kind, before, settings, registry in
            guard settings[TypeSchemaProperty.key.rawValue] != nil, before?[TypeSchemaProperty.self] == nil,
                  registry.properties(for: kind).contains(PublicProperty.key) else { return [:] }
            return [PublicProperty.key.rawValue: true]
        }
    }
}
