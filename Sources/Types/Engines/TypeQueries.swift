import Canvas
import Foundation
import Queries
import Topology

/// Types in queries, in Types: `:is-a(S)` is a shape that is a shape S matches, however far:
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
/// A path into the values (`[fieldValues.stauts="x"]`) that names a member no type of the file has is
/// answered with a warning, `unknown_field`: the query still runs, since a note may hold what a type no longer
/// has. Nothing is said while any note lists a type that is gone, whose fields are unknown (`FileFields`).
///
/// `--ask` is told the file's types and their fields under `<fields>` (`FileFields.text(for:)`, bounded, a line a
/// type: keys and kinds, never a note's values).
///
/// What each reads (`QueryReads`): the relation and the text format the file. The relation is answered from
/// a fact of the file (`TypeFacts`, `TypeIndex.graph`, a value the index keeps by each commit, so taking it
/// up is O(1) and the answer is worked out off the main actor); the text format reads the names in it.
/// `:incomplete` the editor: the check is the main actor's (the field book), asked in slices of only the
/// shapes that have types.
public struct TypeQueriesPlugin: ListedPlugin {
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
                                   onMain: { record, _, _, context in context.editor.fieldChecks?.fullCheck(of: record).isIncomplete ?? false },
                                   problems: { record, _, _, context in
                                       // What it needs, field by field: the same answer the word was given.
                                       (context.editor.fieldChecks?.fullCheck(of: record).problems ?? []).filter { $0.kind == .needed }.map { problem in
                                           ShapeProblem(field: problem.path.field, path: problem.path.isRoot ? nil : problem.path.pointer,
                                                        class: problem.kind.word, message: problem.message)
                                       }
                                   })
        // What `--ask` is told of the file's types: a line each, their fields' keys and kinds, never a value.
        registrar.queryAskFact(tag: "fields") { editor, question in editor.fileFields?.text(for: question) ?? "" }
        // A path into a note's values names a field no type has: a warning, and the query still answers.
        registrar.queryPathCheck(attribute: FieldValuesProperty.key.rawValue) { members, editor in
            editor.fileFields?.unknown(members).map { QueryPathUnknown(index: $0.index, known: $0.known) }
        }
    }
}

/// The file's types as a query takes them up: `TypeIndex.graph`, a function of the records alone.
struct TypeFacts: QueryFileFact {
    let graph: TypeGraph

    static func current(in editor: CanvasEditor) -> TypeFacts {
        TypeFacts(graph: editor.types?.graph ?? TypeGraph())
    }
}
