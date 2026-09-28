import AppKit
import Canvas
import Selection
import SwiftUI

/// The table of contents: a Mac source list of the shown board's shapes. The app shows it in the
/// detail panel when nothing or several shapes are selected (through Composition); it follows the
/// editor by itself. Clicking a row gives it the keyboard, as a source list does: the arrow keys
/// move through the rows, Delete runs the `.delete` command (what Delete on the canvas and Edit ›
/// Delete run: deleting the selection), a double-click or Return on a row opens its shape (as
/// Return on the canvas does: Selection's `editor.open`), and Escape calls `onExit`, which gives the keyboard back to the
/// canvas. So does hiding the list while a row has the keyboard.
///
/// Its header names the board listed: `heading` says how, else it's "Board". The list doesn't know
/// what a board is; whoever places it (Composition) does.
public struct TableOfContentsView: View {
    let editor: CanvasEditor
    let onExit: @MainActor () -> Void
    let heading: @MainActor (CanvasEditor) -> ContentsHeading?
    @State private var window = ContentsWindowBox()

    public init(editor: CanvasEditor, onExit: @escaping @MainActor () -> Void = {},
                heading: @escaping @MainActor (CanvasEditor) -> ContentsHeading? = { _ in nil }) {
        self.editor = editor
        self.onExit = onExit
        self.heading = heading
    }

    public var body: some View {
        Group {
            if let state = editor.tableOfContents {
                ContentsList(state: state, editor: editor, heading: heading)
            } else {
                ContentUnavailableView("No Contents", systemImage: "list.bullet.indent")
            }
        }
        .onExitCommand(perform: onExit)
        .background(ContentsWindowReader(box: window, onHide: reclaimSoon))
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
/// button while it can run (`editor.canPerform`).
public struct ContentsHeading {
    public var title: String
    public var systemImage: String?
    public var up: CanvasCommand?

    public init(_ title: String, systemImage: String? = nil, up: CanvasCommand? = nil) {
        self.title = title
        self.systemImage = systemImage
        self.up = up
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
    let heading: @MainActor (CanvasEditor) -> ContentsHeading?

    var body: some View {
        let entries = state.entries
        if entries.isEmpty && !state.isFiltered {
            ContentUnavailableView("No Shapes", systemImage: "square.on.square.dashed",
                                   description: Text("Shapes on the board are listed here."))
        } else {
            List(selection: Binding(get: { Set(editor.selectedShapeIDs) }, set: { state.select($0) })) {
                Section {
                    OutlineGroup(entries, children: \.children) { entry in
                        ContentsRow(entry: entry, state: state)
                            .tag(entry.id)
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
                    ContentsHeader(state: state, editor: editor, heading: heading)
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

/// The board's heading (else "Board"), with a button up from it while it can go up; or "Selection"
/// with a button that lists every shape again. Its own view, so what the heading reads redraws only
/// the header.
struct ContentsHeader: View {
    let state: ContentsState
    let editor: CanvasEditor
    let heading: @MainActor (CanvasEditor) -> ContentsHeading?

    var body: some View {
        HStack(spacing: ContentsStyle.headerSpacing) {
            if state.isFiltered {
                Text("Selection")
                Spacer()
                Button("Show All", action: state.showAll)
                    .buttonStyle(.borderless)
                    .help("List every shape on the board")
            } else {
                let heading = heading(editor) ?? ContentsHeading("Board")
                if let up = heading.up, editor.canPerform(up) {
                    Button { editor.perform(up) } label: {
                        Image(systemName: "chevron.up")
                            .frame(width: ContentsStyle.upWidth)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .help("Go up")
                    .accessibilityLabel("Up")
                }
                if let symbol = heading.systemImage {
                    Image(systemName: symbol)
                }
                Text(heading.title).lineLimit(1)
                Spacer()
            }
        }
    }
}

/// A row and its hover, which the canvas shares: the pointer on the row hovers its shape, which the
/// canvas outlines faintly, and the row is tinted while its shape is hovered, from here or from the
/// canvas (unless it's selected, as the canvas outlines only an unselected shape's hover). The tint
/// observes only this row's shape (`isHovered`), so the hover moving down the list redraws the row it
/// leaves and the row it reaches, not every row.
struct ContentsRow: View {
    let entry: ContentsEntry
    let state: ContentsState

    var body: some View {
        #if DEBUG
        let _ = (state.rowsRedrawn += 1)
        #endif
        ContentsRowView(entry: entry)
            .equatable()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())      // the whole cell, not just the label's text
            .onContinuousHover { phase in
                if case .active = phase { state.hover(entry.id) } else { state.endHover(entry.id) }
            }
            .onDisappear { state.endHover(entry.id) }
            .listRowBackground(state.isHovered(entry.id) ? ContentsHoverHighlight() : nil)
    }
}

/// A mark: a small dot, centered in a square wide enough to hover for its tooltip.
struct ContentsMarkView: View {
    let mark: ContentsMark

    var body: some View {
        Circle()
            .fill(mark.color)
            .frame(width: ContentsStyle.markSize, height: ContentsStyle.markSize)
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
/// unless its shape changes, so dragging another shape costs one comparison: a row is the same
/// object until its shape changes, or its marks might.
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

/// Fills the box, and reports the list being hidden (it, or a view it's in, like the panel), which
/// `onDisappear` doesn't.
struct ContentsWindowReader: NSViewRepresentable {
    let box: ContentsWindowBox
    let onHide: @MainActor () -> Void
    func makeNSView(context: Context) -> ReaderView { ReaderView(box: box, onHide: onHide) }
    func updateNSView(_ view: ReaderView, context: Context) { view.onHide = onHide }

    final class ReaderView: NSView {
        let box: ContentsWindowBox
        var onHide: @MainActor () -> Void
        init(box: ContentsWindowBox, onHide: @escaping @MainActor () -> Void) {
            self.box = box
            self.onHide = onHide
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("not from a nib") }
        override func viewDidMoveToWindow() { if let window { box.window = window } }
        override func viewDidHide() { onHide() }
    }
}
