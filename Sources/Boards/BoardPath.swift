import AppKit
import Canvas
import SwiftUI
import TableOfContents

/// Where you are in a file's boards, as data-canvas shows it: a small pill of crumbs, root first,
/// the board shown last, for over the top middle of the canvas (the host places it over the whole
/// canvas, with `.overlay(alignment: .top)`: the pill keeps `BoardsStyle.topInset` from its top edge,
/// and a crumb's menu stays inside it). Nothing on the root. The board shown is bold and not a
/// button; each board above is, and shows that board with the shape you came through selected
/// (`editor.goUp(to:)`). The crumbs are separated by ›s. More than four fold the middle into
/// "…", a button drawn as those crumbs are, whose menu lists the boards it hides (`foldedMenu`),
/// starting at the pill's bottom edge, as a crumb's menu does.
///
/// Every crumb has a menu, as data-canvas's do, unmarked (the board shown's only while it has
/// shapes): the pointer on the crumb shows it below the crumb (`BoardCrumbs.pointerEntered(crumb:)`),
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

    /// How far down over the canvas the path reaches on a board, in points: to its pill's bottom
    /// edge, nothing on the root, where it shows nothing. The host tells the editor
    /// (`coveredTop`), so a fit (a board's first visit, Zoom to Fit, `reveal`) leaves it clear.
    @MainActor
    public static func coveredHeight(on board: BoardID) -> CGFloat {
        guard !board.isRoot else { return 0 }
        let font = NSFont.systemFont(ofSize: BoardsStyle.fontSize, weight: .medium)
        return BoardsStyle.topInset + 2 * BoardsStyle.verticalPadding + (font.ascender - font.descender + font.leading).rounded(.up)
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
                FoldedCrumbs(folded: layout.folded, crumbs: crumbs, editor: editor)
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

    /// Drawn only: VoiceOver reads the crumbs in order, so a "Forward" image between each pair would
    /// be noise.
    private var separator: some View {
        Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    /// A crumb shows its menu, if it has one, as the pointer stays on it; nothing marks it.
    @ViewBuilder
    private func item(_ crumb: BoardCrumb, isCurrent: Bool) -> some View {
        Group {
            if isCurrent {
                CrumbWidth(maxWidth: BoardsStyle.crumbMaxWidth) {
                    CrumbTitle(title: crumb.title).fontWeight(.semibold)
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
                        CrumbTitle(title: crumb.title)
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

/// A crumb's title, on one line cut in the middle (a button's own title would wrap).
struct CrumbTitle: View {
    let title: String

    var body: some View {
        Text(title).lineLimit(1).truncationMode(.middle)
    }
}

/// The boards the path folds, as "…": a button built as a board above's crumb is (borderless, in its
/// gray and the pill's type), which shows them in a menu (`BoardPath.foldedMenu`) lined up with its
/// leading edge, the menu's top at the pill's bottom edge, where a crumb's menu starts. (A SwiftUI
/// `Menu` draws as a pop-up button, which takes no style from around it and draws without the pill's
/// vibrancy: darker than the crumbs on a light pill, near white on a dark one.) To assistive apps
/// it's a pop-up button, "Boards between", whose press shows that menu and whose children are the
/// boards it folds, each a button that goes up to its board.
struct FoldedCrumbs: View {
    let folded: [BoardCrumb]
    let crumbs: BoardCrumbs
    let editor: CanvasEditor
    @State private var anchor = MenuAnchor()

    var body: some View {
        Button(action: showMenu) {
            Text("…")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .background(MenuAnchorView(anchor: anchor))
        .help(Self.name)
        // A click leaves the keyboard with the canvas, even with Full Keyboard Access on.
        .focusable(false)
        // What assistive apps read in its place; never drawn. Its primary action is what a press
        // runs: a `Menu` without one does nothing when pressed here, having no pop-up button to open.
        .accessibilityRepresentation {
            Menu {
                ForEach(folded) { crumb in
                    Button(crumb.title) {
                        crumbs.closeMenu()
                        editor.goUp(to: crumb.board)
                    }
                }
            } label: {
                Text(Self.name)
            } primaryAction: {
                showMenu()
            }
        }
    }

    /// Its tooltip, and its name to assistive apps.
    private static let name = "Boards between"

    private func showMenu() {
        crumbs.closeMenu()
        guard let view = anchor.view else { return }
        // AppKit puts the first item's top at the point, and its own padding above that.
        let drop = BoardsStyle.menuGap + BoardsStyle.systemMenuTopPadding
        let below = view.isFlipped ? view.bounds.maxY + drop : view.bounds.minY - drop
        BoardPath.foldedMenu(folded, editor: editor).popUp(positioning: nil, at: NSPoint(x: view.bounds.minX, y: below), in: view)
    }
}

extension BoardPath {
    /// The empty view behind "…", which its menu is placed against: the fold's button is the one
    /// over it, as a test finds it.
    public static let foldedAnchor = NSUserInterfaceItemIdentifier("BoardPath.folded")

    /// The menu "…" shows: the boards it folds, root side first, each going up to its board
    /// (`editor.goUp(to:)`), as a crumb does. Made afresh each time it shows; a test reads and
    /// chooses its items (`performActionForItem(at:)`) without showing it.
    @MainActor
    public static func foldedMenu(_ folded: [BoardCrumb], editor: CanvasEditor) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for crumb in folded {
            let action = FoldedMenuAction { [weak editor] in editor?.goUp(to: crumb.board) }
            let item = NSMenuItem(title: crumb.title, action: #selector(FoldedMenuAction.fire), keyEquivalent: "")
            item.target = action
            item.representedObject = action          // the item holds its target weakly
            menu.addItem(item)
        }
        return menu
    }
}

/// What an item of the fold's menu runs: its target, kept alive as its `representedObject`. The
/// item stays a plain NSMenuItem, since AppKit may copy one through initializers a subclass wouldn't
/// inherit.
final class FoldedMenuAction: NSObject {
    private let run: @MainActor () -> Void

    init(_ run: @escaping @MainActor () -> Void) { self.run = run }

    /// AppKit sends menu actions on the main thread.
    @MainActor @objc func fire() { run() }
}

/// The view the fold's menu is placed against, kept for the button's action.
@MainActor
final class MenuAnchor {
    weak var view: NSView?
}

/// An empty view behind the fold's button, for its menu to be placed against; it takes no clicks.
struct MenuAnchorView: NSViewRepresentable {
    let anchor: MenuAnchor

    func makeNSView(context: Context) -> NSView {
        let view = PassThroughView()
        view.identifier = BoardPath.foldedAnchor
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) { anchor.view = view }

    private final class PassThroughView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
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
