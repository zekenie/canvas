import Canvas
import CanvasTesting
import Foundation
import Mentions
import TestKit

// One mention, alone (`MentionToken`): a string that is exactly one token, read and written as mention
// text reads and writes it, and draw's shorthand `@[Title]`.

private let a = idA.rawValue.uuidString

@MainActor let tokenTests = Suite("Tokens", [
    test("a whole token reads, its label unescaped, its id as written") {
        let read = MentionToken.read("@[Ann Lee](shape:\(a))")
        expectEqual(read?.id, idA)
        expectEqual(read?.label, "Ann Lee")
        let escaped = MentionToken.read("@[a\\]b\\\\c](shape:\(a))")
        expectEqual(escaped?.label, "a]b\\c")
        let lower = MentionToken.read("@[x](shape:\(a.lowercased()))")
        expectEqual(lower?.id, idA, "an agent's lowercase id is the same shape")
        expectEqual(MentionToken.read("@[](shape:\(a))")?.label, "", "a blank label is a token")
    },

    test("anything that is not exactly one token is nil") {
        let token = "@[Ann](shape:\(a))"
        expectEqual(MentionToken.read("see " + token) == nil, true, "text before")
        expectEqual(MentionToken.read(token + " ") == nil, true, "text after")
        expectEqual(MentionToken.read(token + token) == nil, true, "two tokens")
        expectEqual(MentionToken.read("\\" + token) == nil, true, "an escaped opening")
        expectEqual(MentionToken.read("@[Ann](Shape:\(a))") == nil, true, "a look-alike in another case")
        expectEqual(MentionToken.read("@[An\nn](shape:\(a))") == nil, true, "a line break in the label")
        expectEqual(MentionToken.read("") == nil, true)
        expectEqual(MentionToken.read("Ann Lee") == nil, true)
        expectEqual(MentionToken.read("@[](shape:\(a.dropLast()))") == nil, true, "a 46-byte near miss")
        expectEqual(MentionToken.read("@[x](shape:not-a-uuid-not-a-uuid-not-a-uuid-xxx)") == nil, true)
    },

    test("write is canonical: the label escaped, a line break a space, the id uppercase; read gives it back") {
        expectEqual(MentionToken.write(idA, label: "a]b\\c"), "@[a\\]b\\\\c](shape:\(a))")
        expectEqual(MentionToken.write(idA, label: "two\nlines"), "@[two lines](shape:\(a))")
        for label in ["Ann Lee", "a]b", "\\", "@[x]", "Café ☕️", "", "(shape:\(a))"] {
            let written = MentionToken.write(idB, label: label)
            expectEqual(MentionToken.read(written)?.id, idB, label)
            expectEqual(MentionToken.read(written)?.label, label, label)
        }
    },

    test("read agrees with the grammar on random strings: exactly one mention run and nothing else") {
        var rng = SplitMix(seed: 0x70CE)
        let alphabet = Array("ab @[]()\\:shape\n-0123456789ABCDEF")
        for _ in 0..<10_000 {
            var string = ""
            if Bool.random(using: &rng) { string += String((0..<Int.random(in: 0...4, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }) }
            if Int.random(in: 0..<4, using: &rng) > 0 { string += MentionToken.write(Bool.random(using: &rng) ? idA : idB, label: String((0..<Int.random(in: 0...4, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })) }
            if Bool.random(using: &rng) { string += String((0..<Int.random(in: 0...3, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! }) }
            let runs = MentionText(stored: string).runs
            if case .mention(let id, let label)? = runs.first, runs.count == 1 {
                let read = MentionToken.read(string)
                expectEqual(read?.id, id, string)
                expectEqual(read?.label, label, string)
            } else {
                expectEqual(MentionToken.read(string) == nil, true, string)
            }
        }
    },

    test("the shorthand is the title of a string that is exactly @[Title]") {
        expectEqual(MentionToken.shorthand("@[Ann Lee]"), "Ann Lee")
        expectEqual(MentionToken.shorthand("@[a\\]b]"), "a]b")
        expectEqual(MentionToken.shorthand("@[a\\\\b]"), "a\\b")
        expectEqual(MentionToken.shorthand("@[Ann](shape:\(a))"), nil, "a full token")
        expectEqual(MentionToken.shorthand("see @[Ann]"), nil)
        expectEqual(MentionToken.shorthand("@[Ann] there"), nil)
        expectEqual(MentionToken.shorthand("@[Ann]@[Bo]"), nil, "two of them")
        expectEqual(MentionToken.shorthand("\\@[Ann]"), nil)
        expectEqual(MentionToken.shorthand("@[An\nn]"), nil)
        expectEqual(MentionToken.shorthand("@["), nil)
        expectEqual(MentionToken.shorthand("@[Ann"), nil)
        expectEqual(MentionToken.shorthand("@[Ann\\]"), nil, "the last bracket is escaped")
        expectEqual(MentionToken.shorthand(""), nil)
    },
])
