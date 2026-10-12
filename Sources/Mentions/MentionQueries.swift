import Canvas
import Queries
import Topology

/// Mentions in queries, in Mentions: `:mentions(S)` is a shape whose text mentions a shape S
/// matches, and `:mentioned-by(S)` one a shape S matches mentions: Topology's mention edges
/// (`MentionEdge`), from the shape whose text holds the mention to the shape it names, on any
/// board, a shape's mention of itself too. And mention text (a string whose schema says
/// `contentMediaType: text/x-canvas-mentions`) reads in queries and rows as a person reads it: plain
/// text, each mention "@" and the name its target has now (`MentionState.labels`, taken as the query
/// takes up the file), or the name it holds while its target is gone, never the stored form with its
/// ids.
///
/// What each reads (`QueryReads`): the file, all three. The relations read Topology's edges, in
/// whatever view the query asks; the text format reads the names mentions show, which are their
/// shapes' names, a function of the records that `MentionState` keeps (`MentionLabels`), taken as
/// a `QueryFileFact` (`MentionedNames`), so a query that searches note text (`[text*=…]`,
/// `:contains`) is `readsOnlyTheFile` and a stand-in's own query may read it.
public struct MentionQueriesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { "mention-queries" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.queryRelation(Word.mentions.rawValue, "its text mentions a shape S matches", example: #":mentions("Checkout")"#,
                                types: [MentionEdge.id], direction: .outgoing)
        registrar.queryRelation(Word.mentionedBy.rawValue, "a shape S matches mentions it", example: #":mentioned-by("API gateway")"#,
                                types: [MentionEdge.id], direction: .incoming)
        registrar.queryTextFormat(mediaType: MentionTextFormat.mediaType, describes: "mentions read as @Name", reads: .file,
                                  prepare: { $0.fact(MentionedNames.self).labels },
                                  // Read from the stored string in one pass, with no runs made: a scan reads every note's.
                                  read: { stored, labels in MentionText.plainText(stored: stored) { labels.label(of: $0) } })
    }

    /// The words it adds.
    enum Word: String {
        case mentions, mentionedBy = "mentioned-by"
    }
}

/// The names mentions show now, as a query reads mention text: each mentioned shape's name while
/// it's live, from its record, which Mentions keeps (`MentionState.labels`, shared, O(1) to take).
/// A function of the records alone, so the format that reads it reads only the file.
struct MentionedNames: QueryFileFact {
    let labels: MentionLabels

    static func current(in editor: CanvasEditor) -> MentionedNames {
        MentionedNames(labels: editor.mentions?.labels ?? MentionLabels())
    }
}
