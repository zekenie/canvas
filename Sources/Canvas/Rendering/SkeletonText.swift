/// How long greeked text is (`RenderContext.fillSkeletonText`), from what it says, without laying
/// it out: in columns, a narrow character's width each, as a terminal counts them, so a bar is as
/// long as its text's columns times the font's average narrow advance (about half an em). What
/// every skeleton that shows text as bars goes by (a note's lines and a schema card's, through
/// `SkeletonTextBars`, and Titles' cover, which sizes its text by them), so
/// text in Japanese or in emoji is about as long greeked as in full, twice Latin text of as many
/// characters, and every kind's bars count alike. Pure, and allocates nothing.
public enum SkeletonText {
    /// A scalar's columns, taken alone: 2 for one set a full em wide (East Asian Wide and
    /// Fullwidth: CJK, kana, Hangul, fullwidth forms) or drawn as an emoji, 0 for one drawn on
    /// another or not at all (combining marks, Hangul's trailing jamo, variation selectors, skin
    /// tones, zero-width spaces and joiners, direction marks), else 1: Markus Kuhn's `wcwidth`,
    /// approximated by the blocks that hold most of each (a mark in a script's own block, a Hebrew
    /// point or a Devanagari vowel sign, counts 1; the symbols among which some are drawn as emoji
    /// ask `isEmojiPresentation`). Everything under U+1100, Latin, Greek, Cyrillic, Arabic and the
    /// Indic scripts, costs a comparison or two.
    public static func columns(of scalar: Unicode.Scalar) -> Int {
        let value = scalar.value
        guard value >= 0x1100 else { return value < 0x300 || value > 0x36F ? 1 : 0 }
        switch value {
        // Hangul's vowel and trailing jamo, combining marks, zero widths, joiners and direction
        // marks, variation selectors, skin tones, tags.
        case 0x1160...0x11FF, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF, 0x20D0...0x20FF, 0xFE20...0xFE2F,
             0x200B...0x200F, 0x2060...0x2064, 0xFEFF,
             0xFE00...0xFE0F, 0xE0100...0xE01EF, 0x1F3FB...0x1F3FF, 0xE0000...0xE007F:
            return 0
        // Hangul's leading jamo; CJK's radicals, punctuation, kana, ideographs, compatibility and
        // fullwidth forms; Yi and more jamo; Hangul syllables; Tangut and the kana supplements;
        // the emoji blocks; the ideographs past the first plane.
        case 0x1100...0x115F, 0x2329...0x232A, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
             0xF900...0xFAFF, 0xFE10...0xFE19, 0xFE30...0xFE6F, 0xFF00...0xFF60, 0xFFE0...0xFFE6,
             0xA000...0xA4CF, 0xA960...0xA97F, 0xAC00...0xD7A3, 0x16FE0...0x1B2FF,
             0x1F200...0x1F2FF, 0x1F300...0x1F64F, 0x1F680...0x1F6FF, 0x1F900...0x1F9FF, 0x1FA70...0x1FAFF,
             0x20000...0x3FFFD:
            return 2
        // Regional indicators, two to a flag.
        case 0x1F1E6...0x1F1FF:
            return 1
        // Symbols, some of them drawn as emoji (a check mark, a star, a coffee).
        case 0x2300...0x2BFF, 0x1F000...0x1F1FF, 0x1F7E0...0x1F7FF:
            return scalar.properties.isEmojiPresentation ? 2 : 1
        default:
            return 1
        }
    }

    /// Text's columns: each scalar's, but a scalar a zero-width joiner joins to the one before it
    /// counts nothing (a family, a rainbow flag: an emoji sequence draws one emoji). One pass over
    /// its UTF-8, a byte at a time while it's ASCII.
    public static func columns(of text: some StringProtocol) -> Int {
        if let columns = text.utf8.withContiguousStorageIfAvailable(columns(ofUTF8:)) { return columns }
        var tally = Tally()
        for scalar in text.unicodeScalars { tally.add(scalar) }
        return tally.columns
    }

    /// Text's columns, counted as `columns(of:)` counts them only until they reach `limit`: what's
    /// past it isn't read (a mention's pill, which stops growing at a length, by the name it holds).
    /// At least `limit`, once they reach it (a wide character may take them past it).
    public static func columns(of text: some StringProtocol, upTo limit: Int) -> Int {
        var tally = Tally()
        for scalar in text.unicodeScalars {
            guard tally.columns < limit else { break }
            tally.add(scalar)
        }
        return tally.columns
    }

    /// A string's UTF-8, which is always well formed: while it's ASCII, as most text is, a byte is
    /// a column; past that, a scalar at a time.
    private static func columns(ofUTF8 bytes: UnsafeBufferPointer<UInt8>) -> Int {
        guard let first = bytes.firstIndex(where: { $0 >= 0x80 }) else { return bytes.count }
        var tally = Tally(columns: first), rest = UnsafeBufferPointer(rebasing: bytes[first...]).makeIterator()
        var parser = Unicode.UTF8.ForwardParser()
        while case .valid(let encoded) = parser.parseScalar(from: &rest) { tally.add(Unicode.UTF8.decode(encoded)) }
        return tally.columns
    }

    /// Columns counted so far, and whether the next scalar is joined to the last.
    private struct Tally {
        var columns = 0
        var joining = false

        mutating func add(_ scalar: Unicode.Scalar) {
            if joining { joining = false } else { columns += SkeletonText.columns(of: scalar) }
            if scalar.value == 0x200D { joining = true }
        }
    }
}
