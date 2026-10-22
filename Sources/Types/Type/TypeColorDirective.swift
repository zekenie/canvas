import Canvas
import Colors

/// A type's color in its schema: `"$color": {"const": "blue"}`, a directive in the root's `properties`
/// beside `$title` (`SchemaDirectives`: no field), its `const` a literal, a color's name or a hex value
/// as a shape's `color` holds one (`ShapeColor`). It says what the type's shape's own color says
/// (Colors' `color`, what the type is drawn in: `TypeColors`), and every write keeps the two saying it
/// (`keep`, the rule `canBeType()` gives the kind): a color given to a type (the panel's row, `/color`,
/// Color ▸, draw's `color:`, a file's color renamed or removed) is written in its JSON in the same step,
/// and one written in its JSON (by hand, by draw's `schema:`, by words that are JSON) is its color;
/// taking the member out takes the color away. The type's own: a type built on it is drawn in its own
/// color, and no note of the type holds anything for it. One of two such members (`HeldDirective`).
public enum TypeColorDirective {
    /// The member's key in the root's `properties`, and its one keyword: the color.
    public static let name = "color"
    public static let key = "$" + name
    public static let keyword = HeldDirective.keyword
    static let directive = HeldDirective(name: name)

    /// What a schema says of its type's color.
    public enum Reading: Equatable, Sendable {
        /// No `$color`.
        case none
        case color(ShapeColor)
        /// A `$color` that isn't `{"const": <a color>}`.
        case notAColor
    }

    /// What `text` says; nil while it isn't a JSON object (a text being typed says nothing).
    public static func reading(of text: String) -> Reading? {
        guard let root = try? JSONReader.read(text), root.isObject else { return nil }
        return reading(of: root)
    }

    /// What a schema's root says (the last `$color` of the last `properties`, as JSON is read).
    public static func reading(of root: JSONNode) -> Reading {
        guard let member = directive.member(in: root) else { return .none }
        guard let literal = member[keyword]?.string, let color = ShapeColor(literal) else { return .notAColor }
        return .color(color)
    }

    /// Whether a reading says what a shape's own color does: none for none, the color for the color (a
    /// name whatever its case).
    public static func says(_ reading: Reading, _ color: ShapeColor?) -> Bool {
        switch (reading, color) {
        case (.none, nil): true
        case let (.color(said), held?):
            if let a = said.name, let b = held.name { ShapeColor.key(of: a) == ShapeColor.key(of: b) } else { said == held }
        default: false
        }
    }

    // MARK: Writing it

    /// `text` saying `color` as its type's: the `const` of its `$color` replaced (the member's value
    /// made `{"const": …}` if it was something else), else the member put in first in the root's
    /// `properties` (and a `properties` put in the root, first, if it has none); with nil, every
    /// `$color` taken out. Nil when the text isn't a JSON object or its `properties` isn't one. The rest
    /// of the text stays as typed.
    public static func text(_ text: String, saying color: ShapeColor?) -> String? {
        guard let color else { return directive.removed(from: text) }
        return directive.text(text, saying: JSONReader.literal(color.text), isSaid: { $0.string == color.text })
    }

    // MARK: Keeping it

    /// The rule `canBeType()` gives a kind (`keepsInStep`): after every write a type's color and its
    /// `$color` say one thing. A write that changes the member (or a schema that comes with one: a
    /// shape put in, or made a type) gives the shape that color (none, the member taken out; nothing,
    /// one that isn't a color); else a write that changes the color (or a shape that comes, or is made
    /// a type, with one) writes it in the member, a text that isn't a JSON object staying as it is (a text
    /// before that wasn't one is taken as having said the color then). Two
    /// that disagree with neither changed (a board from before) are left: the next change to either
    /// puts them in step.
    public static func keep(_ before: AnyShapeRecord?, _ record: inout AnyShapeRecord) {
        guard let schema = record[TypeSchemaProperty.self] else { return }
        let held = before?[TypeSchemaProperty.self]
        let color = record.ownColor
        let colorMoved = held == nil || before?.ownColor != color
        let textMoved = held?.text != schema.text
        // With no color and no `$color` in the text there is nothing to keep, and nothing to read.
        guard colorMoved || textMoved, color != nil || schema.text.contains(key) || held?.text.contains(key) == true,
              let now = reading(of: schema.text), !says(now, color) else { return }
        // The member moved when the text before said otherwise; a text before that was being typed (no JSON)
        // is taken as having said the color the shape held then, so a member typed away keystroke by keystroke
        // takes the color with it; a shape that held no schema before moved it by holding one.
        let directiveMoved = textMoved && (held.map { reading(of: $0.text).map { $0 != now } ?? !says(now, before?.ownColor) } ?? (now != .none))
        if directiveMoved {
            switch now {
            case .none: record[ColorProperty.self] = nil
            case .color(let said): record[ColorProperty.self] = spelled(said)
            case .notAColor: break
            }
        } else if colorMoved, let written = text(schema.text, saying: color), written != schema.text {
            record[TypeSchemaProperty.self] = SchemaText(written)
        }
    }

    /// A built-in name in its list's spelling (`Blue` is `blue`), as Colors stores one; a file's own
    /// name as written (its spelling is the file's to say), a value as it is.
    private static func spelled(_ color: ShapeColor) -> ShapeColor {
        color.name.flatMap(BuiltInColors.named).map(\.color) ?? color
    }
}
