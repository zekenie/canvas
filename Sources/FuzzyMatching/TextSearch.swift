import Foundation

/// A place a search found in a text: a range of the text's UTF-16 units (an `NSRange`'s units, so
/// a text view's, a layout manager's and `NSString`'s), and whether the text there is the query's
/// as typed, folded (`isExact`), or a typo's.
public struct TextHit: Hashable, Sendable {
    public let range: Range<Int>
    public let isExact: Bool

    public init(range: Range<Int>, isExact: Bool) {
        self.range = range
        self.isExact = isExact
    }
}

/// A text folded once, for searching it again for each keystroke: lowercased, without diacritics,
/// half- and full-width forms made one, each whitespace character a plain space, as the matcher
/// folds a label, but one Unicode scalar at a time (a decomposed `e` and acute accent folds to
/// `e`, as the one scalar `é` does), into UTF-16 units. A hit in the folded units is mapped back
/// to the original's units through a table kept only if folding changed any scalar's length (`ß`
/// folds to two units, a combining mark to none): in the usual text, ASCII, there's nothing to
/// keep. Immutable and `Sendable`: an index holds them, a search on another thread reads them.
public struct FoldedText: Sendable {
    let units: [UInt16]
    /// For each folded unit, the original units of the scalar it came from (a mark folded away
    /// belongs to the scalar before it, so a hit that ends there takes the mark along); nil when
    /// every scalar folded to as many units as it had, so folded offsets are the original's.
    let sources: Sources?
    /// The original's length in UTF-16 units.
    public let originalLength: Int

    struct Sources: Sendable {
        let starts: [Int32]
        let ends: [Int32]
    }

    public init(_ text: String) {
        if let ascii = FoldedText.foldASCII(text) {
            units = ascii
            sources = nil
            originalLength = ascii.count
            return
        }
        var units: [UInt16] = []
        var starts: [Int32] = [], ends: [Int32] = []
        units.reserveCapacity(text.utf8.count)
        var identity = true
        var offset = 0
        var folded: [UInt32: [UInt16]] = [:]
        var dropped: [String: Bool] = [:]
        // The scalar before a combining mark, and the marks since: what Foundation folds as one.
        var cluster = ""
        for scalar in text.unicodeScalars {
            let length = scalar.value > 0xFFFF ? 2 : 1
            let before = units.count
            let properties = scalar.properties
            if scalar.value < 0x80 {
                units.append(FoldedText.asciiFolded[Int(scalar.value)])
                cluster = String(scalar)
            } else if properties.isWhitespace {
                units.append(0x20)
                cluster = String(scalar)
            } else if properties.generalCategory == .nonspacingMark, !cluster.isEmpty {
                let key = cluster + String(scalar)
                let drop: Bool
                if let known = dropped[key] {
                    drop = known
                } else {
                    drop = FoldedText.fold(key) == FoldedText.fold(cluster)
                    dropped[key] = drop
                }
                if !drop { units.append(contentsOf: FoldedText.scalarFolded(scalar, &folded)) }
                cluster = key
            } else {
                units.append(contentsOf: FoldedText.scalarFolded(scalar, &folded))
                cluster = String(scalar)
            }
            let count = units.count - before
            if count != length { identity = false }
            if count > 0 {
                for _ in 0..<count {
                    starts.append(Int32(truncatingIfNeeded: offset))
                    ends.append(Int32(truncatingIfNeeded: offset + length))
                }
            } else if let last = ends.indices.last {
                ends[last] = Int32(truncatingIfNeeded: offset + length)
            }
            offset += length
        }
        self.units = units
        sources = identity ? nil : Sources(starts: starts, ends: ends)
        originalLength = offset
    }

    /// The folded text's length in units: what a search scans.
    public var count: Int { units.count }

    /// Whether folding left nothing: an empty text, or one of marks alone.
    public var isEmpty: Bool { units.isEmpty }

    /// The original units a range of folded units came from.
    func original(_ range: Range<Int>) -> Range<Int> {
        guard let sources else { return range }
        return Int(sources.starts[range.lowerBound])..<Int(sources.ends[range.upperBound - 1])
    }

    // MARK: Folding

    private static let foldOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]

    /// ASCII folded: lowercased, whitespace a space.
    static let asciiFolded: [UInt16] = (0..<128).map { value -> UInt16 in
        switch value {
        case 0x41...0x5A: return UInt16(value + 0x20)
        case 0x09...0x0D, 0x20: return 0x20
        default: return UInt16(value)
        }
    }

    /// The folded units of an ASCII text, or nil for any other, or one without contiguous bytes.
    private static func foldASCII(_ text: String) -> [UInt16]? {
        text.utf8.withContiguousStorageIfAvailable { bytes -> [UInt16]? in
            var isASCII = true
            let result = [UInt16](unsafeUninitializedCapacity: bytes.count) { buffer, count in
                count = 0
                for byte in bytes {
                    guard byte < 0x80 else {
                        isASCII = false
                        return
                    }
                    buffer[count] = asciiFolded[Int(byte)]
                    count += 1
                }
            }
            return isASCII ? result : nil
        } ?? nil
    }

    private static func fold(_ string: String) -> String {
        string.folding(options: foldOptions, locale: nil)
    }

    /// One scalar folded alone (`cache` keeps what it's folded to), as itself if folding leaves
    /// nothing.
    private static func scalarFolded(_ scalar: Unicode.Scalar, _ cache: inout [UInt32: [UInt16]]) -> [UInt16] {
        if let known = cache[scalar.value] { return known }
        let result = Array(fold(String(scalar)).utf16)
        let units = result.isEmpty ? Array(String(scalar).utf16) : result
        cache[scalar.value] = units
        return units
    }
}

/// Find's matcher: a query, a phrase of words, searched for in folded texts. The hits, in text
/// order, are every place the query's text is (the query folded, whitespace runs equal to one
/// another, mid-word included, one hit never inside another), and then where it would be but for
/// a typo: starting at a word's start (not mid-word), each word of the query of four letters or
/// more taking one edit (a letter changed, added, left out, or two neighbors swapped, as the
/// matcher's typo tier; the first letter of every word right), shorter words exact, and the last
/// word a prefix of the text's word (typing mid-word keeps its hits). Words are separated by
/// whitespace in the text as in the query. A fuzzy hit that overlaps an exact one is dropped. A text
/// has at most `hitCap` hits, and the search stops looking for more there.
///
/// Prepare the query once per keystroke (`init`) and each text once (`FoldedText`); `hits(in:)`
/// then allocates only its hits and the ranges it finds on the way (a text with none allocates nothing). Pure, `Sendable`, nonisolated: it runs on any thread, and
/// checks `isCancelled` every `cancellationInterval` units of a text, so one long text can't hold
/// up a new keystroke.
public struct TextSearch: Sendable {
    /// The most hits a text gives.
    public static let hitCap = 100
    /// How many units of a text it reads between asking if it's cancelled.
    public static let cancellationInterval = 1 << 16
    /// A word this many letters or longer may have a typo.
    public static let typoMinimumLetters = 4

    /// The query's words, folded.
    let words: [[UInt16]]
    /// The words with one space between each: what an exact hit is.
    let phrase: [UInt16]
    /// Whether the word at an index may have an edit.
    let editable: [Bool]

    public init(_ query: String) {
        let folded = FoldedText(query).units
        var words: [[UInt16]] = []
        var current: [UInt16] = []
        for unit in folded {
            if unit == 0x20 {
                if !current.isEmpty { words.append(current) }
                current = []
            } else {
                current.append(unit)
            }
        }
        if !current.isEmpty { words.append(current) }
        self.words = words
        phrase = Array(words.joined(separator: [0x20]))
        editable = words.map { TextSearch.letters(in: $0) >= TextSearch.typoMinimumLetters }
    }

    /// Whether there's nothing to search for (no word).
    public var isEmpty: Bool { words.isEmpty }

    /// Whether a text can have a typo's hit at all: some word of the query may have an edit.
    public var isFuzzy: Bool { editable.contains(true) }

    /// The hits in a text, in order, at most `hitCap`. If `isCancelled` says so, what was found so
    /// far: the caller, who cancelled, drops it.
    public func hits(in text: FoldedText, isCancelled: () -> Bool = { false }) -> [TextHit] {
        guard !words.isEmpty, !text.isEmpty else { return [] }
        return text.units.withUnsafeBufferPointer { units in
            var exact: [Range<Int>] = []
            guard scanExact(units, into: &exact, isCancelled: isCancelled) else { return merged(exact, [], in: text) }
            var fuzzy: [Range<Int>] = []
            if isFuzzy { _ = scanFuzzy(units, avoiding: exact, into: &fuzzy, isCancelled: isCancelled) }
            return merged(exact, fuzzy, in: text)
        }
    }

    /// The hits in a text: folds it, as `FoldedText` does. For a text searched once; one searched
    /// again keeps its `FoldedText`.
    public func hits(in text: String, isCancelled: () -> Bool = { false }) -> [TextHit] {
        hits(in: FoldedText(text), isCancelled: isCancelled)
    }

    // MARK: Exact

    /// Every place the phrase is, one after another (never overlapping); false if cancelled.
    private func scanExact(_ T: UnsafeBufferPointer<UInt16>, into hits: inout [Range<Int>], isCancelled: () -> Bool) -> Bool {
        let n = T.count, first = phrase[0], space: UInt16 = 0x20
        var i = 0, checkAt = TextSearch.cancellationInterval
        while i + phrase.count <= n {
            if i >= checkAt {
                if isCancelled() { return false }
                checkAt = i + TextSearch.cancellationInterval
            }
            guard T[i] == first else {
                i += 1
                continue
            }
            // The phrase from here, each space of it a run of spaces in the text.
            var j = i, matched = true
            for unit in phrase {
                guard j < n else {
                    matched = false
                    break
                }
                if unit == space {
                    guard T[j] == space else {
                        matched = false
                        break
                    }
                    while j < n, T[j] == space { j += 1 }
                } else {
                    guard T[j] == unit else {
                        matched = false
                        break
                    }
                    j += 1
                }
            }
            if matched {
                hits.append(i..<j)
                if hits.count >= TextSearch.hitCap { return true }
                i = j
            } else {
                i += 1
            }
        }
        return true
    }

    // MARK: Fuzzy

    /// Every place the words are but for typos, from a word start, one after another (never
    /// overlapping), skipping those that overlap an exact hit; false if cancelled.
    private func scanFuzzy(_ T: UnsafeBufferPointer<UInt16>, avoiding exact: [Range<Int>], into hits: inout [Range<Int>],
                           isCancelled: () -> Bool) -> Bool {
        let n = T.count, first = words[0][0]
        var i = 0, checkAt = TextSearch.cancellationInterval, behind = 0
        while i < n {
            if i >= checkAt {
                if isCancelled() { return false }
                checkAt = i + TextSearch.cancellationInterval
            }
            guard T[i] == first, TextSearch.isWordBoundary(T, i), let end = matchWords(T, from: i) else {
                i += 1
                continue
            }
            while behind < exact.count, exact[behind].upperBound <= i { behind += 1 }
            if behind < exact.count, exact[behind].lowerBound < end {
                i += 1
                continue
            }
            hits.append(i..<end)
            if hits.count >= TextSearch.hitCap { return true }
            i = max(end, i + 1)
        }
        return true
    }

    /// Where the query's words end in the text from `start`, each word matched within its edit
    /// and the last a prefix; nil if they don't.
    func matchWords(_ T: UnsafeBufferPointer<UInt16>, from start: Int) -> Int? {
        var p = start
        for (index, word) in words.enumerated() {
            let isLast = index == words.count - 1
            guard let end = TextSearch.matchWord(word, in: T, at: p, edit: editable[index], isLast: isLast) else { return nil }
            if isLast { return end }
            // A run of spaces to the next word.
            p = end
            while p < T.count, T[p] == 0x20 { p += 1 }
        }
        return nil
    }

    /// Where `word` ends in the text from `p`: the text from `p` equal to it, or, with `edit`, one
    /// edit away, and the first letter right; the best end if more than one: no edit, then the
    /// nearest the query's own length, then the shortest. Never over a space of the text: a word is one word
    /// of it. Not the last word: it must end where the text has a space. The last word may end
    /// anywhere, a prefix of the text's.
    static func matchWord(_ Q: [UInt16], in T: UnsafeBufferPointer<UInt16>, at p: Int, edit: Bool, isLast: Bool) -> Int? {
        let n = T.count, length = Q.count
        guard p < n, T[p] == Q[0] else { return nil }
        func valid(_ end: Int) -> Bool { isLast || (end < n && T[end] == 0x20) }
        var k = 1
        while k < length, p + k < n, T[p + k] == Q[k] { k += 1 }
        if k == length, valid(p + length) { return p + length }
        guard edit else { return nil }
        // What's left of the query from `qi` is the text from `ti` on, as far as the query goes.
        func rest(_ qi: Int, _ ti: Int) -> Bool {
            let count = length - qi
            guard p + ti + count <= n else { return false }
            for d in 0..<count where Q[qi + d] != T[p + ti + d] { return false }
            return true
        }
        if k == length {
            // The query is the text's start: one edit is a letter left off its end, or one more.
            if length > 1, valid(p + length - 1) { return p + length - 1 }
            if p + length + 1 <= n, T[p + length] != 0x20, valid(p + length + 1) { return p + length + 1 }
            return nil
        }
        // One edit, by where the text ends: as long as the query (a letter changed, or two swapped),
        // one short (a letter of the query added), one long (a letter of the query left out).
        if p + k < n, T[p + k] != 0x20, rest(k + 1, k + 1), valid(p + length) { return p + length }   // changed
        if k + 1 < length, p + k + 1 < n, Q[k] == T[p + k + 1], Q[k + 1] == T[p + k], rest(k + 2, k + 2), valid(p + length) {
            return p + length                                                                    // two swapped
        }
        if rest(k + 1, k), valid(p + length - 1) { return p + length - 1 }                       // added in the query
        if p + k < n, T[p + k] != 0x20, rest(k, k + 1), valid(p + length + 1) { return p + length + 1 }   // left out of the query
        return nil
    }

    // MARK: Words

    /// Whether `i` isn't between two letters or digits (a word start, or a word's end, as well as
    /// where there's no word).
    static func isWordBoundary(_ T: UnsafeBufferPointer<UInt16>, _ i: Int) -> Bool {
        i == 0 || i >= T.count || !(isWord(T, i - 1) && isWord(T, i))
    }

    /// Whether the scalar that has the unit at `i` is a letter or a digit.
    static func isWord(_ T: UnsafeBufferPointer<UInt16>, _ i: Int) -> Bool {
        let unit = T[i]
        if unit < 0x80 { return (unit >= 0x30 && unit <= 0x39) || (unit >= 0x61 && unit <= 0x7A) || (unit >= 0x41 && unit <= 0x5A) }
        var value = UInt32(unit)
        if unit >= 0xD800, unit <= 0xDBFF, i + 1 < T.count, T[i + 1] >= 0xDC00, T[i + 1] <= 0xDFFF {
            value = 0x10000 + ((value - 0xD800) << 10) + (UInt32(T[i + 1]) - 0xDC00)
        } else if unit >= 0xDC00, unit <= 0xDFFF, i > 0, T[i - 1] >= 0xD800, T[i - 1] <= 0xDBFF {
            value = 0x10000 + ((UInt32(T[i - 1]) - 0xD800) << 10) + (value - 0xDC00)
        }
        guard let scalar = Unicode.Scalar(value) else { return false }
        return scalar.properties.isAlphabetic || scalar.properties.numericType != nil
    }

    /// How many scalars of `word` are letters or digits.
    static func letters(in word: [UInt16]) -> Int {
        word.withUnsafeBufferPointer { buffer in
            var count = 0
            for i in 0..<buffer.count where !(buffer[i] >= 0xDC00 && buffer[i] <= 0xDFFF) && isWord(buffer, i) { count += 1 }
            return count
        }
    }

    // MARK: Hits

    /// The exact and the fuzzy hits as one list in text order, in the text's own units, at most
    /// `hitCap`, none overlapping another (folding a scalar to more units can put two hits on one
    /// scalar: the later is dropped).
    private func merged(_ exact: [Range<Int>], _ fuzzy: [Range<Int>], in text: FoldedText) -> [TextHit] {
        var result: [TextHit] = []
        result.reserveCapacity(min(exact.count + fuzzy.count, TextSearch.hitCap))
        var e = 0, f = 0
        while result.count < TextSearch.hitCap, e < exact.count || f < fuzzy.count {
            let takeExact = f >= fuzzy.count || (e < exact.count && exact[e].lowerBound < fuzzy[f].lowerBound)
            let range = takeExact ? exact[e] : fuzzy[f]
            if takeExact { e += 1 } else { f += 1 }
            let original = text.original(range)
            if let last = result.last, last.range.upperBound > original.lowerBound { continue }
            result.append(TextHit(range: original, isExact: takeExact))
        }
        return result
    }
}
