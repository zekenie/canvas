import AppKit
import Canvas
import Observation
import SwiftUI
import TableOfContents
import TextEditing

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
///
/// The crumb where the path turns read-only, the first whose board is (a locked subboard's, and so
/// every board under it), has a small lock after its name; the crumbs below it have none
/// (`BoardCrumbs.readOnlyStart`). Folded into "…", it's the lock on its item in the menu.
///
/// The root's crumb is the file's name, as the host has it (`editor.rootName`), else "Board".
///
/// The keys: Go › Board Path (⌥⌘P) gives the pill the keyboard, on the last crumb (the board shown).
/// Left and Right step between the crumbs and "…" (they stop at the ends), Return or Space goes up to
/// the crumb's board (the board shown's goes nowhere) or shows "…"'s menu, Down shows a crumb's menu,
/// which takes the keyboard on its rows (Up and Down walk them, Right and Left open and close, Return
/// picks one), Escape closes the menu onto its crumb and then gives the keyboard back to the canvas
/// (`onExit`), and Tab or ⇧Tab gives the keyboard back to the canvas. The keys come to a view behind the pill
/// (`PathKeyView`), the keyboard's one owner; the stop that has it is outlined. A click on a crumb,
/// "…" or a row does what it did and hands the keyboard back to the canvas too, and the crumbs and
/// "…" are Full Keyboard Access stops as any button is. To assistive apps the pill is a group,
/// "Board path", whose action "Show Contents" shows the menu of the crumb with the keyboard (else the
/// last's), and its key view reads where the keyboard is.
public struct BoardPath: View {
    let editor: CanvasEditor
    let onExit: @MainActor () -> Void

    /// `onExit` gives the keyboard back to the canvas (the host's, `registrar.hostOverlay`).
    public init(editor: CanvasEditor, onExit: @escaping @MainActor () -> Void = {}) {
        self.editor = editor
        self.onExit = onExit
    }

    public var body: some View {
        if let crumbs = editor.boardCrumbs {
            BoardPathPill(crumbs: crumbs, editor: editor, onExit: onExit)
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
    let onExit: @MainActor () -> Void
    /// The view behind "…", which its menu is placed against.
    @State private var foldAnchor = MenuAnchor()

    var body: some View {
        #if DEBUG
        let _ = (crumbs.pathRedrawn += 1)
        #endif
        if !crumbs.crumbs.isEmpty {
            let layout = crumbs.layout(rootName: editor.name(of: .root))
            // The canvas, which the menu that shows stays inside: only the pill and the menu take
            // clicks, the rest is the canvas's.
            GeometryReader { canvas in
                pill(layout)
                    .frame(width: canvas.size.width, height: canvas.size.height, alignment: .top)
                    .overlayPreferenceValue(CrumbBounds.self, alignment: .topLeading) { bounds in
                        GeometryReader { proxy in
                            CrumbMenuLayer(crumbs: crumbs, editor: editor, crumbFrames: bounds.mapValues { proxy[$0] }, canvas: proxy.size, onExit: onExit)
                        }
                    }
                    .background(PathKeys(crumbs: crumbs, editor: editor, layout: layout, anchor: foldAnchor, onExit: onExit))
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
                FoldedCrumbs(folded: layout.folded, crumbs: crumbs, editor: editor, anchor: foldAnchor, onExit: onExit)
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
        .accessibilityElement(children: .contain)
        .accessibilityLabel(BoardsStyle.pathLabel)
        .accessibilityAction(named: BoardsStyle.showContents) {
            let focused = crumbs.focus.flatMap { stop -> BoardID? in if case .crumb(let board) = stop { board } else { nil } }
            if let board = focused ?? crumbs.crumbs.last?.board { crumbs.openFromKeyboard(board) }
        }
    }

    /// Drawn only: VoiceOver reads the crumbs in order, so a "Forward" image between each pair would
    /// be noise.
    private var separator: some View {
        Image(systemName: "chevron.right").imageScale(.small).foregroundStyle(.tertiary)
            .accessibilityHidden(true)
    }

    /// A crumb shows its menu, if it has one, as the pointer stays on it; nothing marks it but the
    /// lock, on the crumb where the read-only part of the path starts.
    @ViewBuilder
    private func item(_ crumb: BoardCrumb, isCurrent: Bool) -> some View {
        let isReadOnlyStart = crumb.board == crumbs.readOnlyStart
        Group {
            if isCurrent {
                CrumbWidth(maxWidth: BoardsStyle.crumbMaxWidth) {
                    CrumbTitle(title: crumb.title, isReadOnlyStart: isReadOnlyStart).fontWeight(.semibold)
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
                        // A click leaves the keyboard with the canvas, even with Full Keyboard Access on.
                        onExit()
                    } label: {
                        CrumbTitle(title: crumb.title, isReadOnlyStart: isReadOnlyStart)
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help(crumb.title)
                }
            }
        }
        .modifier(CrumbFocus(isFocused: crumbs.focus == .crumb(crumb.board)))
        .accessibilityAction(named: BoardsStyle.showContents) { crumbs.openFromKeyboard(crumb.board) }
        .onHover { inside in
            if inside { crumbs.pointerEntered(crumb: crumb.board) } else { crumbs.pointerExited(crumb: crumb.board) }
        }
        .anchorPreference(key: CrumbBounds.self, value: .bounds) { [crumb.board: $0] }
    }
}

/// The outline around the crumb that has the keyboard.
struct CrumbFocus: ViewModifier {
    let isFocused: Bool

    func body(content: Content) -> some View {
        content.overlay {
            if isFocused {
                RoundedRectangle(cornerRadius: BoardsStyle.focusRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: BoardsStyle.focusWidth)
                    .padding(-BoardsStyle.focusWidth)
            }
        }
    }
}

/// A crumb's title, on one line cut in the middle (a button's own title would wrap), with a small
/// lock after it on the crumb where the path's read-only part starts.
struct CrumbTitle: View {
    let title: String
    var isReadOnlyStart = false

    var body: some View {
        let text = Text(title).lineLimit(1).truncationMode(.middle)
        if isReadOnlyStart {
            HStack(spacing: BoardsStyle.readOnlySpacing) {
                text
                Image(systemName: BoardsStyle.readOnlySymbol)
                    .imageScale(.small)
                    .foregroundStyle(.secondary)
                    .help(BoardsStyle.readOnlyLabel)
                    .accessibilityLabel(BoardsStyle.readOnlyLabel)
            }
        } else {
            text
        }
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
    let anchor: MenuAnchor
    let onExit: @MainActor () -> Void

    var body: some View {
        Button {
            // A click: the menu, then the keyboard back to the canvas.
            Self.show(folded: folded, crumbs: crumbs, editor: editor, anchor: anchor)
            onExit()
        } label: {
            Text("…")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .background(MenuAnchorView(anchor: anchor))
        .help(BoardsStyle.foldLabel)
        .modifier(CrumbFocus(isFocused: crumbs.focus == .fold))
        // What assistive apps read in its place; never drawn. Its primary action is what a press
        // runs: a `Menu` without one does nothing when pressed here, having no pop-up button to open.
        .accessibilityRepresentation {
            Menu {
                ForEach(folded) { crumb in
                    Button {
                        crumbs.closeMenu()
                        editor.goUp(to: crumb.board)
                    } label: {
                        CrumbTitle(title: crumb.title, isReadOnlyStart: crumb.board == crumbs.readOnlyStart)
                    }
                }
            } label: {
                Text(BoardsStyle.foldLabel)
            } primaryAction: {
                Self.show(folded: folded, crumbs: crumbs, editor: editor, anchor: anchor)
            }
        }
    }

    /// Shows the menu of the boards "…" folds, lined up with its leading edge, its top at the pill's
    /// bottom edge, where a crumb's menu starts. It is modal.
    static func show(folded: [BoardCrumb], crumbs: BoardCrumbs, editor: CanvasEditor, anchor: MenuAnchor) {
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
    /// (`editor.goUp(to:)`), as a crumb does, and the one where the path's read-only part starts, if
    /// it's folded, with a lock on its item (`BoardCrumbs.readOnlyStart`). Made afresh each time it
    /// shows; a test reads and chooses its items (`performActionForItem(at:)`) without showing it.
    @MainActor
    public static func foldedMenu(_ folded: [BoardCrumb], editor: CanvasEditor) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let readOnlyStart = editor.boardCrumbs?.readOnlyStart
        for crumb in folded {
            let item = NSMenuItem(title: crumb.title) { [weak editor] in editor?.goUp(to: crumb.board) }
            if crumb.board == readOnlyStart {
                item.image = NSImage(systemSymbolName: BoardsStyle.readOnlySymbol, accessibilityDescription: BoardsStyle.readOnlyLabel)
            }
            menu.addItem(item)
        }
        return menu
    }
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
    let onExit: @MainActor () -> Void

    var body: some View {
        if let open = crumbs.openMenu, let menu = crumbs.menu(of: open), let crumb = crumbFrames[open],
           editor.tableOfContents?.outline(of: menu.board).isEmpty == false {
            let margin = BoardsStyle.menuMargin
            let top = crumb.maxY + BoardsStyle.menuGap
            let width = min(BoardsStyle.menuWidth, canvas.width - 2 * margin)
            let left = max(margin, min(crumb.minX, canvas.width - margin - width))
            let height = min(BoardsStyle.menuMaxHeight, canvas.height - margin - top)
            if width > 0, height > 2 * BoardsStyle.menuPadding {
                CrumbMenuPanel(crumbs: crumbs, editor: editor, menu: menu, maxHeight: height, onExit: onExit)
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
    let onExit: @MainActor () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: BoardsStyle.menuRadius, style: .continuous)
        ContentsOutline(editor: editor, board: menu.board, highlighted: menu.highlighted, maxHeight: maxHeight - 2 * BoardsStyle.menuPadding,
                        keyboard: crumbs.menuKeyboard) {
            crumbs.pick($0)
            // A row picked leaves the keyboard with the canvas, with Full Keyboard Access on as off.
            onExit()
        }
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

/// What a key does to the path.
enum PathKey {
    case left, right, up, down, activate, escape
    case tab

    /// The key an event is, with no modifier held (⇧ with Tab); nil for any other. Read through
    /// `KeyMeaning`, which drops the flags that are no modifier (Caps Lock, the keypad's, the arrows'
    /// function flag), so a key reads the same with Caps Lock on.
    init?(_ event: NSEvent) {
        guard let reading = KeyMeaning.Reading(event: event) else { return nil }
        let steps = reading.meaning == .next || reading.meaning == .previous
        guard reading.modifiers.isEmpty || (steps && reading.modifiers == .shift) else { return nil }
        switch reading.meaning {
        case .left: self = .left
        case .right: self = .right
        case .up: self = .up
        case .down: self = .down
        case .activate, .toggle: self = .activate
        case .back: self = .escape
        case .next, .previous: self = .tab
        case .finish, .delete: return nil
        }
    }
}

/// The view behind the pill that has the keyboard while the path does (`BoardCrumbs.requestKeyboard`):
/// it takes the keys and changes where the keyboard is in the pill (`BoardCrumbs.focus`) or its menu
/// (`menuKeyboard`), which the pill draws; it draws nothing and takes no clicks. A key it has no use
/// for does nothing, and Tab and Escape always move on.
struct PathKeys: NSViewRepresentable {
    let crumbs: BoardCrumbs
    let editor: CanvasEditor
    let layout: (leading: [BoardCrumb], folded: [BoardCrumb], trailing: [BoardCrumb])
    let anchor: MenuAnchor
    let onExit: @MainActor () -> Void

    func makeNSView(context: Context) -> PathKeyView {
        let view = PathKeyView()
        crumbs.keyView = view
        return view
    }

    func updateNSView(_ view: PathKeyView, context: Context) {
        crumbs.keyView = view
        view.crumbs = crumbs
        crumbs.giveKeyboardBack = onExit
        view.handle = { key in handle(key) }
        // What assistive apps read where the keyboard is.
        view.reading = { value() }
    }

    /// The stops, leading first: each crumb, and "…" where it is.
    private var stops: [PathStop] {
        layout.leading.map { .crumb($0.board) } + (layout.folded.isEmpty ? [] : [.fold]) + layout.trailing.map { .crumb($0.board) }
    }

    /// Where the keyboard is, as it is read: the crumb, "…", or the menu's row.
    private func value() -> String {
        if let row = crumbs.menuKeyboard.rowName { return row }
        switch crumbs.focus {
        case .crumb(let board)?: return editor.name(of: board)
        case .fold?: return BoardsStyle.foldLabel
        case nil: return ""
        }
    }

    /// Whether the key was used.
    private func handle(_ key: PathKey) -> Bool {
        if crumbs.menuKeyboard.isTaken { return menuKey(key) }
        // No stop to act on (the board changed under the keyboard, a crumb is gone): Tab and Escape
        // still move on, so the keyboard is never left with a view that does nothing.
        guard let stop = crumbs.focus, let index = stops.firstIndex(of: stop) else {
            guard key == .tab || key == .escape else { return false }
            leave()
            return true
        }
        switch key {
        case .left:
            if index > 0 { crumbs.focus = stops[index - 1] }
        case .right:
            if index + 1 < stops.count { crumbs.focus = stops[index + 1] }
        case .activate:
            switch stop {
            case .crumb(let board):
                crumbs.closeMenu()
                if editor.goUp(to: board) { onExit() }
            case .fold:
                FoldedCrumbs.show(folded: layout.folded, crumbs: crumbs, editor: editor, anchor: anchor)
            }
        case .down:
            switch stop {
            case .crumb(let board): crumbs.openFromKeyboard(board)
            case .fold: FoldedCrumbs.show(folded: layout.folded, crumbs: crumbs, editor: editor, anchor: anchor)
            }
        case .escape:
            if crumbs.openMenu != nil {
                crumbs.closeMenuToCrumb()
            } else {
                crumbs.focus = nil
                onExit()
            }
        case .up:
            break
        case .tab:
            leave()
        }
        return true
    }

    /// Tab, ⇧Tab: the keyboard goes back to the canvas, the menu shown closed.
    private func leave() {
        crumbs.closeMenu()
        crumbs.focus = nil
        onExit()
    }

    /// A key while the menu has the keyboard.
    private func menuKey(_ key: PathKey) -> Bool {
        let menu = crumbs.menuKeyboard
        switch key {
        case .up: menu.press(.up)
        case .down: menu.press(.down)
        case .left: menu.press(.left)
        case .right: menu.press(.right)
        case .activate:
            if let row = menu.row {
                crumbs.pick(row)
                onExit()
            } else {
                // A section's row has no shape to go to: it opens or closes.
                menu.press(.activate)
            }
        case .escape: crumbs.closeMenuToCrumb()
        case .tab: leave()
        }
        return true
    }
}

final class PathKeyView: NSView {
    var handle: ((PathKey) -> Bool)?
    /// Where the keyboard is, as assistive apps read it: the crumb, "…" or the menu's row.
    var reading: (() -> String)?
    weak var crumbs: BoardCrumbs?

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .group }
    override func accessibilityLabel() -> String? { BoardsStyle.pathLabel }
    override func accessibilityValue() -> Any? { reading?() }

    override func resignFirstResponder() -> Bool {
        crumbs?.keyboardLeft()
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard let key = PathKey(event), handle?(key) == true else { return }
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
}
