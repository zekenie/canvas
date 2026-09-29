import CoreGraphics
import Foundation

/// How greeked text is set in lines (`SkeletonTextBars`), in world units: a column's width, a
/// line's height, and where each line's bar is in its line, over the text's x-height.
public struct SkeletonTextMetrics: Hashable, Sendable {
    /// A column's width (as `SkeletonText` counts columns) once words wrap: a line holds the box's
    /// width over it.
    public var advance: CGFloat
    public var lineHeight: CGFloat
    /// How far down its line a line's bar starts, and how tall it is.
    public var barTop: CGFloat
    public var barHeight: CGFloat

    public init(advance: CGFloat, lineHeight: CGFloat, barTop: CGFloat, barHeight: CGFloat) {
        self.advance = advance
        self.lineHeight = lineHeight
        self.barTop = barTop
        self.barHeight = barHeight
    }

    /// A column's share of an em of the system font once its words wrap, for `advance`: calibrated
    /// once against string drawing, which put a dozen typical notes (lists, sentences, a date) of
    /// 16-point text on 55 lines 168 points wide: at 0.52 em a column they count 56, while their
    /// glyphs alone average 0.46 em. A character set a full em wide, two columns, counts 1.04.
    public static let systemFontColumn: CGFloat = 0.52
}

/// A run of greeked text: text, or something set in its line as wide as some columns (a
/// mention's pill), which shows.
public enum SkeletonTextRun: Sendable {
    case text(String)
    case inline(columns: CGFloat)
}

/// A run of a kind's own text, as it's greeked (a mention text's runs).
public protocol SkeletonTextRunConvertible {
    var skeletonTextRun: SkeletonTextRun { get }
}

extension SkeletonTextRun: SkeletonTextRunConvertible {
    public var skeletonTextRun: SkeletonTextRun { self }
}

/// Where text puts its lines, without laying it out: a bar per line, handed over as it's worked out
/// (no array, for `RenderContext.fillSkeletonText`), from the top of `box`, the text's box, as many
/// as it holds. Each paragraph takes as many lines as its columns fill at the metrics' `advance`
/// (as `SkeletonText.columns(of:)` counts them: a CJK character or an emoji two, a mark none), one
/// at least, and a bar each, the box's width, but its last, as long as what's left of it; a
/// paragraph with nothing that shows (none, or spaces) is a blank line. A line feed, a carriage
/// return, or both, ends one; an inline run (a mention's pill) counts its columns, and shows. One
/// pass over the text, as far as the box goes: a paragraph that shows is read only until it fills
/// the lines left, so a shape costs about the same whatever it holds (a paragraph of a million
/// characters, what one of 150 does), and text typed in the app, still the UTF-16 a text view cut
/// it from, is read a chunk at a time, never transcoded. What every kind's greeked paragraphs go
/// by (a note's text, a schema card's description), so they wrap alike.
public struct SkeletonTextBars<Runs: RandomAccessCollection>: Sequence, IteratorProtocol where Runs.Element: SkeletonTextRunConvertible {
    /// First, and apart from the runs: what the text's bytes are read into isn't generic, so its
    /// loops are compiled for them, whatever the runs are.
    private var lines: SkeletonTextLines
    private let runs: Runs
    /// Where the next paragraph starts: a run, and within a text run, `lines.offset`.
    private var run: Runs.Index

    public init(_ runs: Runs, in box: CGRect, metrics: SkeletonTextMetrics) {
        lines = SkeletonTextLines(box: box, metrics: metrics)
        self.runs = runs
        run = runs.startIndex
    }

    public mutating func next() -> CGRect? {
        while lines.hasRoom {
            if lines.needsParagraph {
                guard let paragraph = nextParagraph(filling: lines.room) else { return nil }
                guard lines.begin(paragraph) else { continue }
            }
            return lines.nextBar()
        }
        return nil
    }

    /// The next paragraph's columns and whether any of them shows, read until a line break ends
    /// it, or, once it shows, until it fills `room`, the columns the lines left hold: then nothing
    /// after it can show, and every bar left is the box's width, however long it goes on. Nil once
    /// the text is read.
    private mutating func nextParagraph(filling room: CGFloat) -> SkeletonTextLines.Count? {
        guard !lines.isRead else { return nil }
        var count = SkeletonTextLines.Count()
        while run != runs.endIndex, !count.fills(room) {
            switch runs[run].skeletonTextRun {
            case .inline(let columns):
                count.add(inline: columns)
                lines.afterReturn = false
            case .text(let text):
                if lines.read(text, into: &count, filling: room) { return count }
                lines.offset = 0
            }
            runs.formIndex(after: &run)
        }
        lines.isRead = true
        return count
    }
}

extension SkeletonTextBars where Runs == CollectionOfOne<SkeletonTextRun> {
    /// Plain text's bars.
    public init(_ text: String, in box: CGRect, metrics: SkeletonTextMetrics) {
        self.init(CollectionOfOne(.text(text)), in: box, metrics: metrics)
    }
}

/// The lines of `SkeletonTextBars` as they're handed over, and how a text run is read into a
/// paragraph's columns: nothing here depends on what the runs are.
struct SkeletonTextLines {
    /// The shortest a paragraph's last bar is, in columns: a word of one letter still shows as a
    /// bar rather than a dot.
    static let shortestLine: CGFloat = 2
    /// The most lines a box is taken to hold, far more than any shape shows, so a box of any
    /// height (a board edited by hand may say 1e21) counts them in an `Int` without trapping.
    static let mostLines: CGFloat = 100_000
    /// How much of text whose UTF-8 isn't at hand is read at a time, in UTF-16 code units, on the
    /// stack.
    static let chunk = 64

    private let box: CGRect
    private let metrics: SkeletonTextMetrics
    /// How many columns a line holds, and how many lines the box does.
    private let perLine: CGFloat
    private let lines: Int
    /// Where the next paragraph starts within the text run being read: a byte of its UTF-8, or a
    /// code unit of its UTF-16 where its UTF-8 isn't at hand.
    var offset = 0
    /// The last line break was a carriage return, so a line feed just after it is part of it.
    var afterReturn = false
    var isRead = false
    /// The next line's number, and what's left of the paragraph being handed over: its lines, and
    /// its last line's columns.
    private var line = 0
    private var left = 0
    private var last: CGFloat = 0

    init(box: CGRect, metrics: SkeletonTextMetrics) {
        self.box = box
        self.metrics = metrics
        perLine = Swift.max(1, box.width / metrics.advance)
        let rows = box.height / metrics.lineHeight
        lines = box.isNull || box.width <= 0 || !(rows >= 1) ? 0 : Int(Swift.min(rows, Self.mostLines))
    }

    var hasRoom: Bool { line < lines }
    /// The paragraph being handed over is done: the next one is read.
    var needsParagraph: Bool { left == 0 }
    /// The columns the lines left hold.
    var room: CGFloat { perLine * CGFloat(lines - line) }

    /// Starts handing over a paragraph's bars; false for one where nothing shows, a blank line.
    mutating func begin(_ paragraph: Count) -> Bool {
        guard paragraph.shows else {
            line += 1
            return false
        }
        // However wide, it takes at most the lines left: read until it filled them, or an inline
        // run past them.
        left = Swift.max(1, Int(Swift.min((paragraph.columns / perLine).rounded(.up), CGFloat(lines - line))))
        last = paragraph.columns - CGFloat(left - 1) * perLine
        return true
    }

    /// The paragraph's next line's bar.
    mutating func nextBar() -> CGRect {
        left -= 1
        let length = left == 0 ? Swift.min(perLine, Swift.max(last, Self.shortestLine)) : perLine
        let bar = CGRect(x: box.minX, y: box.minY + CGFloat(line) * metrics.lineHeight + metrics.barTop,
                         width: box.width * length / perLine, height: metrics.barHeight)
        line += 1
        return bar
    }

    /// Reads a text run from `offset` into `count`: its UTF-8, where it's at hand (a string made
    /// in Swift, or read from a board), else its UTF-16 (a string a text view made, bridged from
    /// the NSString it cut it from until the board is read again, whose UTF-8 would be transcoded
    /// a byte at a time, 5 to 30 times slower). True once a line break ends the paragraph, with
    /// `offset` just past it.
    mutating func read(_ text: String, into count: inout Count, filling room: CGFloat) -> Bool {
        if let ended = text.utf8.withContiguousStorageIfAvailable({ read(utf8: $0, into: &count, filling: room) }) { return ended }
        return read(utf16: text as NSString, into: &count, filling: room)
    }

    /// A string's UTF-8, which is well formed: a byte at a time while it's ASCII, else a scalar,
    /// as long as its first byte says.
    private mutating func read(utf8 bytes: UnsafeBufferPointer<UInt8>, into count: inout Count, filling room: CGFloat) -> Bool {
        var i = offset
        while i < bytes.count {
            let byte = bytes[i]
            if byte < 0x80 {
                i += 1
                if ends(at: byte, &count) {
                    offset = i
                    return true
                }
            } else {
                let length = byte < 0xE0 ? 2 : byte < 0xF0 ? 3 : 4
                var value = UInt32(byte & (0xFF >> (length + 1)))
                for next in i + 1..<Swift.min(i + length, bytes.count) { value = value << 6 | UInt32(bytes[next] & 0x3F) }
                i += length
                add(Unicode.Scalar(value) ?? "\u{FFFD}", &count)
            }
            if count.fills(room) { return false }
        }
        return false
    }

    /// An NSString's UTF-16, `chunk` code units at a time into a buffer on the stack, a pair of
    /// surrogates a scalar (a pair the chunk's end would split is read with the next chunk) and a
    /// lone one U+FFFD, as Swift reads it.
    private mutating func read(utf16 string: NSString, into count: inout Count, filling room: CGFloat) -> Bool {
        let length = string.length
        return withUnsafeTemporaryAllocation(of: unichar.self, capacity: Self.chunk) { chunk in
            var start = offset
            while start < length {
                var end = Swift.min(start + Self.chunk, length)
                string.getCharacters(chunk.baseAddress!, range: NSRange(location: start, length: end - start))
                if end - start > 1, end < length, UTF16.isLeadSurrogate(chunk[end - start - 1]) { end -= 1 }
                var k = 0
                while k < end - start {
                    let unit = chunk[k]
                    k += 1
                    if unit < 0x80 {
                        if ends(at: UInt8(unit), &count) {
                            offset = start + k
                            return true
                        }
                    } else if UTF16.isLeadSurrogate(unit), k < end - start, UTF16.isTrailSurrogate(chunk[k]) {
                        let value = 0x10000 + (UInt32(unit & 0x3FF) << 10 | UInt32(chunk[k] & 0x3FF))
                        k += 1
                        add(Unicode.Scalar(value) ?? "\u{FFFD}", &count)
                    } else {
                        add(Unicode.Scalar(unit) ?? "\u{FFFD}", &count)
                    }
                    if count.fills(room) { return false }
                }
                start = end
            }
            return false
        }
    }

    /// A character under U+0080: a line feed or a carriage return ends the paragraph (true), but
    /// a line feed just after a carriage return is part of it, and counts nothing; anything else
    /// is a column.
    private mutating func ends(at byte: UInt8, _ count: inout Count) -> Bool {
        let wasReturn = afterReturn
        afterReturn = byte == 0x0D
        guard byte != 0x0A, byte != 0x0D else { return !(byte == 0x0A && wasReturn) }
        count.add(ascii: byte)
        return false
    }

    /// Any other scalar, a column or two, or none.
    private mutating func add(_ scalar: Unicode.Scalar, _ count: inout Count) {
        afterReturn = false
        count.add(scalar)
    }

    /// A paragraph's columns so far, and whether any of them shows.
    struct Count {
        var columns: CGFloat = 0
        var shows = false
        /// The last scalar was a zero-width joiner, so the next is drawn with the one before it (an
        /// emoji sequence is one emoji) and counts nothing, as `SkeletonText` counts.
        var joining = false

        /// Whether it shows and holds `room` columns: every line from here on is one of its own,
        /// full.
        func fills(_ room: CGFloat) -> Bool { shows && columns >= room }

        /// A character under U+0080 but a line break: a column, shown unless it's a space or a
        /// control.
        mutating func add(ascii byte: UInt8) {
            if joining { joining = false } else { columns += 1 }
            if byte > 0x20 { shows = true }
        }

        /// Any other scalar: its columns, as `SkeletonText.columns(of:)` counts one.
        mutating func add(_ scalar: Unicode.Scalar) {
            if !joining { columns += CGFloat(SkeletonText.columns(of: scalar)) }
            joining = scalar.value == 0x200D
            shows = true
        }

        /// Something set in the line, `columns` wide, which shows; a width that isn't a number, or
        /// isn't above none, adds none.
        mutating func add(inline columns: CGFloat) {
            if columns > 0 { self.columns += columns }
            shows = true
            joining = false
        }
    }
}
