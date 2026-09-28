import Foundation

/// How well a query matches a label: its score (the tier's, up to `MentionRanking.exact`), and the
/// label's matched characters, as ranges of `Character` offsets, for the picker to set in semibold.
public struct MentionMatch: Hashable, Sendable {
    public let score: Int
    public let matched: [Range<Int>]

    public init(score: Int, matched: [Range<Int>]) {
        self.score = score
        self.matched = matched
    }
}

/// The picker's weights: the tiers a match falls in, and what's added or taken away for the
/// shape (a placeholder label, a recent pick, nearness). Pure, so nonisolated.
public enum MentionRanking {
    /// The label is the query.
    public static let exact = 1000
    /// The label starts with the query.
    public static let prefix = 800
    /// Each word of the query starts a word of the label, in order ("gro li", "Grocery List").
    public static let wordPrefixes = 600
    /// The query is in the label, anywhere.
    public static let substring = 400
    /// The query's characters are in the label in order ("grcy"): at most this, and more for
    /// characters at word starts and in runs, less for gaps (fzf's scoring).
    public static let subsequence = 300
    /// A word of the label starts with the query but for one typo (a character changed, added,
    /// left out, or two swapped), for a query this long or longer that matched nothing better.
    public static let typo = 100
    public static let typoMinimumQuery = 4
    /// The typo pass runs only when the other tiers found fewer than this many shapes.
    public static let typoPassBelow = 8

    /// Taken off a placeholder label ("Untitled Task").
    public static let placeholderPenalty = 50
    /// Added for a recent pick: this for the latest, less for each pick back.
    public static let recentBonus = 100
    /// Added for nearness to the text's shape: this at no distance, half at `nearnessScale` world
    /// units; worked out for the best `nearnessCandidates` only.
    public static let nearnessBonus = 50
    public static let nearnessScale: Double = 1000
    public static let nearnessCandidates = 200

    /// The most shapes a query lists.
    public static let maxMatches = 50
    /// The most an empty query lists in each of its sections.
    public static let recentShown = 4
    public static let nearbyShown = 4
    /// The picks kept for "Recent" and the recent bonus.
    public static let recentKept = 20
}

/// Fuzzy matching of what's typed after `@` against shapes' labels, case and diacritics ignored.
/// Each label takes its best tier: exact, prefix, word prefixes, substring, subsequence, and, for a
/// query of four characters or more that matched nothing above, one typo.
///
/// Labels are folded once (`Label`: lowercased, without diacritics, each scalar marked where it
/// starts a word), and a query once per keystroke (`Query`); matching reads both through buffers,
/// so the catalog keeps every label's keys back to back and a keystroke's two passes over them
/// allocate nothing but what they find.
public enum MentionMatcher {
    /// How `query` matches `label`; nil for not at all.
    public static func match(_ query: String, in label: String) -> MentionMatch? {
        let query = Query(query)
        guard !query.isEmpty else { return nil }
        return match(query, in: Label(label))
    }

    /// How a prepared query matches a prepared label, the typo tier included; nil for not at all.
    static func match(_ query: Query, in label: Label) -> MentionMatch? {
        query.withView { q in
            label.keys.withUnsafeBufferPointer { keys in
                var spans: [Range<Int>] = []
                guard let score = tier(q, keys, &spans, wantSpans: true) ?? typo(q, keys, &spans, wantSpans: true) else { return nil }
                return MentionMatch(score: score, matched: label.characters(spans))
            }
        }
    }

    // MARK: Prepared text

    /// Set on a label's key where a word starts; the rest of the key is the folded scalar.
    static let wordStart: UInt32 = 1 << 31
    static let scalarBits: UInt32 = ~wordStart
    static let space: UInt32 = 0x20

    /// A query folded once per keystroke: lowercased, without diacritics, each run of whitespace one
    /// space, trimmed.
    struct Query {
        let scalars: [UInt32]
        /// Without its spaces: what a subsequence must find.
        let compact: [UInt32]
        /// Each word, as a range of `scalars`.
        let words: [Range<Int>]
        let characterCount: Int

        init(_ text: String) {
            var scalars: [UInt32] = []
            var characters = 0
            for character in text {
                if character.isWhitespace {
                    if let last = scalars.last, last != space { scalars.append(space) }
                    continue
                }
                characters += 1
                scalars.append(contentsOf: fold(character))
            }
            while scalars.last == space { scalars.removeLast() }
            self.scalars = scalars
            compact = scalars.filter { $0 != space }
            var words: [Range<Int>] = [], start = 0
            for (i, scalar) in scalars.enumerated() where scalar == space {
                if i > start { words.append(start..<i) }
                start = i + 1
            }
            if scalars.count > start { words.append(start..<scalars.count) }
            self.words = words
            characterCount = characters
        }

        var isEmpty: Bool { scalars.isEmpty }

        func withView<R>(_ body: (QueryView) throws -> R) rethrows -> R {
            try scalars.withUnsafeBufferPointer { scalars in
                try compact.withUnsafeBufferPointer { compact in
                    try words.withUnsafeBufferPointer { words in
                        try body(QueryView(scalars: scalars, compact: compact, words: words, characterCount: characterCount))
                    }
                }
            }
        }
    }

    /// A query as matching reads it.
    struct QueryView {
        let scalars: UnsafeBufferPointer<UInt32>
        let compact: UnsafeBufferPointer<UInt32>
        let words: UnsafeBufferPointer<Range<Int>>
        let characterCount: Int
    }

    /// A label folded once: each folded scalar, marked where it starts a word (`keys`), and the
    /// `Character` offset in the label it came from (`owners`).
    struct Label {
        let keys: [UInt32]
        let owners: [Int32]

        init(_ text: String) {
            var keys: [UInt32] = [], owners: [Int32] = []
            keys.reserveCapacity(text.utf8.count)
            owners.reserveCapacity(text.utf8.count)
            _ = fold(text, into: &keys) { character, scalars in owners.append(contentsOf: repeatElement(Int32(character), count: scalars)) }
            self.keys = keys
            self.owners = owners
        }

        /// Spans of folded scalars as ranges of the label's characters, merged where they touch.
        func characters(_ spans: [Range<Int>]) -> [Range<Int>] {
            var result: [Range<Int>] = []
            for span in spans where !span.isEmpty {
                let lower = Int(owners[span.lowerBound]), upper = Int(owners[span.upperBound - 1]) + 1
                if let last = result.last, last.upperBound >= lower {
                    result[result.count - 1] = last.lowerBound..<max(last.upperBound, upper)
                } else {
                    result.append(lower..<upper)
                }
            }
            return result
        }
    }

    /// Appends a label's keys to `keys` (the catalog's buffer), and returns how many characters it
    /// has: what `Label` holds, without the owners or an array of its own.
    static func appendKeys(of text: String, to keys: inout [UInt32]) -> Int {
        fold(text, into: &keys, owner: nil)
    }

    /// Folds `text` onto the end of `keys`, marking word starts; tells `owner` the offset of each
    /// character and how many scalars it folded to; returns its length in characters.
    private static func fold(_ text: String, into keys: inout [UInt32], owner: ((_ character: Int, _ scalars: Int) -> Void)?) -> Int {
        let first = keys.count
        var characters = 0
        if text.utf8.allSatisfy({ $0 < 0x80 }) {
            // ASCII, the usual label: one scalar a character, lowercased.
            for byte in text.utf8 {
                keys.append(UInt32(byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : (isSpaceByte(byte) ? 0x20 : byte)))
                owner?(characters, 1)
                characters += 1
            }
        } else {
            for character in text {
                let folded = character.isWhitespace ? [space] : fold(character)
                keys.append(contentsOf: folded)
                owner?(characters, folded.count)
                characters += 1
            }
        }
        var previousIsWord = false
        for i in first..<keys.count {
            let isWord = isWordScalar(keys[i])
            if isWord && !previousIsWord { keys[i] |= wordStart }
            previousIsWord = isWord
        }
        return characters
    }

    // MARK: The tiers

    /// The best tier above the typo's: its score, and, if `wantSpans`, the spans of `L` matched.
    static func tier(_ q: QueryView, _ L: UnsafeBufferPointer<UInt32>, _ spans: inout [Range<Int>], wantSpans: Bool) -> Int? {
        let n = L.count, m = q.scalars.count
        guard n > 0, m > 0, isSubsequence(q.compact, of: L) else { return nil }
        if m <= n, hasPrefix(L, q.scalars, at: 0) {
            if wantSpans { spans = [0..<m] }
            return m == n ? MentionRanking.exact : MentionRanking.prefix
        }
        if wordPrefixes(q, in: L, &spans, wantSpans: wantSpans) { return MentionRanking.wordPrefixes }
        if let start = firstIndex(of: q.scalars, in: L) {
            if wantSpans { spans = [start..<start + m] }
            return MentionRanking.substring
        }
        return subsequence(q.compact, in: L, &spans, wantSpans: wantSpans)
    }

    /// Each query word the start of a label word (the text from there on starting with it), each
    /// after the last.
    private static func wordPrefixes(_ q: QueryView, in L: UnsafeBufferPointer<UInt32>, _ spans: inout [Range<Int>], wantSpans: Bool) -> Bool {
        guard !q.words.isEmpty else { return false }
        var found: [Range<Int>] = []
        var position = 0
        for word in q.words {
            let prefix = UnsafeBufferPointer(rebasing: q.scalars[word])
            var i = position, start = -1
            while i < L.count {
                if L[i] & wordStart != 0, hasPrefix(L, prefix, at: i) {
                    start = i
                    break
                }
                i += 1
            }
            guard start >= 0 else { return false }
            if wantSpans { found.append(start..<start + prefix.count) }
            position = start + prefix.count
        }
        if wantSpans { spans = found }
        return true
    }

    /// fzf's scoring, on the shortest window that holds the query's characters in order: each
    /// matched character scores, more at a word start, the label's start, and in a run; each gap
    /// costs. Scaled into (typo, subsequence].
    private static func subsequence(_ c: UnsafeBufferPointer<UInt32>, in L: UnsafeBufferPointer<UInt32>, _ spans: inout [Range<Int>],
                                    wantSpans: Bool) -> Int? {
        let m = c.count
        guard m > 0 else { return nil }
        // The earliest end, then back from it to the latest start: the shortest window there.
        var j = 0, end = -1
        for i in 0..<L.count where L[i] & scalarBits == c[j] {
            j += 1
            if j == m {
                end = i
                break
            }
        }
        guard end >= 0 else { return nil }
        var start = end
        j = m - 1
        var i = end
        while i >= 0 {
            if L[i] & scalarBits == c[j] {
                if j == 0 {
                    start = i
                    break
                }
                j -= 1
            }
            i -= 1
        }
        var raw = 0, previous = -1
        j = 0
        i = start
        while i <= end, j < m {
            if L[i] & scalarBits == c[j] {
                raw += Score.match
                if L[i] & wordStart != 0 { raw += Score.boundary }
                if i == 0 { raw += Score.first }
                if previous >= 0 {
                    let gap = i - previous - 1
                    if gap == 0 { raw += Score.consecutive } else { raw -= Score.gapStart + (gap - 1) * Score.gapExtension }
                }
                if wantSpans { spans.append(i..<i + 1) }
                previous = i
                j += 1
            }
            i += 1
        }
        let best = m * (Score.match + Score.boundary + Score.consecutive) + Score.first
        let span = MentionRanking.subsequence - MentionRanking.typo
        return MentionRanking.typo + max(1, min(span, Int((Double(max(raw, 0)) / Double(best) * Double(span)).rounded())))
    }

    /// fzf's constants.
    private enum Score {
        static let match = 16
        static let boundary = 8
        static let first = 8
        static let consecutive = 4
        static let gapStart = 3
        static let gapExtension = 1
    }

    /// One typo: a word of the label (from its start on) starting with the query but for one
    /// character changed, added, left out, or two neighbors swapped. Only for a query of
    /// `typoMinimumQuery` characters or more.
    static func typo(_ q: QueryView, _ L: UnsafeBufferPointer<UInt32>, _ spans: inout [Range<Int>], wantSpans: Bool) -> Int? {
        guard q.characterCount >= MentionRanking.typoMinimumQuery else { return nil }
        for start in 0..<L.count where L[start] & wordStart != 0 {
            if let length = prefixLengthWithinOneEdit(q.scalars, L, from: start) {
                if wantSpans { spans = [start..<start + length] }
                return MentionRanking.typo
            }
        }
        return nil
    }

    /// How much of `L` from `start` the query matches as a prefix with at most one edit (Damerau):
    /// nil if it takes more.
    private static func prefixLengthWithinOneEdit(_ Q: UnsafeBufferPointer<UInt32>, _ L: UnsafeBufferPointer<UInt32>, from start: Int) -> Int? {
        let available = L.count - start
        var k = 0
        while k < Q.count, k < available, Q[k] == L[start + k] & scalarBits { k += 1 }
        if k == Q.count { return k }                                   // no edit: a plain prefix
        // What's left of the query from `qi` is a prefix of the label from `li`.
        func rest(_ qi: Int, _ li: Int) -> Int? {
            let count = Q.count - qi
            guard count <= L.count - (start + li) else { return nil }
            for d in 0..<count where Q[qi + d] != L[start + li + d] & scalarBits { return nil }
            return li + count
        }
        if k < available, let length = rest(k + 1, k + 1) { return length }            // changed
        if let length = rest(k + 1, k) { return max(length, k) }                        // added in the query
        if k < available, let length = rest(k, k + 1) { return length }                // left out of the query
        if k + 1 < Q.count, k + 1 < available, Q[k] == L[start + k + 1] & scalarBits, Q[k + 1] == L[start + k] & scalarBits,
           let length = rest(k + 2, k + 2) { return length }                            // two swapped
        return nil
    }

    // MARK: Helpers

    private static func isSpaceByte(_ byte: UInt8) -> Bool { byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D }

    /// A character folded as the matcher reads it: lowercased, without diacritics.
    static func fold(_ character: Character) -> [UInt32] {
        if let ascii = character.asciiValue {
            return [UInt32(ascii >= 0x41 && ascii <= 0x5A ? ascii + 0x20 : ascii)]
        }
        let folded = String(character).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        let scalars = folded.unicodeScalars.map { $0.value & scalarBits }
        return scalars.isEmpty ? [character.unicodeScalars.first!.value] : scalars
    }

    private static func isWordScalar(_ value: UInt32) -> Bool {
        if value < 0x80 {
            return (value >= 0x30 && value <= 0x39) || (value >= 0x61 && value <= 0x7A) || (value >= 0x41 && value <= 0x5A)
        }
        guard let scalar = Unicode.Scalar(value) else { return false }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    private static func isSubsequence(_ c: UnsafeBufferPointer<UInt32>, of L: UnsafeBufferPointer<UInt32>) -> Bool {
        guard !c.isEmpty else { return true }
        var j = 0
        let target = c.count
        for key in L where key & scalarBits == c[j] {
            j += 1
            if j == target { return true }
        }
        return false
    }

    private static func hasPrefix(_ L: UnsafeBufferPointer<UInt32>, _ p: UnsafeBufferPointer<UInt32>, at start: Int) -> Bool {
        guard start + p.count <= L.count else { return false }
        for k in 0..<p.count where L[start + k] & scalarBits != p[k] { return false }
        return true
    }

    private static func firstIndex(of p: UnsafeBufferPointer<UInt32>, in L: UnsafeBufferPointer<UInt32>) -> Int? {
        guard !p.isEmpty, p.count <= L.count else { return nil }
        let first = p[0]
        for start in 0...(L.count - p.count) where L[start] & scalarBits == first && hasPrefix(L, p, at: start) { return start }
        return nil
    }
}
