import Canvas
import Foundation
import TestKit

// How long greeked text is (`SkeletonText`): columns as a terminal counts them, a narrow character
// one, a wide one or an emoji two, a mark or a joiner none.
@MainActor let skeletonTextTests = Suite("Skeleton text", [
    test("a scalar's columns: 1 narrow, 2 wide or an emoji, 0 drawn on another or not at all") {
        let cases: [(Unicode.Scalar, Int)] = [
            ("a", 1), (" ", 1), ("é", 1), ("ж", 1), ("ب", 1), ("क", 1), ("ｱ", 1), ("☺", 1), ("→", 1),
            ("東", 2), ("の", 2), ("メ", 2), ("가", 2), ("Ａ", 2), ("。", 2), ("𠀋", 2), ("🎉", 2), ("🚀", 2), ("🥑", 2),
            ("✅", 2), ("⭐", 2), ("☕", 2), ("⌚", 2),
            ("\u{301}", 0), ("\u{20E3}", 0), ("\u{200B}", 0), ("\u{200D}", 0), ("\u{200F}", 0), ("\u{FE0F}", 0),
            ("\u{E0101}", 0), ("\u{1F3FD}", 0), ("\u{1161}", 0),
            ("\u{1F1EF}", 1),
        ]
        for (scalar, columns) in cases {
            expectEqual(SkeletonText.columns(of: scalar), columns, "U+\(String(scalar.value, radix: 16, uppercase: true))")
        }
    },
    test("text's columns: each scalar's, but what a zero-width joiner joins") {
        let cases: [(String, Int)] = [
            ("", 0), ("Groceries", 9), ("Hello, world", 12), ("café", 4), ("cafe\u{301}", 4), ("Привет", 6),
            ("東京の会議メモ", 14), ("안녕하세요", 10), ("ＡＢＣ", 6), ("ｱｲｳ", 3), ("Plan 東京", 9),
            ("🎉🎉🎉🎉", 8), ("✅ done", 7), ("👍🏽", 2), ("🇯🇵", 2), ("1️⃣", 1), ("👨‍👩‍👧", 2), ("🏳️‍🌈 pride", 8),
            ("a\u{200D}b", 1),
        ]
        for (text, columns) in cases { expectEqual(SkeletonText.columns(of: text), columns, text) }
    },
    test("a substring, and a string bridged from Foundation, count as the string they hold") {
        let text = "Note: ask 東京 about 🎉, then 👨‍👩‍👧 and café"
        let columns = SkeletonText.columns(of: text)
        expectEqual(columns, 41)
        expectEqual(SkeletonText.columns(of: text.dropFirst(6)), columns - 6)
        let bridged = NSMutableString(string: text) as String
        expectEqual(SkeletonText.columns(of: bridged), columns, "read a scalar at a time, where its UTF-8 isn't at hand")
        expectEqual(SkeletonText.columns(of: bridged.dropFirst(6)), columns - 6)
    },
    test("without joiners, text's columns are its scalars', ASCII or not, wherever the first wide one falls") {
        let pool: [Unicode.Scalar] = ["a", "Z", " ", "é", "\u{301}", "東", "가", "🎉", "✅", "☺", "\u{FE0F}", "ж", "Ａ"]
        var generator = SplitMix(seed: 0x736B_656C_6574_6F6E)
        for _ in 0..<200 {
            let scalars = (0..<Int.random(in: 0...24, using: &generator)).map { _ in pool.randomElement(using: &generator)! }
            var text = ""
            text.unicodeScalars.append(contentsOf: scalars)
            expectEqual(SkeletonText.columns(of: text), scalars.reduce(0) { $0 + SkeletonText.columns(of: $1) }, text)
        }
    },
])

/// A deterministic generator, so the fuzz is the same every run.
private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
