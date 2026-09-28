import Canvas
import SwiftUI
import TableOfContents

/// Where you are in a file's boards, as data-canvas shows it: a small pill of crumbs, root first,
/// the board shown last, for over the top middle of the canvas (the host places it over the whole
/// canvas, with `.overlay(alignment: .top)`: the pill keeps `BoardsStyle.topInset` from its top edge,
/// and a crumb's menu stays inside it). Nothing on the root. The board shown is bold and not a
/// button; each board above is, and shows that board with the shape you came through selected
/// (`editor.goUp(to:)`). More than four fold the middle into "…", a menu of the boards it hides.
///
/// Every crumb has a menu, as data-canvas's do, marked by a caret (the board shown's only while it
/// has shapes): the pointer on the crumb shows it below the crumb (`BoardCrumbs.pointerEntered(crumb:)`),
/// that board's rows as the table of contents lists them (`ContentsOutline`), with the shape whose
/// board is next on the path highlighted, the way you came; a row picked goes to its shape, or into
/// its board (`BoardCrumbs.pick`). The path reads only the crumbs (`BoardCrumbs`), so it redraws
/// when another board is shown or a board above changes, never for a commit on the board shown;
/// the menu that shows reads its board's rows.
public struct BoardPath: View {
    let editor: CanvasEditor
    let rootName: String

    /// `rootName` names the root's crumb: the file's name, say.
    public init(editor: CanvasEditor, rootName: String) {
        self.editor = editor
        self.rootName = rootName
    }

    public var body: some View {
        if let crumbs = editor.boardCrumbs {
            BoardPathPill(crumbs: crumbs, editor: editor, rootName: rootName)
        }
    }
}

/// Where each crumb is, by its board, for its menu to show below it.
struct CrumbBounds: PreferenceKey {
    static var defaultValue: [BoardID: Anchor<CGRect>] { [:] }
    static func reduce(value: inout [BoardID: Anchor<CGRect>], nextValue: () -> [BoardID: Anchor<CGRect>]) {
        value.merge(nextValue()) { $1 }
    }
}

struct BoardPathPill: View {
    let crumbs: BoardCrumbs
    let editor: CanvasEditor
    let rootName: String

    var body: some View {
        #if DEBUG
        let _ = (crumbs.pathRedrawn += 1)
        #endif
        if !crumbs.crumbs.isEmpty {
            let layout = crumbs.layout(rootName: rootName.isEmpty ? BoardsStyle.rootFallback : rootName)
            // The canvas, which the menu that shows stays inside: only the pill and the menu take
            // clicks, the rest is the canvas's.
            GeometryReader { canvas in
                pill(layout)
                    .frame(width: canvas.size.width, height: canvas.size.height, alignment: .top)
                    .overlayPreferenceValue(CrumbBounds.self, alignment: .topLeading) { bounds in
                        GeometryReader { proxy in
                            CrumbMenuLayer(crumbs: crumbs, editor: editor, crumbFrames: bounds.mapValues { proxy[$0] }, canvas: proxy.size)
                        }
                    }
            }
        }
    }

    private func pill(_ layout: (leading: [BoardCrumb], folded: [BoardCrumb], trailing: [BoardCrumb])) -> some View {
        HStack(spacing: BoardsStyle.spacing) {
            ForEach(layout.leading) { crumb in
                if crumb.id != layout.leading.first?.id { separator }
                item(crumb, isCurrent: layout.trailing.isEmpty && crumb.id == layout.leading.last?.id)
            }
            if !layout.folded.isEmpty {
                separator
                Menu {
                    ForEach(layout.folded) { crumb in
                        Button(crumb.title) { editor.goUp(to: crumb.board) }
                    }
                } label: {
                    Text("…")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Boards between")
                .focusable(false)
            }
            ForEach(layout.trailing) { crumb in
                separator
                item(crumb, isCurrent: crumb.id == layout.trailing.last?.id)
            }
        }
        .font(.system(size: BoardsStyle.fontSize, weight: .medium))
        .lineLimit(1)
        .padding(.horizontal, BoardsStyle.horizontalPadding)
        .padding(.vertical, BoardsStyle.verticalPadding)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator))
        .frame(maxWidth: BoardsStyle.maxWidth)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.top, BoardsStyle.topInset)
    }

    private var separator: some View {
        Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
    }

    /// A crumb with a menu has a caret after its title, and shows the menu as the pointer stays on it.
    @ViewBuilder
    private func item(_ crumb: BoardCrumb, isCurrent: Bool) -> some View {
        let hasMenu = crumbs.menu(of: crumb.board) != nil
        Group {
            if isCurrent {
                CrumbWidth(maxWidth: BoardsStyle.crumbMaxWidth) {
                    CrumbTitle(title: crumb.title, hasMenu: hasMenu).fontWeight(.semibold)
                }
                .help(crumb.title)
                .accessibilityAddTraits(.isHeader)
                // A click on it closes its menu, as data-canvas's does: it goes nowhere.
                .contentShape(Rectangle())
                .onTapGesture { crumbs.closeMenu() }
            } else {
                CrumbWidth(maxWidth: BoardsStyle.crumbMaxWidth) {
                    Button {
                        crumbs.closeMenu()
                        editor.goUp(to: crumb.board)
                    } label: {
                        CrumbTitle(title: crumb.title, hasMenu: hasMenu)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(crumb.title)
                    // A click leaves the keyboard with the canvas, even with Full Keyboard Access on.
                    .focusable(false)
                }
            }
        }
        .onHover { inside in
            if inside { crumbs.pointerEntered(crumb: crumb.board) } else { crumbs.pointerExited(crumb: crumb.board) }
        }
        .anchorPreference(key: CrumbBounds.self, value: .bounds) { [crumb.board: $0] }
    }
}

/// A crumb's title, on one line cut in the middle (a button's own title would wrap), and its caret.
struct CrumbTitle: View {
    let title: String
    let hasMenu: Bool

    var body: some View {
        HStack(spacing: BoardsStyle.caretSpacing) {
            Text(title).lineLimit(1).truncationMode(.middle)
            if hasMenu {
                Image(systemName: "chevron.down")
                    .font(.system(size: BoardsStyle.caretSize, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The menu that shows, if one does, below its crumb and lined up with it, kept inside the canvas.
/// Its own view, so a menu showing or closing redraws only this.
struct CrumbMenuLayer: View {
    let crumbs: BoardCrumbs
    let editor: CanvasEditor
    /// Where each crumb is, in the canvas's coordinates.
    let crumbFrames: [BoardID: CGRect]
    let canvas: CGSize

    var body: some View {
        if let open = crumbs.openMenu, let menu = crumbs.menu(of: open), let crumb = crumbFrames[open],
           editor.tableOfContents?.outline(of: menu.board).isEmpty == false {
            let margin = BoardsStyle.menuMargin
            let top = crumb.maxY + BoardsStyle.menuGap
            let width = min(BoardsStyle.menuWidth, canvas.width - 2 * margin)
            let left = max(margin, min(crumb.minX, canvas.width - margin - width))
            let height = min(BoardsStyle.menuMaxHeight, canvas.height - margin - top)
            if width > 0, height > 2 * BoardsStyle.menuPadding {
                CrumbMenuPanel(crumbs: crumbs, editor: editor, menu: menu, maxHeight: height)
                    .frame(width: width)
                    .offset(x: left, y: top)
            }
        }
    }
}

/// A crumb's menu: its board's rows (`ContentsOutline`), the way you came highlighted, on a panel as
/// tall as they are, up to `maxHeight`. The pointer on it keeps it.
struct CrumbMenuPanel: View {
    let crumbs: BoardCrumbs
    let editor: CanvasEditor
    let menu: CrumbMenu
    let maxHeight: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BoardsStyle.menuRadius, style: .continuous)
        ContentsOutline(editor: editor, board: menu.board, highlighted: menu.highlighted,
                        maxHeight: maxHeight - 2 * BoardsStyle.menuPadding) { crumbs.pick($0) }
            .padding(BoardsStyle.menuPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                shape.fill(.thickMaterial)
                    .shadow(color: .black.opacity(BoardsStyle.menuShadowOpacity), radius: BoardsStyle.menuShadowRadius, y: BoardsStyle.menuShadowY)
            }
            .overlay(shape.strokeBorder(.separator))
            .contentShape(shape)
            .onHover { inside in
                if inside { crumbs.pointerEnteredMenu() } else { crumbs.pointerExitedMenu() }
            }
    }
}

/// A crumb as wide as its title, but no wider than `maxWidth` (nor than it's offered): a longer
/// title is truncated. (A frame's `maxWidth` would widen a short one.)
struct CrumbWidth: Layout {
    let maxWidth: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let crumb = subviews.first else { return .zero }
        return crumb.sizeThatFits(capped(proposal, crumb))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let crumb = subviews.first else { return }
        crumb.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }

    private func capped(_ proposal: ProposedViewSize, _ crumb: LayoutSubview) -> ProposedViewSize {
        let ideal = crumb.sizeThatFits(.unspecified).width
        let width = min(ideal, maxWidth, proposal.width ?? .infinity)
        return ProposedViewSize(width: width, height: proposal.height)
    }
}
