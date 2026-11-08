/// Text on the canvas whose Undo is the board's while it has nothing of its own to undo or redo: a row's line, whose draft
/// commits as the caret leaves it, so ⌘Z after a row's commit takes that step back (editing ends, as any undo ends it). The
/// window asks it, for Edit ▸ Undo and Redo, their titles and ⌘Z; any other text's Undo is its own while it has the keyboard.
@MainActor
public protocol UndoesBoardWhenEmpty: AnyObject {}
