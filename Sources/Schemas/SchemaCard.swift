import Canvas
import CoreGraphics

/// A JSON Schema on the canvas, drawn as a card listing its fields. The schema is kept as its text,
/// not as a parsed value: a dictionary would lose the order its properties were written in (which
/// the card shows, and whoever wrote them cares about), and a schema being typed isn't JSON for a
/// while. Its name is the schema's own `"title"`: one place to say it.
public struct SchemaCard: BoxShapeProps {
    public static let kind: ShapeKind = "schema-card"
    /// Append only. The count is the version boards record.
    public static let migrations: [PropsMigration] = []
    public static let properties = Properties<SchemaCard>(title: "Schema card") {
        Property("frame", \.frame).required()
        Property("schema", \.schema)
            .description("A JSON Schema, as text: its properties in the order written, kept as typed while it isn't JSON. Its \"title\" is the card's name.")
            .keywords(["contentMediaType": .string("application/schema+json")])
        Property("prompt", \.prompt).description("What the schema should hold, in words.")
    }
    /// A placed card: 240 wide (as a task card), and as tall as the empty card, which `starter` is.
    public static let defaultSize = CGSize(width: SchemaCardMetrics.defaultWidth, height: SchemaCardMetrics.emptyHeight)
    /// A new card's schema: an object with no properties yet.
    public static let starter = """
    {
      "type": "object",
      "properties": {}
    }
    """

    public var frame: CGRect
    /// Written with `setSchema`, which keeps the card as tall as what it lists.
    public internal(set) var schema: String
    public var prompt: String

    /// A card as it is: its frame isn't fitted to its schema (see `setSchema`).
    public init(frame: CGRect = .zero, schema: String = SchemaCard.starter, prompt: String = "") {
        self.frame = frame
        self.schema = schema
        self.prompt = prompt
    }

    public init() { self.init(frame: .zero) }

    /// Sets the schema's text and, if it's JSON, the card's height to what it lists, keeping its
    /// top-left corner and width (so the card grows and shrinks downward, in the same transaction).
    /// A text that isn't JSON leaves the frame as it was: a typo doesn't make the card jump.
    public mutating func setSchema(_ text: String) {
        schema = text
        if let height = SchemaCard.height(for: text) { frame.size.height = height }
    }

    /// Renames the schema: sets its root `"title"` (added first if there's none; removed when
    /// `title` is blank), changing nothing else in the text. Does nothing unless the schema is a
    /// JSON object.
    public mutating func setTitle(_ title: String) {
        guard let text = SchemaCard.retitled(schema, title) else { return }
        setSchema(text)
    }

    /// The height a card's content sets: 45 and 22 a row (at most 7 fields, and the rules line), or
    /// the empty card's 89 for a schema with no fields. Nil for a text that isn't JSON. Arithmetic
    /// only: no text is measured, and the width never matters.
    public static func height(for schema: String) -> CGFloat? {
        let document = SchemaDocument(schema)
        guard document.error == nil else { return nil }
        return SchemaCardMetrics.height(rows: SchemaCardMetrics.rows(for: document))
    }
}

extension SchemaCard {
    /// `text` with its root object's `"title"` set to `title`, or nil if it isn't a JSON object.
    static func retitled(_ text: String, _ title: String) -> String? {
        guard let root = try? JSONReader.read(text), let members = root.members else { return nil }
        let utf8 = Array(text.utf8)
        func replacing(_ range: Range<Int>, with new: String) -> String {
            String(decoding: utf8[..<range.lowerBound], as: UTF8.self) + new + String(decoding: utf8[range.upperBound...], as: UTF8.self)
        }
        let blank = title.allSatisfy(\.isWhitespace)
        if let i = members.lastIndex(where: { $0.key == "title" }) {
            let member = members[i]
            guard blank else { return replacing(member.value.range, with: JSONReader.literal(title)) }
            // Removed with its comma, and the space before the next member's key (the member's own
            // indentation stays, for the member that takes its place).
            if i + 1 < members.count { return replacing(member.keyRange.lowerBound..<members[i + 1].keyRange.lowerBound, with: "") }
            if i > 0 { return replacing(members[i - 1].value.range.upperBound..<member.value.range.upperBound, with: "") }
            return replacing(root.range.lowerBound + 1..<root.range.upperBound - 1, with: "")
        }
        guard !blank else { return text }
        let name = JSONReader.literal(title)
        guard let first = members.first else {
            return replacing(root.range.lowerBound + 1..<root.range.upperBound - 1, with: " \"title\": \(name) ")
        }
        // First, laid out as the first member is: indented the same, or compact.
        let space = String(decoding: utf8[root.range.lowerBound + 1..<first.keyRange.lowerBound], as: UTF8.self)
        let member = space.isEmpty ? "\"title\":\(name)," : "\"title\": \(name),\(space)"
        return replacing(first.keyRange.lowerBound..<first.keyRange.lowerBound, with: member)
    }
}

/// The card's vertical metrics, in world units: all that decides its height, so the height is
/// arithmetic (no fonts), nonisolated, beside the props. `SchemaStyle` keeps the rest of the look.
public enum SchemaCardMetrics {
    public static let defaultWidth: CGFloat = 240
    public static let padding: CGFloat = 12
    /// The title's line: what 14-point semibold system text takes, as the task card measures it.
    public static let titleLineHeight: CGFloat = 17
    public static let headerGap: CGFloat = 8
    public static let chipHeight: CGFloat = 18
    /// A chip, and the gap under it.
    public static let rowHeight: CGFloat = 22
    public static let rowGap: CGFloat = rowHeight - chipHeight
    /// The empty, invalid and not-an-object states' box.
    public static let stateHeight: CGFloat = 40
    /// At most this many field rows: 8 fields or more show 6 and "+N more".
    public static let maxRows = 7
    /// A card with no rows (a state).
    public static let emptyHeight = height(rows: 0)

    /// How tall a card of `rows` rows is (field rows, "+N more", the rules line); 0 is a state.
    public static func height(rows: Int) -> CGFloat {
        let body = rows == 0 ? stateHeight : CGFloat(rows) * rowHeight - rowGap
        return padding + titleLineHeight + headerGap + body + padding
    }

    /// The rows a schema's content wants: its top-level fields, at most `maxRows`, and the rules
    /// line if it has rules. 0 for a text that isn't a JSON object, or has no fields.
    public static func rows(for document: SchemaDocument) -> Int {
        guard document.isObject, !document.fields.isEmpty else { return 0 }
        return min(document.fields.count, maxRows) + (document.rules.isEmpty ? 0 : 1)
    }
}
