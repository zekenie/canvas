import AppKit
@_spi(Host) import Canvas
import CanvasRPC
import CanvasTesting
import ContextMenus
import DetailPanel
import Keyboard
import Mentions
import Selection
import TestKit
import Topology

// The stored form: `synth-probe/grammar.swift` as tests, the escaper of the migration step, the
// schema, and names through the core.

private let a = idA.rawValue.uuidString
private let b = idB.rawValue.uuidString

/// The grammar's named cases, each run list with the string it's written as.
private let namedCases: [([MentionRun], String)] = [
    ([.text("Ask "), .mention(idA, label: "Groceries"), .text(" first")], "Ask @[Groceries](shape:\(a)) first"),
    ([.text("literal @[x](shape:\(a)) here")], "literal \\@[x](shape:\(a)) here"),
    ([.text("C:\\"), .mention(idA, label: "Dir")], "C:\\\\@[Dir](shape:\(a))"),
    ([.text("\\@[x")], "\\\\\\@[x"),
    ([.text("a\\b and a@b.c and @[x]")], "a\\b and a@b.c and \\@[x]"),
    ([.mention(idA, label: "a]b\\c"), .mention(idB, label: "")], "@[a\\]b\\\\c](shape:\(a))@[](shape:\(b))"),
    ([.text("@[a"), .mention(idB, label: "L")], "\\@[a@[L](shape:\(b))"),
    ([.text("me@"), .mention(idA, label: "x")], "me@@[x](shape:\(a))"),
    ([.text("\\\\\\"), .mention(idA, label: "three")], "\\\\\\\\\\\\@[three](shape:\(a))"),
    ([.text("end\\")], "end\\"),
    ([.text("Emoji 👍🏽 and é "), .mention(idA, label: "Café ☕️")], "Emoji 👍🏽 and é @[Café ☕️](shape:\(a))"),
]

/// A deterministic generator, so the fuzz is the same every run.
struct SplitMix: RandomNumberGenerator {
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

/// Runs over a hostile alphabet.
private func fuzzedRuns(_ rng: inout SplitMix) -> [MentionRun] {
    let alphabet: [Character] = ["@", "[", "]", "(", ")", "\\", "a", " ", "\n", "s", "h", ":", "é"]
    let labelAlphabet = alphabet.filter { $0 != "\n" }
    var runs: [MentionRun] = []
    for _ in 0..<Int.random(in: 1...5, using: &rng) {
        if Bool.random(using: &rng) {
            runs.append(.text(String((0..<Int.random(in: 0...8, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })))
        } else {
            let label = String((0..<Int.random(in: 0...4, using: &rng)).map { _ in labelAlphabet.randomElement(using: &rng)! })
            runs.append(.mention(Bool.random(using: &rng) ? idA : idB, label: label))
        }
    }
    return runs
}

/// The grammar as first written, scanning from every `@[` (quadratic in `@[`s that never close):
/// what the parser must still read every string as.
private func referenceParse(_ string: String) -> [MentionRun] {
    let at: Unicode.Scalar = "@", open: Unicode.Scalar = "[", close: Unicode.Scalar = "]", backslash: Unicode.Scalar = "\\"
    let head = Array("](shape:".unicodeScalars)
    func isLineBreak(_ c: Unicode.Scalar) -> Bool { c == "\n" || c == "\r" }
    let s = Array(string.unicodeScalars)
    func mention(at i: Int) -> (ShapeID, String, Int)? {
        guard i + 1 < s.count, s[i] == at, s[i + 1] == open else { return nil }
        var j = i + 2
        var label = String.UnicodeScalarView()
        while j < s.count {
            let c = s[j]
            if c == backslash {
                guard j + 1 < s.count, s[j + 1] == close || s[j + 1] == backslash else { return nil }
                label.append(s[j + 1])
                j += 2
                continue
            }
            if c == close { break }
            if isLineBreak(c) { return nil }
            label.append(c)
            j += 1
        }
        guard j + head.count + 37 <= s.count, Array(s[j..<j + head.count]) == head else { return nil }
        let idStart = j + head.count
        let idScalars = s[idStart..<idStart + 36]
        guard s[idStart + 36] == ")", idScalars.allSatisfy(\.isASCII),
              let uuid = UUID(uuidString: String(String.UnicodeScalarView(idScalars))) else { return nil }
        return (ShapeID(uuid), String(label), idStart + 37)
    }
    var runs: [MentionRun] = []
    var text = String.UnicodeScalarView()
    func flush() {
        if !text.isEmpty { runs.append(.text(String(text))) }
        text = String.UnicodeScalarView()
    }
    var i = 0
    while i < s.count {
        if s[i] == backslash {
            var n = 0
            while i + n < s.count, s[i + n] == backslash { n += 1 }
            let a = i + n
            if a + 1 < s.count, s[a] == at, s[a + 1] == open {
                text.append(contentsOf: repeatElement(backslash, count: n / 2))
                if n % 2 == 1 {
                    text.append(at)
                    i = a + 1
                    continue
                }
                if let (id, label, end) = mention(at: a) {
                    flush()
                    runs.append(.mention(id, label: label))
                    i = end
                    continue
                }
                text.append(at)
                i = a + 1
                continue
            }
            text.append(contentsOf: repeatElement(backslash, count: n))
            i = a
            continue
        }
        if let (id, label, end) = mention(at: i) {
            flush()
            runs.append(.mention(id, label: label))
            i = end
            continue
        }
        text.append(s[i])
        i += 1
    }
    flush()
    return runs
}

/// Runs as the grammar keeps them: no empty text, no two text runs in a row.
private func normalized(_ runs: [MentionRun]) -> [MentionRun] { MentionText(runs).runs }

/// A kind that gives its mention text a length bound, which the registry refuses.
private struct Bounded: BoxShapeProps {
    static let kind: ShapeKind = "bounded"
    static let properties = Properties<Bounded> {
        Property("frame", \.frame).required()
        Property("text", \.text).maxLength(20)
    }
    var frame: CGRect = .zero
    var text: MentionText = ""
    init() {}
}

private struct BoundedDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Bounded>, in context: RenderContext) {}
}

/// A struct in a kind's props holding patterned mention text in a list.
private struct Line: SchemaDefined, Hashable {
    static let properties = Properties<Line> {
        Property("text", \.text).pattern("^a")
    }
    var text: MentionText = ""
    init() {}
}

extension Line: ShapeNaming {}

private struct Lines: BoxShapeProps {
    static let kind: ShapeKind = "lines"
    static let properties = Properties<Lines> {
        Property("frame", \.frame).required()
        Property("lines", \.lines)
    }
    var frame: CGRect = .zero
    var lines: [Line] = []
    init() {}
}

private struct LinesDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Lines>, in context: RenderContext) {}
}

@MainActor let textTests = Suite("Mention text", [
    test("the grammar's named cases write as they should, and read back as they were") {
        for (runs, stored) in namedCases {
            let text = MentionText(runs)
            expectEqual(text.stored, stored)
            expectEqual(text.runs, normalized(runs))
            let read = MentionText(stored: stored)
            expectEqual(read.runs, normalized(runs), stored)
            expectEqual(MentionText(read.runs).stored, stored)
        }
    },

    test("20,000 fuzzed run lists round-trip: parse(write(runs)) is runs, and write(parse(s)) is s") {
        var rng = SplitMix(seed: 0x6D65_6E74_696F_6E73)
        var failures = 0
        for _ in 0..<20_000 {
            let runs = fuzzedRuns(&rng)
            let written = MentionText(runs)
            let read = MentionText(stored: written.stored)
            if read.runs != written.runs || MentionText(read.runs).stored != written.stored {
                failures += 1
                if failures < 4 { expect(false, "\(runs) wrote \(written.stored.debugDescription), read back \(read.runs)") }
            }
        }
        expectEqual(failures, 0)
    },

    test("a label's line break is written as a space, since a label is one line") {
        let text = MentionText([.mention(idA, label: "Two\nlines\r")])
        expectEqual(text.stored, "@[Two lines ](shape:\(a))")
        expectEqual(text.runs, [.mention(idA, label: "Two lines ")])
    },

    test("reads are lenient: a lowercase id or an empty name is a mention; anything short of a whole one is text") {
        let lower = MentionText(stored: "Ask @[Groceries](shape:\(a.lowercased())) ok")
        expectEqual(lower.runs, [.text("Ask "), .mention(idA, label: "Groceries"), .text(" ok")])
        expectEqual(MentionText(stored: "@[](shape:\(a))").runs, [.mention(idA, label: "")])
        for text in ["\\@[Groceries](shape:\(a))", "@[x]", "@[Q3](time:q3)", "@[x](shape:\(a.dropLast()))",
                     "@[x](shape: \(a))", "@[two\nlines](shape:\(a))", "@[x](shape:\(a)", "@[a]b](shape:\(a))"] {
            let read = MentionText(stored: text)
            expectEqual(read.mentioned, [], text)
            expect(read.runs.count == 1, text)
        }
        expectEqual(MentionText(stored: "\\@[Groceries](shape:\(a))").runs, [.text("@[Groceries](shape:\(a))")])
        expectEqual(MentionText(stored: "@[x](shape:ZZZZZZZZ-2F4D-4A6B-9C3E-5D2F1A0B9C8D)").mentioned, [])
    },

    test("a value keeps the string it was read with: stored is verbatim, and equality compares it") {
        let lowercase = "See @[x](shape:\(a.lowercased()))"
        let read = MentionText(stored: lowercase)
        expectEqual(read.stored, lowercase)
        let canonical = MentionText(read.runs)
        expectEqual(canonical.runs, read.runs)
        expect(canonical != read, "two spellings of one mention are different values")
        expectEqual(canonical.stored, "See @[x](shape:\(a))")
        // Coded as one JSON string, byte for byte.
        let data = try JSONEncoder().encode(read)
        expectEqual(String(decoding: data, as: UTF8.self), try String(decoding: JSONEncoder().encode(lowercase), as: UTF8.self))
        expectEqual(try JSONDecoder().decode(MentionText.self, from: data), read)
        expectEqual(try JSONDecoder().decode(MentionText.self, from: data).stored, lowercase)
    },

    test("a string literal, and init(plain:), are plain text: a look-alike stays text") {
        let literal: MentionText = "Buy @[milk](shape:7C1E0B8A-2F4D-4A6B-9C3E-5D2F1A0B9C8D)"
        expectEqual(literal.runs, [.text("Buy @[milk](shape:\(a))")])
        expectEqual(literal.mentioned, [])
        expectEqual(literal.stored, "Buy \\@[milk](shape:\(a))")
        expectEqual(MentionText(plain: "Buy milk").stored, "Buy milk")
        expectEqual(MentionText(plain: "").runs, [])
        let empty: MentionText = ""
        expectEqual(empty.stored, "")
    },

    test("what it says: mentioned, blank, the first line, and the plain form") {
        let text = MentionText([.text("\n  \nAsk "), .mention(idA, label: "Groceries"), .text(" about "), .mention(idB, label: "B"),
                                .text(" and "), .mention(idA, label: "Groceries"), .text("\nsecond line")])
        expectEqual(text.mentioned, [idA, idB, idA])
        expect(!text.isBlank)
        expect(MentionText(plain: " \n\t ").isBlank)
        expect(!MentionText([.mention(idA, label: "")]).isBlank, "a mention is something")
        expectEqual(text.firstLine, "Ask @… about @… and @…", "no name another shape was called")
        expectEqual(text.plainText { $0.shape == idA ? "Food" : nil }, "\n  \nAsk @Food about @B and @Food\nsecond line")
        expectEqual(MentionText(plain: " ").firstLine, nil)
        expectEqual(MentionText(plain: String(repeating: "x", count: 120)).firstLine?.count, 80)
        expectEqual(MentionText([.mention(idA, label: "A"), .text(" \n "), .mention(idB, label: "B"), .text(" due\nlater")]).firstLine, "@… due",
                    "a line of mentions alone has no words")
        expectEqual(MentionText([.mention(idA, label: "A")]).firstLine, nil)
    },

    test("a reading spells each mention as it's told, and a spelling, or any of it, is its pill in the text as drawn") {
        let idC = ShapeID()
        let text = MentionText([.text("Ask "), .mention(idA, label: "Groceries"), .mention(idB, label: "Bo"), .text(" now "),
                                .mention(idC, label: ""), .text("!")])
        let read = text.reading { id, label in id.shape == idA ? "Food" : label }
        // Drawn: "Ask " (0–4), A's pill 4, B's pill 5, " now " (6–11), C's pill 11, "!" 12.
        expectEqual(read.text, "Ask FoodBo now !")
        expectEqual(read.mentions.map(\.spelling), [4..<8, 8..<10, 15..<15])
        expectEqual(read.mentions.map(\.pill), [4, 5, 11])
        let cases: [(NSRange, NSRange, String)] = [
            (NSRange(location: 4, length: 4), NSRange(location: 4, length: 1), "a spelling, its pill"),
            (NSRange(location: 5, length: 4), NSRange(location: 4, length: 2), "from inside one to inside the next, both pills"),
            (NSRange(location: 8, length: 2), NSRange(location: 5, length: 1), "a spelling right after another, its own pill"),
            (NSRange(location: 11, length: 3), NSRange(location: 7, length: 3), "text after pills, shifted"),
            (NSRange(location: 15, length: 1), NSRange(location: 12, length: 1), "a start at an empty spelling, after its pill"),
            (NSRange(location: 10, length: 5), NSRange(location: 6, length: 5), "an end at an empty spelling, before its pill"),
            (NSRange(location: 12, length: 0), NSRange(location: 8, length: 0), "an empty range, empty"),
            (NSRange(location: 0, length: 16), NSRange(location: 0, length: 13), "the whole text, the whole drawn text"),
        ]
        for (range, drawn, what) in cases { expectEqual(read.drawnRange(of: range), drawn, what) }
        expectEqual(MentionText(plain: "plain").reading { _, _ in "x" }.drawnRange(of: NSRange(location: 1, length: 3)), NSRange(location: 1, length: 3))
    },

    test("parsing is linear: thousands of @[ that never close, on one line, read in a moment, as text") {
        for unclosed in [String(repeating: "@[", count: 20_000), String(repeating: "@[x\\", count: 10_000), "@[" + String(repeating: "\\@[", count: 10_000)] {
            var text = MentionText(plain: "")
            let elapsed = threadCPUTime { text = MentionText(stored: unclosed) }
            expect(elapsed < .milliseconds(250), "\(unclosed.utf8.count) bytes took \(elapsed)")
            expectEqual(text.mentioned, [])
            expectEqual(text.runs.count, 1, "all text")
        }
        let short = String(repeating: "@[x\\", count: 50)
        expectEqual(MentionText(stored: short).runs, referenceParse(short))
    },

    test("the parser reads 20,000 fuzzed strings as the scan from every @[ does") {
        var rng = SplitMix(seed: 0x7061_7273_6520_6C69)
        let alphabet: [String] = ["@", "[", "]", "(", ")", "\\", "a", " ", "\n", "@[", "](shape:", a, b.lowercased(), "\\]", "\\\\"]
        var failures = 0
        for _ in 0..<20_000 {
            var string = ""
            for _ in 0..<Int.random(in: 0...12, using: &rng) { string += alphabet.randomElement(using: &rng)! }
            if Bool.random(using: &rng) { string += MentionText(fuzzedRuns(&rng)).stored }
            if MentionText(stored: string).runs != referenceParse(string) {
                failures += 1
                if failures < 4 { expect(false, "\(string.debugDescription) read as \(MentionText(stored: string).runs), not \(referenceParse(string))") }
            }
        }
        expectEqual(failures, 0)
    },

    test("plain text read from the stored string in one pass is what its runs read as: the named cases and 20,000 fuzzed strings, ids near and far from ones") {
        let names: [ShapeID: String] = [idA: "Live 👍🏽 ]name\\"]
        for (_, stored) in namedCases {
            expectEqual(MentionText.plainText(stored: stored), MentionText(stored: stored).plainText(), stored)
            expectEqual(MentionText.plainText(stored: stored) { names[$0.shape] }, MentionText(stored: stored).plainText { names[$0.shape] }, stored)
        }
        // Ids as UUID(uuidString:) reads them, and ones it doesn't: mixed case, a letter past f, a hyphen
        // out of place, a character that isn't ASCII or is NUL, one too short.
        let mixed = String(a.enumerated().map { $0.offset % 2 == 0 ? Character($0.element.lowercased()) : $0.element })
        let nearIDs = [a, b.lowercased(), mixed, String(a.dropLast()) + "g", a.replacingOccurrences(of: "-", with: "x"),
                       String(a.dropLast()) + "é", String(a.dropLast()) + "\u{0}", String(a.dropFirst()), "{" + a.dropFirst(2) + "}"]
        let alphabet = ["@", "[", "]", ")", "\\", "a", " ", "\n", "\r", "é", "@[", "](shape:", "\\]", "\\\\", "👍🏽"] + nearIDs + nearIDs.map { $0 + ")" }
            + nearIDs.map { "@[x\\]y](shape:\($0))" }
        var rng = SplitMix(seed: 0x706C_6169_6E20_7478)
        var failures = 0, mentioning = 0
        for _ in 0..<20_000 {
            var string = ""
            for _ in 0..<Int.random(in: 0...14, using: &rng) { string += alphabet.randomElement(using: &rng)! }
            if Bool.random(using: &rng) { string += MentionText(fuzzedRuns(&rng)).stored }
            let reference = MentionText(stored: string)
            if !reference.mentioned.isEmpty { mentioning += 1 }
            for live in [false, true] {
                let fast = MentionText.plainText(stored: string) { live ? names[$0.shape] : nil }
                let read = reference.plainText { live ? names[$0.shape] : nil }
                if fast != read {
                    failures += 1
                    if failures < 4 { expect(false, "\(string.debugDescription) reads as \(fast.debugDescription), not \(read.debugDescription)") }
                }
            }
        }
        expectEqual(failures, 0)
        expect(mentioning > 10_000, "most strings hold a mention: \(mentioning)")
    },

    test("escapeLookalikesV1 escapes old text byte for byte, so it reads back as it was, and leaves text without @[ as it is") {
        let cases: [(String, String)] = [
            ("Ask @[Groceries](shape:\(a)) first", "Ask \\@[Groceries](shape:\(a)) first"),
            ("C:\\@[x", "C:\\\\\\@[x"),
            ("two \\\\@[", "two \\\\\\\\\\@["),
            ("@[", "\\@["),
            ("a@b.c @ [x] \\n C:\\path", "a@b.c @ [x] \\n C:\\path"),
            ("end\\", "end\\"),
            ("", ""),
        ]
        for (old, escaped) in cases {
            var props: JSONObject = ["text": .string(old), "frame": [[0, 0], [10, 10]]]
            MentionTextFormat.escapeLookalikesV1(in: &props, "text")
            expectEqual(props["text"], .string(escaped), old)
            expectEqual(props["frame"], [[0, 0], [10, 10]])
            let read = MentionText(stored: escaped)
            expectEqual(read.plainText(), old, "reads back as the text it was")
            expectEqual(read.mentioned, [])
            expectEqual(MentionText(plain: old).stored, escaped, "the frozen escaper agrees with today's writer")
        }
        var missing: JSONObject = ["frame": [[0, 0], [10, 10]]]
        MentionTextFormat.escapeLookalikesV1(in: &missing, "text")
        expectEqual(missing, ["frame": [[0, 0], [10, 10]]])
        var number: JSONObject = ["text": 3]
        MentionTextFormat.escapeLookalikesV1(in: &number, "text")
        expectEqual(number, ["text": 3])
    },

    test("escapeLookalikesV1 is idempotent on text without a look-alike, and deterministic on any: fuzzed old text reads back as it was") {
        var rng = SplitMix(seed: 42)
        let alphabet: [Character] = ["@", "[", "]", "(", ")", "\\", "a", " ", "\n", "s", "h", ":"]
        for _ in 0..<5_000 {
            let old = String((0..<Int.random(in: 0...16, using: &rng)).map { _ in alphabet.randomElement(using: &rng)! })
            var once: JSONObject = ["text": .string(old)]
            MentionTextFormat.escapeLookalikesV1(in: &once, "text")
            var again: JSONObject = ["text": .string(old)]
            MentionTextFormat.escapeLookalikesV1(in: &again, "text")
            expectEqual(once, again)
            guard case .string(let escaped)? = once["text"] else { continue }
            expectEqual(MentionText(stored: escaped).plainText(), old, old.debugDescription)
            if !old.contains("@[") {
                expectEqual(escaped, old)
                var twice = once
                MentionTextFormat.escapeLookalikesV1(in: &twice, "text")
                expectEqual(twice, once, "without a look-alike, a second pass changes nothing")
            }
        }
    },

    test("the schema: one shared definition, mentions.text, a plain string; a scoped use says what it admits beside the reference") {
        let registry = try Registry(plugins: mentionPlugins())
        let jot = try require(registry.schema(for: Jot.kind)).json
        let reference: JSONValue = .string("#/$defs/mentions.text")
        expectEqual(jot["properties"]?["text"], ["$ref": reference, "default": "", "description": "What the jot says."])
        let definition = try require(jot["$defs"]?["mentions.text"])
        expectEqual(definition["type"], "string")
        expectEqual(definition["contentMediaType"], .string(MentionTextFormat.mediaType))
        let description = try require(definition["description"]?.stringValue)
        expect(description.contains("@[name](shape:ID)"))
        expect(description.contains("\\@[ is a literal @["))
        let brief = try require(registry.schema(for: Brief.kind)).json
        expectEqual(brief["properties"]?["plates"], ["$ref": reference, "default": "", "x-canvas-mentions": ["kinds": ["plate"]]])
        expectEqual(brief["properties"]?["blockedBy"], ["$ref": reference, "default": "", "x-canvas-mentions": ["scope": "Blockers"]])
        expectEqual(brief["$defs"]?.objectValue?.keys.filter { $0.hasPrefix("mentions.") }, ["mentions.text"])
        // Shapes hold up against it, mentions and all.
        let h = try mentionHarness()
        let id = h.add(Jot(CGRect(x: 0, y: 0, width: 100, height: 100), text: MentionText([.text("See "), .mention(idA, label: "A")])))
        expectEqual(registry.schemaViolations(of: try require(h.editor.document[id])), [])
    },

    test("the registry refuses a length or a pattern beside mention text, anywhere in a kind's schema") {
        let bounded = Contributor(id: "bounded") { registrar in
            registrar.shape(BoundedDefinition()) { $0.mentionable() }
        }
        do {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), DetailPanelPlugin(), ContextMenusPlugin(), MentionsPlugin(), bounded])
            expect(false, "a bounded mention text should be refused")
        } catch let error as RegistryError {
            guard case .invalid(let point, let reason) = error else { return expect(false, "\(error)") }
            expectEqual(point, "ShapeMentions")
            expect(reason.contains("bounded") && reason.contains("maxLength") && reason.contains("/properties/text"), reason)
        }
        let lines = Contributor(id: "lines") { registrar in
            registrar.shape(LinesDefinition()) { $0.mentionText { _ in [] } }
        }
        do {
            _ = try Registry(plugins: [KeyboardPlugin(), SelectionPlugin(), TopologyPlugin(), DetailPanelPlugin(), ContextMenusPlugin(), MentionsPlugin(), lines])
            expect(false, "a patterned mention text in a list should be refused")
        } catch let error as RegistryError {
            guard case .invalid(let point, let reason) = error else { return expect(false, "\(error)") }
            expectEqual(point, "MentionTexts")
            expect(reason.contains("lines") && reason.contains("pattern"), reason)
        }
    },

    test("names through the core: a copy renames the mentions of shapes copied with it, keeping their labels, and keeps the rest") {
        let h = try mentionHarness()
        let text = MentionText(stored: "Ask @[Old name](shape:\(a.lowercased())) and @[B](shape:\(b))")
        let jot = h.add(Jot(CGRect(x: 0, y: 0, width: 100, height: 100), text: text))
        let registry = h.editor.registry
        expect(registry.namingKinds.contains(Jot.kind) && registry.namingKinds.contains(Brief.kind))
        expect(!registry.namingKinds.contains(Plate.kind))
        let record = try require(h.editor.document[jot])
        var walked: [(String, [ShapeID])] = []
        record.forEachNamingValue(in: registry) { property, value in
            var ids: [ShapeID] = []
            value.forEachNamedShape { ids.append($0) }
            walked.append((property, ids))
        }
        expectEqual(walked.map(\.0), ["text"])
        expectEqual(walked.first?.1, [idA, idB])

        let copied = try require(record.remappingReferences({ $0 == idA ? idC : nil }, in: h.editor.shapeContext))
        let copiedText = try require(copied.typed(as: Jot.self)).props.text
        expectEqual(copiedText.runs, [.text("Ask "), .mention(idC, label: "Old name"), .text(" and "), .mention(idB, label: "B")])
        let kept = try require(record.remappingReferences({ _ in nil }, in: h.editor.shapeContext))
        expectEqual(try require(kept.typed(as: Jot.self)).props.text.stored, text.stored, "nothing renamed: byte for byte")
        expectEqual(record.boundShapes(in: h.editor.shapeContext), [], "names aren't bindings")
    },

    test("deleting a mentioned shape writes nothing to the text that names it") {
        let h = try mentionHarness()
        let plate = h.editor.add(Plate(CGRect(x: 300, y: 0, width: 100, height: 80)), titled: "Groceries")
        let jot = h.add(Jot(CGRect(x: 0, y: 0, width: 100, height: 100), text: MentionText([.mention(plate, label: "Groceries")])))
        let before = try require(h.editor.document[jot])
        h.editor.delete(plate)
        expectEqual(h.editor.document[jot], before)
    },
])
