import Canvas
import CanvasRPC
import Foundation
import Queries
import Titles
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
                                related: { shape, graph in graph.parents(of: shape) },
                                makes: { anchors, record, editor in IsAFit.making(record, of: anchors, in: editor) })
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
        // And how arrows join them, by type (else kind), with counts: what a question follows from one shape to another.
        registrar.queryAskFact(tag: "connections") { editor, question in editor.fileFields?.connectionsText(for: question) ?? "" }
        // A path into a note's values names a field no type has: a warning, and the query still answers.
        registrar.queryPathCheck(attribute: FieldValuesProperty.key.rawValue) { members, editor in
            editor.fileFields?.unknown(members).map { QueryPathUnknown(index: $0.index, known: $0.known) }
        } makes: { members, literal, record, editor in
            FieldFit.value(at: members, literal, of: record, in: editor)
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

    /// The types' revision and the ends': a type changed, or an arrow at a relationship type moved its ends.
    static func revision(in editor: CanvasEditor) -> Int? { editor.relationships?.graphRevision ?? 0 }
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

    /// `TypeIndex.graphRevision`: a type changed, never a note's own list.
    static func revision(in editor: CanvasEditor) -> Int? { editor.types?.graphRevision ?? 0 }
}

/// A shape made to be what `:is-a(S)` says (`makes:`, which `QueryState.fit` calls, so a shape made where only shapes of a type
/// are accepted is one): the type S names is added to the shape's `is`, at the end, as adding a type adds it. A type is named
/// by its title (folded as a title is; a title that more than one type has names none, since which is meant is no one's to
/// say: nothing is written) or by `#id`, and of several alternatives (`:is-a("Task", "Bug")`) the first that names a type the
/// shape may be is the one written. Nothing is written for a shape of a kind that holds no `is`, one that is already of a
/// type any alternative names (or of a type built on it), a type that is gone or not a type, a pill, one the shape's role may
/// not take (an arrow's relationship types, a note's plain ones), the shape itself, or one that is the shape in turn.
@MainActor
enum IsAFit {
    /// `record` with the first type the anchors name that it may be added to its `is`; nil when nothing is written.
    static func making(_ record: AnyShapeRecord, of anchors: [QueryAnchor], in editor: CanvasEditor) -> AnyShapeRecord? {
        guard !record.isOpaque, editor.registry.isTypeable(record.kind), let index = editor.types else { return nil }
        let graph = index.graph
        let named = anchors.compactMap { type(named: $0, in: graph, editor: editor) }
        guard !named.isEmpty else { return nil }
        let own = record[IsAProperty.self] ?? []
        let held = graph.chained(own.map(\.shape)).union(own.map(\.shape))
        // Already one of them, however far: it matches, whichever alternative it is.
        guard !named.contains(where: held.contains) else { return nil }
        let role = TypeRole(of: record, in: editor)
        guard let type = named.first(where: { $0 != record.id && role.offers($0, in: index) && !graph.reaches(record.id, from: $0) }) else { return nil }
        var written = record
        editor.addType(type, to: &written)
        return written
    }

    /// The one type an anchor names: by id, a shape that is a type; by title, the type so titled when there is one, and (with a
    /// kind said) of that kind. Never a shape that isn't there, is kept aside or is a pill.
    private static func type(named anchor: QueryAnchor, in graph: TypeGraph, editor: CanvasEditor) -> ShapeID? {
        func usable(_ id: ShapeID) -> Bool {
            guard graph.types.contains(id), let record = editor.shape(inFile: id), !record.isOpaque,
                  !editor.registry.standIns.kinds.contains(record.kind) else { return false }
            return anchor.kind.map { $0 == record.kind } ?? true
        }
        if let id = anchor.id { return usable(id) ? id : nil }
        guard let title = TitleProperty.folded(anchor.title) else { return nil }
        let candidates = graph.names.filter { TitleProperty.folded($0.value) == title && usable($0.key) }.map(\.key)
        return candidates.count == 1 ? candidates[0] : nil
    }
}

/// A value a query says a note's field has (`[fieldValues.status="todo"]`, which `QueryState.fit` writes), typed by the field
/// as the note's types give it (the chain of its `is`, as the check reads it): text stays text whatever it looks like (`02134`),
/// a number is a number (a whole one for an integer field), a choice is the choice as spelled (`i` finds it), a date is a day,
/// a date-time an instant, a yes or no is true or false. A member through a group, another type's fields or pairs is walked;
/// nothing is written for a path no field of the note's types names, a list, a group or pairs itself, an either, or a value
/// the field's kind doesn't take. Nothing is sure without the note's types, so a note of none gets nothing.
@MainActor
enum FieldFit {
    static func value(at members: [String], _ literal: QueryMemberLiteral, of record: AnyShapeRecord, in editor: CanvasEditor) -> JSONValue? {
        guard let book = editor.fieldBook, let types = record[IsAProperty.self]?.map(\.shape), !types.isEmpty, !members.isEmpty,
              let field = book.field(at: FieldPath(members.map { .key($0) }), types: types),
              case .plain(let kind) = book.kind(of: field) else { return nil }
        let text = literal.text
        switch kind {
        case .text:
            return .string(text)
        case .number(let integer):
            guard let number = Double(text), number.isFinite else { return nil }
            if integer, number != number.rounded() { return nil }
            return .number(number)
        case .yesNo:
            return Bool(text).map(JSONValue.bool)
        case .date:
            return KindSchema.isDay(text) ? .string(text) : nil
        case .dateTime:
            let formatter = ISO8601DateFormatter()
            if KindSchema.isDay(text) { return .string(text + "T00:00:00Z") }
            return formatter.date(from: text) != nil ? .string(text) : nil
        case .choice(let options):
            let found = options.first { literal.ignoresCase ? $0.label.caseInsensitiveCompare(text) == .orderedSame : $0.label == text }
            return found?.value
        }
    }
}
