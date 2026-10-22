import AppKit
import Canvas
import Selection
import SwiftUI
import TextEditing

/// The table of contents: a Mac source list of the shown board's shapes, a shape that owns a board
/// opening onto that board's (`BoardRows`). The app shows it in the detail panel when nothing or
/// several shapes are selected (`ContentsOverviewPlugin`), and while it's walked by keys
/// (`ContentsState.isWalkedByKeys`); it follows the editor by itself. Clicking a row gives it the
/// keyboard, as a source list does: ↑ and ↓ move through the rows (⇧ extends), and so do Tab and ⇧Tab,
/// which stay in the list; → and ← open and close a row's disclosure triangle; Delete runs the
/// `.delete` command (what Delete on the canvas and Edit › Delete run: deleting the selection); a
/// double-click or Return on a row opens its shape (as Return on the canvas does: Selection's
/// `editor.open`); and Escape calls `onExit`, which gives the keyboard back to the canvas, as ⌘↑ and ⌘↩ do. So does
/// hiding the list while a row has the keyboard. It tells the state when it has the keyboard, from
/// the window's first responder, and which selections its keys made.
///
/// Its header names the board listed: a plugin says how (`ContentsHeadings`), else it's "Board".
/// The list doesn't know what a board is called; the plugin that names boards does.
public struct TableOfContentsView: View {
    let editor: CanvasEditor
    let onExit: @MainActor () -> Void
    @State private var window = ContentsWindowBox()

    public init(editor: CanvasEditor, onExit: @escaping @MainActor () -> Void = {}) {
        self.editor = editor
        self.onExit = onExit
    }

    public var body: some View {
        Group {
            if let state = editor.tableOfContents {
                ContentsList(state: state, editor: editor)
            } else {
                ContentUnavailableView("No Contents", systemImage: "list.bullet.indent")
            }
        }
        // Heard before the list's table, which handles the key after: a selection it makes for one
        // is the keys'. Tab and ⇧Tab step the rows as ↓ and ↑ do, rather than leaving the list.
        .onKeyPress(phases: [.down, .repeat]) { press in key(press) }
        .onExitCommand(perform: onExit)
        .background(ContentsWindowReader(box: window, onHide: reclaimSoon, onFirstResponder: noteKeyboard))
    }

    /// A key on its way to the list's table, while the list has the keyboard.
    private func key(_ press: KeyPress) -> KeyPress.Result {
        guard let state = editor.tableOfContents else { return .ignored }
        state.keyReachedList()
        // ⌘↑ is out to the list's container, the canvas, and ⌘↩ finishes, as Escape gives the canvas the keyboard (Go ›
        // Enclosing Board takes ⌘↑ first on a board inside another); ⌥Tab and ⌥⇧Tab go into a thing's drawn parts,
        // which a row has none of (keyboard navigation's P6: same key, same meaning).
        let held = KeyMeaning.Modifiers(press.modifiers)
        let backTab = press.characters == ContentsStyle.backTab
        if held == .command, press.key == .upArrow || press.key == .return {
            onExit()
            return .handled
        }
        if press.key == .tab || backTab, held.contains(.option) { return .handled }
        guard press.key == .tab || backTab, held.subtracting(.shift).isEmpty,
              let table = window.window?.firstResponder as? NSTableView else { return .ignored }
        let up = backTab || held.contains(.shift)
        let arrow = String(UnicodeScalar(UInt16(up ? NSUpArrowFunctionKey : NSDownArrowFunctionKey))!)
        guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.numericPad, .function],
                                           timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: table.window?.windowNumber ?? 0,
                                           context: nil, characters: arrow, charactersIgnoringModifiers: arrow,
                                           isARepeat: press.phase == .repeat, keyCode: up ? 126 : 125) else { return .ignored }
        table.keyDown(with: event)
        return .handled
    }

    /// The window's first responder changed: whether it's this list's table.
    private func noteKeyboard(_ hasIt: Bool) {
        guard let state = editor.tableOfContents, state.listHasKeyboard != hasIt else { return }
        state.listHasKeyboard = hasIt
    }

    /// After AppKit has hidden the list: if the keyboard fell to the window, hand it to the canvas.
    private func reclaimSoon() {
        _ = editor.scheduler.schedule(after: .zero) { [window, onExit] in
            if let window = window.window, window.firstResponder === window { onExit() }
        }
    }
}

/// What the table of contents' header calls the board it lists, when it lists every shape: its
/// title, a symbol before it, and a command that goes up from it, which the header offers as a
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

/// Which list the table of contents shows: one per board and scope, so a change of either replaces
/// the rows rather than moving them; and a new one each time a commit brings rows in at several
/// places at once (`ContentsState.replacements`), so those rows come in as one run too.
struct ContentsListID: Hashable {
    let board: BoardID
    let scope: [ShapeID]?
    let replacements: Int
}

/// The rows, under a header that says whether they're the whole board or the selection.
struct ContentsList: View {
    let state: ContentsState
    let editor: CanvasEditor

    var body: some View {
        let entries = state.entries
        if entries.isEmpty && !state.isFiltered {
            ContentUnavailableView("No Shapes", systemImage: "square.on.square.dashed",
                                   description: Text("Shapes on the board are listed here."))
        } else {
            List(selection: Binding(get: { Set(editor.selectedShapeIDs) }, set: { state.selectFromList($0) })) {
                Section {
                    ForEach(ListedRows(entries, state: state)) { listed in
                        ContentsTree(listed: listed, state: state)
                    }
                    // A new scope's rows replace the last scope's, rather than coming in around the
                    // rows both list, so they arrive as one run under the header; and so do the rows
                    // after a commit that brings rows in at several places at once. Rows arriving in
                    // runs at several places, the last row among them, make AppKit measure the last
                    // row from inside measuring the first run (it resizes the table after each run),
                    // and log "a reentrant operation in its NSTableView delegate", a future assert.
                    // AppKit's own doing: a plain NSTableView whose rows size themselves does it too.
                    // Another board's rows replace this one's the same way, whatever the scopes: a
                    // file put in place can show a board holding some of the last one's shapes.
                    // Read after `entries`, which counts the replacements.
                    .id(ContentsListID(board: editor.board, scope: state.scope, replacements: state.replacements))
                } header: {
                    ContentsHeader(state: state, editor: editor)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)         // on the panel's background, not a sidebar's
            .onDeleteCommand { editor.perform(.delete) }
            // No menu of its own (the canvas's is the shapes'): a double-click or Return on a row.
            .contextMenu(forSelectionType: ShapeID.self, menu: { _ in }, primaryAction: { state.open($0) })
        }
    }
}

/// A row, and under its disclosure triangle, while it's expanded, the rows nested under it, each
/// level a tree of its own, so each collapses on its own and rows nest as deep as their shapes do.
/// Whether it's expanded is the state's (`isExpanded`, observed for this row alone): a container's
/// row starts expanded, every other collapsed, and a row keeps what the person turns it to. A
/// collapsed row's nested rows aren't read (a subboard's board's, `BoardRows`): the list asks for
/// them only once it's expanded, as an `OutlineGroup` does.
struct ContentsTree: View {
    let listed: ListedRow
    let state: ContentsState

    var body: some View {
        if let children = listed.children {
            let entry = listed.entry
            let isExpanded = state.isExpanded(entry)
            DisclosureGroup(isExpanded: Binding(get: { isExpanded }, set: { state.setExpanded(entry, $0) })) {
                ForEach(children) { child in
                    ContentsTree(listed: child, state: state)
                }
            } label: {
                ContentsRow(entry: entry, state: state)
                    .background(DisclosureName(name: entry.spokenName))
                    .tag(listed.id)
            }
        } else {
            ContentsRow(entry: listed.entry, state: state)
                .tag(listed.id)
        }
    }
}

/// A row as the list shows it: its entry, and the rows nested under it, if any. Those are the rows
/// of the board its shape owns (`nestedBoard`), then the rows nested under it on its own board
/// (`children`): a subboard's row opens onto what's inside it, as a frame's opens onto what it
/// holds and a shape's onto the arrows that start from it.
@MainActor
struct ListedRow: Identifiable {
    let id: ShapeID
    let entry: ContentsEntry
    let state: ContentsState

    init(_ entry: ContentsEntry, state: ContentsState) {
        id = entry.id
        self.entry = entry
        self.state = state
    }

    /// Nil for none, so the row shows no disclosure triangle. The list asks for this of every row on
    /// every update, collapsed or not, so it's cheap: a board's rows are read only once the list asks
    /// what's in it, which it does only once the row is expanded (`ListedRows`).
    var children: ListedRows? {
        if let board = state.boardToOpen(under: entry) {
            return ListedRows(BoardRows(board, then: entry.children ?? [], state: state), state: state)
        }
        return entry.children.map { ListedRows($0, state: state) }
    }
}

/// Rows as the list shows them, a level at a time, front to back: entries, which are in document
/// order, the other way round, so the top row is the shape painted over the rest, as in a layers
/// list; or a board's rows (`BoardRows`), read only once something asks for one of them or how many
/// there are.
@MainActor
struct ListedRows {
    private let rows: Rows
    private let state: ContentsState

    private enum Rows {
        /// In document order.
        case entries([ContentsEntry])
        /// Front to back already.
        case board(BoardRows)
    }

    init(_ entries: [ContentsEntry], state: ContentsState) {
        rows = .entries(entries)
        self.state = state
    }

    init(_ board: BoardRows, state: ContentsState) {
        rows = .board(board)
        self.state = state
    }
}

extension ListedRows: @MainActor RandomAccessCollection {
    var startIndex: Int { 0 }

    var endIndex: Int {
        switch rows {
        case .entries(let entries): entries.count
        case .board(let board): board.entries.count
        }
    }

    subscript(position: Int) -> ListedRow {
        switch rows {
        case .entries(let entries): ListedRow(entries[entries.count - 1 - position], state: state)
        case .board(let board): ListedRow(board.entries[position], state: state)
        }
    }
}

/// The rows of a board a row opens onto (`ContentsState.outline(of:)`), then those nested under the
/// row on its own board, each front to back, read the first time they're asked for: the list asks
/// only once the row is expanded, so a collapsed subboard costs its row and no more, however much
/// its board holds.
@MainActor
final class BoardRows {
    private let board: BoardID
    private let nested: [ContentsEntry]
    private let state: ContentsState
    private var made: [ContentsEntry]?

    init(_ board: BoardID, then nested: [ContentsEntry], state: ContentsState) {
        self.board = board
        self.nested = nested
        self.state = state
    }

    var entries: [ContentsEntry] {
        if let made { return made }
        let entries = state.outline(of: board).reversed() + nested.reversed()
        made = entries
        return entries
    }
}

/// The board's heading (`ContentsState.heading`: a plugin's, else "Board"), with a button up from it
/// while it can go up; or "Selection" with a button that lists every shape again. Its own view, so
/// what the heading reads redraws only the header.
struct ContentsHeader: View {
    let state: ContentsState
    let editor: CanvasEditor

    var body: some View {
        HStack(spacing: ContentsStyle.headerSpacing) {
            if state.isFiltered {
                Text(ContentsStyle.selectionHeading)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                // View › Show All Shapes, the command.
                Button(ContentsStyle.showAllButton) { editor.perform(.showAllShapes) }
                    .buttonStyle(.borderless)
                    .help(ContentsStyle.showAllHelp)
            } else {
                let heading = state.heading
                if let up = heading.up, editor.canPerform(up) {
                    let upTitle = editor.registry.title(of: up) ?? up.rawValue
                    Button { editor.perform(up) } label: {
                        // Not a chevron: in a list's disclosure column, one reads as collapsing.
                        Image(systemName: ContentsStyle.upSymbol)
                            .frame(width: ContentsStyle.upWidth)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help(heading.upHelp ?? upTitle)
                    .accessibilityLabel(upTitle)
                }
                if let symbol = heading.systemImage {
                    Image(systemName: symbol)
                }
                Text(heading.title).lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
            }
        }
    }
}

/// A row and its hover, which the canvas shares: the pointer on the row hovers its shape, which the
/// canvas outlines faintly, and the row is tinted while its shape is hovered, from here or from the
/// canvas (unless it's selected, as the canvas outlines only an unselected shape's hover). The tint
/// observes only this row's shape (`isHovered`), so the hover moving down the list redraws the row it
/// leaves and the row it reaches, not every row. The row is a drag of its shape (`dragItem`; the
/// table drags every selected row when it's selected) and a drop target (`ContentsRowDrop`), with
/// its line above or below it, or its ring, while a drag points there (`dropZone`, observed for this
/// row alone).
struct ContentsRow: View {
    let entry: ContentsEntry
    let state: ContentsState
    @State private var height: CGFloat = 0

    var body: some View {
        #if DEBUG
        let _ = (state.rowsRedrawn += 1)
        #endif
        let zone = state.dropZone(for: entry.id)
        ContentsRowView(entry: entry)
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())      // the whole cell, not just the label's text
            .onContinuousHover { phase in
                if case .active = phase { state.hover(entry.id) } else { state.endHover(entry.id) }
            }
            .onDisappear { state.endHover(entry.id) }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 }
            .itemProvider { [entry, state] in state.dragItem(from: entry.id) }
            .onDrop(of: [.contentsRows], delegate: ContentsRowDrop(entry: entry, state: state, height: height))
            .overlay(alignment: zone == .below ? .bottomLeading : .topLeading) {
                if zone == .above || zone == .below {
                    ContentsDropLine()
                        .offset(y: (zone == .above ? -1 : 1) * ContentsStyle.dropLineDot / 2)
                }
            }
            .listRowBackground(zone == .on || state.isHovered(entry.id) ? ContentsRowBackground(isDropTarget: zone == .on) : nil)
    }
}

/// A row's background while it's hovered, or a drop on it is pointed at.
struct ContentsRowBackground: View {
    let isDropTarget: Bool

    var body: some View {
        if isDropTarget {
            ContentsDropHighlight()
        } else {
            ContentsHoverHighlight()
        }
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

/// A hovered row's tint: the selection highlight's shape, in a faint accent, as the canvas's hover
/// outline is the selection's, faint.
struct ContentsHoverHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: ContentsStyle.highlightRadius, style: .continuous)
            .fill(Color.accentColor.opacity(ContentsStyle.hoverOpacity))
            .padding(.horizontal, ContentsStyle.highlightInset)
    }
}

/// One row, as its kind drew it, then its marks at the trailing end. Skipped (`.equatable()`)
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

/// The list's window, for `reclaimSoon`.
@MainActor
final class ContentsWindowBox {
    weak var window: NSWindow?
}

/// Fills the box, reports the list being hidden (it, or a view it's in, like the panel), which
/// `onDisappear` doesn't, and says whether the window's first responder is the list's table each
/// time it changes: a table in the list's frame, as the reader is drawn behind the list.
struct ContentsWindowReader: NSViewRepresentable {
    let box: ContentsWindowBox
    let onHide: @MainActor () -> Void
    let onFirstResponder: @MainActor (Bool) -> Void
    func makeNSView(context: Context) -> ReaderView { ReaderView(box: box, onHide: onHide, onFirstResponder: onFirstResponder) }
    func updateNSView(_ view: ReaderView, context: Context) {
        view.onHide = onHide
        view.onFirstResponder = onFirstResponder
    }

    final class ReaderView: NSView {
        let box: ContentsWindowBox
        var onHide: @MainActor () -> Void
        var onFirstResponder: @MainActor (Bool) -> Void
        private var watching: NSKeyValueObservation?
        init(box: ContentsWindowBox, onHide: @escaping @MainActor () -> Void, onFirstResponder: @escaping @MainActor (Bool) -> Void) {
            self.box = box
            self.onHide = onHide
            self.onFirstResponder = onFirstResponder
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not from a nib") }
        override func viewDidMoveToWindow() {
            if let window { box.window = window }
            watching = window?.observe(\.firstResponder, options: [.initial, .new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.firstResponderChanged() }
            }
            if window == nil { onFirstResponder(false) }
        }
        override func viewDidHide() { onHide() }
        // Drawn behind the list: never what a click lands on.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func firstResponderChanged() {
            guard let window, let table = window.firstResponder as? NSTableView, !isHiddenOrHasHiddenAncestor else { return onFirstResponder(false) }
            let frame = table.convert(table.visibleRect, to: nil)
            onFirstResponder(convert(bounds, to: nil).contains(CGPoint(x: frame.midX, y: frame.midY)))
        }
    }
}

/// Names the row's disclosure triangle for assistive apps by the row ("Checkout"; AppKit's role and
/// value say it's a disclosure triangle, open or not), which the list's table draws beside the row
/// and gives no name: drawn behind the row, it finds the triangle in the row's view whenever it's
/// placed or laid out, and as the row it's in is reused.
struct DisclosureName: NSViewRepresentable {
    let name: String
    func makeNSView(context: Context) -> NamingView { NamingView(name: name) }
    func updateNSView(_ view: NamingView, context: Context) { view.name = name }

    final class NamingView: NSView {
        var name: String { didSet { if name != oldValue { nameTriangle() } } }
        init(name: String) {
            self.name = name
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not from a nib") }
        override func viewDidMoveToWindow() { nameTriangle() }
        override func layout() {
            super.layout()
            nameTriangle()
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        private func nameTriangle() {
            var view = superview
            while let current = view, !(current is NSTableRowView) { view = current.superview }
            guard let row = view else { return }
            for case let button as NSButton in row.subviews where button.identifier == NSOutlineView.disclosureButtonIdentifier {
                if button.accessibilityLabel() != name { button.setAccessibilityLabel(name) }
                if button.cell?.accessibilityLabel() != name { button.cell?.setAccessibilityLabel(name) }
            }
        }
    }
}
