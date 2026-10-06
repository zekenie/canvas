import Canvas
import Foundation
import Titles

/// One piece of mention text: text as it reads, or a mention of a shape with the name it was
/// called when the text was last written (its snapshot, shown only while the shape isn't there).
public enum MentionRun: Hashable, Sendable {
    case text(String)
    case mention(ShapeID, label: String)
}

/// Greeked, zoomed out (`SkeletonTextBars`: a note's skeleton): text as it reads, and a mention as
/// wide as its pill, by the name it holds (its target isn't looked up), read only as far as a pill
/// grows.
extension MentionRun: SkeletonTextRunConvertible {
    public var skeletonTextRun: SkeletonTextRun {
        switch self {
        case .text(let text): .text(text)
        case .mention(_, let label): .inline(columns: Self.pillColumns(named: label))
        }
    }

    /// How many of its text's columns (about half an em of its font each, `SkeletonTextMetrics`) a
    /// pill takes: its symbol and padding (1.5 em), and its label, set 0.85 as large (about 0.39
    /// em a column), at most 16 em (`MentionStyle`).
    static let pillColumns: CGFloat = 3
    static let pillColumn: CGFloat = 0.75
    static let longestPill: CGFloat = 30
    /// The most of a label that counts: past this many columns its pill is `longestPill`.
    static let longestLabel = Int(((longestPill - pillColumns) / pillColumn).rounded(.up))

    static func pillColumns(named label: String) -> CGFloat {
        Swift.min(pillColumns + CGFloat(SkeletonText.columns(of: label, upTo: longestLabel)) * pillColumn, longestPill)
    }
}

/// Text that may mention shapes, restricted to what `Scope` admits (`MentionText` admits any
/// mentionable shape). Stored as one string in which `@[label](shape:UUID)` is a mention: in a
/// label, `\]` stands for `]` and `\\` for `\`; in the text, `\@[` is a literal `@[`, and any
/// backslashes just before an `@[` are doubled. Anything that isn't a whole mention is text, byte
/// for byte. Its runs are parsed once, as it's made.
///
/// A value keeps the string it was made from: `stored` is that string, and equality compares it,
/// so an agent's lowercase id or a board's text writes back as it was read. Text made from runs
/// (`init(_:)`, and so whatever a Mentions surface writes) is canonical: ids in uppercase, every
/// look-alike escaped. A string literal is plain text (`init(plain:)`): `StickyNote(text: "Hi")`.
public struct ScopedMentionText<Scope: MentionScope>: Sendable, ExpressibleByStringLiteral {
    /// The string, as it was made or read.
    public let stored: String
    /// What it says, in order: text runs are never empty, and never two in a row.
    public let runs: [MentionRun]

    /// Any string: what isn't a whole mention is text.
    public init(stored: String) {
        self.stored = stored
        runs = MentionGrammar.parse(stored)
    }

    /// Text without mentions, as it reads: look-alikes are escaped, so it never gains one.
    public init(plain: String) {
        self.init([.text(plain)])
    }

    /// Plain text, as `init(plain:)`.
    public init(stringLiteral value: String) {
        self.init(plain: value)
    }

    /// The runs, written canonically. A label's line breaks become spaces.
    public init(_ runs: [MentionRun]) {
        let normalized = MentionGrammar.normalize(runs)
        stored = MentionGrammar.write(normalized)
        self.runs = normalized
    }

    /// The same text, of another scope: its string and runs as they are, with nothing parsed again.
    init<Other>(_ other: ScopedMentionText<Other>) {
        stored = other.stored
        runs = other.runs
    }

    /// Every shape it mentions, in text order, repeats included.
    public var mentioned: [ShapeID] {
        runs.compactMap { if case .mention(let id, _) = $0 { id } else { nil } }
    }

    /// Whether it says nothing: no mention, and only whitespace.
    public var isBlank: Bool {
        runs.allSatisfy { if case .text(let text) = $0 { text.allSatisfy(\.isWhitespace) } else { false } }
    }

    /// Its first line with words in it, trimmed, each mention "@…", and cut to a title's length
    /// (`TitleProperty.maxLength` characters); nil if it has none (a line of mentions alone has
    /// none). What an untitled shape is called where it's mentioned.
    ///
    /// No other shape's name is in it, live or held: a mention holds its target's name as it was
    /// written, which for an untitled shape is its first line, so a name made of the names its
    /// mentions hold would take in its own each time two notes that mention each other are
    /// written, and grow.
    public var firstLine: String? {
        var line = "", hasWords = false
        for run in runs {
            switch run {
            case .text(let text):
                for character in text {
                    if character.isNewline {
                        if hasWords { return Self.trimmedName(line) }
                        line = ""
                    } else {
                        line.append(character)
                        if !character.isWhitespace { hasWords = true }
                    }
                }
            case .mention:
                line += Self.mentionInName
            }
        }
        return hasWords ? Self.trimmedName(line) : nil
    }

    /// What a mention reads as in `firstLine`.
    private static var mentionInName: String { "@…" }

    private static func trimmedName(_ line: String) -> String {
        String(line.trimmingCharacters(in: .whitespaces).prefix(TitleProperty.maxLength))
    }

    /// Text that looks like a mention but reads as text, as written: each `@[` that isn't escaped,
    /// starts no mention, and has `(shape` (in any case) later on its line before another `@[`,
    /// through the first `)` after that, else to the line's end or that `@[`. So
    /// `@[x](shape: 7C1E…)` (a space), `@[x](shape:1234)` (no UUID) and `@[a]b](shape:…)` (a `]`
    /// not escaped) are look-alikes, and `\@[`, a literal `@[`, and `@[x]` alone aren't: what an
    /// agent or a hand meant as a mention and got wrong. No surface writes one, since text made
    /// from runs escapes every `@[` in its text.
    ///
    /// Text with no more `@[`s left unescaped than it has mentions has none, which one pass over
    /// its bytes tells: so asking costs little for text without, and nothing is kept for it (a
    /// value's size is what fits in an existential's buffer, as it's walked as `any ShapeNaming`).
    public var lookalikes: [String] {
        let mentions = runs.reduce(0) { if case .mention = $1 { $0 + 1 } else { $0 } }
        return MentionGrammar.unescapedOpenings(in: stored) > mentions ? MentionGrammar.lookalikes(in: stored) : []
    }

    /// What text stored so reads as plain text, as `init(stored:)`'s `plainText(label:)` reads it,
    /// in one pass over its bytes, with no runs made: for what reads many texts once (a query's scan
    /// and its rows). Text without an `@[` reads as it's stored, and costs a pass that finds none.
    public static func plainText(stored: String, label: (ShapeID) -> String? = { _ in nil }) -> String {
        MentionGrammar.plainText(of: stored, label: label)
    }

    /// What it reads as plain text: each mention as "@" and its name, the name `label` gives, or,
    /// where it gives none, the label the mention holds.
    public func plainText(label: (ShapeID) -> String? = { _ in nil }) -> String {
        var plain = ""
        for run in runs {
            switch run {
            case .text(let text): plain += text
            case .mention(let id, let stored): plain += "@" + (label(id) ?? stored)
            }
        }
        return plain
    }
}

/// Equal when stored alike, byte for byte: two spellings of one mention (a lowercase id) differ,
/// as they write differently.
extension ScopedMentionText: Hashable {
    public static func == (a: Self, b: Self) -> Bool { a.stored == b.stored }
    public func hash(into hasher: inout Hasher) { hasher.combine(stored) }
}

extension ScopedMentionText: CustomStringConvertible {
    public var description: String { stored }
}

/// As one JSON string, the stored form.
extension ScopedMentionText: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(stored: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stored)
    }
}

/// One shared definition, `mentions.text`, whatever the scope: a scoped use says what its scope
/// admits beside the reference (`x-canvas-mentions`).
extension ScopedMentionText: SchemaDescribed {
    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        var json = definitions.reference("text", of: MentionTextFormat.self) { _ in MentionTextFormat.definition }
        if let annotation = Scope.schemaAnnotation() { json[MentionTextFormat.annotationKey] = .object(annotation) }
        return json
    }
}

/// Coded by hand, as one string, so it names its shapes itself: the core finds it through the
/// property list that holds it, and a copy renames its mentions of the shapes copied with it.
extension ScopedMentionText: ShapeNaming {
    public func forEachNamedShape(_ body: (ShapeID) -> Void) {
        for run in runs { if case .mention(let id, _) = run { body(id) } }
    }

    /// The same text with the mentions `rename` gives an id for renamed, each keeping its label;
    /// the stored form is written again only if an id changed.
    public func renamingShapes(_ rename: (ShapeID) -> ShapeID?) -> Self {
        var changed = false
        let renamed = runs.map { run -> MentionRun in
            guard case .mention(let id, let label) = run, let new = rename(id), new != id else { return run }
            changed = true
            return .mention(new, label: label)
        }
        return changed ? Self(renamed) : self
    }
}

/// Any scope's mention text, for code that reads mentions wherever a shape keeps them: among the
/// naming leaves the core walks (`forEachNamingLeaf`), in a struct, a list, a set or a dictionary.
protocol MentionTextHolding {
    /// Each run, in order.
    func forEachMentionRun(_ body: (MentionRun) -> Void)
    /// What the text may mention: its type's scope.
    var scope: any MentionScope.Type { get }
    /// Its look-alikes (`ScopedMentionText.lookalikes`).
    var lookalikes: [String] { get }
}

extension ScopedMentionText: MentionTextHolding {
    func forEachMentionRun(_ body: (MentionRun) -> Void) { runs.forEach(body) }
    var scope: any MentionScope.Type { Scope.self }
}

/// Mention text that may mention any mentionable shape.
public typealias MentionText = ScopedMentionText<AnyMentionable>

// MARK: The grammar

/// The stored form, read and written. Scalar by scalar: every character the grammar gives a
/// meaning to is ASCII, so text in any script passes through as it is.
enum MentionGrammar {
    private static let at: Unicode.Scalar = "@"
    private static let open: Unicode.Scalar = "["
    private static let close: Unicode.Scalar = "]"
    private static let backslash: Unicode.Scalar = "\\"
    private static let head = Array("](shape:".unicodeScalars)

    static func isLineBreak(_ scalar: Unicode.Scalar) -> Bool { scalar == "\n" || scalar == "\r" }

    /// Whether the string has an `@[` anywhere: without one it's all text, as it is.
    static func mayHoldMentions(_ string: String) -> Bool {
        var previous: UInt8 = 0
        for byte in string.utf8 {
            if previous == 0x40, byte == 0x5B { return true }
            previous = byte
        }
        return false
    }

    /// Runs merged and cleaned: no empty text run, no two text runs in a row, no line break in a
    /// label (each becomes a space, as a label is one line).
    static func normalize(_ runs: [MentionRun]) -> [MentionRun] {
        var out: [MentionRun] = []
        for run in runs {
            switch run {
            case .text(let text):
                guard !text.isEmpty else { continue }
                if case .text(let previous)? = out.last { out[out.count - 1] = .text(previous + text) } else { out.append(run) }
            case .mention(let id, let label):
                let oneLine = label.unicodeScalars.contains(where: isLineBreak)
                    ? String(String.UnicodeScalarView(label.unicodeScalars.map { isLineBreak($0) ? " " : $0 })) : label
                out.append(.mention(id, label: oneLine))
            }
        }
        return out
    }

    /// A label read from `start` (just past an `@[`): what it says, with `\]` and `\\` undone, and
    /// where its scan stopped: at its `]`, or at a line break, a backslash that escapes nothing, or
    /// the end, where it isn't a label. A scan from any `@[` inside what it read would read the same
    /// scalars from where this one did and stop there the same way.
    private static func label(in s: [Unicode.Scalar], from start: Int) -> (text: String, end: Int) {
        var j = start
        var label = String.UnicodeScalarView()
        while j < s.count {
            let c = s[j]
            if c == backslash {
                guard j + 1 < s.count, s[j + 1] == close || s[j + 1] == backslash else { return (String(label), j) }
                label.append(s[j + 1])
                j += 2
                continue
            }
            if c == close { break }
            if isLineBreak(c) { return (String(label), j) }
            label.append(c)
            j += 1
        }
        return (String(label), j)
    }

    /// What a label's `]` at `close` starts when it's a mention's: `](shape:UUID)`, the id and
    /// where the mention ends; nil for anything else.
    private static func shapeSuffix(in s: [Unicode.Scalar], at close: Int) -> (ShapeID, Int)? {
        guard close + head.count + 37 <= s.count, Array(s[close..<close + head.count]) == head else { return nil }
        let idStart = close + head.count
        let idScalars = s[idStart..<idStart + 36]
        guard s[idStart + 36] == ")", idScalars.allSatisfy(\.isASCII),
              let uuid = UUID(uuidString: String(String.UnicodeScalarView(idScalars))) else { return nil }
        return (ShapeID(uuid), idStart + 37)
    }

    /// A whole mention starting at `i` (an `@`): its id, its label, and where it ends. When there's
    /// none, `labelEnd` is where the label's scan stopped (its `]`, a line break, a backslash that
    /// escapes nothing, or the end), if it began: no `@[` before that point starts a mention either,
    /// since a scan from one would read the same scalars from where this one read them and stop
    /// there the same way.
    private static func mention(in s: [Unicode.Scalar], at i: Int, labelEnd: inout Int) -> (ShapeID, String, Int)? {
        guard i + 1 < s.count, s[i] == at, s[i + 1] == open else { return nil }
        let (label, end) = label(in: s, from: i + 2)
        labelEnd = end
        guard end < s.count, s[end] == close, let (id, mentionEnd) = shapeSuffix(in: s, at: end) else { return nil }
        return (id, label, mentionEnd)
    }

    /// The runs `string` reads as.
    static func parse(_ string: String) -> [MentionRun] {
        guard mayHoldMentions(string) else { return string.isEmpty ? [] : [.text(string)] }
        var failures: [Int]?
        return parse(Array(string.unicodeScalars), failures: &failures)
    }

    /// How many `@[`s aren't escaped (an even number of backslashes, none included, just before
    /// the `@`). Each mention starts at one, so text with no more of them than mentions has no `@[`
    /// that failed to start one. Byte by byte: every character it looks for is ASCII.
    static func unescapedOpenings(in string: String) -> Int {
        var count = 0
        var backslashes = 0              // the run just before this byte
        var atAfter = -1                 // the run before the `@` just before this byte; -1: none
        for byte in string.utf8 {
            if byte == 0x5B, atAfter >= 0, atAfter % 2 == 0 { count += 1 }
            atAfter = byte == 0x40 ? backslashes : -1
            backslashes = byte == 0x5C ? backslashes + 1 : 0
        }
        return count
    }

    /// Linear: an `@[` whose label's scan failed rules out every `@[` up to where it stopped
    /// (`mention(in:at:labelEnd:)`), which isn't scanned again, so many unclosed `@[`s on one line
    /// cost their length, not its square. Where each `@[` that isn't escaped and starts no mention
    /// is (its `@`) goes in `failures`, if it's there.
    private static func parse(_ s: [Unicode.Scalar], failures: inout [Int]?) -> [MentionRun] {
        var runs: [MentionRun] = []
        var text = String.UnicodeScalarView()
        func flush() {
            if !text.isEmpty { runs.append(.text(String(text))) }
            text = String.UnicodeScalarView()
        }
        /// No mention starts before this: a failed scan got this far.
        var ruledOut = 0
        func mention(at a: Int) -> (ShapeID, String, Int)? {
            guard a >= ruledOut else { return nil }
            return Self.mention(in: s, at: a, labelEnd: &ruledOut)
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
                    failures?.append(a)
                    text.append(at)
                    i = a + 1
                    continue
                }
                text.append(contentsOf: repeatElement(backslash, count: n))
                i = a
                continue
            }
            if s[i] == at, i + 1 < s.count, s[i + 1] == open {
                if let (id, label, end) = mention(at: i) {
                    flush()
                    runs.append(.mention(id, label: label))
                    i = end
                    continue
                }
                failures?.append(i)
            }
            text.append(s[i])
            i += 1
        }
        flush()
        return runs
    }

    // MARK: Plain text, from the bytes

    private static let headBytes = Array("](shape:".utf8)

    /// `parse(_:)`'s runs as `plainText(label:)` reads them, from the string's UTF-8 in one pass:
    /// every character the grammar gives a meaning to is ASCII, and no byte of another character is
    /// one, so each is found, and each run of text copied, byte for byte, as the scalar parse finds
    /// and copies them. Text with no `@[` is as it's stored.
    static func plainText(of string: String, label: (ShapeID) -> String?) -> String {
        guard mayHoldMentions(string) else { return string }
        var string = string
        return string.withUTF8 { plainText(of: $0, label: label) }
    }

    private static func plainText(of s: UnsafeBufferPointer<UInt8>, label: (ShapeID) -> String?) -> String {
        let backslash: UInt8 = 0x5C, at: UInt8 = 0x40, open: UInt8 = 0x5B
        var out: [UInt8] = []
        out.reserveCapacity(s.count)
        var ruledOut = 0                 // no mention starts before this: a failed scan got this far
        var i = 0
        while i < s.count {
            var a = i                    // an `@[` that isn't escaped starts here, once found
            if s[i] == backslash {
                var n = 0
                while i + n < s.count, s[i + n] == backslash { n += 1 }
                a = i + n
                guard a + 1 < s.count, s[a] == at, s[a + 1] == open else {
                    out.append(contentsOf: repeatElement(backslash, count: n))
                    i = a
                    continue
                }
                out.append(contentsOf: repeatElement(backslash, count: n / 2))
                if n % 2 == 1 {
                    out.append(at)
                    i = a + 1
                    continue
                }
            } else if s[i] != at || i + 1 >= s.count || s[i + 1] != open {
                out.append(s[i])
                i += 1
                continue
            }
            out.append(at)
            if a >= ruledOut, let (id, name, end) = mention(in: s, at: a, labelEnd: &ruledOut) {
                if let live = label(id) {
                    out.append(contentsOf: live.utf8)
                } else {
                    // The label as it holds it: `\]` and `\\` stand for `]` and `\`.
                    var k = name.lowerBound
                    while k < name.upperBound {
                        if s[k] == backslash { k += 1 }
                        out.append(s[k])
                        k += 1
                    }
                }
                i = end
            } else {
                i = a + 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// `mention(in:at:labelEnd:)` over bytes: the id, where the label is (escapes and all), and
    /// where the mention ends.
    private static func mention(in s: UnsafeBufferPointer<UInt8>, at i: Int, labelEnd: inout Int) -> (ShapeID, Range<Int>, Int)? {
        let backslash: UInt8 = 0x5C, close: UInt8 = 0x5D
        var j = i + 2
        while j < s.count {
            let c = s[j]
            if c == backslash {
                guard j + 1 < s.count, s[j + 1] == close || s[j + 1] == backslash else {
                    labelEnd = j
                    return nil
                }
                j += 2
                continue
            }
            if c == close { break }
            if c == 0x0A || c == 0x0D {
                labelEnd = j
                return nil
            }
            j += 1
        }
        labelEnd = j
        guard j + headBytes.count + 37 <= s.count else { return nil }
        for k in 0..<headBytes.count where s[j + k] != headBytes[k] { return nil }
        let idStart = j + headBytes.count
        guard s[idStart + 36] == 0x29, let uuid = uuid(in: s, at: idStart) else { return nil }
        return (ShapeID(uuid), (i + 2)..<j, idStart + 37)
    }

    /// The UUID written in the 36 bytes at `start` as `UUID(uuidString:)` reads one: hex digits in
    /// either case, in groups of 8, 4, 4, 4 and 12 with a hyphen between each; nil for anything else.
    private static func uuid(in s: UnsafeBufferPointer<UInt8>, at start: Int) -> UUID? {
        var bytes: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        let parsed = withUnsafeMutableBytes(of: &bytes) { out -> Bool in
            var k = start, n = 0
            while n < 16 {
                if k - start == 8 || k - start == 13 || k - start == 18 || k - start == 23 {
                    guard s[k] == 0x2D else { return false }
                    k += 1
                }
                guard let high = hexValue(s[k]), let low = hexValue(s[k + 1]) else { return false }
                out[n] = high << 4 | low
                n += 1
                k += 2
            }
            return true
        }
        return parsed ? UUID(uuid: bytes) : nil
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: byte - 0x30
        case 0x41...0x46: byte - 0x41 + 10
        case 0x61...0x66: byte - 0x61 + 10
        default: nil
        }
    }

    private static let shapeWord = Array("(shape".unicodeScalars)

    /// `ScopedMentionText.lookalikes`: from each failed `@[` with `(shape` after it on its line,
    /// before any other `@[` (so `@[x]` before a real mention isn't one), through the first `)`
    /// after that, else to the line's end or the next `@[` (less the whitespace before it). So one
    /// never holds another `@[`, and the text's are linear to find: each failed `@[`'s search
    /// stops at the next.
    static func lookalikes(in string: String) -> [String] {
        guard mayHoldMentions(string) else { return [] }
        let s = Array(string.unicodeScalars)
        var failures: [Int]? = []
        _ = parse(s, failures: &failures)
        var found: [String] = []
        for start in failures ?? [] {
            var word = start + 2
            while word < s.count, !isLineBreak(s[word]), !isShapeWord(in: s, at: word), !opens(s, at: word) { word += 1 }
            guard word < s.count, isShapeWord(in: s, at: word) else { continue }
            var end = word + shapeWord.count
            while end < s.count, !isLineBreak(s[end]), s[end] != ")", !opens(s, at: end) { end += 1 }
            if end < s.count, s[end] == ")" {
                end += 1
            } else {
                while s[end - 1].properties.isWhitespace { end -= 1 }
            }
            found.append(String(String.UnicodeScalarView(s[start..<end])))
        }
        return found
    }

    /// Whether an `@[` starts at `i`.
    private static func opens(_ s: [Unicode.Scalar], at i: Int) -> Bool {
        s[i] == at && i + 1 < s.count && s[i + 1] == open
    }

    /// Whether `(shape` starts at `i`, in any case.
    private static func isShapeWord(in s: [Unicode.Scalar], at i: Int) -> Bool {
        guard i + shapeWord.count <= s.count else { return false }
        for (k, expected) in shapeWord.enumerated() {
            let c = s[i + k]
            let lowered = ("A"..."Z").contains(c) ? Unicode.Scalar(c.value + 32)! : c
            guard lowered == expected else { return false }
        }
        return true
    }

    // MARK: Names

    /// `MentionTextFormat.resolvingNames(in:_:)`: the string with each `@[name]` that names a shape
    /// by its name written as a whole mention. Read as `parse` reads it, scalar by scalar, so a
    /// backslash and an `@[` mean what they mean in the stored form, and linear in the same way: a
    /// scan that stops short (at a line break, a backslash that escapes nothing, or the end) rules
    /// out the `@[`s it read past. A name is a label's: it ends at the first `]` no backslash
    /// escapes, on the line the `@[` is on. What's left as it is, byte for byte: every other
    /// character; a whole mention (`@[label](shape:ID)`, the id in any case); and a look-alike, a name's
    /// `]` followed by `(shape` in any case, which is a mention gone wrong, not one by name.
    static func resolvingNames<E: Error>(in string: String, _ resolve: (String) throws(E) -> (id: ShapeID, label: String)) throws(E) -> String {
        guard mayHoldMentions(string) else { return string }
        let s = Array(string.unicodeScalars)
        var out: [Unicode.Scalar] = []       // not a string, which copies itself whole for each append
        var copied = 0                       // s[..<copied] is in `out`; 0 until a name is written
        var ruledOut = 0                     // no `@[` starts a mention before this: a failed scan got this far
        var i = 0
        while i < s.count {
            var a = i                        // an `@[` that no backslash escapes starts here, once found
            if s[i] == backslash {
                var n = 0
                while i + n < s.count, s[i + n] == backslash { n += 1 }
                a = i + n
                guard a + 1 < s.count, s[a] == at, s[a + 1] == open else {
                    i = a
                    continue
                }
                if n % 2 == 1 {              // `\@[`: a literal `@[`
                    i = a + 1
                    continue
                }
            } else if s[i] != at || i + 1 >= s.count || s[i + 1] != open {
                i += 1
                continue
            }
            guard a >= ruledOut else {
                i = a + 1
                continue
            }
            let (name, end) = label(in: s, from: a + 2)
            ruledOut = end
            guard end < s.count, s[end] == close else {
                i = a + 1
                continue
            }
            if let (_, mentionEnd) = shapeSuffix(in: s, at: end) {
                i = mentionEnd
                continue
            }
            guard !isShapeWord(in: s, at: end + 1) else {
                i = a + 1
                continue
            }
            let (id, shown) = try resolve(name)
            out.append(contentsOf: s[copied..<a])
            append(id, label: shown, to: &out)
            copied = end + 1
            i = end + 1
        }
        guard copied > 0 else { return string }
        out.append(contentsOf: s[copied...])
        return String(String.UnicodeScalarView(out))
    }

    /// A mention, written canonically: its label with `]` and `\` escaped (a line break a space),
    /// and its id in uppercase.
    private static func append<Out: RangeReplaceableCollection>(_ id: ShapeID, label: String, to out: inout Out) where Out.Element == Unicode.Scalar {
        out.append(contentsOf: "@[".unicodeScalars)
        for c in label.unicodeScalars {
            if c == backslash || c == close { out.append(backslash) }
            out.append(isLineBreak(c) ? " " : c)
        }
        out.append(contentsOf: "](shape:\(id.rawValue.uuidString))".unicodeScalars)
    }

    /// Normalized runs, written canonically.
    static func write(_ runs: [MentionRun]) -> String {
        var out = String.UnicodeScalarView()
        for (n, run) in runs.enumerated() {
            switch run {
            case .mention(let id, let label):
                append(id, label: label, to: &out)
            case .text(let text):
                let nextIsMention: Bool = if n + 1 < runs.count, case .mention = runs[n + 1] { true } else { false }
                guard nextIsMention || mayHoldMentions(text) else {
                    out.append(contentsOf: text.unicodeScalars)
                    continue
                }
                escape(Array(text.unicodeScalars), beforeMention: nextIsMention, into: &out)
            }
        }
        return String(out)
    }

    /// Text as the stored form writes it: each `@[` as `\@[`, and each run of backslashes just
    /// before one (or before the mention that follows, at the end) doubled.
    private static func escape(_ c: [Unicode.Scalar], beforeMention: Bool, into out: inout String.UnicodeScalarView) {
        var i = 0
        while i < c.count {
            if c[i] == backslash {
                var k = 0
                while i + k < c.count, c[i + k] == backslash { k += 1 }
                let a = i + k
                let beforeAt = (a + 1 < c.count && c[a] == at && c[a + 1] == open) || (a == c.count && beforeMention)
                out.append(contentsOf: repeatElement(backslash, count: beforeAt ? 2 * k : k))
                i = a
                continue
            }
            if c[i] == at, i + 1 < c.count, c[i + 1] == open {
                out.append(backslash)
                out.append(at)
                i += 1
                continue
            }
            out.append(c[i])
            i += 1
        }
    }
}
