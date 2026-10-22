import Canvas
import Observation
import SwiftUI

/// A board's rows as the table of contents lists them, front to back, for a small panel that names
/// the board (the path's crumb menus, which Boards shows over the canvas): each row as its kind draws it, on one
/// line, and the rows nested under it behind a disclosure triangle, as in the list: a container's
/// expanded, every other row collapsed until it's opened (a subboard's: its board's rows, read once
/// it's opened); the panel's own, so each time it shows they start so again. `highlighted`'s row is
/// tinted as a hovered row is in the list (the way you came, in a crumb's menu), and the row under
/// the pointer is lit. A click on a row picks its shape (`onPick`):
/// what picking does is the host's. It reads the rows through `ContentsState.outline(of:)`, so it
/// follows the file while it shows, and makes the views of only the rows in view. As tall as its
/// rows, up to `maxHeight`, past which it scrolls; it opens at the top. Nothing without the table
/// of contents' plugin, or for a board with no rows.
///
/// With a `keyboard` its rows take the keyboard, as a source list's do, from the host's key view
/// (`OutlineKeyboard.press`): Up and Down walk them (stopping at the ends), Right opens a row's
/// disclosure, or goes on to its first nested row once it is open, Left closes it, or goes to the row
/// it is nested under. Return, Space and Escape are the host's (the row in focus is
/// `OutlineKeyboard.row`). The row in focus is outlined and kept in view. Every row is named for
/// assistive apps, the disclosure by its row ("Checkout, expand"), and the highlighted row carries
/// the value "current path" (`ContentsStyle.outlineCurrentPath`).
public struct ContentsOutline: View {
    let editor: CanvasEditor
    let board: BoardID
    let highlighted: ShapeID?
    let maxHeight: CGFloat
    let keyboard: OutlineKeyboard?
    let onPick: @MainActor (ShapeID) -> Void

    public init(editor: CanvasEditor, board: BoardID, highlighted: ShapeID? = nil, maxHeight: CGFloat,
                keyboard: OutlineKeyboard? = nil, onPick: @escaping @MainActor (ShapeID) -> Void) {
        self.editor = editor
        self.board = board
        self.highlighted = highlighted
        self.maxHeight = maxHeight
        self.keyboard = keyboard
        self.onPick = onPick
    }

    public var body: some View {
        if let state = editor.tableOfContents {
            let entries = state.outline(of: board)
            if !entries.isEmpty {
                OutlineRows(state: state, entries: entries, highlighted: highlighted, maxHeight: maxHeight, keyboard: keyboard, onPick: onPick)
                    .id(board)          // another board's rows start afresh, at the top
            }
        }
    }
}

/// A key an outline answers (`OutlineKeyboard.press`).
public enum OutlineKey: Sendable {
    case up, down, left, right
}

/// How a host gives an outline the keyboard (`ContentsOutline`): the host owns the key view and
/// feeds the outline its keys, the outline answers with the row in focus (`row`, nil while none is,
/// the host's to read) and keeps it in view. `take()` asks for the keyboard, on the highlighted
/// row, else the first, as soon as the outline shows; `reset()` gives it up.
@MainActor
@Observable
public final class OutlineKeyboard {
    /// The row that has the keyboard, and what it is called (as assistive apps read it).
    public internal(set) var row: ShapeID? {
        didSet { if row == nil { rowName = nil } }
    }
    public internal(set) var rowName: String?
    /// Whether the keyboard was asked for and no row has taken it yet.
    public internal(set) var isWaiting = false
    @ObservationIgnored var step: (@MainActor (OutlineKey) -> Void)?

    public init() {}

    /// The keyboard goes to the outline's highlighted row, else its first, once it shows.
    public func take() { isWaiting = true }

    /// The keyboard is given up.
    public func reset() {
        isWaiting = false
        if row != nil { row = nil }
    }

    /// Whether the outline has the keyboard, or is about to.
    public var isTaken: Bool { isWaiting || row != nil }

    /// A key, answered by the outline if it shows.
    public func press(_ key: OutlineKey) { step?(key) }
}

/// A row of the outline as shown: its entry, how deep it's nested, whether rows are, and whether
/// they show.
struct OutlineLine: Identifiable {
    let entry: ContentsEntry
    let depth: Int
    let isExpandable: Bool
    let isExpanded: Bool
    var id: ShapeID { entry.id }
}

extension OutlineLine {
    /// What the row is called to assistive apps: the list's name for it (`ContentsEntry.spokenName`),
    /// so a row is said alike in both.
    @MainActor
    var name: String { entry.spokenName }
}

/// The rows in view, flattened: each row, then, while it's expanded, the rows nested under it.
struct OutlineRows: View {
    let state: ContentsState
    let entries: [ContentsEntry]
    let highlighted: ShapeID?
    let maxHeight: CGFloat
    let keyboard: OutlineKeyboard?
    let onPick: @MainActor (ShapeID) -> Void
    /// The rows turned from how they start (`ContentsEntry.startsExpanded`), here.
    @State private var turned: Set<ShapeID> = []

    var body: some View {
        let lines = Self.lines(of: entries, turned: turned, state: state)
        // It opens at the top, as data-canvas's menus do: scrolling a lazy stack to a row far down
        // lays out the rows before it (some 70 ms to the last of 10,000).
        ScrollViewReader { scroll in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(lines) { line in
                        OutlineRow(line: line, isExpanded: line.isExpanded, isHighlighted: line.id == highlighted,
                                   hasKeyboard: keyboard?.row == line.id, takesKeyboard: keyboard != nil,
                                   toggle: { toggle(line.id) }, pick: { onPick(line.id) })
                            .id(line.id)
                    }
                }
            }
            .onChange(of: keyboard?.row) { _, row in
                if let row { scroll.scrollTo(row) }
            }
        }
        .frame(height: min(CGFloat(lines.count) * ContentsStyle.outlineRowHeight, maxHeight))
        .onAppear { arm(lines) }
        .onChange(of: keyboard?.isWaiting) { arm(lines) }
        .onChange(of: lines.map(\.id)) { arm(lines) }
    }

    /// Takes the keyboard if it was asked for, and answers the keys with the rows now shown.
    private func arm(_ lines: [OutlineLine]) {
        guard let keyboard else { return }
        keyboard.step = { key in Self.step(key, in: lines, keyboard: keyboard, toggle: toggle) }
        if keyboard.isWaiting, !lines.isEmpty {
            let first = lines.first { $0.id == highlighted } ?? lines.first
            keyboard.row = first?.id
            keyboard.rowName = first?.name
            keyboard.isWaiting = false
        }
    }

    /// A key on the row with the keyboard.
    private static func step(_ key: OutlineKey, in lines: [OutlineLine], keyboard: OutlineKeyboard, toggle: (ShapeID) -> Void) {
        guard let row = keyboard.row, let index = lines.firstIndex(where: { $0.id == row }) else { return }
        let line = lines[index]
        var next: OutlineLine?
        switch key {
        case .down:
            if index + 1 < lines.count { next = lines[index + 1] }
        case .up:
            if index > 0 { next = lines[index - 1] }
        case .right:
            if line.isExpandable, !line.isExpanded { toggle(line.id) }
            else if line.isExpanded, index + 1 < lines.count, lines[index + 1].depth > line.depth { next = lines[index + 1] }
        case .left:
            if line.isExpanded { toggle(line.id) }
            else { next = lines[..<index].last(where: { $0.depth < line.depth }) }
        }
        if let next {
            keyboard.row = next.id
            keyboard.rowName = next.name
        }
    }

    private func toggle(_ id: ShapeID) {
        if turned.remove(id) == nil { turned.insert(id) }
    }

    /// The rows shown: every top-level row, and under each row expanded (a container's, unless it's
    /// in `turned`; any other row, if it is) the rows nested under it, the rows of the board its
    /// shape owns first (`nestedBoard`), each level front to back (entries, in document order, the
    /// other way round), as in the list.
    static func lines(of entries: [ContentsEntry], turned: Set<ShapeID>, state: ContentsState) -> [OutlineLine] {
        var lines: [OutlineLine] = []
        lines.reserveCapacity(entries.count)
        func add(_ entries: [ContentsEntry], depth: Int) {
            for entry in entries.reversed() {
                let board = state.boardToOpen(under: entry)
                let isExpandable = board != nil || entry.children != nil
                let isExpanded = isExpandable && entry.startsExpanded != turned.contains(entry.id)
                lines.append(OutlineLine(entry: entry, depth: depth, isExpandable: isExpandable, isExpanded: isExpanded))
                guard isExpanded else { continue }
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
    /// Whether the outline's keyboard is on this row, and whether the outline takes one at all.
    let hasKeyboard: Bool
    let takesKeyboard: Bool
    let toggle: () -> Void
    let pick: () -> Void
    @State private var isHovered = false

    private var name: String { line.name }

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
                // The arrows open and close it from its row; it takes no stop of its own.
                .focusable(false)
                .accessibilityLabel(ContentsStyle.outlineDisclosureSpoken(name, isExpanded: isExpanded))
            } else {
                Color.clear.frame(width: ContentsStyle.outlineDisclosureWidth)
            }
            row
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
        .overlay {
            // The row with the keyboard.
            if hasKeyboard {
                RoundedRectangle(cornerRadius: ContentsStyle.outlineRadius, style: .continuous)
                    .strokeBorder(Color.accentColor, lineWidth: ContentsStyle.outlineFocusWidth)
            }
        }
        .onHover { isHovered = $0 }
    }

    /// The row's button: a click picks its shape, the keyboard on the row too.
    @ViewBuilder
    private var row: some View {
        let button = Button(action: pick) {
            // The list's row, so the two never differ (an outline's rows have no marks).
            ContentsRowView(entry: line.entry)
                .labelStyle(OutlineLabelStyle())
                // The row's colors, as in the list: a borderless button's label is dimmed.
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(name)
        .accessibilityValue(isHighlighted ? ContentsStyle.outlineCurrentPath : "")
        if takesKeyboard {
            // The host's key view has the keyboard, and gives it back once a row is picked.
            button
        } else {
            // With no keyboard to take, a click never takes it (with Full Keyboard Access on, a
            // button's would, and it would fall to the window once the panel closes).
            button.focusable(false)
        }
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
