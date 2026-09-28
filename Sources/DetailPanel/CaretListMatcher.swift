import Foundation

/// How well a query matches a label: its score (the tier's, up to `CaretListRanking.exact`), and the
/// label's matched characters, as ranges of `Character` offsets, for a caret list to set in semibold.
public struct CaretListMatch: Hashable, Sendable {
    public let score: Int
    public let matched: [Range<Int>]

    public init(score: Int, matched: [Range<Int>]) {
        self.score = score
        self.matched = matched
    }
}

/// The tiers a match falls in, and when the typo's is tried: what every caret list ranks typed
/// text by, so the `@` picker and a code editor's completions agree. What a list adds for what it
/// lists (Mentions' recent picks and nearness) is its own. Pure, so nonisolated.
public enum CaretListRanking {
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
    /// A list tries the typo's tier only when the others found fewer than this many labels.
    public static let typoPassBelow = 8
}

/// Fuzzy matching of what's typed (a caret list's query) against labels, case and diacritics
/// ignored. Each label takes its best tier: exact, prefix, word prefixes, substring, subsequence,
/// and, for a query of four characters or more that matched nothing above, one typo.
///
/// Labels are folded once (`Label`: lowercased, without diacritics, each scalar marked where it
/// starts a word), and a query once per keystroke (`Query`); matching reads both through buffers,
/// so a list of many labels (Mentions' catalog) can keep every label's keys back to back
/// (`appendKeys`), and a keystroke's two passes over them (`rank`: `tier`, then `typo`) allocate
/// nothing but what they find.
public enum CaretListMatcher {
    /// How `query` matches `label`; nil for not at all.
    public static func match(_ query: String, in label: String) -> CaretListMatch? {
        let query = Query(query)
        guard !query.isEmpty else { return nil }
        return match(query, in: Label(label))
    }

    /// How `query` matches each of `labels`, index for index, as every list matches what's typed
    /// (`rank`). Nil for a label it doesn't match, and for every label when the query is empty (a
    /// list then shows what it lists as it comes).
    public static func matches(_ query: String, in labels: [String]) -> [CaretListMatch?] {
        let query = Query(query)
        var found = [CaretListMatch?](repeating: nil, count: labels.count)
        guard !query.isEmpty else { return found }
        let folded = labels.map(Label.init)
        // Every label's keys back to back, as a catalog keeps them.
        var keys: [UInt32] = [], starts: [Int] = []
        keys.reserveCapacity(folded.reduce(0) { $0 + $1.keys.count })
        for label in folded {
            starts.append(keys.count)
            keys.append(contentsOf: label.keys)
        }
        starts.append(keys.count)
        query.withView { q in
            keys.withUnsafeBufferPointer { keys in
                rank(q, count: folded.count, wantSpans: true, label: { UnsafeBufferPointer(rebasing: keys[starts[$0]..<starts[$0 + 1]]) }) { index, score, spans in
                    found[index] = CaretListMatch(score: score, matched: folded[index].characters(spans))
                }
            }
        }
        return found
    }

    /// Matches a query against `count` labels, as every caret list does: every tier but the typo's
    /// over each (`tier`), then, if that found fewer than `CaretListRanking.typoPassBelow` and the
    /// query is long enough to have a typo, the typo's over the rest (`typo`). `label` gives the keys
    /// of the label at an index (as `appendKeys` wrote them, in a buffer indexed from 0, as
    /// `UnsafeBufferPointer(rebasing:)` makes one), or nil to pass it over (what a list leaves out:
    /// Mentions' owner, and what its scope doesn't admit); it's asked again for each label the
    /// second pass reads. `found` hears each label matched, its
    /// score and, with `wantSpans`, the spans of its keys matched (else none): the first pass's in
    /// order of index, then the second's. What a list adds to the scores, and how it orders them,
    /// is its own.
    public static func rank(_ q: QueryView, count: Int, wantSpans: Bool, label: (_ index: Int) -> UnsafeBufferPointer<UInt32>?,
                            found: (_ index: Int, _ score: Int, _ spans: [Range<Int>]) -> Void) {
        // Those the first pass matched, in order, as far as the second pass needs them: no more
        // than it runs for.
        var matched: [Int] = [], matches = 0
        var spans: [Range<Int>] = []
        for index in 0..<count {
            guard let keys = label(index) else { continue }
            if wantSpans { spans.removeAll(keepingCapacity: true) }
            guard let score = tier(q, keys, &spans, wantSpans: wantSpans) else { continue }
            if matches < CaretListRanking.typoPassBelow { matched.append(index) }
            matches += 1
            found(index, score, spans)
        }
        guard matches < CaretListRanking.typoPassBelow, q.characterCount >= CaretListRanking.typoMinimumQuery else { return }
        // The labels matched are passed over as the second pass walks by them.
        var next = 0
        for index in 0..<count {
            if next < matched.count, matched[next] == index {
                next += 1
                continue
            }
            guard let keys = label(index) else { continue }
            if wantSpans { spans.removeAll(keepingCapacity: true) }
            guard let score = typo(q, keys, &spans, wantSpans: wantSpans) else { continue }
            found(index, score, spans)
        }
    }

    /// How a prepared query matches a prepared label, the typo tier included; nil for not at all.
    public static func match(_ query: Query, in label: Label) -> CaretListMatch? {
        query.withView { q in
            label.keys.withUnsafeBufferPointer { keys in
                var spans: [Range<Int>] = []
                guard let score = tier(q, keys, &spans, wantSpans: true) ?? typo(q, keys, &spans, wantSpans: true) else { return nil }
                return CaretListMatch(score: score, matched: label.characters(spans))
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
    public struct Query {
        let scalars: [UInt32]
        /// Without its spaces: what a subsequence must find.
        let compact: [UInt32]
        /// Each word, as a range of `scalars`.
        let words: [Range<Int>]
        let characterCount: Int

        public init(_ text: String) {
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

        public var isEmpty: Bool { scalars.isEmpty }

        /// Reads the query through buffers, for `tier` and `typo`.
        public func withView<R>(_ body: (QueryView) throws -> R) rethrows -> R {
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
    public struct QueryView {
        let scalars: UnsafeBufferPointer<UInt32>
        let compact: UnsafeBufferPointer<UInt32>
        let words: UnsafeBufferPointer<Range<Int>>
        /// Its length in characters, whitespace left out: what the typo's tier asks of it.
        public let characterCount: Int
    }

    /// A label folded once: each folded scalar, marked where it starts a word (`keys`), and the
    /// `Character` offset in the label it came from (`owners`).
    public struct Label {
        let keys: [UInt32]
        let owners: [Int32]

        public init(_ text: String) {
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

    /// Appends a label's keys to `keys` (a list's buffer), and returns how many characters it has:
    /// what `Label` holds, without the owners or an array of its own.
    public static func appendKeys(of text: String, to keys: inout [UInt32]) -> Int {
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

    /// The best tier above the typo's for a label's keys (`L`, as `appendKeys` wrote them): its
    /// score, and, if `wantSpans`, the spans of `L` matched.
    static func tier(_ q: QueryView, _ L: UnsafeBufferPointer<UInt32>, _ spans: inout [Range<Int>], wantSpans: Bool) -> Int? {
        let n = L.count, m = q.scalars.count
        guard n > 0, m > 0, isSubsequence(q.compact, of: L) else { return nil }
        if m <= n, hasPrefix(L, q.scalars, at: 0) {
            if wantSpans { spans = [0..<m] }
            return m == n ? CaretListRanking.exact : CaretListRanking.prefix
        }
        if wordPrefixes(q, in: L, &spans, wantSpans: wantSpans) { return CaretListRanking.wordPrefixes }
        if let start = firstIndex(of: q.scalars, in: L) {
            if wantSpans { spans = [start..<start + m] }
            return CaretListRanking.substring
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
        let span = CaretListRanking.subsequence - CaretListRanking.typo
        return CaretListRanking.typo + max(1, min(span, Int((Double(max(raw, 0)) / Double(best) * Double(span)).rounded())))
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
        guard q.characterCount >= CaretListRanking.typoMinimumQuery else { return nil }
        for start in 0..<L.count where L[start] & wordStart != 0 {
            if let length = prefixLengthWithinOneEdit(q.scalars, L, from: start) {
                if wantSpans { spans = [start..<start + length] }
                return CaretListRanking.typo
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
