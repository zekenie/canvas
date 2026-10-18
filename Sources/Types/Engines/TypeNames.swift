import Canvas
import Draw

/// Types in draw, in Types: `is: "Employee card"` on a shape, and on an edge
/// (`edge "A" -> "B" is: "Friendship"`, an edge's attributes being the arrow's), names the types a
/// shape is by their titles, as the rest of a script names shapes (`context.shape(called:)`: a
/// shape the script draws, else the board it draws on, the window's, or elsewhere in the file), and
/// the shape keeps their ids (`TypeLink.mediaType`, a string of an entry). What a script may name
/// there is `TypeIndex.canBeNamed`, the one function over a record and the registry that says which
/// shapes are types (and, later, custom shapes); any other shape named is refused: `"Ann" is a
/// sticky-note, which isn't a type or a shape`. A quoted title for a list is a one-item list
/// (Draw's), several are JSON: `is: ["Person", "Employee card"]`. And `schema:` keeps the type's
/// `$color` when it says none.
public struct TypeNamesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "type-names" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.drawTextFormat(mediaType: TypeLink.mediaType, describes: "<Title> of a type or shape") { text, context throws(DrawError) in
            let registry = context.registry
            let found = try context.shape(called: text) { record, writing in
                TypeIndex.canBeNamed(record, registry: registry, writing: writing) ? nil : "which isn't a type or a shape"
            }
            // A shape isn't its own type (`/is-a` refuses it too).
            guard found.id != context.owner else {
                throw DrawError("\"\(text)\" can't be its own type", reason: "invalid_value", hint: "name another type")
            }
            // Nor one of the types of a type built on it, which would make a cycle: what `/is-a` refuses
            // (`TypeIndex.admits`), as far as the file says. A shape the script draws in the same run isn't in
            // the file yet, so a cycle between shapes of one script isn't checked (`reaches` is cycle-safe).
            if let owner = context.owner, let index = context.service(TypeIndex.self), index.graph.reaches(owner, from: found.id) {
                throw DrawError("\"\(text)\" is already built on this shape, which would make a cycle", reason: "invalid_value", hint: "name another type")
            }
            return found.id.description
        }
        // A schema written whole keeps the type's `$color` unless it says one, as the model's does
        // (`TypeColorDirective.carried`): a script run again says `unchanged`, and a color given to the
        // type since stays; `color: null` takes it away.
        registrar.drawValueWriter(for: TypeSchemaProperty.key, merge: { written, held in
            guard case .string(let text) = written else { return written }
            return .string(TypeColorDirective.carried(from: held?.stringValue, into: text))
        })
    }
}
