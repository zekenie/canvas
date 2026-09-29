import Canvas

// Queries: `canvas query`'s engine. A query (QueryLanguage's CSS-like selector) is checked against
// what the app has, the vocabulary (`QueryVocabulary`: kinds and their schemas' attributes, edge
// types, words), into a plan (`QueryPlan`), which is answered about the whole file: every shape on
// every board the app can show, by kind, name, id, schema-typed attribute, text, Topology's
// containment and typed edges, and the words plugins add.
//
// A horizontal on Topology, which it reads containment and edges from, and on the core. It knows no
// plugin: what shapes are called, what an untitled owner's board is called, words beyond the
// language's and how text of a media type reads come through its points (`QueryNames`,
// `QueryBoardNames`, `QueryWords`, `QueryTextFormats`), which bridges fill. Kinds, attributes and
// edge types come from the query's text and are checked against the registry as it resolves;
// DrawScript lends it only "did you mean" (`Suggestions`).
//
// A query costs the main actor its reading and one turn that takes up the file (`QuerySnapshot`,
// O(1)); it's answered off the main actor (`Evaluation`), a set at a time, but for what only the
// main actor can say, asked in slices of 2 ms, one at a time (`MainFacts`). It keeps nothing between
// queries and hears no commit (`QueryState`).

extension PluginID {
    public static let queries: PluginID = "queries"
}

/// The query engine's plugin: its service (`editor.queries`), and the points bridges fill. Every
/// plugin list with it needs `TopologyPlugin`: without Topology every query is refused
/// (`no_topology`), since what a query ranges over and its order are Topology's.
public struct QueriesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .queries }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.service { QueryState(editor: $0) }
        registrar.contribute(QueryEngine(), to: QueryEngines.self)
    }
}

/// That this app answers queries: `QueriesPlugin`'s mark (only this module can make one), so that
/// what has a registry and no editor, a command about no board, can tell (`registry.answersQueries`)
/// without an editor's service to look up (`editor.queries`).
public struct QueryEngine: Sendable {
    init() {}
}

/// Who answers queries: `QueriesPlugin`, once.
public enum QueryEngines {}

extension QueryEngines: KeyedExtensionPoint {
    public typealias Contribution = QueryEngine
    public static var owner: PluginID { .queries }
    public static func uniqueKeys(of _: QueryEngine, for _: ShapeTarget) -> [AnyHashable] { [QueryPointKey(name: label)] }
    public static func summary(of _: QueryEngine, for _: ShapeTarget) -> String { label }
    static let label = "query engine"
}

extension Registry {
    /// Whether this app answers queries (`QueriesPlugin` is installed): a lookup of its mark, for
    /// what has a registry and no editor to ask (`editor.queries`).
    public var answersQueries: Bool { !contributions(to: QueryEngines.self).isEmpty }
}
