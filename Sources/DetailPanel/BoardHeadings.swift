import Canvas

// MARK: Board headings

/// What a board is called over its rows in a list: its title, and a symbol before it.
public struct BoardHeading: Hashable {
    public var title: String
    public var systemImage: String?

    public init(_ title: String, systemImage: String? = nil) {
        self.title = title
        self.systemImage = systemImage
    }
}

/// What heads each board's rows in the lists that group shapes by board (Find's), from the plugin
/// that knows what a board is called (Boards', its
/// `BoardHeadingsPlugin`: the path's names), so neither the panel nor a list learns what names a
/// board. At most one: two are `RegistryError.conflict` at startup. Without one the root's rows are
/// headed "Board" and another board's have no name. Read through `editor.boardHeading(of:)`.
public enum BoardHeadings {}

extension BoardHeadings: KeyedExtensionPoint {
    public typealias Contribution = @MainActor (BoardID, CanvasEditor) -> BoardHeading
    public static var owner: PluginID { .detailPanel }
    public static func uniqueKeys(of _: Contribution, for _: ShapeTarget) -> [AnyHashable] { ["heading"] }
    public static func summary(of _: Contribution, for _: ShapeTarget) -> String { "board heading" }
}

extension PluginRegistrar {
    /// What a board is called over its rows in a list (`BoardHeadings`). Read in a panel's body, for
    /// each board with rows in view:
    ///
    ///     registrar.boardHeading { board, editor in BoardHeading(editor.name(of: board), systemImage: editor.symbol(of: board)) }
    public mutating func boardHeading(_ heading: @escaping @MainActor (BoardID, CanvasEditor) -> BoardHeading) {
        contribute(heading, to: BoardHeadings.self)
    }
}

extension CanvasEditor {
    /// What heads a board's rows in a list: what a plugin calls the board (`registrar.boardHeading`),
    /// else "Board" for the root and no name for any other. Whoever reads it observes what the
    /// contributor reads.
    public func boardHeading(of board: BoardID) -> BoardHeading {
        registry.contributions(to: BoardHeadings.self).first?.value(board, self)
            ?? BoardHeading(board.isRoot ? DetailStyle.rootBoardHeading : "")
    }
}
