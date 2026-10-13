import Foundation

/// The panel list's words and numbers.
@MainActor
enum NeighborStyle {
    /// The tab's title.
    nonisolated static let tab = "Connections"
    /// The list of what a shape is inside, outermost first.
    nonisolated static let inside = "Inside"
    /// The list of what's directly inside a shape.
    nonisolated static let contains = "Contains"
    /// What the root board is called while the file has no name.
    nonisolated static let rootName = "Board"
    /// A row's symbol, for a kind with none.
    nonisolated static let fallbackSymbol = "square.dashed"
    /// The tab's order: after a horizontal's feature tabs (50), before Style (100).
    nonisolated static let tabOrder = 60

    static let empty = "No Connections"
    static let noMatches = "No Matches"
    static let searchPrompt = "Search"
    /// The lists get a search field once they hold this many shapes in all: more than a panel shows
    /// without scrolling.
    static let searchFrom = 20
    /// The room under a row that has a caption, so the caption reads as its row's and not the next's.
    static let captionedRowBottom: CGFloat = 4
    /// How long commits must have stopped before the lists are asked again.
    static let settle: Duration = .milliseconds(100)
    /// The space between the search field and the lists, as between a section's rows.
    static let spacing: CGFloat = 8
    /// The space between one list and the next list's head.
    static let groupSpacing: CGFloat = 6
}
