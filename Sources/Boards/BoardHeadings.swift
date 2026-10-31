import Canvas
import DetailPanel
import TableOfContents

extension PluginID {
    public static let boardContents: PluginID = "board-contents"
    public static let boardHeadings: PluginID = "board-headings"
}

/// The table of contents' heading (`ContentsHeadings`): the board shown's crumb, so the list names
/// its board as the path does and redraws as the path does, with the way up to the board above
/// (`.goUpBoard`, which does not depend on what is selected, as ⌘↑ does: it steps out of a group or a
/// container first), called as Go › Enclosing Board is and with no key; on the root, the file's name
/// (`editor.rootName`), else "Board".
/// A plugin value of its own, after `BoardsPlugin` and `TableOfContentsPlugin`: a list without the
/// table of contents leaves it out.
public struct BoardContentsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .boardContents }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.contentsHeading { editor in
            guard let crumb = editor.boardCrumbs?.crumbs.last else { return ContentsHeading(editor.name(of: .root)) }
            return ContentsHeading(crumb.title, systemImage: crumb.systemImage, up: .goUpBoard)
        }
    }
}

/// What heads each board's rows in a list that groups shapes by board (`BoardHeadings`: Find's): the
/// board's name and symbol, as the path has them (`editor.name(of:)`, `symbol(of:)`). A plugin value
/// of its own, after `BoardsPlugin`: a list without the detail panel leaves it out.
public struct BoardHeadingsPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .boardHeadings }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.boardHeading { board, editor in BoardHeading(editor.name(of: board), systemImage: editor.symbol(of: board)) }
    }
}
