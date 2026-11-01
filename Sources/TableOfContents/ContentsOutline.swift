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
/// of contents' plugin, or for a board with no rows. The rows of a kind that gathers them in a
/// section (`ContentsSections`) are under the section's row, after their level's other rows, as in
/// the list, closed until it's opened (open from the start where it holds the highlighted row); a
/// click on it opens or closes it, since it has no shape to pick.
///
/// With a `keyboard` its rows take the keyboard, as a source list's do, from the host's key view
/// (`OutlineKeyboard.press`): Up and Down walk them (stopping at the ends), Right opens a row's
/// disclosure, or goes on to its first nested row once it is open, Left closes it, or goes to the row
/// it is nested under. Return, Space and Escape are the host's (the row in focus is
/// `OutlineKeyboard.row`), but on a section's row, which `.activate` opens or closes. The row in
/// focus is outlined and kept in view. Every row is named for assistive apps, the disclosure by its
/// row ("Checkout, expand"), and the highlighted row carries the value "current path"
/// (`ContentsStyle.outlineCurrentPath`).
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
                OutlineRows(state: state, board: board, entries: entries, highlighted: highlighted, maxHeight: maxHeight, keyboard: keyboard,
                            onPick: onPick)
                    .id(board)          // another board's rows start afresh, at the top
            }
        }
    }
}

/// A key an outline answers (`OutlineKeyboard.press`): the arrows, and `activate` (Return or Space),
/// which opens or closes a section's row, and leaves a row's to the host, which picks its shape.
public enum OutlineKey: Sendable {
    case up, down, left, right, activate
}

/// How a host gives an outline the keyboard (`ContentsOutline`): the host owns the key view and
/// feeds the outline its keys, the outline answers with the row in focus (`row`, nil while none is,
/// the host's to read) and keeps it in view. `take()` asks for the keyboard, on the highlighted
/// row, else the first, as soon as the outline shows; `reset()` gives it up.
@MainActor
@Observable
public final class OutlineKeyboard {
    /// The line that has the keyboard: a row, or a section's row.
    var line: OutlineLineID? {
        didSet { if line == nil { rowName = nil } }
    }
    /// The shape of the row that has the keyboard: nil on a section's row, or with none.
    public var row: ShapeID? {
        guard case .row(let id)? = line else { return nil }
        return id
    }
    /// What the line that has the keyboard is called (as assistive apps read it).
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
        if line != nil { line = nil }
    }

    /// Whether the outline has the keyboard, or is about to.
    public var isTaken: Bool { isWaiting || line != nil }

    /// A key, answered by the outline if it shows.
    public func press(_ key: OutlineKey) { step?(key) }
}

/// What a line of the outline is: a shape's row, or the row of a section at its level.
enum OutlineLineID: Hashable {
    case row(ShapeID)
    case section(ContentsSectionKey)
}

/// A line of the outline as shown: a row (its entry) or a section's row (the section, and how many
/// rows it holds), how deep it's nested, whether rows are, and whether they show.
struct OutlineLine: Identifiable {
    enum Shows {
        case row(ContentsEntry)
        case section(ContentsSection, count: Int)
    }

    let id: OutlineLineID
    let shows: Shows
    let depth: Int
    let isExpandable: Bool
    let isExpanded: Bool

    /// The row's shape; nil for a section's row.
    var shape: ShapeID? {
        guard case .row(let id) = id else { return nil }
        return id
    }
}

extension OutlineLine {
    /// What the line is called to assistive apps: the list's name for a row
    /// (`ContentsEntry.spokenName`), so a row is said alike in both; a section's title.
    @MainActor
    var name: String {
        switch shows {
        case .row(let entry): entry.spokenName
        case .section(let section, _): section.title
        }
    }
}

/// The rows in view, flattened: each row, then, while it's expanded, the rows nested under it.
struct OutlineRows: View {
    let state: ContentsState
    let board: BoardID
    let entries: [ContentsEntry]
    let highlighted: ShapeID?
    let maxHeight: CGFloat
    let keyboard: OutlineKeyboard?
    let onPick: @MainActor (ShapeID) -> Void
    /// The lines turned from how they start (`ContentsEntry.startsExpanded`; a section's row closed,
    /// but one holding the highlighted row), here.
    @State private var turned: Set<OutlineLineID> = []

    var body: some View {
        let lines = Self.lines(of: entries, board: board, highlighted: highlighted, turned: turned, state: state)
        // It opens at the top, as data-canvas's menus do: scrolling a lazy stack to a row far down
        // lays out the rows before it (some 70 ms to the last of 10,000).
        ScrollViewReader { scroll in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(lines) { line in
                        OutlineRow(line: line, isExpanded: line.isExpanded, isHighlighted: line.shape != nil && line.shape == highlighted,
                                   hasKeyboard: keyboard?.line == line.id, takesKeyboard: keyboard != nil,
                                   toggle: { toggle(line.id) }, pick: { if let shape = line.shape { onPick(shape) } else { toggle(line.id) } })
                            .id(line.id)
                    }
                }
            }
            .onChange(of: keyboard?.line) { _, line in
                if let line { scroll.scrollTo(line) }
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
            let first = lines.first { $0.shape != nil && $0.shape == highlighted } ?? lines.first
            keyboard.line = first?.id
            keyboard.rowName = first?.name
            keyboard.isWaiting = false
        }
    }

    /// A key on the line with the keyboard.
    private static func step(_ key: OutlineKey, in lines: [OutlineLine], keyboard: OutlineKeyboard, toggle: (OutlineLineID) -> Void) {
        guard let focused = keyboard.line, let index = lines.firstIndex(where: { $0.id == focused }) else { return }
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
        case .activate:
            // A row's is the host's to pick; a section's row opens or closes.
            if line.shape == nil, line.isExpandable { toggle(line.id) }
        }
        if let next {
            keyboard.line = next.id
            keyboard.rowName = next.name
        }
    }

    private func toggle(_ id: OutlineLineID) {
        if turned.remove(id) == nil { turned.insert(id) }
    }

    /// The lines shown: every top-level row, and under each row expanded (a container's, unless it's
    /// in `turned`; any other row, if it is) the rows nested under it, the rows of the board its
    /// shape owns first (`nestedBoard`), each level front to back (entries, in document order, the
    /// other way round), as in the list; each level's sections after its rows, closed unless turned
    /// (open, unless turned, where it holds the highlighted row, the way you came), as in the list.
    static func lines(of entries: [ContentsEntry], board: BoardID, highlighted: ShapeID?, turned: Set<OutlineLineID>,
                      state: ContentsState) -> [OutlineLine] {
        var lines: [OutlineLine] = []
        lines.reserveCapacity(entries.count)
        /// A level's rows (as listed, back to front), under `parent`'s row (nil: the board's top level).
        func add(_ level: [ContentsEntry], under parent: ShapeID?, depth: Int) {
            let gathered = state.gathered(level)
            for entry in gathered.rows { add(entry, depth: depth) }
            for section in gathered.sections {
                let id = OutlineLineID.section(ContentsSectionKey(section.section, at: parent.map { .under($0) } ?? .top(board)))
                let holdsHighlighted = highlighted.map { highlighted in section.rows.contains { $0.id == highlighted } } ?? false
                let isExpanded = holdsHighlighted != turned.contains(id)
                lines.append(OutlineLine(id: id, shows: .section(section.section, count: section.rows.count), depth: depth,
                                         isExpandable: true, isExpanded: isExpanded))
                guard isExpanded else { continue }
                for entry in section.rows { add(entry, depth: depth + 1) }
            }
        }
        func add(_ entry: ContentsEntry, depth: Int) {
            let board = state.boardToOpen(under: entry)
            let isExpandable = board != nil || entry.children != nil
            let isExpanded = isExpandable && entry.startsExpanded != turned.contains(.row(entry.id))
            lines.append(OutlineLine(id: .row(entry.id), shows: .row(entry), depth: depth, isExpandable: isExpandable, isExpanded: isExpanded))
            guard isExpanded else { return }
            // The rows of the board it owns, then those nested under it where it is: one level, as listed
            // (back to front), so its sections gather both.
            add((entry.children ?? []) + (board.map { state.outline(of: $0) } ?? []), under: entry.id, depth: depth + 1)
        }
        add(entries, under: nil, depth: 0)
        return lines
    }
}

/// One row: indented as deep as it's nested, a disclosure triangle when rows are nested under it,
/// and the row as its kind drew it, a button that picks its shape; or a section's row, a button that
/// opens or closes it.
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

    /// The row's button: a click picks its shape (a section's row: opens or closes it), the keyboard on
    /// the row too.
    @ViewBuilder
    private var row: some View {
        let button = Button(action: pick) {
            label
                .labelStyle(OutlineLabelStyle())
                // The row's colors, as in the list: a borderless button's label is dimmed.
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(name)
        .accessibilityValue(value)
        if takesKeyboard, line.shape != nil {
            // The host's key view has the keyboard, and gives it back once a row is picked. A section's
            // row picks nothing (the menu stays), so its click never takes the keyboard (below).
            button
        } else {
            // With no keyboard to take, a click never takes it (with Full Keyboard Access on, a
            // button's would, and it would fall to the window once the panel closes).
            button.focusable(false)
        }
    }

    /// The list's row, so the two never differ (an outline's rows have no marks), or a section's.
    @ViewBuilder
    private var label: some View {
        switch line.shows {
        case .row(let entry): ContentsRowView(entry: entry)
        case .section(let section, let count): ContentsSectionLabel(section: section, count: count)
        }
    }

    /// What assistive apps read after the row's name: "current path" on the way you came; a section's
    /// row, how many rows it holds.
    private var value: String {
        if case .section(_, let count) = line.shows { return ContentsStyle.sectionCount(count) }
        return isHighlighted ? ContentsStyle.outlineCurrentPath : ""
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
