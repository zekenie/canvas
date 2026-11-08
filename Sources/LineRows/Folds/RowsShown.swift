import Canvas
import CoreGraphics

// What a shape written as lines shows: every row, or, folded, the rows a fold keeps and a line for what it hides. One list
// (`RowsShown`), made in one place from what the person asked for (`RowFold`), that the kind's layout, its render, its
// parts' rects (so its ports and the arrows bound to its rows) and the "+N ›" line's face all read. A fold is a view: it
// changes no record and is no step.

extension PluginID {
    public static let lineRows: PluginID = "line-rows"
}

/// What the person asked a shape's rows to show (⌃⌘↑, a header closed): never which rows are hidden, so rows added or
/// taken out while it's folded need nothing done. Kept per file on this Mac with its view, never in the file.
public struct RowFold: Hashable, Sendable, Codable {
    /// Folded to the rows its kind marks (a table's keys and unique columns), the first two where it marks none.
    public var toMarked: Bool
    /// Headers closed: the rows under each hidden behind it and its count (a path prefix's group; no kind has headers yet).
    public var closed: Set<PartID>

    public init(toMarked: Bool = false, closed: Set<PartID> = []) {
        self.toMarked = toMarked
        self.closed = closed
    }

    /// Asks for nothing: every row shows.
    public var isEmpty: Bool { !toMarked && closed.isEmpty }
}

/// The lines a folded shape shows, in order, and the line standing for each of its rows: a row shown is its own line, a
/// hidden one the closed header over it or the "+N ›" line. A kind that reads none (nil) shows every row.
public struct RowsShown: Hashable, Sendable {
    public enum Line: Hashable, Sendable {
        /// A row shown, by its index among the shape's rows.
        case row(Int)
        /// A closed header, by its index, and how many rows it hides.
        case header(Int, hiding: Int)
        /// "+N ›": the rows the fold hides that no closed header does.
        case more(Int)
    }

    public let lines: [Line]
    /// The rows' ids, in order.
    public let ids: [PartID]
    /// For each row, by index, the line standing for it.
    let standing: [Int]

    /// How many lines are drawn.
    public var count: Int { lines.count }

    /// The line standing for row `index`: its own, its closed header's, or the "+N ›" line's.
    public func line(standingFor index: Int) -> Int { standing[index] }

    /// The line standing for the row with that id; nil for an id that isn't one of the shape's rows.
    public func line(standingFor id: PartID) -> Int? { ids.firstIndex(of: id).map { standing[$0] } }

    /// Whether row `index` is shown on a line of its own.
    public func isShown(_ index: Int) -> Bool {
        switch lines[standing[index]] {
        case .row(let row), .header(let row, _): row == index
        case .more: false
        }
    }

    /// The row drawn on `line` (a closed header's too); nil for the "+N ›" line.
    public func row(atLine line: Int) -> Int? {
        guard lines.indices.contains(line) else { return nil }
        switch lines[line] {
        case .row(let row), .header(let row, _): return row
        case .more: return nil
        }
    }

    /// The "+N ›" line, and how many rows it stands for; nil where the fold hides none but behind headers.
    public var more: (line: Int, count: Int)? {
        guard let last = lines.last, case .more(let count) = last else { return nil }
        return (lines.count - 1, count)
    }

    /// How many rows are shown on lines of their own.
    public var shownRows: Int { lines.reduce(0) { if case .row = $1 { $0 + 1 } else { $0 } } }

    /// How many rows a fold that keeps none of a kind's marks keeps: the first two (an enum's `pending`, `paid`, "+4 ›").
    public static let unmarkedKept = 2

    /// The lines `rows` show under `fold`: a closed header's rows hidden behind it, then, folded to its marks, the rows
    /// `marked` names (the first `unmarkedKept` where it names none) and a "+N ›" line last for the rest. Rows in `peeked`
    /// show in their place whatever hides them (Find's hits). Nil where nothing is hidden: the shape shows every row.
    public static func make(rows: [FoldRow], fold: RowFold, marked: Set<PartID>, peeked: Set<PartID> = []) -> RowsShown? {
        guard !fold.isEmpty, !rows.isEmpty else { return nil }
        // Which header hides each row (none for a row in no closed group), and which rows the marks keep.
        var hidingHeader = [Int?](repeating: nil, count: rows.count)
        var header: Int?
        for (index, row) in rows.enumerated() {
            if row.isHeader {
                header = fold.closed.contains(row.id) ? index : nil
            } else if let header, !peeked.contains(row.id) {
                hidingHeader[index] = header
            }
        }
        var kept = Set<Int>()
        if fold.toMarked {
            let lines = rows.indices.filter { !rows[$0].isHeader }
            let marks = lines.filter { marked.contains(rows[$0].id) }
            kept = Set(marks.isEmpty ? Array(lines.prefix(unmarkedKept)) : marks)
        }
        var lines: [Line] = [], standing = [Int](repeating: 0, count: rows.count)
        var headerLine: [Int: Int] = [:], hiddenUnder: [Int: Int] = [:], moreRows: [Int] = []
        for index in rows.indices {
            if let header = hidingHeader[index] {
                hiddenUnder[header, default: 0] += 1
                standing[index] = headerLine[header] ?? 0
                continue
            }
            let row = rows[index]
            if row.isHeader {
                headerLine[index] = lines.count
                standing[index] = lines.count
                lines.append(fold.closed.contains(row.id) ? .header(index, hiding: 0) : .row(index))
            } else if !fold.toMarked || kept.contains(index) || peeked.contains(row.id) {
                standing[index] = lines.count
                lines.append(.row(index))
            } else {
                moreRows.append(index)
            }
        }
        for (header, count) in hiddenUnder {
            guard let line = headerLine[header] else { continue }
            lines[line] = .header(header, hiding: count)
        }
        if !moreRows.isEmpty {
            for index in moreRows { standing[index] = lines.count }
            lines.append(.more(moreRows.count))
        }
        guard !moreRows.isEmpty || !hiddenUnder.isEmpty else { return nil }
        return RowsShown(lines: lines, ids: rows.map(\.id), standing: standing)
    }
}

/// What a shape written as lines is laid out by, besides its record: while it's edited, what the session sets (the waiting
/// line, the focused row, a line wider than the shape); folded, the lines it shows. Nothing on a shape that is neither,
/// so a frame pays nothing more.
public enum LineRowsLayout {
    /// Where the waiting line is while it has the caret, an index among the rows (its count: last): the kind lays itself
    /// out a line taller and leaves that line empty, the field's to draw. Nil while a row or the title has the caret.
    public static let waiting = LayoutInputKey<Int>("line-rows-waiting")
    /// The row the caret is in: the kind draws it not at all, since the field draws it as it's typed.
    public static let focused = LayoutInputKey<PartID>("line-rows-focused")
    /// The lines a folded shape shows (`RowsShown`), provided by LineRows from its fold (`RowFolds`): nil for a shape
    /// that shows every row, and while it's edited. Provided, not set, so a commit to a folded shape keeps it folded.
    public static let shown = LayoutInputKey<RowsShown>("line-rows-shown")
    /// How wide the shape is laid out while the line being typed in it is wider than it is (its text, the row's insets
    /// and gutter), provided by LineRows from the session: never narrower than the stored width, nil at rest.
    public static let width = LayoutInputKey<CGFloat>("line-rows-width")

    /// The line row `index` is drawn on while the waiting line is at `waiting` (nil: none): the rows after it a line down.
    public static func line(of index: Int, waiting: Int?) -> Int {
        guard let waiting, index >= waiting else { return index }
        return index + 1
    }
}
