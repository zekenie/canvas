import EmbeddingModels
import Foundation
import TestKit

/// One case of Fixtures/texts.json: the words a note is made of and the text `texts.mjs`'s code makes of them
/// (the owner's one change: a trailing extension of anything that looks like a file name goes, not only
/// ".swift"), except the one marked `deviation`.
private struct TextCase: Decodable {
    var title: String?
    var words: String?
    var text: String
    var deviation: Bool?
}

private func cases() throws -> [TextCase] {
    try JSONDecoder().decode([TextCase].self, from: Data(contentsOf: URL(fileURLWithPath: "Tests/EmbeddingModelsTests/Fixtures/texts.json")))
}

@MainActor let embeddingTextTests = Suite("The text a note is embedded by", [
    test("every case of the fixture, character for character, as texts.mjs writes it") {
        let all = try cases()
        expect(all.count >= 40, "\(all.count) cases")
        for (index, kase) in all.enumerated() {
            let made = EmbeddingText.of(title: kase.title, words: kase.words)
            expect(Array(made.utf8) == Array(kase.text.utf8), "case \(index) (\(kase.title ?? "no title")): \(made.prefix(80)) is not \(kase.text.prefix(80))")
        }
    },
    test("one case is a deviation, a cut that falls inside a surrogate pair, and only that one") {
        let marked = try cases().filter { $0.deviation == true }
        expectEqual(marked.count, 1)
        let kase = try require(marked.first)
        let made = EmbeddingText.of(title: kase.title, words: kase.words)
        expectEqual(made, "Pair. " + String(repeating: "a", count: 899), "the pair's first half is dropped, where JavaScript's slice would keep it")
        expect(made.utf16.count <= 6 + 900)
    },
    test("a title's extension goes when it looks like a file name, and not else") {
        expectEqual(EmbeddingText.of(title: "Draw.swift", words: "x"), "Draw. x")
        expectEqual(EmbeddingText.of(title: "README.md", words: "x"), "README. x")
        expectEqual(EmbeddingText.of(title: "X.swift\n", words: "x"), "X.swift . x", "a newline after it: $ without the m flag matches only at the very end")
        expectEqual(EmbeddingText.of(title: "v1.2", words: "x"), "v1.2. x")
        expectEqual(EmbeddingText.of(title: "Mr. Smith", words: "x"), "Mr. Smith. x")
    },
    test("what JavaScript's \\s is, and what it isn't") {
        expectEqual(EmbeddingText.of(title: "T", words: "a\u{FEFF}b"), "T. a b", "U+FEFF is space")
        expectEqual(EmbeddingText.of(title: "T", words: "a\u{85}b"), "T. a\u{85}b", "U+0085 is not")
        expectEqual(EmbeddingText.of(title: "T", words: "\u{FEFF}a\u{2028}\u{2029}\u{3000}b\u{FEFF}"), "T. a b")
    },
    test("nothing at all is a dot, and the text is the UTF-16's first 900 units of the words") {
        expectEqual(EmbeddingText.of(title: nil, words: nil), ".")
        expectEqual(EmbeddingText.of(title: "", words: ""), ".")
        let long = String(repeating: "a", count: 899) + "z" + "zzz"
        expectEqual(EmbeddingText.of(title: "T", words: long), "T. " + String(repeating: "a", count: 899) + "z")
        // 451 emoji are 902 units, 450 of them are 900: counted in Characters, the cut would be 900 of them.
        let emoji = String(repeating: "\u{1F600}", count: 451)
        expectEqual(EmbeddingText.of(title: nil, words: emoji), ". " + String(repeating: "\u{1F600}", count: 450))
    },
    test("two texts that are canonically equal stay two, and the corpus's own texts are what they were") {
        let precomposed = EmbeddingText.of(title: "caf\u{E9}", words: "same")
        let decomposed = EmbeddingText.of(title: "cafe\u{301}", words: "same")
        expect(Array(precomposed.utf8) != Array(decomposed.utf8), "two texts to the memory")
        expectEqual(precomposed, decomposed, "though String says they are equal, which is why nothing here keys by String")
    },
])
