import AppKit
import Canvas
import Chrome
import Selection
import SwiftUI
import TextEditing

/// The table of contents: a Mac source list of the shown board's shapes, a shape that owns a board
/// opening onto that board's (`ContentsList`, AppKit's outline, which makes views for the rows in
/// view alone, so a board of any size shows at once). The app shows it in the window's sidebar,
/// whatever is selected (`TableOfContentsPlugin`'s `hostSidebar`); it follows the editor by itself,
/// showing a selection made elsewhere on its rows, opened to and scrolled to. A click on a row selects
/// its shape and gives the canvas the keyboard (`onExit`), so the canvas's keys act on it at once; a
/// double-click opens it. With the keyboard (View ▸ Focus Sidebar), ↑ and ↓ move through the rows
/// (⇧ extends), and so do Tab and ⇧Tab, which stay in the list; → and ← open and close a row's
/// disclosure triangle; Delete runs the `.delete` command (what Delete on the canvas and Edit › Delete
/// run: deleting the selection); Return on a row opens its shape (as Return on the canvas does:
/// Selection's `editor.open`); and Escape calls `onExit`, which gives the keyboard back to the canvas,
/// as ⌘↑ and ⌘↩ do. So does hiding the list while a row has the keyboard.
///
/// Its header names the board listed: a plugin says how (`ContentsHeadings`), else it's "Board". It
/// stays at the top as the rows scroll under it, and looks as the inspector's does (the window's
/// chrome's, `ChromeStyle`), on an empty board too; in the window's sidebar it is the title bar's row
/// (`PaneTitleRow`). The list doesn't know what a board is called; the plugin that names boards does.
public struct TableOfContentsView: View {
    let editor: CanvasEditor
    let onExit: @MainActor () -> Void
    @Environment(\.paneTitleRow) private var titleRow

    public init(editor: CanvasEditor, onExit: @escaping @MainActor () -> Void = {}) {
        self.editor = editor
        self.onExit = onExit
    }

    public var body: some View {
        if let state = editor.tableOfContents {
            VStack(spacing: 0) {
                ContentsHeader(state: state, editor: editor)
                    .frame(height: titleRow?.height ?? ChromeStyle.headerHeight)
                Rectangle().fill(Color(nsColor: ChromeStyle.hairline)).frame(height: ChromeStyle.hairlineWidth)
                let entries = state.entries
                if entries.isEmpty {
                    ContentUnavailableView("No Shapes", systemImage: "square.on.square.dashed",
                                           description: Text("Shapes on the board are listed here."))
                        .frame(maxHeight: .infinity)
                } else {
                    // Read after `entries`, which brings the listing up to date: what the list shows, so
                    // SwiftUI hands the list each change of it (a commit, the selection, another board).
                    ContentsList(state: state, editor: editor, onExit: onExit,
                                 shown: ContentsShown(board: editor.board, listing: state.listedSerial, version: state.listedVersion,
                                                      revision: editor.revision, selection: editor.selectedShapeIDs))
                }
            }
        } else {
            ContentUnavailableView("No Contents", systemImage: "list.bullet.indent")
        }
    }
}

/// What the table of contents' header calls the board it lists: its title, a symbol before it, and a command that goes up from it, which the header offers as a
/// button while it can run (`editor.canPerform`), called what the command is (`registry.title(of:)`,
/// what VoiceOver says, and what a menu item that runs it is called), with `upHelp` its tooltip (the
/// title and its key, where it has one: "Back (⌘[)"; the title, by default).
public struct ContentsHeading {
    public var title: String
    public var systemImage: String?
    public var up: CanvasCommand?
    public var upHelp: String?

    public init(_ title: String, systemImage: String? = nil, up: CanvasCommand? = nil, upHelp: String? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.up = up
        self.upHelp = upHelp
    }
}

/// The board's heading (`ContentsState.heading`: a plugin's, else "Board"), with a button up from it
/// while it can go up: the pane's header, as the inspector's is (its symbol dimmed in its column, its
/// title in the header's type). In the window's sidebar it is the title bar's row, past the window's
/// buttons, where the window's own title starts, in the title's type and with no symbol, as the title
/// has none: on the root the two are the same name in the same place, the title showing while the
/// sidebar doesn't. A press there on its words or nothing is the window's (`TitleRowDragArea`). Its own
/// view, so what the heading reads redraws only the header.
struct ContentsHeader: View {
    let state: ContentsState
    let editor: CanvasEditor
    @Environment(\.paneTitleRow) private var row

    var body: some View {
        HStack(spacing: ChromeStyle.headerSpacing) {
            content
        }
        .padding(.leading, row?.leading ?? ChromeStyle.headerInset)
        .padding(.trailing, row?.trailing ?? ChromeStyle.headerInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            if row != nil { TitleRowDragArea() }
        }
    }

    @ViewBuilder private var content: some View {
        let heading = state.heading
        if let up = heading.up, editor.canPerform(up) {
            let upTitle = editor.registry.title(of: up) ?? up.rawValue
            Button { editor.perform(up) } label: {
                // Not a chevron: beside a list, one reads as collapsing.
                Image(systemName: ContentsStyle.upSymbol)
                    .font(ContentsStyle.upFont)
                    .frame(width: ContentsStyle.upWidth)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .help(heading.upHelp ?? upTitle)
            .accessibilityLabel(upTitle)
        }
        if row == nil, let symbol = heading.systemImage {
            Image(systemName: symbol)
                .font(ChromeStyle.headerSymbol)
                .foregroundStyle(.secondary)
                .frame(width: ChromeStyle.headerSymbolWidth)
        }
        Text(heading.title).font(row == nil ? ChromeStyle.headerTitle : ChromeStyle.rowTitle).lineLimit(1)
            .allowsHitTesting(row == nil)
            .accessibilityAddTraits(.isHeader)
        Spacer(minLength: 0)
    }
}

/// A mark: a small dot, or its symbol, centered in a square wide enough to hover for its tooltip.
struct ContentsMarkView: View {
    let mark: ContentsMark

    var body: some View {
        Group {
            if let symbol = mark.symbol {
                Image(systemName: symbol)
                    .font(.system(size: ContentsStyle.markSymbolSize))
                    .foregroundStyle(mark.color)
            } else {
                Circle()
                    .fill(mark.color)
                    .frame(width: ContentsStyle.markSize, height: ContentsStyle.markSize)
            }
        }
        .frame(width: ContentsStyle.markTarget, height: ContentsStyle.markTarget)
        .contentShape(Rectangle())
        .help(mark.help)
        .accessibilityElement()
        .accessibilityLabel(mark.help)
    }
}

/// One row, as its kind drew it, then its marks at the trailing end: what the list's cell for a row
/// shows (`ContentsCell`), and a crumb's menu's row (`ContentsOutline`). Skipped (`.equatable()`)
/// unless its shape changes, so a drag costs one comparison, whatever it moves: a row is the same
/// object until its shape changes other than by moving, or its marks do.
struct ContentsRowView: View, Equatable {
    let entry: ContentsEntry

    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated { a.entry.row === b.entry.row }
    }

    var body: some View {
        let marks = entry.marks
        HStack(spacing: 0) {
            entry.row.view
                .environment(\.contentsSymbol, entry.symbol)
                .environment(\.contentsKindName, entry.kindName)
                .frame(maxWidth: .infinity, alignment: .leading)    // so the marks line up at the end
            ForEach(marks.indices, id: \.self) { i in
                ContentsMarkView(mark: marks[i])
            }
        }
        .lineLimit(1)
    }
}
