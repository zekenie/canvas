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
/// `:incomplete` is not here: it is Validation's (`ValidationQueriesPlugin`), a shape with an issue of Validation's third
/// level, and Types' rule over values says one for a field its types need, or a relationship row an end marks Needed,
/// left empty (`TypeValidationPlugin`: [types](types.md#checks)).
///
/// A path into the values (`[fieldValues.stauts="x"]`) that names a member no type of the file has is
/// answered with a warning, `unknown_field`: the query still runs, since a note may hold what a type no longer
/// has. Nothing is said while any note lists a type that is gone, whose fields are unknown (`FileFields`).
///
/// `--ask` is told the file's types and their fields under `<fields>` (`FileFields.text(for:)`, bounded, a line a
/// type: keys and kinds, never a note's values), and which shapes are of each under `<instances>`
/// (`FileFields.instancesText(for:)`: their titles, a line a type), so a note of no type is told apart from one that is.
///
/// What each reads (`QueryReads`): the relation and the text format the file. The relation is answered from
/// a fact of the file (`TypeFacts`, `TypeIndex.graph`, a value the index keeps by each commit, so taking it
/// up is O(1) and the answer is worked out off the main actor); the text format reads the names in it.
public struct TypeQueriesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "type-queries" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.queryRelation(IsAEdge.id.rawValue, "it is, however far, a type S matches: its types and theirs",
                                example: #":is-a("Person")"#, reads: .file, transitive: true, namesTypes: true,
                                argumentShapes: { $0.types },
                                prepare: { $0.fact(TypeFacts.self).graph },
                                seeds: { $0.sources },
                                related: { shape, graph in graph.parents(of: shape) })
        registrar.queryTextFormat(mediaType: TypeLink.mediaType, describes: "types read as their titles", reads: .file,
                                  prepare: { $0.fact(TypeFacts.self).graph.names },
                                  read: { stored, names in
                                      // A type that is gone, or has no title, stays the id it is.
                                      UUID(uuidString: stored).flatMap { names[ShapeID($0)] } ?? stored
                                  })
        // An arrow whose ends do not fit its relationship type: the app's verdict (`RelationChecks`) and this word call the
        // one `fit`. A word of the file: the graph is taken in O(1), and each arrow is judged off the main actor from its
        // connection in the snapshot (one edge; a pill stands for one shape the snapshot resolves to; an end that is not
        // read gives no verdict, as the check gives none). Its rows carry no `problems`: `arrow:misfit:invalid` does.
        registrar.queryPseudoClass("misfit", "it is an arrow whose ends do not fit its relationship type",
                                   example: #"arrow:is-a("Friendship"):misfit"#, reads: .file,
                                   prepare: { preparation in
                                       let registry = preparation.registry
                                       return MisfitFacts(graph: preparation.fact(RelationshipFacts.self).graph,
                                                          relating: Set(registry.kinds.filter { registry.relates($0) }),
                                                          standIns: registry.standIns.kinds)
                                   },
                                   seeds: { $0.graph.types.relationshipTypes.isEmpty ? [] : $0.graph.types.sources },
                                   matches: { shape, facts in facts.isMisfit(shape) ? .yes : .no })
        // What `--ask` is told of the file's types: a line each, their fields' keys and kinds, never a value.
        registrar.queryAskFact(tag: "fields") { editor, question in editor.fileFields?.text(for: question) ?? "" }
        // And which shapes are of each, by title, so a note of no type is told apart from one that is.
        registrar.queryAskFact(tag: "instances") { editor, question in editor.fileFields?.instancesText(for: question) ?? "" }
        // A path into a note's values names a field no type has: a warning, and the query still answers.
        registrar.queryPathCheck(attribute: FieldValuesProperty.key.rawValue) { members, editor in
            editor.fileFields?.unknown(members).map { QueryPathUnknown(index: $0.index, known: $0.known) }
        }
    }
}

/// The file's relationships as a query takes them up: the types and the ends `RelationshipIndex` keeps by each commit, a
/// function of the records alone (`:misfit`).
struct RelationshipFacts: QueryFileFact {
    let graph: RelationshipGraph

    static func current(in editor: CanvasEditor) -> RelationshipFacts {
        RelationshipFacts(graph: editor.relationships?.graph ?? RelationshipGraph(types: TypeGraph(), ends: RelationshipEnds()))
    }
}

/// What `:misfit` judges by: the graph, the kinds of arrow that relate, and the kinds that are pills.
struct MisfitFacts: Sendable {
    let graph: RelationshipGraph
    let relating: Set<ShapeKind>
    let standIns: Set<ShapeKind>

    /// Whether the arrow's ends do not fit one of its relationship types, each end judged alone as the check judges it. An
    /// end the snapshot resolves to one shape (the shape itself, or what a pill stands for) is read; one it leaves as it
    /// was (a pill the kind may not stand for now, or one that stands for nothing), one that is several (a pill that
    /// finds several shapes: its arrow runs to each) and one that is not there has no verdict, as the check's
    /// `unjudged` ends have none, and neither has an arrow with no connection (an end free). A pill that finds one
    /// shape by a question it asks is read as that shape; the check calls it a query and judges nothing.
    func isMisfit(_ shape: QueryShape) -> Bool {
        guard relating.contains(shape.record.kind), let list = shape.record[IsAProperty.self] else { return false }
        let types = list.map(\.shape).filter(graph.isRelationshipType)
        guard !types.isEmpty else { return false }
        let connections = shape.topology.edges(carriedBy: shape.record.id).filter(\.isConnection)
        guard !connections.isEmpty else { return false }
        func read(_ ends: [ShapeID]) -> EndReading {
            guard let end = ends.first, ends.allSatisfy({ $0 == end }), let record = shape.topology.shape(end), !standIns.contains(record.kind) else { return .empty }
            return .note(end)
        }
        let from = read(connections.map(\.source)), to = read(connections.map(\.target))
        return types.contains { graph.fit(of: $0, from: from, to: to)?.isMisfit == true }
    }
}

/// The file's types as a query takes them up: `TypeIndex.graph`, a function of the records alone.
struct TypeFacts: QueryFileFact {
    let graph: TypeGraph

    static func current(in editor: CanvasEditor) -> TypeFacts {
        TypeFacts(graph: editor.types?.graph ?? TypeGraph())
    }
}
