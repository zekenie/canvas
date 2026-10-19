import Canvas
import CanvasRPC
import CanvasTesting
import CoreGraphics
import Foundation
import Mentions
import TestKit

// Names in text, as a script writes a mention: `@[name]` for the shape called name, written as the
// whole mention the stored form keeps (`MentionTextFormat.resolvingNames`), and what a text's scope
// admits, read from what its schema says (`registry.mentionAdmission`). Fixtures only: the resolver
// is the test's, and no shape is looked up.

private let a = idA.rawValue.uuidString
private let b = idB.rawValue.uuidString
private let c = idC.rawValue.uuidString

/// A resolver that gives each name an id (`ids`, else a new one, the next of `fresh`) and the label
/// it holds (`labels`, else the name), and keeps the names it was asked, in order.
@MainActor private final class Names {
    var ids: [String: ShapeID] = [:]
    var labels: [String: String] = [:]
    var asked: [String] = []
    private var next: UInt8 = 0

    init(_ ids: [String: ShapeID] = [:], labels: [String: String] = [:]) {
        self.ids = ids
        self.labels = labels
    }

    func resolve(_ name: String) -> (id: ShapeID, label: String) {
        asked.append(name)
        if ids[name] == nil {
            next += 1
            ids[name] = ShapeID(UUID(uuid: (0xF0, next, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 0)))
        }
        return (ids[name]!, labels[name] ?? name)
    }
}

/// `text` with its names written, and the names asked.
@MainActor private func resolved(_ text: String, _ names: Names = Names()) -> (text: String, asked: [String]) {
    let written = MentionTextFormat.resolvingNames(in: text) { names.resolve($0) }
    return (written, names.asked)
}

/// What the stored form reads as, runs and all.
private func runs(_ stored: String) -> [MentionRun] { MentionText(stored: stored).runs }

/// The names the grammar says, read by the scan from every `@[` (quadratic in `@[`s that never
/// close): what the single pass must still agree with, character for character. A backslash run
/// before an `@[` is counted back from it, an even one leaving it unescaped.
@MainActor private func referenceNames(_ string: String, _ names: Names) -> String {
    let at: Unicode.Scalar = "@", open: Unicode.Scalar = "[", close: Unicode.Scalar = "]", backslash: Unicode.Scalar = "\\"
    let head = Array("](shape:".unicodeScalars), word = Array("(shape".unicodeScalars)
    func isLineBreak(_ c: Unicode.Scalar) -> Bool { c == "\n" || c == "\r" }
    let s = Array(string.unicodeScalars)
    /// The label read from `start`, and where its `]` is; nil if it doesn't close on its line.
    func label(from start: Int) -> (String, Int)? {
        var j = start
        var text = String.UnicodeScalarView()
        while j < s.count {
            let c = s[j]
            if c == backslash {
                guard j + 1 < s.count, s[j + 1] == close || s[j + 1] == backslash else { return nil }
                text.append(s[j + 1])
                j += 2
                continue
            }
            if c == close { return (String(text), j) }
            if isLineBreak(c) { return nil }
            text.append(c)
            j += 1
        }
        return nil
    }
    /// Where a whole mention's `](shape:UUID)` ends, if one starts at the `]` at `j`.
    func mentionEnd(at j: Int) -> Int? {
        guard j + head.count + 37 <= s.count, Array(s[j..<j + head.count]) == head else { return nil }
        let id = s[j + head.count..<j + head.count + 36]
        guard s[j + head.count + 36] == ")", id.allSatisfy(\.isASCII), UUID(uuidString: String(String.UnicodeScalarView(id))) != nil else { return nil }
        return j + head.count + 37
    }
    func startsShapeWord(at k: Int) -> Bool {
        guard k + word.count <= s.count else { return false }
        return zip(s[k..<k + word.count], word).allSatisfy { Character($0).lowercased() == Character($1).lowercased() }
    }
    var out = String.UnicodeScalarView()
    var i = 0
    while i < s.count {
        guard s[i] == at, i + 1 < s.count, s[i + 1] == open else {
            out.append(s[i])
            i += 1
            continue
        }
        var n = 0
        while i - 1 - n >= 0, s[i - 1 - n] == backslash { n += 1 }
        guard n % 2 == 0, let (name, end) = label(from: i + 2) else {
            out.append(s[i])
            i += 1
            continue
        }
        if let after = mentionEnd(at: end) {
            out.append(contentsOf: s[i..<after])
            i = after
        } else if startsShapeWord(at: end + 1) {
            out.append(s[i])
            i += 1
        } else {
            let (id, shown) = names.resolve(name)
            out.append(contentsOf: MentionText([.mention(id, label: shown)]).stored.unicodeScalars)
            i = end + 1
        }
    }
    return String(out)
}

@MainActor let nameTests = Suite("Names in mention text", [
    test("@[name] is the whole mention of what the resolver gives: its id in uppercase, the label it holds, the rest of the text as it was") {
        let names = Names(["Owner": idA, "Retry": idB], labels: ["Owner": "The owner"])
        let result = resolved("Ask @[Owner] before @[Retry], then @[Owner] again.", names)
        expectEqual(result.text, "Ask @[The owner](shape:\(a)) before @[Retry](shape:\(b)), then @[The owner](shape:\(a)) again.")
        expectEqual(result.asked, ["Owner", "Retry", "Owner"], "asked in text order, repeats too")
        expectEqual(runs(result.text), [.text("Ask "), .mention(idA, label: "The owner"), .text(" before "), .mention(idB, label: "Retry"),
                                        .text(", then "), .mention(idA, label: "The owner"), .text(" again.")])
        // Every other character stays: words in any script, line breaks, a lone bracket, a literal @[.
        let kept = resolved("日本語 @[Owner]\n[x] a@b.c \\@[not] @ [y]  \u{0}\r\n", Names(["Owner": idA]))
        expectEqual(kept.text, "日本語 @[Owner](shape:\(a))\n[x] a@b.c \\@[not] @ [y]  \u{0}\r\n")
        expectEqual(resolved("@[Owner]", Names(["Owner": idA])).text, "@[Owner](shape:\(a))", "all of it")
        expectEqual(resolved("@[A]@[B]@[C]", Names(["A": idA, "B": idB, "C": idC])).text, "@[A](shape:\(a))@[B](shape:\(b))@[C](shape:\(c))")
    },

    test("what isn't a name stays as written, and the resolver is never asked: a whole mention in any case of id, a look-alike, an escaped @[") {
        for text in [
            "Ask @[Owner](shape:\(a)) first",
            "Ask @[Owner](shape:\(a.lowercased())) first",
            "@[](shape:\(b))",
            "@[x](shape: \(a))",
            "@[x](shape:1234)",
            "@[x](SHAPE:\(a))",
            "@[x](Shape",
            "@[x](shape:\(a.dropLast()))",
            "@[x](shape:\(a.replacingOccurrences(of: "-", with: "x")))",
            "no mention @ here, nor [one], nor @[ alone or a@[",
            "literal \\@[x] and \\\\\\@[y]",
            "a [b] (shape) @(shape:x) c",
            "",
            "plain",
        ] {
            let result = resolved(text)
            expectEqual(result.text, text, text)
            expectEqual(result.asked, [], text)
        }
    },

    test("an escaped @[ is a literal one, and backslashes just before an @[ are doubled, as in the stored form") {
        // An odd run of backslashes escapes the `@[`; an even run is literal backslashes, and the `@[` is a name.
        let odd = resolved("\\@[Owner] and \\\\\\@[Owner]", Names(["Owner": idA]))
        expectEqual(odd.text, "\\@[Owner] and \\\\\\@[Owner]")
        expectEqual(odd.asked, [])
        expectEqual(runs(odd.text), [.text("@[Owner] and \\@[Owner]")])
        let even = resolved("\\\\@[Owner] and \\\\\\\\@[Owner]", Names(["Owner": idA]))
        expectEqual(even.text, "\\\\@[Owner](shape:\(a)) and \\\\\\\\@[Owner](shape:\(a))")
        expectEqual(runs(even.text), [.text("\\"), .mention(idA, label: "Owner"), .text(" and \\\\"), .mention(idA, label: "Owner")])
        expectEqual(even.asked, ["Owner", "Owner"])
        // A name that ends in a backslash before a name's ]: `\\` is a backslash.
        let ending = resolved("@[C:\\\\]", Names(["C:\\": idA]))
        expectEqual(ending.text, "@[C:\\\\](shape:\(a))")
        expectEqual(ending.asked, ["C:\\"])
    },

    test("a name is read as a label is: \\] stands for ], \\\\ for a backslash, it ends at the first ] left, and holds an @[ as any text") {
        let names = Names(["a]b": idA, "x\\y": idB, "a @[b": idC])
        let result = resolved("@[a\\]b] @[x\\\\y] @[a @[b] @[Owner]]", names)
        expectEqual(Array(result.asked.prefix(3)), ["a]b", "x\\y", "a @[b"])
        expectEqual(result.asked.dropFirst(3).first, "Owner", "the first ] ends it, the next is text")
        expect(result.text.hasPrefix("@[a\\]b](shape:\(a)) @[x\\\\y](shape:\(b)) @[a @[b](shape:\(c)) @[Owner]("), result.text)
        expect(result.text.hasSuffix("]"), result.text)
        expectEqual(runs(result.text).first, .mention(idA, label: "a]b"))
        // The label held is escaped as a label is, whatever the name was.
        let held = resolved("@[Owner]", Names(["Owner": idA], labels: ["Owner": "a]b\\c\nd"]))
        expectEqual(held.text, "@[a\\]b\\\\c d](shape:\(a))", "a line break in what's held is a space")
        // A blank name is a name too, for the resolver to refuse or not.
        let blank = resolved("@[] @[  ]", Names(["": idA, "  ": idB]))
        expectEqual(blank.asked, ["", "  "])
        expectEqual(blank.text, "@[](shape:\(a)) @[  ](shape:\(b))")
    },

    test("a name that doesn't close on its line is text: no ], a line break first, a backslash that escapes nothing, the end; the next line's names are read") {
        for text in ["@[Owner", "@[Owner\n]", "@[Owner\r]", "@[Owner\\]", "@[C:\\temp]", "@[Owner\\", "@[", "end @[", "@[a @[b"] {
            let result = resolved(text)
            expectEqual(result.text, text, text.debugDescription)
            expectEqual(result.asked, [], text.debugDescription)
        }
        let lines = resolved("@[Open\nthen @[Owner] here", Names(["Owner": idA]))
        expectEqual(lines.asked, ["Owner"])
        expectEqual(lines.text, "@[Open\nthen @[Owner](shape:\(a)) here")
        let windows = resolved("@[Open\r\n@[Owner]", Names(["Owner": idA]))
        expectEqual(windows.text, "@[Open\r\n@[Owner](shape:\(a))")
        // A name's ] followed by (shape, in any case, is a mention gone wrong; anything else after it isn't.
        for text in ["@[x](shape", "@[x](SHAPE:", "@[x](sHaPe: \(a))"] { expectEqual(resolved(text).asked, [], text) }
        for text in ["@[x] (shape", "@[x]\n(shape", "@[x]shape", "@[x] and (shape:\(a))"] { expectEqual(resolved(text).asked, ["x"], text) }
        expectEqual(resolved("@[x] and (shape:\(a))", Names(["x": idB])).text, "@[x](shape:\(b)) and (shape:\(a))")
    },

    test("what the resolver throws is thrown, with nothing written; one that never throws needs no try") {
        struct Refused: Error, Equatable { let name: String }
        var asked: [String] = []
        do throws(Refused) {
            _ = try MentionTextFormat.resolvingNames(in: "Ask @[Owner] before @[Nobody] and @[Retry]") { name throws(Refused) in
                asked.append(name)
                if name == "Nobody" { throw Refused(name: name) }
                return (idA, name)
            }
            expect(false, "the second name was refused")
        } catch {
            expectEqual(error, Refused(name: "Nobody"))
        }
        expectEqual(asked, ["Owner", "Nobody"], "it stops there")
    },

    test("text with no @[ is returned as it is in one pass over its bytes: the resolver isn't asked, and a long text costs next to nothing") {
        let words = String(repeating: "Some words, a [bracket], an @ sign and a \\ backslash. ", count: 20_000)
        var result = ""
        let elapsed = threadCPUTime { result = resolved(words).text }
        expectEqual(result, words)
        expect(elapsed < .milliseconds(100), "\(words.utf8.count) bytes took \(elapsed)")
    },

    test("names are read in linear time: thousands of @[ that never close, or that all do, on one line or many") {
        for unclosed in [String(repeating: "@[", count: 20_000), String(repeating: "@[x\\", count: 10_000), "@[" + String(repeating: "\\@[", count: 10_000)] {
            var result = ""
            let elapsed = threadCPUTime { result = resolved(unclosed).text }
            expect(elapsed < .milliseconds(250), "\(unclosed.utf8.count) bytes took \(elapsed)")
            expectEqual(result, unclosed)
        }
        let many = String(repeating: "@[Owner] and ", count: 20_000)
        var result = ""
        let elapsed = threadCPUTime { result = resolved(many, Names(["Owner": idA])).text }
        expect(elapsed < .milliseconds(400), "\(many.utf8.count) bytes took \(elapsed)")
        expectEqual(result, String(repeating: "@[Owner](shape:\(a)) and ", count: 20_000))
        // One name closed by the last of thousands of bracketed words reads them all as its own.
        let one = "@[" + String(repeating: "[word ", count: 20_000) + "]"
        let elapsedOne = threadCPUTime { result = resolved(one).text }
        expect(elapsedOne < .milliseconds(250), "\(one.utf8.count) bytes took \(elapsedOne)")
        expectEqual(runs(result).count, 1)
    },

    test("the names of a text's mentions, written for them, make the text with its mentions written whole: 20,000 fuzzed texts") {
        var rng = SplitMix(seed: 0x6E61_6D65_7320_6F6B)
        let alphabet: [Character] = ["@", "[", "]", "(", ")", "\\", "a", " ", "\n", "s", "h", ":", "é"]
        let labelAlphabet = alphabet.filter { $0 != "\n" }
        var failures = 0, withMentions = 0
        for _ in 0..<20_000 {
            var pieces: [MentionRun] = []
            for _ in 0..<Int.random(in: 1...6, using: &rng) {
                if Bool.random(using: &rng) {
                    pieces.append(.text(String((0..<Int.random(in: 0...8, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })))
                } else {
                    let label = String((0..<Int.random(in: 0...4, using: &rng)).map { _ in labelAlphabet.randomElement(using: &rng)! })
                    pieces.append(.mention(ShapeID(UUID(uuid: (UInt8.random(in: 0...255, using: &rng), UInt8.random(in: 0...255, using: &rng), 1, 2, 3, 4, 0x40,
                                                                5, 0x80, 6, 7, 8, 9, 10, 11, 12))), label: label))
                }
            }
            let whole = MentionText(pieces)
            if !whole.mentioned.isEmpty { withMentions += 1 }
            // The same text, each mention written as its name alone.
            var named = whole.stored
            for id in whole.mentioned { named = named.replacingOccurrences(of: "(shape:\(id))", with: "") }
            let labels = whole.runs.compactMap { run -> String? in if case .mention(_, let label) = run { label } else { nil } }
            var asked = 0
            let written = MentionTextFormat.resolvingNames(in: named) { name in
                defer { asked += 1 }
                return asked < labels.count ? (whole.mentioned[asked], name) : (idA, name)
            }
            if written != whole.stored || asked != labels.count {
                failures += 1
                if failures < 4 { expect(false, "\(named.debugDescription) is the names of \(whole.stored.debugDescription), not \(written.debugDescription) (\(asked) asked)") }
            }
            // Text written from its runs has no name in it: it's as it is, and nothing is asked.
            var askedOfWhole = 0
            let again = MentionTextFormat.resolvingNames(in: whole.stored) { name in
                askedOfWhole += 1
                return (idA, name)
            }
            if again != whole.stored || askedOfWhole != 0 {
                failures += 1
                if failures < 4 { expect(false, "\(whole.stored.debugDescription) was read as \(again.debugDescription), asking \(askedOfWhole)") }
            }
        }
        expectEqual(failures, 0)
        expect(withMentions > 15_000, "most texts mention: \(withMentions)")
    },

    test("the single pass reads 20,000 fuzzed strings as the scan from every @[ does: what it asks, in order, and what it writes; and once written, no name is left") {
        var rng = SplitMix(seed: 0x7265_6164_206E_616D)
        let alphabet: [String] = ["@", "[", "]", "(", ")", "\\", "a", " ", "\n", "\r", "@[", "](shape:", "](SHAPE:", "(shape", "\\]", "\\\\", "\\@[", "é",
                                  "@[x]", "@[a b]", a, b.lowercased(), "@[x](shape:\(c))", ")"]
        var failures = 0, named = 0
        for _ in 0..<20_000 {
            var string = ""
            for _ in 0..<Int.random(in: 0...14, using: &rng) { string += alphabet.randomElement(using: &rng)! }
            let fast = Names(), reference = Names()
            let written = MentionTextFormat.resolvingNames(in: string) { fast.resolve($0) }
            let expected = referenceNames(string, reference)
            if written != expected || fast.asked != reference.asked {
                failures += 1
                if failures < 4 { expect(false, "\(string.debugDescription) is \(written.debugDescription) asking \(fast.asked), not \(expected.debugDescription) asking \(reference.asked)") }
            }
            if !fast.asked.isEmpty { named += 1 }
            // Written, there's no name left to write; and a look-alike or an unclosed one is where it was.
            let again = Names()
            if MentionTextFormat.resolvingNames(in: written, { again.resolve($0) }) != written || !again.asked.isEmpty {
                failures += 1
                if failures < 4 { expect(false, "\(written.debugDescription) still has a name") }
            }
        }
        expectEqual(failures, 0)
        expect(named > 5_000, "many strings hold a name: \(named)")
    },
])

// MARK: What a text's scope admits, from its schema

@MainActor let admissionTests = Suite("What a text may mention, read from its schema", [
    test("no annotation admits every mentionable shape; a kind that can't be mentioned is never admitted") {
        let h = try mentionHarness()
        let registry = h.editor.registry
        let frame = CGRect(x: 0, y: 0, width: 100, height: 80)
        let plate = try require(h.record(h.editor.add(Plate(frame), titled: "P")))
        let jot = try require(h.record(h.add(Jot(frame))))
        let box = try require(h.record(h.add(Box(frame))))
        expectEqual(registry.mentionAdmission(of: plate, scope: nil), .admitted)
        expectEqual(registry.mentionAdmission(of: jot, scope: nil), .admitted)
        expectEqual(registry.mentionAdmission(of: box, scope: nil), .notMentionable)
        expectEqual(registry.mentionAdmission(of: box, scope: [MentionTextFormat.annotationKey: "?"]), .notMentionable, "whatever the scope says")
        // A scope it can't read is none.
        expectEqual(registry.mentionAdmission(of: jot, scope: ["kinds": "plate"]), .admitted)
        expectEqual(registry.mentionAdmission(of: jot, scope: ["other": 1]), .admitted)
    },

    test("the annotation Only writes admits its kind and says which, for any other that can be mentioned") {
        let h = try mentionHarness()
        let registry = h.editor.registry
        let frame = CGRect(x: 0, y: 0, width: 100, height: 80)
        let plate = try require(h.record(h.editor.add(Plate(frame), titled: "P")))
        let token = try require(h.record(h.add(Token(frame, caption: "T"))))
        let box = try require(h.record(h.add(Box(frame))))
        let only = try require(Only<Plate>.schemaAnnotation())
        expectEqual(registry.mentionAdmission(of: plate, scope: only), .admitted)
        expectEqual(registry.mentionAdmission(of: token, scope: only), .outsideScope(admits: [Plate.kind]))
        expectEqual(registry.mentionAdmission(of: box, scope: only), .notMentionable)
        // A kind that can't be mentioned admits nothing, even named.
        expectEqual(registry.mentionAdmission(of: token, scope: try require(Only<Box>.schemaAnnotation())), .outsideScope(admits: []))
        expectEqual(registry.mentionAdmission(of: token, scope: ["kinds": ["plate", "nothing-like-it", "token"]]), .admitted)
        expectEqual(registry.mentionAdmission(of: try require(h.record(h.add(Jot(frame)))), scope: ["kinds": ["token", "plate"]]),
                    .outsideScope(admits: [Token.kind, Plate.kind]), "as the schema lists them")
    },

    test("the annotation of a declared scope is matched by its title: the kinds that joined it are admitted, the others told them") {
        let h = try mentionHarness()
        let registry = h.editor.registry
        let frame = CGRect(x: 0, y: 0, width: 100, height: 80)
        let plate = try require(h.record(h.editor.add(Plate(frame), titled: "P")))
        let token = try require(h.record(h.add(Token(frame, caption: "T"))))
        let jot = try require(h.record(h.add(Jot(frame))))
        let scope = try require(Blockers.schemaAnnotation())
        expectEqual(registry.mentionAdmission(of: plate, scope: scope), .admitted)
        expectEqual(registry.mentionAdmission(of: token, scope: scope), .admitted)
        expectEqual(registry.mentionAdmission(of: jot, scope: scope), .outsideScope(admits: [Plate.kind, Token.kind]), "in registry order")
        expectEqual(registry.mentionAdmission(of: jot, scope: ["scope": "Nobody declares this"]), .outsideScope(admits: []))
        // What each shape says in a kind's schema is what it's asked by: a brief's two scoped texts.
        let brief = try require(registry.schema(for: Brief.kind)).json
        let plates = try require(brief["properties"]?["plates"]?[MentionTextFormat.annotationKey]?.objectValue)
        let blockedBy = try require(brief["properties"]?["blockedBy"]?[MentionTextFormat.annotationKey]?.objectValue)
        expectEqual(registry.mentionAdmission(of: token, scope: plates), .outsideScope(admits: [Plate.kind]))
        expectEqual(registry.mentionAdmission(of: token, scope: blockedBy), .admitted)
        expectEqual(registry.mentionAdmission(of: jot, scope: blockedBy), .outsideScope(admits: [Plate.kind, Token.kind]))
    },
])
