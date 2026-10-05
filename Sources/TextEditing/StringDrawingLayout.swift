import AppKit

/// Where string drawing (`NSAttributedString.draw(with:options:)`, `.usesLineFragmentOrigin`) puts
/// a string's characters in a box `width` wide: an offscreen `NSLayoutManager` with the 10.2
/// typesetter breaks lines as string drawing does, and puts each glyph where string drawing does
/// across its line (an alignment the string's paragraph style names included); down the box, lines
/// are stacked as string drawing stacks them, each at least `minimumLineHeight` tall. Laid out once
/// as it's made: keep one per text and width, and a range's rects are a lookup.
///
/// What a highlight over drawn text needs (Find's hits on a note, an arrow's label), and what a
/// text's inline pills are placed by (Mentions, which lays out its pills' stand-ins in their place).
@MainActor
public final class StringDrawingLayout {
    /// One line as string drawing stacks it: its glyphs, its top (from the box's top-left, down is
    /// +y) and its height.
    public struct Line: Equatable {
        public let glyphs: NSRange
        public let top: CGFloat
        public let height: CGFloat
    }

    public let string: NSAttributedString
    public let width: CGFloat
    /// The layout, for what reads more than lines and ranges (a glyph's location on its line).
    public let layoutManager: NSLayoutManager
    /// Every line of the string, however tall the box.
    public let lines: [Line]
    private let storage: NSTextStorage
    private let container: NSTextContainer

    public init(_ string: NSAttributedString, width: CGFloat, minimumLineHeight: CGFloat = 0) {
        self.string = string
        self.width = width
        storage = NSTextStorage(attributedString: string)
        layoutManager = NSLayoutManager()
        layoutManager.typesetterBehavior = .behavior_10_2_WithCompatibility
        container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)
        var lines: [Line] = []
        var top: CGFloat = 0
        layoutManager.enumerateLineFragments(forGlyphRange: NSRange(location: 0, length: layoutManager.numberOfGlyphs)) { rect, _, _, glyphs, _ in
            let height = max(rect.height, minimumLineHeight)
            lines.append(Line(glyphs: glyphs, top: top, height: height))
            top += height
        }
        self.lines = lines
    }

    /// The lines that fit in a box `height` tall (string drawing draws no line past it), and
    /// whether any doesn't.
    public func lines(fitting height: CGFloat) -> (lines: ArraySlice<Line>, isCut: Bool) {
        // A hundredth of a point spare, for a height that rounds a hair short.
        let count = lines.firstIndex { $0.top + $0.height > height + 0.01 } ?? lines.count
        return (lines.prefix(count), count < lines.count)
    }

    /// Where each of `ranges` (UTF-16, the string's) is drawn in a box `height` tall: a rect a line
    /// the range is on, from the box's top-left, as wide as its glyphs there and as tall as the line;
    /// none on a line past the box, and none for an empty range or one past the string's end.
    public func lineRects(of ranges: [NSRange], height: CGFloat = .greatestFiniteMagnitude) -> [[CGRect]] {
        let shown = lines(fitting: height).lines
        return ranges.map { range in
            guard range.length > 0, NSMaxRange(range) <= storage.length else { return [] }
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            var rects: [CGRect] = []
            // From the first line that ends past the range's start, found by halves: a long text's
            // hits each cost the lines they're on.
            var low = shown.startIndex, high = shown.endIndex
            while low < high {
                let middle = (low + high) / 2
                if NSMaxRange(shown[middle].glyphs) <= glyphs.location { low = middle + 1 } else { high = middle }
            }
            for line in shown[low...] {
                guard line.glyphs.location < NSMaxRange(glyphs) else { break }
                let part = NSIntersectionRange(glyphs, line.glyphs)
                guard part.length > 0 else { continue }
                // Across the line, where a selection of the range would be (what follows the
                // paragraph's alignment: `boundingRect(forGlyphRange:)` doesn't, in centered text
                // with this typesetter); down it, string drawing's line.
                var low = CGFloat.infinity, high = -CGFloat.infinity
                layoutManager.enumerateEnclosingRects(forGlyphRange: part, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                                      in: container) { rect, _ in
                    low = min(low, rect.minX)
                    high = max(high, rect.maxX)
                }
                guard low < high else { continue }
                rects.append(CGRect(x: low, y: line.top, width: high - low, height: line.height))
            }
            return rects
        }
    }
}
