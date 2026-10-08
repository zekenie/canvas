import AppKit
import Canvas
import TextEditing

/// One name of a row's path: a container's title, or, for one with none, what its kind is called,
/// dimmed and never matched.
public struct JumpToSegment: Hashable, Sendable {
    public var text: String
    /// Whether `text` is its kind's name, for a container nobody titled.
    public var isPlaceholder: Bool
    /// The characters the query matched, as ranges of `Character` offsets in `text`.
    public var matched: [Range<Int>]

    public init(text: String, isPlaceholder: Bool = false, matched: [Range<Int>] = []) {
        self.text = text
        self.isPlaceholder = isPlaceholder
        self.matched = matched
    }
}

/// A shape the palette can pick: its title and where it is (the containers it's inside, outermost
/// first: the boards it's on and the frames it's in, never the root), and how it shows, as the
/// table of contents and the `@` picker show a kind: its symbol, in its tint.
public struct JumpToCandidate {
    public let id: ShapeID
    public let title: String
    /// The title's characters the query matched, as ranges of `Character` offsets.
    public let titleMatched: [Range<Int>]
    public let path: [JumpToSegment]
    public let kindName: String
    public let systemImage: String
    public let tint: NSColor?

    /// The path as the row shows it, its names separated by ›; empty for a shape on the root, in no
    /// container.
    public var pathText: String { path.map(\.text).joined(separator: JumpToStyle.separator) }

    /// The path's matched and dimmed characters as ranges of `Character` offsets in `pathText`.
    var pathRanges: (matched: [Range<Int>], dimmed: [Range<Int>]) {
        var matched: [Range<Int>] = [], dimmed: [Range<Int>] = []
        var offset = 0
        let gap = JumpToStyle.separator.count
        for segment in path {
            let length = segment.text.count
            matched += segment.matched.map { offset + $0.lowerBound..<offset + $0.upperBound }
            if segment.isPlaceholder { dimmed.append(offset..<offset + length) }
            offset += length + gap
        }
        return (matched, dimmed)
    }
}

/// One row of the palette's list: a section's header, a shape that can be picked, or the one row an
/// empty list shows instead (quiet: "No matches"). Only a shape's row can be highlighted and picked.
public enum JumpToRow {
    case header(String)
    case match(JumpToCandidate)
    case empty(String)

    /// The shape a row picks; nil for a header or an empty state.
    public var candidate: JumpToCandidate? {
        if case .match(let candidate) = self { candidate } else { nil }
    }
}

extension JumpToRow {
    /// The rows as the list draws and says them: a shape's symbol in its tint, its title with the
    /// matched characters, its path at the trailing end with its matched characters; said as
    /// "Checkout, Note, in Alpha › Beta, 2 of 7".
    @MainActor
    static func listRows(_ rows: [JumpToRow]) -> [CaretListRow] {
        let shapes = rows.lazy.filter { $0.candidate != nil }.count
        var position = 0
        return rows.map { row in
            switch row {
            case .header(let words): return .header(words)
            case .empty(let words): return .empty(words)
            case .match(let candidate):
                position += 1
                let ranges = candidate.pathRanges
                let path = candidate.pathText
                let place = path.isEmpty ? "" : ", in \(path)"
                return .item(CaretListItem(candidate.title, matched: candidate.titleMatched, symbol: candidate.systemImage, tint: candidate.tint,
                                           detail: path.isEmpty ? nil : path, detailMatched: ranges.matched, detailDimmed: ranges.dimmed,
                                           spoken: "\(candidate.title), \(candidate.kindName)\(place), \(position) of \(shapes)"))
            }
        }
    }
}
