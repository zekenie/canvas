import Canvas
import CoreGraphics

/// A JSON Schema on the canvas, drawn as a card of what it holds in words (its prompt, typed on the
/// card), which the editor's language model writes the schema from, and back (`SchemaSync`). The
/// schema is kept as its text, not as a parsed value: a dictionary would lose the order its
/// properties were written in (which whoever wrote them cares about), and a schema being typed
/// isn't JSON for a while; its panel is where it's written. Its name is the schema's own `"title"`:
/// one place to say it, shown in its title's pill.
public struct SchemaCard: BoxShapeProps {
    public static let kind: ShapeKind = "schema-card"
    /// Append only. The count is the version boards record.
    public static let migrations: [PropsMigration] = []
    public static let properties = Properties<SchemaCard>(title: "Schema card") {
        Property("frame", \.frame).required()
        Property("schema", \.schema)
            .description("A JSON Schema, as text: its properties in the order written, kept as typed while it isn't JSON. Its \"title\" is the card's name.")
            .keywords(["contentMediaType": .string("application/schema+json")])
        Property("prompt", \.prompt).description("What the schema should hold, in words: what the card shows.")
    }
    /// A placed card: 240 wide (as a subboard), and as tall as one line of its description (52).
    public static let defaultSize = CGSize(width: SchemaCardMetrics.defaultWidth, height: SchemaCardMetrics.emptyHeight)
    /// A new card's schema: an object with no properties yet.
    public static let starter = """
    {
      "type": "object",
      "properties": {}
    }
    """

    public var frame: CGRect
    public var schema: String
    /// Written with `setPrompt`, which keeps the card as tall as its text.
    public internal(set) var prompt: String

    /// A card as it is: its frame isn't fitted to its description (see `setPrompt`).
    public init(frame: CGRect = .zero, schema: String = SchemaCard.starter, prompt: String = "") {
        self.frame = frame
        self.schema = schema
        self.prompt = prompt
    }

    public init() { self.init(frame: .zero) }

    /// Sets the description and the card's height to its text at the card's width, set as the card
    /// sets it (a note's text: `SchemaStyle`), keeping its top-left corner and width, so the card
    /// grows and shrinks downward in the same transaction; never shorter than one line
    /// (`SchemaCardMetrics.emptyHeight`). A card too narrow for text keeps its height.
    @MainActor public mutating func setPrompt(_ text: String) {
        prompt = text
        frame.size.height = SchemaStyle.fittedHeight(of: text, width: frame.width, keeping: frame.height)
    }

    /// Renames the schema: sets its root `"title"` (added first if there's none; removed when
    /// `title` is blank), changing nothing else in the text. Does nothing unless the schema is a
    /// JSON object.
    public mutating func setTitle(_ title: String) {
        guard let text = SchemaCard.retitled(schema, title) else { return }
        schema = text
    }

    /// What an untitled card is called in its panel's header and its row, beside its kind's `{}`.
    /// On the canvas it has no title's pill, as an untitled note has none.
    public static let untitled = "Untitled"
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

/// The metrics a card's size comes from, in world units, nonisolated, beside the props: its
/// description is set as a note's text is, in its padding, and measured at that
/// (`SchemaStyle.fittedHeight`, on the main actor, where fonts are). `SchemaStyle` keeps the rest of
/// the look.
public enum SchemaCardMetrics {
    public static let defaultWidth: CGFloat = 240
    /// The description's inset from every edge, and each of its lines' height: a note's.
    public static let padding: CGFloat = 16
    public static let lineHeight: CGFloat = 19
    /// A card of one line, or none: the least a card is, and a new one. A line's height with half a
    /// point spare, so string drawing never cuts it (`SchemaStyle.fittedHeight`), and the padding.
    public static let emptyHeight = (lineHeight + 0.5).rounded(.up) + padding * 2
}
