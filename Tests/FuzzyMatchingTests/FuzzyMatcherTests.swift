import FuzzyMatching
import TestKit

// The matcher every list ranks typed text with: its tiers, the matched characters, and the passes a
// list with many labels makes. Mentions' `@` picker, slash commands and a code editor's completions
// are built on it (MentionsTests, SlashCommandsTests and DetailPanelTests hold each whole).

@MainActor let fuzzyMatcherTests = Suite("Fuzzy matcher", [

    test("the matcher's tiers, with the characters matched, case and diacritics ignored") {
        expectEqual(FuzzyMatcher.match("grocery list", in: "Grocery List"), FuzzyMatch(score: FuzzyRanking.exact, matched: [0..<12]))
        expectEqual(FuzzyMatcher.match("groc", in: "Grocery List"), FuzzyMatch(score: FuzzyRanking.prefix, matched: [0..<4]))
        expectEqual(FuzzyMatcher.match("gro li", in: "Grocery List"), FuzzyMatch(score: FuzzyRanking.wordPrefixes, matched: [0..<3, 8..<10]))
        expectEqual(FuzzyMatcher.match("cery", in: "Grocery List"), FuzzyMatch(score: FuzzyRanking.substring, matched: [3..<7]))
        let subsequence = try require(FuzzyMatcher.match("grcy", in: "Grocery List"))
        expect(subsequence.score > FuzzyRanking.typo && subsequence.score <= FuzzyRanking.subsequence)
        expectEqual(FuzzyMatcher.match("gorcery", in: "Grocery List"), FuzzyMatch(score: FuzzyRanking.typo, matched: [0..<7]))
        expectEqual(FuzzyMatcher.match("CAFÉ", in: "cafe")?.score, FuzzyRanking.exact)
        expectEqual(FuzzyMatcher.match("zebra", in: "Grocery List"), nil)
        expectEqual(FuzzyMatcher.match(" ", in: "Grocery List"), nil)
    },

    test("a list's matches: each label's best tier, the typo's only when the others found fewer than 8") {
        let found = FuzzyMatcher.matches("app", in: ["apple", "pineapple", "banana", "Apricot pie"])
        expectEqual(found.prefix(3).map { $0?.score }, [FuzzyRanking.prefix, FuzzyRanking.substring, nil])
        expectEqual(found[0]?.matched, [0..<3])
        let subsequence = try require(found[3])
        expect(subsequence.score > FuzzyRanking.typo && subsequence.score <= FuzzyRanking.subsequence, "\(subsequence.score)")
        expectEqual(FuzzyMatcher.matches("", in: ["apple", "fig"]).map { $0 == nil }, [true, true], "an empty query matches nothing")
        // "mnago" is "mango" with two letters swapped: a typo, found while few others match.
        expectEqual(FuzzyMatcher.matches("mnago", in: ["mango", "melon"]).map { $0?.score }, [FuzzyRanking.typo, nil])
        let many = Array(repeating: "mn a g o", count: 8) + ["mango"]
        let crowded = FuzzyMatcher.matches("mnago", in: many)
        expectEqual(crowded.prefix(8).compactMap { $0 }.count, 8, "subsequences")
        expectEqual(crowded[8]?.score, nil, "eight found above it: the typo's tier isn't tried")
    },

    test("rank: the tiers over every label a list gives, then the typo's over those left, for a query of four or more") {
        let labels = ["mango", "melon", "mnago pie", "mango", "kiwi"]
        var keys: [UInt32] = [], starts = [0]
        for label in labels {
            _ = FuzzyMatcher.appendKeys(of: label, to: &keys)
            starts.append(keys.count)
        }
        @MainActor func ranked(_ query: String, passingOver skipped: Set<Int> = []) -> [(index: Int, score: Int)] {
            var found: [(index: Int, score: Int)] = []
            FuzzyMatcher.Query(query).withView { q in
                keys.withUnsafeBufferPointer { keys in
                    FuzzyMatcher.rank(q, count: labels.count, wantSpans: false, label: { i in
                        skipped.contains(i) ? nil : UnsafeBufferPointer(rebasing: keys[starts[i]..<starts[i + 1]])
                    }) { index, score, spans in
                        expect(spans.isEmpty, "no spans unless asked")
                        found.append((index, score))
                    }
                }
            }
            return found
        }
        let mnago = ranked("mnago")
        expectEqual(mnago.map(\.index), [2, 0, 3], "the prefix in the first pass, then the typos in the second")
        expectEqual(mnago.map(\.score), [FuzzyRanking.prefix, FuzzyRanking.typo, FuzzyRanking.typo])
        expectEqual(ranked("mnago", passingOver: [0, 2]).map(\.index), [3], "a label the list leaves out is never matched")
        expectEqual(ranked("mna").map(\.index), [2], "under four characters, no typo's pass (mango would be one)")
    },
])
