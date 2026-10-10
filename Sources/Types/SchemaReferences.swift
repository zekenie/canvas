import Canvas
import Foundation
import Mentions

// A type refers to another type's schema as a JSON Schema refers to another document: with a `$ref`
// to the type's URI, `urn:uuid:` and the type's id (`SchemaReferences`), so a type renamed is still
// the one referred to, and so is one on another board of the file. Its words say so with a mention
// of the type (its words are a note's plain mention text, which may mention any shape: a mention of
// a type is a `$ref`, of anything else words), and the sync keeps the two in step through the
// model, which is shown each type as `@` and a word of its name, never its id
// (`SchemaReferenceNames`). A `$ref` names its type as a mention does (`SchemaText` is
// `ShapeNaming`): a type copied with the types it refers to refers to the copies, and one whose type
// is deleted keeps its `$ref`, pointing nowhere until the deletion is undone, as a mention of the
// type shows it missing.

/// A type's JSON Schema, as its text: kept as typed (its members in the order written, and text that
/// isn't JSON yet), one string in a board. It names the types its `$ref`s point to
/// (`SchemaReferences`), as mention text names what it mentions: a copy renames those copied with it
/// and keeps the rest.
public struct SchemaText: Hashable, Sendable, ExpressibleByStringLiteral, CustomStringConvertible {
    public var text: String

    public init(_ text: String) { self.text = text }
    public init(stringLiteral value: String) { text = value }
    public var description: String { text }
}

/// One JSON string in a board.
extension SchemaText: Codable {
    public init(from decoder: any Decoder) throws {
        text = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

extension SchemaText: SchemaDescribed {
    public static func schema(in _: inout SchemaDefinitions) -> JSONObject { ["type": "string"] }
}

/// Coded by hand, so it names its types itself: the core finds it through the property it's the value
/// of, and each `$ref` to a type is a name of it (`SchemaReferences.refs`).
extension SchemaText: ShapeNaming {
    public func forEachNamedShape(_ body: (ShapeID) -> Void) {
        for ref in SchemaReferences.refs(in: text) { body(ref.shape) }
    }

    public func renamingShapes(_ rename: (ShapeID) -> ShapeID?) -> SchemaText {
        SchemaText(SchemaReferences.renaming(text, rename))
    }
}

/// Where a type's `$ref`s point to other types: `urn:uuid:` and the type's id, lowercase (as RFC 9562
/// writes a UUID; read in any case), then nothing (the type's whole schema) or a fragment
/// (`#/$defs/money`, a part of it).
public enum SchemaReferences {
    /// What a type's URI starts with.
    public static let scheme = "urn:uuid:"

    /// The URI a `$ref` points to a type by: its whole schema.
    public static func uri(of shape: ShapeID) -> String { scheme + shape.rawValue.uuidString.lowercased() }

    /// The shape a `$ref` points to, and what follows its URI ("", or a fragment starting with `#`);
    /// nil for a `$ref` to anything else.
    public static func target(of ref: String) -> (shape: ShapeID, fragment: String)? {
        let utf8 = ref.utf8
        guard utf8.count >= schemeBytes.count + 36, starts(utf8, at: utf8.startIndex) else { return nil }
        let start = utf8.index(utf8.startIndex, offsetBy: schemeBytes.count), end = utf8.index(start, offsetBy: 36)
        guard let id = UUID(uuidString: String(decoding: utf8[start..<end], as: UTF8.self)) else { return nil }
        // After a UUID's 36 ASCII bytes: a character's start.
        let fragment = String(decoding: utf8[end...], as: UTF8.self)
        guard fragment.isEmpty || fragment.hasPrefix("#") else { return nil }
        return (ShapeID(id), fragment)
    }

    /// A `$ref` that points to a shape: the shape, what follows its URI, and where its value is in the
    /// schema's text (UTF-8 offsets, the quotes included).
    public struct Ref: Equatable, Sendable {
        public let shape: ShapeID
        public let fragment: String
        public let range: Range<Int>
    }

    /// Each `$ref` in a schema's text that points to a shape, in the text's order: every member named
    /// `$ref`, at any depth, whose value is a type's URI. None while the text isn't JSON, and none
    /// looked for in a text that doesn't say `urn:uuid:` (in any case), which a pass over its bytes
    /// tells: a schema that refers to no shape costs that.
    public static func refs(in text: String) -> [Ref] {
        guard mayRefer(text), let root = try? JSONReader.read(text) else { return [] }
        var refs: [Ref] = []
        forEachRef(in: root) { value, range in
            if let target = target(of: value) { refs.append(Ref(shape: target.shape, fragment: target.fragment, range: range)) }
        }
        return refs
    }

    /// Calls `body` with each `$ref` under `node` whose value is a string, in the text's order: the
    /// value, and where it is in the text (UTF-8 offsets, the quotes included). A `$ref`'s value is
    /// never looked into.
    static func forEachRef(in node: JSONNode, _ body: (String, Range<Int>) -> Void) {
        switch node.value {
        case .object(let members):
            for member in members {
                if member.key == "$ref", let value = member.value.string {
                    body(value, member.value.range)
                } else {
                    forEachRef(in: member.value, body)
                }
            }
        case .array(let elements):
            for element in elements { forEachRef(in: element, body) }
        default:
            break
        }
    }

    /// `text` with each `$ref` to a shape that `rename` gives another id for pointing to that shape
    /// (written as `uri(of:)` writes it, its fragment kept), and the rest byte for byte.
    static func renaming(_ text: String, _ rename: (ShapeID) -> ShapeID?) -> String {
        let edits = refs(in: text).compactMap { ref -> (range: Range<Int>, with: String)? in
            guard let shape = rename(ref.shape), shape != ref.shape else { return nil }
            return (ref.range, JSONReader.literal(uri(of: shape) + ref.fragment))
        }
        return splice(text, edits)
    }

    /// `text` with each range (UTF-8 offsets, in order, none overlapping) replaced.
    static func splice(_ text: String, _ edits: [(range: Range<Int>, with: String)]) -> String {
        guard !edits.isEmpty else { return text }
        let bytes = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var at = 0
        for edit in edits {
            out += bytes[at..<edit.range.lowerBound]
            out += edit.with.utf8
            at = edit.range.upperBound
        }
        out += bytes[at...]
        return String(decoding: out, as: UTF8.self)
    }

    /// Whether `text` says `urn:uuid:` anywhere, in any case.
    static func mayRefer(_ text: String) -> Bool {
        let utf8 = text.utf8
        guard utf8.count >= scheme.utf8.count else { return false }
        if let found = utf8.withContiguousStorageIfAvailable({ bytes in find(in: bytes) }) { return found }
        return Array(utf8).withUnsafeBufferPointer { find(in: $0) }
    }

    private static let schemeBytes = Array(scheme.utf8)

    private static func find(in bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let needle = schemeBytes, count = needle.count
        guard bytes.count >= count else { return false }
        var i = 0
        while i <= bytes.count - count {
            if lowercased(bytes[i]) == needle[0] {
                var k = 1
                while k < count, lowercased(bytes[i + k]) == needle[k] { k += 1 }
                if k == count { return true }
            }
            i += 1
        }
        return false
    }

    /// Whether `bytes` say the scheme at `index`, in any case.
    private static func starts(_ bytes: String.UTF8View, at index: String.UTF8View.Index) -> Bool {
        var i = index
        for byte in schemeBytes {
            guard i < bytes.endIndex, lowercased(bytes[i]) == byte else { return false }
            i = bytes.index(after: i)
        }
        return true
    }

    private static func lowercased(_ byte: UInt8) -> UInt8 { byte >= 65 && byte <= 90 ? byte + 32 : byte }
}

// MARK: What the model is shown

/// The words a model is shown for the types a type's texts name, and how what it writes is read
/// back. Each type is `@` and a word made of its name: its words run together, each after the first
/// capitalized, with anything but letters, digits and `_` left out (`@LineItem` for "Line Item", and
/// `@Schema` for a name with none of those), then a number for a second type with the same word
/// (`@Address2`). Never an id, which a model would have to copy digit for digit. A mention is its
/// word in the description; a `$ref` to a shape, its word in place of the URI (`"$ref": "@Address"`,
/// a fragment kept after it). Both ways, only the shapes named are read: any other `$ref`, and an `@`
/// that isn't one of the words, stay as written.
public struct SchemaReferenceNames: Equatable, Sendable {
    public struct Named: Equatable, Sendable {
        public let shape: ShapeID
        public let word: String
        /// What a mention the model writes calls the shape.
        public let name: String
    }

    /// Each shape named, in the order first named.
    public private(set) var named: [Named] = []
    private var words: [ShapeID: String] = [:]
    /// Each word, lowercased, and its shape.
    private var shapes: [String: ShapeID] = [:]

    /// The types the `words` mention, then those the `schemas` refer to, each called what `name`
    /// says, else (for a mention) what the mention holds: a type referred to that `name` has
    /// nothing for isn't named, nor a shape mentioned that `isType` says isn't a type.
    public init(words texts: [MentionText], schemas: [String], name: (ShapeID) -> String?, isType: (ShapeID) -> Bool = { _ in true }) {
        for text in texts {
            for run in text.runs {
                if case .mention(let shape, let label) = run, words[shape] == nil, isType(shape) { add(shape, name: name(shape) ?? label) }
            }
        }
        for schema in schemas {
            for ref in SchemaReferences.refs(in: schema) where words[ref.shape] == nil {
                if let named = name(ref.shape) { add(ref.shape, name: named) }
            }
        }
    }

    private mutating func add(_ shape: ShapeID, name: String) {
        let base = Self.word(for: name)
        var word = base, number = 2
        while shapes[word.lowercased()] != nil {
            word = base + String(number)
            number += 1
        }
        words[shape] = word
        shapes[word.lowercased()] = shape
        named.append(Named(shape: shape, word: word, name: name))
    }

    /// A name as a word: its words run together, each after the first capitalized, anything but
    /// letters, digits and `_` left out; "Schema" for a name with none of those.
    public static func word(for name: String) -> String {
        var word = "", startsWord = false
        for character in name {
            if isWordCharacter(character) {
                if startsWord, !word.isEmpty { word += character.uppercased() } else { word.append(character) }
                startsWord = false
            } else if character.isWhitespace {
                startsWord = true
            }
        }
        return word.isEmpty ? "Schema" : word
    }

    static func isWordCharacter(_ character: Character) -> Bool { character.isLetter || character.isNumber || character == "_" }

    /// The words, a line each, as the model's `<schemas>` lists them; empty for none.
    public var list: String { named.map { "@" + $0.word }.joined(separator: "\n") }

    /// The shape a word is, written in any case.
    public func shape(forWord word: String) -> ShapeID? { shapes[word.lowercased()] }

    /// The words as the model reads them: each mention of a type `@` and its type's word, against
    /// its pill in the words as they're drawn; a mention of anything else (no type: no word) its
    /// label, as the words say it.
    public func modelText(of text: MentionText) -> MentionReading {
        text.reading { shape, label in words[shape].map { "@" + $0 } ?? label }
    }

    /// The schema as the model reads it: each `$ref` to a named shape its word.
    public func modelSchema(_ schema: String) -> String {
        guard !named.isEmpty else { return schema }
        let edits = SchemaReferences.refs(in: schema).compactMap { ref -> (range: Range<Int>, with: String)? in
            guard let word = words[ref.shape] else { return nil }
            return (ref.range, JSONReader.literal("@" + word + ref.fragment))
        }
        return SchemaReferences.splice(schema, edits)
    }

    /// The model's schema with each `$ref` to a word pointing to its shape again, a fragment after the
    /// word kept after the URI; the rest as the model wrote it.
    public func schema(fromModel text: String) -> String {
        guard !named.isEmpty, text.contains("@"), let root = try? JSONReader.read(text) else { return text }
        var edits: [(range: Range<Int>, with: String)] = []
        SchemaReferences.forEachRef(in: root) { value, range in
            guard value.hasPrefix("@") else { return }
            let hash = value.firstIndex(of: "#") ?? value.endIndex
            guard let shape = self.shape(forWord: String(value[value.index(after: value.startIndex)..<hash])) else { return }
            edits.append((range, JSONReader.literal(SchemaReferences.uri(of: shape) + value[hash...])))
        }
        return SchemaReferences.splice(text, edits)
    }

    /// The model's words, each `@` and a word (in any case, the longest that fits) a mention of its
    /// type, named as the type is: where no letter, digit or `_` comes just before the `@`, nor just
    /// after the word. The rest is text, as the model wrote it.
    public func words(fromModel text: String) -> MentionText {
        guard !named.isEmpty, text.contains("@") else { return MentionText(plain: text) }
        let longestFirst = named.sorted { $0.word.count > $1.word.count }
        var runs: [MentionRun] = [], pending = ""
        var previous: Character?
        var i = text.startIndex
        while i < text.endIndex {
            let character = text[i]
            if character == "@", !(previous.map(Self.isWordCharacter) ?? false),
               let found = match(longestFirst, in: text, after: text.index(after: i)) {
                if !pending.isEmpty { runs.append(.text(pending)) }
                pending = ""
                runs.append(.mention(found.named.shape, label: found.named.name))
                previous = text[text.index(before: found.end)]
                i = found.end
                continue
            }
            pending.append(character)
            previous = character
            i = text.index(after: i)
        }
        if !pending.isEmpty { runs.append(.text(pending)) }
        return MentionText(runs)
    }

    /// The first of `candidates` whose word `text` says from `start`, in any case, with no letter,
    /// digit or `_` after it, and where it ends.
    private func match(_ candidates: [Named], in text: String, after start: String.Index) -> (named: Named, end: String.Index)? {
        for candidate in candidates {
            guard let end = text.index(start, offsetBy: candidate.word.count, limitedBy: text.endIndex),
                  text[start..<end].caseInsensitiveCompare(candidate.word) == .orderedSame else { continue }
            if end < text.endIndex, Self.isWordCharacter(text[end]) { continue }
            return (candidate, end)
        }
        return nil
    }
}
