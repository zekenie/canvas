import AppKit

/// One row of a caret list: a section's header, an item that can be picked, or the one row an
/// empty list shows instead (quiet: "No matches"). Only an item's row can be highlighted and
/// picked.
public enum CaretListRow: Equatable {
    case header(String)
    case item(CaretListItem)
    case empty(String)

    /// The item a row picks; nil for a header or an empty state.
    public var item: CaretListItem? {
        if case .item(let item) = self { item } else { nil }
    }
}

/// What an item's row shows, one line: a symbol in its tint, the title with its matched characters
/// in semibold, a symbol after the title (a read-only shape's lock), and a detail at the trailing
/// end, in the secondary color, its matched characters in semibold too. A title cut short ends in "…". What the item is to its list's
/// owner (a shape, a keyword) is the owner's: it knows its items by their rows' indexes.
public struct CaretListItem: Equatable {
    public var title: String
    /// The title's characters the query matched, as ranges of `Character` offsets
    /// (`FuzzyMatch.matched`).
    public var matched: [Range<Int>]
    /// The title's font (a code editor's, say), its matched characters in its bold; nil for the
    /// list's, the system's at `TextEditingStyle.caretListLabelSize`, matched in its semibold.
    public var font: NSFont?
    /// An SF Symbol before the title; nil for none, and no room kept for one.
    public var symbol: String?
    /// The symbol's color; nil for the secondary label's.
    public var tint: NSColor?
    public var detail: String?
    /// The detail's characters the query matched, as ranges of `Character` offsets in `detail`, set
    /// in semibold as the title's are (a path's names, in Jump To). They aren't said: `spoken` is.
    public var detailMatched: [Range<Int>]
    /// The detail's characters set fainter, as ranges of `Character` offsets in `detail`: a path's
    /// untitled container, shown by its kind's name, never matched.
    public var detailDimmed: [Range<Int>]
    /// An SF Symbol right after the title, in the detail's color.
    public var trailingSymbol: String?
    /// What VoiceOver says for the row.
    public var spoken: String

    /// `spoken` nil: the title, then the detail ("type, keyword").
    public init(_ title: String, matched: [Range<Int>] = [], font: NSFont? = nil, symbol: String? = nil, tint: NSColor? = nil,
                detail: String? = nil, detailMatched: [Range<Int>] = [], detailDimmed: [Range<Int>] = [], trailingSymbol: String? = nil, spoken: String? = nil) {
        self.title = title
        self.matched = matched
        self.font = font
        self.symbol = symbol
        self.tint = tint
        self.detail = detail
        self.detailMatched = detailMatched
        self.detailDimmed = detailDimmed
        self.trailingSymbol = trailingSymbol
        self.spoken = spoken ?? detail.map { "\(title), \($0)" } ?? title
    }
}

/// How big a caret list is: its owner's, since each list has its own (the `@` picker's rows are
/// its shapes, taller than a completion's). Its look (insets, fonts, corners) is every list's,
/// `TextEditingStyle`'s. Points, the same at any zoom.
public struct CaretListMetrics: Equatable, Sendable {
    public var width: CGFloat
    public var rowHeight: CGFloat
    /// How many rows show at once: the list scrolls past them, and a page moves this many.
    public var rowsShown: Int
    /// Between the anchor's line and the list.
    public var offset: CGFloat

    public init(width: CGFloat, rowHeight: CGFloat, rowsShown: Int, offset: CGFloat) {
        self.width = width
        self.rowHeight = rowHeight
        self.rowsShown = rowsShown
        self.offset = offset
    }
}

/// A list shown at a text view's caret, while it's open: its rows, and which row is highlighted.
/// It's the model, headless, of every such list in the app (Mentions' `@` picker, a code editor's
/// completions), shown in a `CaretListWindow`. Its owner says what it lists (`setRows`), when it
/// opens and closes, what the query is and what a pick does; the list keeps the highlight, moves
/// it, and says what each command the keys send does to it (`perform`).
@MainActor
public final class CaretList {
    /// What a command the keys send does while the list is open.
    public enum Action: Hashable, Sendable {
        case moveUp, moveDown, pageUp, pageDown, pick, close
    }

    public let metrics: CaretListMetrics
    /// What it lists.
    public private(set) var rows: [CaretListRow] = []
    /// The index in `rows` of the highlighted row, always an item's; nil when none can be picked.
    public private(set) var highlighted: Int?
    /// Called after the rows or the highlight change.
    public var onChange: (@MainActor () -> Void)?

    public init(metrics: CaretListMetrics, rows: [CaretListRow] = []) {
        self.metrics = metrics
        self.rows = rows
        highlighted = rows.firstIndex { $0.item != nil }
    }

    /// Lists `rows`, the first item highlighted.
    public func setRows(_ rows: [CaretListRow]) {
        self.rows = rows
        highlighted = rows.firstIndex { $0.item != nil }
        onChange?()
    }

    /// The highlighted row's item.
    public var highlightedItem: CaretListItem? { highlighted.flatMap { rows[$0].item } }

    /// The indexes of the rows that can be highlighted, in order.
    private var selectable: [Int] { rows.indices.filter { rows[$0].item != nil } }

    /// Highlights a row (the pointer's over it); a header or an empty state highlights nothing new.
    public func highlight(row index: Int) {
        guard rows.indices.contains(index), rows[index].item != nil, highlighted != index else { return }
        highlighted = index
        onChange?()
    }

    /// Moves the highlight `steps` items down (up, if negative): by one it wraps around the ends,
    /// by more (a page) it stops at them.
    public func moveHighlight(by steps: Int) {
        let selectable = selectable
        guard !selectable.isEmpty else { return }
        let current = highlighted.flatMap { selectable.firstIndex(of: $0) } ?? 0
        let next = abs(steps) == 1 ? (current + steps + selectable.count) % selectable.count
            : min(max(current + steps, 0), selectable.count - 1)
        guard selectable[next] != highlighted else { return }
        highlighted = selectable[next]
        onChange?()
    }

    // MARK: Keys

    /// What a text view command does while the list is open, if it takes it: ↑/↓ (and ⌃P/⌃N)
    /// move the highlight, Page Up/Down (and ⌥) by a page, Return and Tab pick, Escape, ⌥⎋ and F5
    /// (`complete:`) close. Every other command (←/→ among them) is the text view's.
    public static func action(for command: Selector) -> Action? {
        switch command {
        case #selector(NSResponder.moveUp(_:)): .moveUp
        case #selector(NSResponder.moveDown(_:)): .moveDown
        case #selector(NSResponder.scrollPageUp(_:)), #selector(NSResponder.pageUp(_:)): .pageUp
        case #selector(NSResponder.scrollPageDown(_:)), #selector(NSResponder.pageDown(_:)): .pageDown
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)): .pick
        case #selector(NSResponder.cancelOperation(_:)), #selector(NSResponder.complete(_:)): .close
        default: nil
        }
    }

    /// Does what a command does to the list: whether the list takes it (the text view then
    /// doesn't run it), and what's left for its owner to carry out, `.pick` or `.close` (nil when
    /// moving the highlight was all). Return and Tab with nothing to pick aren't taken, so they do
    /// what they would without the list; nor is any command the list doesn't know.
    public func perform(_ command: Selector) -> (taken: Bool, action: Action?) {
        guard let action = Self.action(for: command) else { return (false, nil) }
        switch action {
        case .moveUp: moveHighlight(by: -1)
        case .moveDown: moveHighlight(by: 1)
        case .pageUp: moveHighlight(by: -metrics.rowsShown)
        case .pageDown: moveHighlight(by: metrics.rowsShown)
        case .pick: return highlightedItem == nil ? (false, nil) : (true, .pick)
        case .close: return (true, .close)
        }
        return (true, nil)
    }
}
