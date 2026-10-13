import Canvas
import Titles

extension PublishingState {
    /// What a board is called: its owner's title, else its owner's kind's name; "Board" for the root
    /// (its name is the file's, which the host knows). For what names shapes on boards (a reference's
    /// panel says which board its shape is on).
    public func boardName(of board: BoardID) -> String {
        guard let owner = editor.owner(of: board) else { return PublicStyle.boardName }
        return editor.registry.title(of: owner) ?? editor.registry.label(of: owner.kind).name
    }
}
