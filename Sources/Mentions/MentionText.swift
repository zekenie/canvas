import Canvas
import Foundation
import Titles

/// One piece of mention text: text as it reads, or a mention of a shape with the name it was
/// called when the text was last written (its snapshot, shown only while the shape isn't there).
public enum MentionRun: Hashable, Sendable {
    case text(String)
    case mention(ShapeID, label: String)
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
}

extension ScopedMentionText: MentionTextHolding {
    func forEachMentionRun(_ body: (MentionRun) -> Void) { runs.forEach(body) }
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

    /// A whole mention starting at `i` (an `@`): its id, its label, and where it ends. When there's
    /// none, `labelEnd` is where the label's scan stopped (its `]`, a line break, a backslash that
    /// escapes nothing, or the end), if it began: no `@[` before that point starts a mention either,
    /// since a scan from one would read the same scalars from where this one read them and stop
    /// there the same way.
    private static func mention(in s: [Unicode.Scalar], at i: Int, labelEnd: inout Int) -> (ShapeID, String, Int)? {
        guard i + 1 < s.count, s[i] == at, s[i + 1] == open else { return nil }
        var j = i + 2
        var label = String.UnicodeScalarView()
        while j < s.count {
            let c = s[j]
            if c == backslash {
                guard j + 1 < s.count, s[j + 1] == close || s[j + 1] == backslash else {
                    labelEnd = j
                    return nil
                }
                label.append(s[j + 1])
                j += 2
                continue
            }
            if c == close { break }
            if isLineBreak(c) {
                labelEnd = j
                return nil
            }
            label.append(c)
            j += 1
        }
        labelEnd = j
        guard j + head.count + 37 <= s.count, Array(s[j..<j + head.count]) == head else { return nil }
        let idStart = j + head.count
        let idScalars = s[idStart..<idStart + 36]
        guard s[idStart + 36] == ")", idScalars.allSatisfy(\.isASCII),
              let uuid = UUID(uuidString: String(String.UnicodeScalarView(idScalars))) else { return nil }
        return (ShapeID(uuid), String(label), idStart + 37)
    }

    /// Linear: an `@[` whose label's scan failed rules out every `@[` up to where it stopped
    /// (`mention(in:at:labelEnd:)`), which isn't scanned again, so many unclosed `@[`s on one line
    /// cost their length, not its square.
    static func parse(_ string: String) -> [MentionRun] {
        guard mayHoldMentions(string) else { return string.isEmpty ? [] : [.text(string)] }
        let s = Array(string.unicodeScalars)
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

    /// Normalized runs, written canonically.
    static func write(_ runs: [MentionRun]) -> String {
        var out = String.UnicodeScalarView()
        for (n, run) in runs.enumerated() {
            switch run {
            case .mention(let id, let label):
                out.append(contentsOf: "@[".unicodeScalars)
                for c in label.unicodeScalars {
                    if c == backslash || c == close { out.append(backslash) }
                    out.append(isLineBreak(c) ? " " : c)
                }
                out.append(contentsOf: "](shape:\(id.rawValue.uuidString))".unicodeScalars)
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
