import Canvas

/// What a command line is typed for: the one shape whose text it's on, or the shapes selected. The
/// engine knows which shapes, never which surface draws the line.
public enum SlashTarget: Hashable, Sendable {
    /// A line of one shape's text (a note's words, an arrow's label, a panel's box). The shape is being
    /// written, so a read-only one offers nothing.
    case text(ShapeID)
    /// The command bar: the shapes selected, in selection order (`editor.selectedShapeIDs`: a group
    /// selected whole is its shapes, and a frame is itself, not what it holds). A read-only one is offered
    /// only the commands a plugin declared, whose rule decides (Unlock).
    case selection([ShapeID])

    /// Its shapes, in order.
    public var shapes: [ShapeID] {
        switch self {
        case .text(let id): [id]
        case .selection(let ids): ids
        }
    }
}
