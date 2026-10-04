import Canvas
import Queries
import Titles

// QueryLexicon: the words the query language has for this app's concerns (what shapes and boards
// are called, `:mentions` and `:mentioned-by`, `:invalid` and `:warned`, `:selected`, and how
// mention text reads), each a plugin of its own over Queries' points, so a list can install the
// engine with words of its own (QueriesTests do). It imports the concerns its words are about;
// none of them knows queries.

/// Query names, in QueryLexicon: queries name shapes as Titles has them, for a `"Title"` head,
/// the `title` attribute (`[title^="API"]`), rows and `--ask`'s titles. A kind's shapes are named
/// when it opts into the title Titles keeps (`TitleProperty`), read from the record on any thread;
/// derived when Titles works them out from what the kind keeps (a schema card's, from its schema's
/// `"title"`; a kind both named and derived is derived, since Titles falls back for the shapes
/// nobody named), read through `registry.title(of:)` on the main actor; and a kind with neither has
/// none. A title is folded as Titles folds one (`TitleProperty.folded`), a query's too.
public struct TitleQueriesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "title-queries" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.queryNames(attribute: TitleProperty.key.rawValue,
                             source: { kind, registry in
                                 if registry.titleIsDerived(kind) { return .derived }
                                 return registry.properties(for: kind).contains(TitleProperty.key) ? .named : .none
                             },
                             named: { TitleProperty.folded($0[TitleProperty.self]) },
                             derived: { record, registry in registry.title(of: record) },
                             fold: { TitleProperty.folded($0) })
    }
}
