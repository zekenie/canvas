import Canvas
import SwiftUI

/// A board's rows as the table of contents lists them, for a small panel that names the board (the
/// path's crumb menus, which Boards shows over the canvas): each row as its kind draws it, on one
/// line, and the rows nested under it behind a disclosure triangle, collapsed until it's opened, as
/// in the list (a subboard's: its board's rows, read once it's opened). `highlighted`'s row is
/// tinted as a hovered row is in the list (the way you came, in a crumb's menu), and the row under
/// the pointer is lit. A click on a row picks its shape (`onPick`):
/// what picking does is the host's. It reads the rows through `ContentsState.outline(of:)`, so it
/// follows the file while it shows, and makes the views of only the rows in view. As tall as its
/// rows, up to `maxHeight`, past which it scrolls; it opens at the top. Nothing without the table
/// of contents' plugin, or for a board with no rows.
public struct ContentsOutline: View {
    let editor: CanvasEditor
    let board: BoardID
    let highlighted: ShapeID?
    let maxHeight: CGFloat
    let onPick: @MainActor (ShapeID) -> Void

    public init(editor: CanvasEditor, board: BoardID, highlighted: ShapeID? = nil, maxHeight: CGFloat,
                onPick: @escaping @MainActor (ShapeID) -> Void) {
        self.editor = editor
        self.board = board
        self.highlighted = highlighted
        self.maxHeight = maxHeight
        self.onPick = onPick
    }

    public var body: some View {
        if let state = editor.tableOfContents {
            let entries = state.outline(of: board)
            if !entries.isEmpty {
                OutlineRows(state: state, entries: entries, highlighted: highlighted, maxHeight: maxHeight, onPick: onPick)
                    .id(board)          // another board's rows start collapsed, at the top
            }
        }
    }
}

/// A row of the outline as shown: its entry, how deep it's nested, and whether rows are.
struct OutlineLine: Identifiable {
    let entry: ContentsEntry
    let depth: Int
    let isExpandable: Bool
    var id: ShapeID { entry.id }
}

/// The rows in view, flattened: each row, then, while it's expanded, the rows nested under it.
struct OutlineRows: View {
    let state: ContentsState
    let entries: [ContentsEntry]
    let highlighted: ShapeID?
    let maxHeight: CGFloat
    let onPick: @MainActor (ShapeID) -> Void
    @State private var expanded: Set<ShapeID> = []

    var body: some View {
        let lines = Self.lines(of: entries, expanded: expanded, state: state)
        // It opens at the top, as data-canvas's menus do: scrolling a lazy stack to a row far down
        // lays out the rows before it (some 70 ms to the last of 10,000).
        ScrollView(.vertical) {
            LazyVStack(spacing: 0) {
                ForEach(lines) { line in
                    OutlineRow(line: line, isExpanded: expanded.contains(line.id), isHighlighted: line.id == highlighted,
                               toggle: { toggle(line.id) }, pick: { onPick(line.id) })
                }
            }
        }
        .frame(height: min(CGFloat(lines.count) * ContentsStyle.outlineRowHeight, maxHeight))
    }

    private func toggle(_ id: ShapeID) {
        if expanded.remove(id) == nil { expanded.insert(id) }
    }

    /// The rows shown: every top-level row, and under each row expanded the rows nested under it,
    /// the rows of the board its shape owns first (`nestedBoard`), as in the list.
    static func lines(of entries: [ContentsEntry], expanded: Set<ShapeID>, state: ContentsState) -> [OutlineLine] {
        var lines: [OutlineLine] = []
        lines.reserveCapacity(entries.count)
        func add(_ entries: [ContentsEntry], depth: Int) {
            for entry in entries {
                let board = state.boardToOpen(under: entry)
                lines.append(OutlineLine(entry: entry, depth: depth, isExpandable: board != nil || entry.children != nil))
                guard expanded.contains(entry.id) else { continue }
                if let board { add(state.outline(of: board), depth: depth + 1) }
                if let children = entry.children { add(children, depth: depth + 1) }
            }
        }
        add(entries, depth: 0)
        return lines
    }
}

/// One row: indented as deep as it's nested, a disclosure triangle when rows are nested under it,
/// and the row as its kind drew it, a button that picks its shape.
struct OutlineRow: View {
    let line: OutlineLine
    let isExpanded: Bool
    let isHighlighted: Bool
    let toggle: () -> Void
    let pick: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: CGFloat(line.depth) * ContentsStyle.outlineIndent)
            if line.isExpandable {
                Button(action: toggle) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: ContentsStyle.outlineDisclosureSize, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .frame(width: ContentsStyle.outlineDisclosureWidth, height: ContentsStyle.outlineRowHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .focusable(false)
                .accessibilityLabel(isExpanded ? "Collapse" : "Expand")
            } else {
                Color.clear.frame(width: ContentsStyle.outlineDisclosureWidth)
            }
            Button(action: pick) {
                // The list's row, so the two never differ (an outline's rows have no marks).
                ContentsRowView(entry: line.entry)
                    .labelStyle(OutlineLabelStyle())
                    // The row's colors, as in the list: a borderless button's label is dimmed.
                    .foregroundStyle(Color.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            // A click never takes the keyboard (with Full Keyboard Access on, a button's would, and
            // it would fall to the window once the panel closes).
            .focusable(false)
        }
        .padding(.trailing, ContentsStyle.outlineRowPadding)
        .frame(height: ContentsStyle.outlineRowHeight)
        .lineLimit(1)
        .background {
            ZStack {
                if isHighlighted { highlight(Color.accentColor.opacity(ContentsStyle.hoverOpacity)) }
                if isHovered { highlight(Color.primary.opacity(ContentsStyle.outlineHoverOpacity)) }
            }
        }
        .onHover { isHovered = $0 }
    }

    private func highlight(_ color: Color) -> some View {
        RoundedRectangle(cornerRadius: ContentsStyle.outlineRadius, style: .continuous).fill(color)
    }
}

/// A row's `Label` as a source list lays it out: its symbol in a column of its own, in the accent
/// color unless the row colors it, then its title.
struct OutlineLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: ContentsStyle.outlineIconSpacing) {
            configuration.icon
                .foregroundStyle(Color.accentColor)
                .frame(width: ContentsStyle.outlineIconWidth)
            configuration.title
        }
    }
}
