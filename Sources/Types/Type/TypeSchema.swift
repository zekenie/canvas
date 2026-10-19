import Canvas
import CanvasRPC
import Foundation
import Mentions

/// What makes a shape a Type: its JSON Schema, kept as its text (`SchemaText`: order and half-typed
/// text survive), an added property of the kinds whose words can say what a type holds
/// (`canBeType()`: a note). A shape holding one is a Type, and one without isn't: there's no other
/// mark. It's written whole by `/is-a type` (the starter, or its words) and by the sync from the shape's words
/// (`TypeSync`), and by hand in the panel's Schema tab. Its `$ref`s to `urn:uuid:` and another
/// type's id refer to that type (`SchemaReferences`), so the value names shapes (`ShapeNaming`), as
/// mention text does: a copy refers to the copies made with it. It holds no root `"title"` of its
/// own: a type's name is its shape's title (Titles), put in only for what's sent to the model.
public enum TypeSchemaProperty {}

extension TypeSchemaProperty: ShapeProperty {
    public static let key: PropertyKey = "schema"
    public static var defaultValue: SchemaText? { nil }
    public static var keywords: PropertyKeywords<SchemaText> {
        PropertyKeywords()
            .description("A JSON Schema, as text, which makes the shape a type named by its title: its properties in the order written, kept as typed while it isn't JSON. A \"$ref\" to \"urn:uuid:\" and another type's id refers to that type.")
            .keywords(["contentMediaType": .string("application/schema+json")])
    }

    /// A new type's schema: an object with no properties yet.
    public static let starter = """
    {
      "type": "object",
      "properties": {}
    }
    """
}

/// A shape's words taken as its schema when it is made a type: they are the schema when they are a
/// JSON object, as written but for the whitespace around them (the removal of `/is-a type`'s line
/// leaves a line break the schema should not start or end with).
enum TypeWordsSchema {
    /// The words as a schema; nil if they hold a mention (a pill inside a JSON string still parses),
    /// or trimmed are empty or not a JSON object (an array, a scalar, text).
    static func schema(fromWords words: MentionText) -> String? {
        guard words.mentioned.isEmpty else { return nil }
        let text = words.stored.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let root = try? JSONReader.read(text), root.members != nil else { return nil }
        return text
    }
}

/// A type's name in its schema's text, which holds none of its own: put in as the root `"title"`
/// for what's sent to the model, and taken out of what it writes back (`TypeSync`). A root
/// `"title"` the person typed is kept as typed, and never the name.
enum TypeNaming {
    /// The root object's `"title"`, if the text is a JSON object with one that's a string.
    static func title(of text: String) -> String? {
        guard let root = try? JSONReader.read(text), let members = root.members else { return nil }
        return members.last(where: { $0.key == "title" })?.value.string
    }

    /// `text` with `name` as its root `"title"`, first, laid out as the first member is (indented
    /// the same, or compact); nil if it isn't a JSON object, and the text as it is if it has one.
    static func titled(_ text: String, _ name: String) -> String? {
        guard let root = try? JSONReader.read(text), let members = root.members else { return nil }
        guard !members.contains(where: { $0.key == "title" }), !name.allSatisfy(\.isWhitespace) else { return text }
        let utf8 = Array(text.utf8), literal = JSONReader.literal(name)
        func replacing(_ range: Range<Int>, with new: String) -> String {
            String(decoding: utf8[..<range.lowerBound], as: UTF8.self) + new + String(decoding: utf8[range.upperBound...], as: UTF8.self)
        }
        guard let first = members.first else {
            return replacing(root.range.lowerBound + 1..<root.range.upperBound - 1, with: " \"title\": \(literal) ")
        }
        let space = String(decoding: utf8[root.range.lowerBound + 1..<first.keyRange.lowerBound], as: UTF8.self)
        let member = space.isEmpty ? "\"title\":\(literal)," : "\"title\": \(literal),\(space)"
        return replacing(first.keyRange.lowerBound..<first.keyRange.lowerBound, with: member)
    }

    /// `text` without its root `"title"` (with its comma, and the space before the next member's
    /// key; the member's own indentation stays, for the member that takes its place), and what it
    /// said; nil if it isn't a JSON object or has none.
    static func untitled(_ text: String) -> (text: String, title: String?)? {
        guard let root = try? JSONReader.read(text), let members = root.members,
              let i = members.lastIndex(where: { $0.key == "title" }) else { return nil }
        let utf8 = Array(text.utf8), member = members[i]
        func removing(_ range: Range<Int>) -> String {
            String(decoding: utf8[..<range.lowerBound], as: UTF8.self) + String(decoding: utf8[range.upperBound...], as: UTF8.self)
        }
        let title = member.value.string.flatMap { $0.allSatisfy(\.isWhitespace) ? nil : $0 }
        if i + 1 < members.count { return (removing(member.keyRange.lowerBound..<members[i + 1].keyRange.lowerBound), title) }
        if i > 0 { return (removing(members[i - 1].value.range.upperBound..<member.value.range.upperBound), title) }
        return (removing(root.range.lowerBound + 1..<root.range.upperBound - 1), title)
    }
}
