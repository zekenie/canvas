import Canvas

/// What a command line is typed for: the one shape whose text it's on, the shapes selected, or, with
/// nothing selected, every shape on the board shown. The engine knows which shapes, never which surface
/// draws the line.
public enum SlashTarget: Hashable, Sendable {
    /// A line of one shape's text (a note's words, an arrow's label, a panel's box). The shape is being
    /// written, so a read-only one offers nothing.
    case text(ShapeID)
    /// The command bar: the shapes selected, in selection order (`editor.selectedShapeIDs`: a group
    /// selected whole is its shapes, and a frame is itself, not what it holds). A read-only one is offered
    /// only the commands a plugin declared, whose rule decides (Unlock).
    case selection([ShapeID])
    /// The command bar with nothing selected: every shape on the board shown, as Select All would select
    /// them (`document.shapes`, in document order: arrows, and what frames hold, too). The shapes' commands
    /// act on them as on a selection of them; a command about the target as a whole
    /// (`SelectionSlashCommand`) tells it apart, since nothing was picked out (`/query` asks the whole file).
    case everything([ShapeID])

    /// Its shapes, in order.
    public var shapes: [ShapeID] {
        switch self {
        case .text(let id): [id]
        case .selection(let ids), .everything(let ids): ids
        }
    }

    /// Whether it's a line of one shape's text, rather than the command bar's.
    public var isText: Bool {
        if case .text = self { return true }
        return false
    }
}
