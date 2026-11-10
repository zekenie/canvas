/// Text on the canvas whose Undo is the board's while it has nothing of its own to undo or redo: a row's line, whose draft
/// commits as the caret leaves it, so ⌘Z after a row's commit takes that step back (editing ends, as any undo ends it). The
/// window asks it, for Edit ▸ Undo and Redo, their titles and ⌘Z; any other text's Undo is its own while it has the keyboard.
@MainActor
public protocol UndoesBoardWhenEmpty: AnyObject {
    /// Whether it holds words not yet written to the board (a row's line, changed): its Undo and Redo stay its own then, so
    /// the board's, which would end the editing and write them as a step of their own, doesn't take the draft with it.
    var holdsDraft: Bool { get }
}

extension UndoesBoardWhenEmpty {
    public var holdsDraft: Bool { false }
}
