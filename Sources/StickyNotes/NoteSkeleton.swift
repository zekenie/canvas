import AppKit
import Canvas
import Mentions

// A note zoomed out (`CustomSkeleton`): its yellow, and a bar where each line of its text would
// be, counted from its characters rather than laid out.

extension StickyNoteDefinition: CustomSkeleton {
    /// Its frame in its yellow, square (its 4-point corners are under a point and a half on screen
    /// here) and with no shadow, and its text greeked: two fills, whatever it says. Its outline is
    /// its frame's, as the core draws it.
    func renderSkeleton(_ shape: ShapeRecord<StickyNote>, in context: RenderContext) {
        let frame = shape.frame
        context.cg.setFillColor(NoteStyle.skeletonFill)
        context.cg.fill(frame)
        let box = frame.insetBy(dx: NoteStyle.padding, dy: NoteStyle.padding)
        context.fillSkeletonText(NoteTextBars(shape.props.text, in: box, lineHeight: NoteStyle.lineHeight))
    }
}

extension NoteStyle {
    static let skeletonFill = color.cgColor
}

/// Where a note's text puts its lines, without laying it out: a bar per line, handed over as it's
/// worked out (no array), from the top of `box`, the text's box, as many as it holds. Each
/// paragraph takes as many lines as its columns fill at `advance` (as `SkeletonText.columns(of:)`
/// counts them: a CJK character or an emoji two, a mark none), one at least, and a bar each, the
/// box's width, but its last, as long as what's left of it; a paragraph with nothing that shows
/// (none, or spaces) is a blank line. A mention counts as its pill is wide, by the name it holds
/// (its target isn't looked up). One pass over the text, as far as the box goes: a paragraph that
/// shows is read only until it fills the lines left, so a note costs about the same whatever it
/// holds (a paragraph of a million characters, what one of 150 does), and text typed in the app,
/// still the UTF-16 the text view cut it from, is read a chunk at a time, never transcoded.
struct NoteTextBars: Sequence, IteratorProtocol {
    /// A column's share of a line of the note's 16-point text once its words wrap: the box's
    /// width over this is how many columns a line holds. Calibrated once against string drawing,
    /// which put a dozen typical notes (lists, sentences, a date) on 55 lines 168 points wide: at
    /// 0.52 em a column they count 56, while their glyphs alone average 0.46 em. A character set
    /// a full em wide, two columns, counts 1.04.
    static let advance: CGFloat = 0.52 * 16
    /// Where a line's bar is in its line: where string drawing inks a lowercase x in the note's
    /// text, 6.5 to 15 points down its 19, the x-height.
    static let barTop: CGFloat = 6.5
    static let barHeight: CGFloat = 8.5
    /// The shortest a paragraph's last bar is, in columns: a word of one letter still shows as a
    /// bar rather than a dot.
    static let shortestLine: CGFloat = 2
    /// How many columns of a line a mention's pill takes: its symbol and padding (1.5 em) and its
    /// label, in a smaller font (0.85 em, about 0.39 em a column), at most 16 em (Mentions'
    /// `MentionStyle`), in columns of `advance`.
    static let pill: CGFloat = 3
    static let pillColumn: CGFloat = 0.75
    static let longestPill: CGFloat = 30
    /// The most of a label that counts: past this many columns its pill is `longestPill`.
    static let longestLabel = (longestPill - pill) / pillColumn
    /// The most lines a box is taken to hold, far more than any note shows, so a note of any
    /// height (a board edited by hand may say 1e21) counts them in an `Int` without trapping.
    static let mostLines: CGFloat = 100_000
    /// How much of text whose UTF-8 isn't at hand is read at a time, in UTF-16 code units, on the
    /// stack.
    static let chunk = 64

    private let runs: [MentionRun]
    private let box: CGRect
    private let lineHeight: CGFloat
    /// How many columns a line holds, and how many lines the box does.
    private let perLine: CGFloat
    private let lines: Int
    /// Where the next paragraph starts: a run, and within a text run, a byte of its UTF-8, or a
    /// code unit of its UTF-16 where its UTF-8 isn't at hand.
    private var run = 0
    private var offset = 0
    /// The last line break was a carriage return, so a line feed just after it is part of it.
    private var afterReturn = false
    private var isRead = false
    /// The next line's number, and what's left of the paragraph being handed over: its lines, and
    /// its last line's columns.
    private var line = 0
    private var left = 0
    private var last: CGFloat = 0

    /// `lineHeight` is every line's, in world units, as the note draws its text.
    init(_ text: MentionText, in box: CGRect, lineHeight: CGFloat) {
        runs = text.runs
        self.box = box
        self.lineHeight = lineHeight
        perLine = Swift.max(1, box.width / Self.advance)
        let rows = box.height / lineHeight
        lines = box.isNull || box.width <= 0 || !(rows >= 1) ? 0 : Int(Swift.min(rows, Self.mostLines))
    }

    mutating func next() -> CGRect? {
        while line < lines {
            if left == 0 {
                guard let (columns, shows) = nextParagraph(filling: perLine * CGFloat(lines - line)) else { return nil }
                guard shows else {
                    line += 1
                    continue
                }
                left = Swift.max(1, Int((columns / perLine).rounded(.up)))
                last = columns - CGFloat(left - 1) * perLine
            }
            left -= 1
            let length = left == 0 ? Swift.min(perLine, Swift.max(last, Self.shortestLine)) : perLine
            let bar = CGRect(x: box.minX, y: box.minY + CGFloat(line) * lineHeight + Self.barTop,
                             width: box.width * length / perLine, height: Self.barHeight)
            line += 1
            return bar
        }
        return nil
    }

    /// The next paragraph's columns and whether any of them shows (a mention, or anything but a
    /// space or a control), read until a line feed, a carriage return, or both, ends it, or, once
    /// it shows, until it fills `room`, the columns the lines left hold: then nothing after it
    /// can show, and every bar left is the box's width, however long it goes on. Nil once the
    /// text is read.
    private mutating func nextParagraph(filling room: CGFloat) -> (CGFloat, Bool)? {
        guard !isRead else { return nil }
        var count = Count()
        while run < runs.count, !count.fills(room) {
            switch runs[run] {
            case .mention(_, let label):
                count.add(pillNamed: label)
                afterReturn = false
            case .text(let text):
                if read(text, into: &count, filling: room) { return (count.columns, count.shows) }
                offset = 0
            }
            run += 1
        }
        isRead = true
        return (count.columns, count.shows)
    }

    /// Reads a text run from `offset` into `count`: its UTF-8, where it's at hand (a string made
    /// in Swift, or read from a board), else its UTF-16 (a string the text view made, bridged from
    /// the NSString it cut it from until the board is read again, whose UTF-8 would be transcoded
    /// a byte at a time, 5 to 30 times slower). True once a line break ends the paragraph, with
    /// `offset` just past it.
    private mutating func read(_ text: String, into count: inout Count, filling room: CGFloat) -> Bool {
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
    private struct Count {
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

        /// A mention's pill: its symbol and padding, and its label's columns, read only as far as
        /// they count.
        mutating func add(pillNamed label: String) {
            var named = Count()
            for scalar in label.unicodeScalars {
                guard named.columns < NoteTextBars.longestLabel else { break }
                named.add(scalar)
            }
            columns += Swift.min(NoteTextBars.pill + named.columns * NoteTextBars.pillColumn, NoteTextBars.longestPill)
            shows = true
            joining = false
        }
    }
}
