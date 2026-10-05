import FuzzyMatching
import Foundation
import TestKit

// Find's matcher: folding a text once, with a map back to the original's UTF-16 units where
// folding changed any scalar's length; every exact place a phrase is; the typo's hits, from word
// starts; the cap and the cancellation; and a seeded fuzz against a naive implementation.

private func hits(_ query: String, in text: String) -> [TextHit] { TextSearch(query).hits(in: text) }
private func ranges(_ query: String, in text: String) -> [Range<Int>] { hits(query, in: text).map(\.range) }

@MainActor let textSearchTests = Suite("Text search", [
    // MARK: Folding, and the way back to the original's units

    test("case, accents and width are folded; a hit is in the original's UTF-16 units") {
        expectEqual(ranges("hello", in: "Say HELLO there"), [4..<9])
        expectEqual(ranges("cafe", in: "un café noir"), [3..<7])
        expectEqual(ranges("CAFÉ", in: "un cafe noir"), [3..<7])
        expectEqual(ranges("abc", in: "ＡＢＣ"), [0..<3], "full-width letters are the plain ones")
        expectEqual(ranges("istanbul", in: "İstanbul"), [0..<8], "a dotted capital I")
        expectEqual(ranges("世界", in: "你好世界"), [2..<4], "CJK")
    },

    test("ß folds to two units: a hit maps to the one scalar, and two hits on it are one") {
        expectEqual(ranges("strasse", in: "Straße"), [0..<6])
        expectEqual(ranges("ss", in: "Straße"), [4..<5])
        expectEqual(ranges("s", in: "Straße"), [0..<1, 4..<5], "the second s of ß is the same place")
        expectEqual(ranges("x", in: "ß🙂x"), [3..<4], "offsets after a pair of units in a text that changed lengths")
        expectEqual(ranges("eß", in: "Weiß"), [], "folded `weiss` has no `eß`: the query folds too, to `ess`")
        expectEqual(ranges("eiß", in: "Weiß"), [1..<4])
    },

    test("an accent that's its own scalar folds away, and a hit ending on its letter takes it along") {
        let decomposed = "cafe\u{301} noir"
        expectEqual(decomposed.utf16.count, 10)
        expectEqual(ranges("cafe", in: decomposed), [0..<5])
        expectEqual(ranges("café", in: decomposed), [0..<5], "the query's precomposed é is the same")
        expectEqual(ranges("noir", in: decomposed), [6..<10])
        expectEqual(ranges("e", in: "e\u{301}e\u{302}"), [0..<2, 2..<4])
        expectEqual(FoldedText(decomposed).originalLength, 10)
    },

    test("an emoji is two UTF-16 units, and offsets count them") {
        expectEqual(ranges("b", in: "a🙂b🙂 b"), [3..<4, 7..<8])
        expectEqual(ranges("🙂", in: "a🙂b🙂 b"), [1..<3, 4..<6])
        expectEqual(ranges("a 🙂", in: "a   🙂"), [0..<6])
    },

    test("ASCII keeps no map, and the text's length is its own") {
        let folded = FoldedText("Hello\tWorld\n")
        expectEqual(folded.count, 12)
        expectEqual(folded.originalLength, 12)
        expectEqual(ranges("hello world", in: "Hello\tWorld\n"), [0..<11], "any whitespace is a space")
        expect(FoldedText("").isEmpty)
        expectEqual(hits("a", in: ""), [])
    },

    // MARK: Exact hits

    test("every occurrence, mid-word too, one after another") {
        expectEqual(ranges("ab", in: "ab ab ab"), [0..<2, 3..<5, 6..<8])
        expectEqual(ranges("a", in: "aaa"), [0..<1, 1..<2, 2..<3])
        expectEqual(ranges("aa", in: "aaaa"), [0..<2, 2..<4], "a hit is never inside another")
        expectEqual(ranges("ell", in: "Hello, Jelly"), [1..<4, 8..<11])
        expect(hits("ell", in: "Hello, Jelly").allSatisfy(\.isExact))
    },

    test("a phrase is its words in a row, whitespace runs equal") {
        expectEqual(ranges("foo bar", in: "foo   bar\nbaz"), [0..<9])
        expectEqual(ranges("bar  baz", in: "foo   bar\nbaz"), [6..<13])
        expectEqual(ranges("  foo   bar  ", in: "foo bar"), [0..<7], "the query's edges don't count")
        expectEqual(ranges("foobar", in: "foo bar"), [], "no space, not a hit")
        expectEqual(ranges("foo bar", in: "foo, bar"), [], "a comma between isn't whitespace")
        expectEqual(ranges("o b", in: "foo   bar"), [2..<7], "mid-word at both ends")
    },

    test("nothing to search for finds nothing") {
        expect(TextSearch("").isEmpty)
        expect(TextSearch(" \n ").isEmpty)
        expect(!TextSearch("a").isEmpty)
        expectEqual(hits("", in: "abc"), [])
        expectEqual(hits(" ", in: "a b"), [])
    },

    // MARK: Typos

    test("one edit in a word of four letters or more: swapped, left out, added, changed") {
        let text = "a something else"
        for typo in ["somehting", "somthing", "somethiing", "somethang"] {
            let found = hits(typo, in: text)
            expectEqual(found.map(\.range), [2..<11], typo)
            expectEqual(found.map(\.isExact), [false], typo)
        }
        expectEqual(ranges("somthng", in: text), [], "two edits")
        expectEqual(ranges("xomething", in: text), [], "the first letter is right")
        expectEqual(ranges("omething", in: text), [3..<11], "and one from the middle of a word is exact or nothing")
    },

    test("a word of fewer than four letters is exact") {
        expectEqual(ranges("teh cat", in: "the cat"), [])
        expectEqual(ranges("cut", in: "cat"), [])
        expectEqual(ranges("cat", in: "cat"), [0..<3])
        expect(!TextSearch("the cat").isFuzzy)
        expect(TextSearch("the cart").isFuzzy)
    },

    test("every word of a phrase has its own edit, from a word start, and the last may be a prefix") {
        expectEqual(hits("hello wrold", in: "say hello world now"), [TextHit(range: 4..<15, isExact: false)])
        expectEqual(ranges("helo world", in: "say hello world now"), [4..<15])
        expectEqual(ranges("helo wrd", in: "say hello world now"), [], "wrd is three letters, so exact")
        expectEqual(ranges("helo wrld", in: "say hello world now"), [4..<15], "each word its own edit")
        expectEqual(ranges("hello wor", in: "say hello world now"), [4..<13], "a prefix of the text's word, exact")
        expectEqual(ranges("somthin", in: "something"), [0..<8], "a prefix of the word, with a typo")
        expectEqual(ranges("hello wrold", in: "hello  world"), [0..<12], "a run of spaces between")
        expectEqual(ranges("hello wrold", in: "hello, world"), [0..<12], "a comma after a word is its one edit")
        expectEqual(ranges("hello wrold", in: "hello ,world"), [], "a word can't start at the comma")
        expectEqual(ranges("ello wrold", in: "say hello world now"), [], "from a word start, so not from `ello`")
        expectEqual(ranges("ello world", in: "say hello world now"), [5..<15], "an exact hit is mid-word if it is")
    },

    test("a typo's hit never takes a space of the text for a letter") {
        expectEqual(ranges("abcde", in: "abcd efgh"), [0..<4], "left off its end, not `abcd `")
        expectEqual(ranges("abcdx", in: "abcd efgh"), [0..<4])
    },

    test("a fuzzy hit that overlaps an exact one is dropped; the exact ones come first in order") {
        // `aabcde` is `abcde` with an extra `a`: a typo's hit from 0, over the exact one from 1.
        expectEqual(hits("abcde", in: "aabcde"), [TextHit(range: 1..<6, isExact: true)])
        expectEqual(hits("hello", in: "hello").count, 1, "an exact hit's own fuzzy twin isn't a second")
        expectEqual(hits("something", in: "somehting and something"),
                    [TextHit(range: 0..<9, isExact: false), TextHit(range: 14..<23, isExact: true)])
        expectEqual(hits("somethin", in: "something and somehtin"),
                    [TextHit(range: 0..<8, isExact: true), TextHit(range: 14..<22, isExact: false)])
        expectEqual(hits("color", in: "colour color"), [TextHit(range: 0..<5, isExact: false), TextHit(range: 7..<12, isExact: true)],
                    "colour is color with a letter changed: highlighted as long as the query")
    },

    // MARK: Caps and cancellation

    test("a text has at most 100 hits") {
        let exact = hits("a", in: String(repeating: "a ", count: 150))
        expectEqual(exact.count, TextSearch.hitCap)
        expectEqual(exact.last?.range, 198..<199)
        let fuzzy = hits("somehting", in: String(repeating: "something ", count: 150))
        expectEqual(fuzzy.count, TextSearch.hitCap)
        expect(fuzzy.allSatisfy { !$0.isExact })
        expectEqual(fuzzy.last?.range, 990..<999)
        // The first hundred in text order, whichever kind: a typo's hit before the exact ones.
        let mixed = hits("something", in: "somehting " + String(repeating: "something ", count: 150))
        expectEqual(mixed.count, TextSearch.hitCap)
        expectEqual(mixed.first, TextHit(range: 0..<9, isExact: false))
        expect(mixed.dropFirst().allSatisfy(\.isExact))
    },

    test("cancelling is asked every 64K units, and stops the search with what it had") {
        let long = FoldedText(String(repeating: "x", count: 300_000) + " needle")
        var asked = 0
        let search = TextSearch("needle")
        expectEqual(search.hits(in: long, isCancelled: { asked += 1; return false }).map(\.range), [300_001..<300_007])
        expect(asked >= 4, "\(asked)")
        asked = 0
        expectEqual(search.hits(in: long, isCancelled: { asked += 1; return true }), [])
        expectEqual(asked, 1, "the first no stops it")
        var short = 0
        _ = search.hits(in: FoldedText("a needle"), isCancelled: { short += 1; return false })
        expectEqual(short, 0, "a short text is never interrupted")
        // A cancel in the typo's pass keeps the exact hits found.
        let text = FoldedText("needle " + String(repeating: "x", count: 200_000))
        var calls = 0
        let kept = search.hits(in: text, isCancelled: { calls += 1; return calls > 3 })
        expectEqual(kept.map(\.range), [0..<6])
    },

    test("10,000 texts of a sentence or two search in a keystroke's time, even debug-built") {
        let words = ["note", "something", "board", "plan", "checkout", "alpha", "Gamma", "orders", "Ünïcode", "flow"]
        var random = SplitMix(seed: 7)
        let texts = (0..<10_000).map { _ in
            (0..<Int.random(in: 4...20, using: &random)).map { _ in words.randomElement(using: &random)! }.joined(separator: " ")
        }
        let folded = texts.map(FoldedText.init)
        for query in ["n", "note 5", "somthing", "zzzzq"] {
            let search = TextSearch(query)
            var total = 0
            let time = threadCPUTime { for text in folded { total += search.hits(in: text).count } }
            // Release builds do this in a few milliseconds; a debug build gets a wide margin.
            expect(time < .milliseconds(500), "\(query): \(time), \(total) hits")
        }
    },

    // MARK: Against a naive implementation

    test("seeded texts and queries agree with a naive search, hit for hit") {
        var random = SplitMix(seed: 20_261_005)
        let alphabet = Array("abcdABCD  -,1éÉ")
        let vocabulary = ["abcd", "dcba", "abab", "cab", "bad", "dab", "badcab", "cadabc", "Décaf", "abcdab", "bead", "ÉcÉ"]
        let separators = [" ", " ", "  ", ", ", " - ", "\n"]
        /// A word, now and then with a typo: one letter changed, added, left out, swapped, or the end cut.
        func mutated(_ word: String, using random: inout SplitMix) -> String {
            var chars = Array(word)
            switch Int.random(in: 0..<10, using: &random) {
            case 0 where chars.count > 1: chars.removeLast()
            case 1: chars.insert(alphabet.randomElement(using: &random)!, at: Int.random(in: 0...chars.count, using: &random))
            case 2 where chars.count > 1: chars.remove(at: Int.random(in: 0..<chars.count, using: &random))
            case 3 where chars.count > 1:
                let i = Int.random(in: 0..<(chars.count - 1), using: &random)
                chars.swapAt(i, i + 1)
            case 4: chars[Int.random(in: 0..<chars.count, using: &random)] = alphabet.randomElement(using: &random)!
            case 5 where chars.count > 3: chars.removeLast(Int.random(in: 1...2, using: &random))
            default: break
            }
            return String(chars).trimmingCharacters(in: .whitespaces)
        }
        var failures = 0, exactFound = 0, fuzzyFound = 0
        for round in 0..<4000 {
            var tokens: [String] = []
            for _ in 0..<Int.random(in: 1...8, using: &random) {
                tokens.append(round % 5 == 0 ? String((0..<Int.random(in: 1...6, using: &random)).map { _ in alphabet.randomElement(using: &random)! })
                                             : mutated(vocabulary.randomElement(using: &random)!, using: &random))
            }
            var text = ""
            for (i, token) in tokens.enumerated() { text += (i > 0 ? separators.randomElement(using: &random)! : "") + token }
            let start = Int.random(in: 0..<tokens.count, using: &random)
            let take = Int.random(in: 1...min(3, tokens.count - start), using: &random)
            let words = tokens[start..<(start + take)].map { mutated($0, using: &random) }
            let query = words.joined(separator: Bool.random(using: &random) ? " " : "  ")
            let expected = naiveHits(query, in: text)
            let actual = hits(query, in: text)
            exactFound += actual.filter(\.isExact).count
            fuzzyFound += actual.filter { !$0.isExact }.count
            if expected != actual {
                failures += 1
                if failures <= 3 { expectEqual(actual, expected, "\(query.debugDescription) in \(text.debugDescription)") }
            }
        }
        expectEqual(failures, 0)
        expect(exactFound > 1000 && fuzzyFound > 300, "exact \(exactFound), fuzzy \(fuzzyFound): the texts and queries should meet")
    },

    test("seeded texts of ß, emoji, CJK, combining marks and İ give hits in bounds, whole, and equal to the query's fold") {
        var random = SplitMix(seed: 20_261_007)
        let vocabulary = ["straße", "STRASSE", "café", "cafe\u{301}", "İstanbul", "naïve", "日本語", "東京タワー", "🙂smile", "a🙂b", "résumé", "re\u{301}sume\u{301}",
                          "ＡＢＣ", "Weiß", "👨‍👩‍👧 family", "abcd", "ÅngstrÖm"]
        let folding: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        var exactChecked = 0, fuzzyChecked = 0
        for round in 0..<1500 {
            var tokens: [String] = []
            for _ in 0..<Int.random(in: 1...8, using: &random) { tokens.append(vocabulary.randomElement(using: &random)!) }
            let text = tokens.joined(separator: " ")
            let nsText = text as NSString
            let word = tokens.randomElement(using: &random)!.split(separator: " ").first.map(String.init)!
            var query = word
            let typo = round % 2 == 1 && word.count > 4
            if typo {
                var chars = Array(word)
                chars.swapAt(chars.count - 3, chars.count - 2)
                query = String(chars)
            }
            for hit in hits(query, in: text) {
                expect(hit.range.lowerBound >= 0 && hit.range.lowerBound < hit.range.upperBound && hit.range.upperBound <= nsText.length,
                       "\(hit) in bounds of \(text.debugDescription)")
                guard hit.range.lowerBound >= 0, hit.range.upperBound <= nsText.length, hit.range.lowerBound < hit.range.upperBound else { continue }
                let slice = nsText.substring(with: NSRange(location: hit.range.lowerBound, length: hit.range.count))
                expect(!slice.contains("\u{FFFD}"), "\(hit) splits a pair of units in \(text.debugDescription)")
                if hit.isExact {
                    exactChecked += 1
                    expectEqual(slice.folding(options: folding, locale: nil), query.folding(options: folding, locale: nil),
                                "exact \(hit) of \(query.debugDescription) in \(text.debugDescription)")
                } else {
                    fuzzyChecked += 1
                }
            }
            if !typo { expect(!hits(query, in: text).isEmpty, "\(query.debugDescription) is in \(text.debugDescription)") }
        }
        expect(exactChecked > 1000 && fuzzyChecked > 50, "exact \(exactChecked), fuzzy \(fuzzyChecked)")
    },
])

// MARK: The naive search

/// What the search should find, written the plain way: the text folded a Character at a time (every
/// character of the test's alphabet is one scalar, one unit, folded to one), the exact phrase
/// tried at every offset, and a word matched by trying every end and taking the edit distance of
/// each, where the real search reasons about the one edit's place.
private func naiveHits(_ query: String, in text: String) -> [TextHit] {
    let t = naiveFold(text)
    let words = naiveFold(query).split(separator: " ").map(Array.init)
    guard !words.isEmpty else { return [] }
    let n = t.count

    // Exact: from each offset, the words with a run of spaces between, each letter equal.
    var exact: [Range<Int>] = []
    var i = 0
    while i < n {
        var j = i, ok = true
        for (index, word) in words.enumerated() {
            if index > 0 {
                guard j < n, t[j] == " " else { ok = false; break }
                while j < n, t[j] == " " { j += 1 }
            }
            guard j + word.count <= n, Array(t[j..<(j + word.count)]) == word else { ok = false; break }
            j += word.count
        }
        if ok && j > i {
            exact.append(i..<j)
            i = j
        } else {
            i += 1
        }
    }

    // Fuzzy: from each word start, each word to its best end.
    func isWord(_ c: Character) -> Bool { c.isLetter || c.isNumber }
    func distance(_ a: [Character], _ b: [Character]) -> Int {
        var d = [[Int]](repeating: [Int](repeating: 0, count: b.count + 1), count: a.count + 1)
        for x in 0...a.count { d[x][0] = x }
        for y in 0...b.count { d[0][y] = y }
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        for x in 1...a.count {
            for y in 1...b.count {
                d[x][y] = min(d[x - 1][y] + 1, d[x][y - 1] + 1, d[x - 1][y - 1] + (a[x - 1] == b[y - 1] ? 0 : 1))
                if x > 1, y > 1, a[x - 1] == b[y - 2], a[x - 2] == b[y - 1] { d[x][y] = min(d[x][y], d[x - 2][y - 2] + 1) }
            }
        }
        return d[a.count][b.count]
    }
    func wordEnd(_ word: [Character], at p: Int, isLast: Bool) -> Int? {
        guard p < n, t[p] == word[0] else { return nil }
        let allowed = word.filter(isWord).count >= 4 ? 1 : 0
        var best: (distance: Int, off: Int, end: Int)?
        for end in (p + 1)...n {
            let piece = Array(t[p..<end])
            if piece.contains(" ") { break }
            if !isLast, !(end < n && t[end] == " ") { continue }
            let d = distance(word, piece)
            let off = abs(end - (p + word.count))
            if d <= allowed, best == nil || (d, off) < (best!.distance, best!.off) { best = (d, off, end) }
        }
        return best?.end
    }
    func phraseEnd(from start: Int) -> Int? {
        var p = start
        for (index, word) in words.enumerated() {
            let isLast = index == words.count - 1
            guard let end = wordEnd(word, at: p, isLast: isLast) else { return nil }
            if isLast { return end }
            p = end
            while p < n, t[p] == " " { p += 1 }
        }
        return nil
    }

    var fuzzy: [Range<Int>] = []
    if words.contains(where: { $0.filter(isWord).count >= 4 }) {
        i = 0
        while i < n {
            let midWord = i > 0 && isWord(t[i - 1]) && isWord(t[i])
            if !midWord, t[i] == words[0][0], let end = phraseEnd(from: i) {
                if exact.contains(where: { $0.lowerBound < end && $0.upperBound > i }) {
                    i += 1
                } else {
                    fuzzy.append(i..<end)
                    i = max(end, i + 1)
                }
            } else {
                i += 1
            }
        }
    }
    let all = (exact.map { ($0, true) } + fuzzy.map { ($0, false) }).sorted { $0.0.lowerBound < $1.0.lowerBound }
    return all.prefix(TextSearch.hitCap).map { TextHit(range: $0.0, isExact: $0.1) }
}

private func naiveFold(_ text: String) -> [Character] {
    text.map { character in
        if character.isWhitespace { return " " }
        return Character(String(character).folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil))
    }
}
