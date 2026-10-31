import Canvas
import CanvasRPC
import Foundation
import Types

// A type's rules, as its schema holds them, and the rules a shape is checked against: those of every type along its
// chain, most general first.

/// A rule a type carries: a sentence in English that should hold of every shape of the type, and the phrases in it
/// that find shapes (chips: `find`), each with the query it was turned into.
public struct Rule: Hashable, Sendable {
    /// The sentence, as written.
    public var says: String
    /// The phrases in it that find shapes, in the order written.
    public var find: [RuleChip]

    public init(says: String, find: [RuleChip] = []) {
        self.says = says
        self.find = find
    }

    /// The rule with these words: the chips whose phrase is still in them, as words of their own, kept; the rest let go of.
    public func saying(_ words: String) -> Rule {
        Rule(says: words, find: find.filter { Self.range(of: $0.phrase, in: words) != nil })
    }

    /// Where each chip's phrase is in the sentence, in the order written: each phrase found after the one before it, else
    /// from the start, never as part of a longer word; a chip whose phrase isn't in the sentence has none.
    public var chipRanges: [(chip: RuleChip, range: Range<String.Index>)] {
        var found: [(RuleChip, Range<String.Index>)] = []
        var from = says.startIndex
        for chip in find {
            guard let range = Self.range(of: chip.phrase, in: says, from: from) ?? Self.range(of: chip.phrase, in: says) else { continue }
            found.append((chip, range))
            from = range.upperBound
        }
        return found
    }

    /// Where `phrase` is in `text`, at or after `from`, as words of its own: where its first or last character is a letter
    /// or a digit, the one beside it in the text isn't ("rest" is not in "interest").
    public static func range(of phrase: String, in text: String, from: String.Index? = nil) -> Range<String.Index>? {
        guard !phrase.isEmpty else { return nil }
        func word(_ character: Character?) -> Bool { character.map { $0.isLetter || $0.isNumber } ?? false }
        var start = from ?? text.startIndex
        while start <= text.endIndex, let found = text.range(of: phrase, range: start..<text.endIndex) {
            let before = found.lowerBound > text.startIndex ? text[text.index(before: found.lowerBound)] : nil
            let after = found.upperBound < text.endIndex ? text[found.upperBound] : nil
            if !(word(before) && word(phrase.first)) && !(word(after) && word(phrase.last)) { return found }
            start = text.index(after: found.lowerBound)
        }
        return nil
    }

    /// The sentence with each chip's phrase in brackets, as a request about one of them says it.
    public var bracketed: String {
        var text = says
        for (_, range) in chipRanges.reversed() {
            text.replaceSubrange(range, with: "[" + says[range] + "]")
        }
        return text
    }
}

/// A phrase in a rule that finds shapes, and the query it was turned into: nil until the words are interpreted (a
/// phrase picked as a shape has its query at once).
public struct RuleChip: Hashable, Sendable {
    public var phrase: String
    public var query: String?

    public init(phrase: String, query: String?) {
        self.phrase = phrase
        self.query = query
    }
}

/// A rule as a shape is checked against it: with the type it's on.
public struct ChainedRule: Hashable, Sendable {
    public var rule: Rule
    /// The type that carries it.
    public var type: ShapeID
    /// What the type is called, as the request says it: its title, else "Untitled".
    public var typeName: String

    public init(rule: Rule, type: ShapeID, typeName: String) {
        self.rule = rule
        self.type = type
        self.typeName = typeName
    }
}

/// Where a type keeps its rules, and reading them: `"$rules": {"const": [{"says": "…", "find": [{"phrase": "…",
/// "query": "…"}]}]}` in the root's `properties`, a directive Types holds aside (`registrar.typeDirective`), so the
/// model that keeps a type's words and schema in step never sees it and a schema written whole keeps it.
public enum RuleBook {
    /// The directive's name: `$rules`.
    public static let directive = "rules"

    /// A type's rules, as its schema's text says them, in order; none for text that isn't JSON, a schema without the
    /// member, or a member that isn't a list. A rule with no words, or that isn't an object, is passed over, and so is a
    /// chip without a phrase; a chip with no query (or an empty one) is words not interpreted yet.
    public static func rules(inSchema text: String) -> [Rule] {
        guard text.contains("$" + directive), let schema = try? JSON(text: text) else { return [] }
        return rules(inSchema: schema)
    }

    /// A type's rules, as its schema says them.
    public static func rules(inSchema schema: JSONValue) -> [Rule] {
        guard let list = schema["properties"]?["$" + directive]?["const"]?.arrayValue else { return [] }
        return list.compactMap { item -> Rule? in
            guard let says = item["says"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines), !says.isEmpty else { return nil }
            let find = (item["find"]?.arrayValue ?? []).compactMap { chip -> RuleChip? in
                guard let phrase = chip["phrase"]?.stringValue, !phrase.isEmpty else { return nil }
                let query = chip["query"]?.stringValue.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
                return RuleChip(phrase: phrase, query: query)
            }
            return Rule(says: says, find: find)
        }
    }

    /// `rules` as a schema's member says them: what `RuleWriter` writes.
    public static func member(_ rules: [Rule]) -> JSONValue {
        .object(["const": .array(rules.map { rule -> JSONValue in
            var object: [String: JSONValue] = ["says": .string(rule.says)]
            if !rule.find.isEmpty {
                object["find"] = .array(rule.find.map { chip -> JSONValue in
                    var item: [String: JSONValue] = ["phrase": .string(chip.phrase)]
                    if let query = chip.query { item["query"] = .string(query) }
                    return .object(item)
                })
            }
            return .object(object)
        })])
    }

    /// A type's rules, by its id, as the file has them now: none for a shape that is no type.
    @MainActor
    public static func rules(of type: ShapeID, in editor: CanvasEditor) -> [Rule] {
        guard let text = editor.withoutObservingDocument({ editor.file.record(type) })?[TypeSchemaProperty.self]?.text else { return [] }
        return rules(inSchema: text)
    }

    /// The rules `shape` is checked against: every rule of every type along its chain (`TypeIndex.lineage(of:)`, C3, the
    /// list read latest first), the most general type's first, each type's in the order written; so a more specific
    /// type's rules come later, as the request says they win. Empty for a type itself, which is checked by none.
    @MainActor
    public static func chain(for shape: ShapeID, in editor: CanvasEditor) -> [ChainedRule] {
        guard let types = editor.types else { return [] }
        return chain(for: shape, types: types) { rules(of: $0, in: editor) }
    }

    /// The same, a type's rules read by `rules` (a reader that keeps them).
    @MainActor
    static func chain(for shape: ShapeID, types: TypeIndex, rules: (ShapeID) -> [Rule]) -> [ChainedRule] {
        guard !types.isType(shape) else { return [] }
        var chained: [ChainedRule] = []
        for type in types.lineage(of: shape).reversed() where types.isType(type) {
            let found = rules(type)
            guard !found.isEmpty else { continue }
            let name = types.name(of: type) ?? "Untitled"
            chained += found.map { ChainedRule(rule: $0, type: type, typeName: name) }
        }
        return chained
    }

    /// The most general type along `shape`'s chain, by its name: what the questions call the shape ("does this car meet
    /// them?"), its first letter lower-case unless the name reads as an acronym or a name written so ("PR", "iPhone").
    @MainActor
    public static func noun(for shape: ShapeID, in editor: CanvasEditor) -> String? {
        guard let types = editor.types else { return nil }
        guard let root = types.lineage(of: shape).last(where: { types.isType($0) }), let name = types.name(of: root) else { return nil }
        return noun(of: name)
    }

    /// A type's name as a noun in a sentence.
    public static func noun(of name: String) -> String {
        let letters = Array(name)
        guard let first = letters.first, first.isUppercase else { return name }
        if letters.count > 1, letters[1].isUppercase { return name }
        return first.lowercased() + String(letters.dropFirst())
    }
}
