import AppKit
import Canvas
import Selection
import SwiftUI

/// The table of contents: a Mac source list of the board's shapes. The app shows it in the detail
/// panel when nothing or several shapes are selected (through Composition); it follows the editor
/// by itself. Clicking a row gives it the keyboard, as a source list does: the arrow keys move
/// through the rows, Delete runs the `.delete` command (what Delete on the canvas and Edit › Delete
/// run: deleting the selection), and Escape calls `onExit`, which gives the keyboard back to the
/// canvas. So does hiding the list while a row has the keyboard.
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
            List(selection: Binding(get: { Set(editor.selectedShapeIDs) }, set: { state.select($0) })) {
                Section {
                    OutlineGroup(entries, children: \.children) { entry in
                        ContentsRow(entry: entry, state: state)
                            .tag(entry.id)
                    }
                } header: {
                    ContentsHeader(isFiltered: state.isFiltered, showAll: state.showAll)
                }
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)         // on the panel's background, not a sidebar's
            .onDeleteCommand { editor.perform(.delete) }
        }
    }
}

/// "Board", or "Selection" with a button that lists every shape again.
struct ContentsHeader: View {
    let isFiltered: Bool
    let showAll: @MainActor () -> Void

    var body: some View {
        HStack {
            Text(isFiltered ? "Selection" : "Board")
            Spacer()
            if isFiltered {
                Button("Show All", action: showAll)
                    .buttonStyle(.borderless)
                    .help("List every shape on the board")
            }
        }
    }
}

/// A row and its hover, which the canvas shares: the pointer on the row hovers its shape, which the
/// canvas outlines faintly, and the row is tinted while its shape is hovered, from here or from the
/// canvas (unless it's selected, as the canvas outlines only an unselected shape's hover).
struct ContentsRow: View {
    let entry: ContentsEntry
    let state: ContentsState

    var body: some View {
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

/// A hovered row's tint: the selection highlight's shape, in a faint accent, as the canvas's hover
/// outline is the selection's, faint.
struct ContentsHoverHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: ContentsStyle.highlightRadius, style: .continuous)
            .fill(Color.accentColor.opacity(ContentsStyle.hoverOpacity))
            .padding(.horizontal, ContentsStyle.highlightInset)
    }
}

/// One row, as its kind drew it. Skipped (`.equatable()`) unless its shape changes, so dragging
/// another shape costs one comparison.
struct ContentsRowView: View, Equatable {
    let entry: ContentsEntry

    nonisolated static func == (a: Self, b: Self) -> Bool {
        MainActor.assumeIsolated { a.entry.record == b.entry.record && a.entry.symbol == b.entry.symbol }
    }

    var body: some View {
        entry.row
            .environment(\.contentsSymbol, entry.symbol)
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
