import Canvas
import Foundation
import Queries
import Topology
import Types

/// Types in queries, in QueryLexicon: `:is-a(S)` is a shape that is a shape S matches, however far:
/// through the types a shape lists (`is`) and the types of those,
/// breadth first and cycle-safe (reachability: the order does not matter to `:is-a`). So `:is-a("Person")` finds
/// Ann, a card of Employee card, which is a Person. It is `:edge-to(S, is-a)` that stays direct, one
/// hop. The word is the one `.Name` is refused toward (`namesTypes`: the hint reads `:is-a("Name")`).
/// And a type read where a shape lists its types (`[is~="Person"]`, a row's `is`) reads as its
/// title, never its id.
///
/// `:incomplete` is a shape with a field its types need, left empty (`FieldChecks.fullCheck(of:)`, the
/// check of its values against the fields of its types, whatever else is wrong with them, on any board of
/// the file): not an error, so a shape that is also `:invalid` matches both. A needed yes or no never counts.
///
/// What each reads (`QueryReads`): the relation and the text format the file. The relation is answered from
/// a fact of the file (`TypeFacts`, `TypeIndex.graph`, a value the index keeps by each commit, so taking it
/// up is O(1) and the answer is worked out off the main actor); the text format reads the names in it.
/// `:incomplete` the editor: the check is the main actor's (the field book), asked in slices of only the
/// shapes that have types.
public struct TypeQueriesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "type-queries" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.queryRelation(IsAEdge.id.rawValue, "it is, however far, a type S matches: its types and theirs",
                                example: #":is-a("Person")"#, reads: .file, transitive: true, namesTypes: true,
                                prepare: { $0.fact(TypeFacts.self).graph },
                                seeds: { $0.sources },
                                related: { shape, graph in graph.parents(of: shape) })
        registrar.queryTextFormat(mediaType: TypeLink.mediaType, describes: "types read as their titles", reads: .file,
                                  prepare: { $0.fact(TypeFacts.self).graph.names },
                                  read: { stored, names in
                                      // A type that is gone, or has no title, stays the id it is.
                                      UUID(uuidString: stored).flatMap { names[ShapeID($0)] } ?? stored
                                  })
        registrar.queryPseudoClass("incomplete", "it has a field its types need, left empty", example: #":is-a("Order"):incomplete"#,
                                   prepare: { $0.editor.types?.graph ?? TypeGraph() },
                                   seeds: { $0.sources },
                                   matches: { _, _ in .onMain },
                                   onMain: { record, _, _, context in context.editor.fieldChecks?.fullCheck(of: record).isIncomplete ?? false })
    }
}

/// The file's types as a query takes them up: `TypeIndex.graph`, a function of the records alone.
struct TypeFacts: QueryFileFact {
    let graph: TypeGraph

    static func current(in editor: CanvasEditor) -> TypeFacts {
        TypeFacts(graph: editor.types?.graph ?? TypeGraph())
    }
}
