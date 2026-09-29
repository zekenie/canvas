import Canvas
import Mentions
import Queries
import Topology

/// A bridge between two horizontals: mentions in queries. `:mentions(S)` is a shape whose text
/// mentions a shape S matches, and `:mentioned-by(S)` one a shape S matches mentions: Topology's
/// mention edges (`MentionEdge`), from the shape whose text holds the mention to the shape it names,
/// on any board, a shape's mention of itself too. And mention text (a string whose schema says
/// `contentMediaType: text/x-canvas-mentions`) reads in queries and rows as a person reads it: plain
/// text, each mention "@" and the name its target has now (`MentionState.labels`, taken as the query
/// takes up the file), or the name it holds while its target is gone, never the stored form with its
/// ids. Queries has never heard of mentions, nor Mentions of queries.
public struct MentionQueriesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "mention-queries" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.queryRelation(Word.mentions.rawValue, "its text mentions a shape S matches", example: #":mentions("Checkout")"#,
                                types: [MentionEdge.id], direction: .outgoing)
        registrar.queryRelation(Word.mentionedBy.rawValue, "a shape S matches mentions it", example: #":mentioned-by("API gateway")"#,
                                types: [MentionEdge.id], direction: .incoming)
        registrar.queryTextFormat(mediaType: MentionTextFormat.mediaType, describes: "mentions read as @Name",
                                  prepare: { $0.editor.mentions?.labels ?? MentionLabels() },
                                  // Read from the stored string in one pass, with no runs made: a scan reads every note's.
                                  read: { stored, labels in MentionText.plainText(stored: stored) { labels.label(of: $0) } })
    }

    /// The words it adds.
    enum Word: String {
        case mentions, mentionedBy = "mentioned-by"
    }
}
