import Canvas
import TableOfContents

/// Rows of the table of contents that show mention text, with the names of the shapes it mentions
/// as they're named now: a kind whose row reads its mention text names these as its `affected`, so
/// a rename remakes the rows of the shapes that mention what was renamed, and nothing else.
///
///     note.contentsRow(affected: MentionRows.affected) { note, context in
///         ContentsLabel(context.plainText(note.props.text), placeholder: "Empty Note")
///     }
public enum MentionRows {
    /// The shapes whose rows a commit may change without changing them: those that mention a shape
    /// whose name, symbol or state the commit changed. What the commit changed, never the board.
    @MainActor
    public static func affected(_ changes: ChangeSet, _ context: ContentsContext) -> Set<ShapeID> {
        context.service(MentionState.self)?.rowsAffected(by: changes) ?? []
    }
}

extension ContentsContext {
    /// Mention text as a row reads it: each mention "@" and its target's live name, or the name it
    /// holds where its target isn't on the board.
    public func plainText<S>(_ text: ScopedMentionText<S>) -> String {
        service(MentionState.self)?.plainText(text) ?? text.plainText()
    }
}
