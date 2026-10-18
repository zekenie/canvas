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
/// color, and no note of the type holds anything for it.
public enum TypeColorDirective {
    /// The member's key in the root's `properties`, and its one keyword: the color.
    public static let name = "color"
    public static let key = "$" + name
    public static let keyword = "const"

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
        guard let member = root["properties"]?[key] else { return .none }
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
        guard let color else { return removed(from: text) }
        let literal = JSONReader.literal(color.text)
        guard let root = try? JSONReader.read(text), root.isObject else { return nil }
        if let constant = root["properties"]?[key]?.members?.last(where: { $0.key == keyword })?.value {
            return constant.string == color.text ? text : replacing(constant.range, in: text, with: literal)
        }
        return setting(raw: "{\"\(keyword)\": \(literal)}", in: text)
    }

    /// `written` with the `$color` member `held` has, as `held` writes it, when `written` has none: a
    /// schema written whole (draw's `schema:`, the model's) keeps the type's color unless it says one.
    /// `written` as it is when it has a `$color`, when either isn't a JSON object, or `held` has none.
    public static func carried(from held: String?, into written: String) -> String {
        guard let held, let new = try? JSONReader.read(written), new.isObject, new["properties"]?[key] == nil,
              let old = try? JSONReader.read(held), let value = old["properties"]?[key] else { return written }
        return setting(raw: slice(value.range, of: held), in: written) ?? written
    }

    /// `text` without its `$color`, as the model is sent a schema: the color is no business of its.
    public static func stripped(_ text: String) -> String { removed(from: text) ?? text }

    /// Whether two schemas' texts are the same but for their `$color`: what a type given another color
    /// changes, which says nothing of its fields.
    public static func sameButColor(_ a: String, _ b: String) -> Bool {
        a == b || (a.contains(key) || b.contains(key)) && stripped(a) == stripped(b)
    }

    /// `text` with `raw` as its `$color`'s value: in place of the one it has, else put in.
    private static func setting(raw: String, in text: String) -> String? {
        guard let root = try? JSONReader.read(text), root.isObject else { return nil }
        guard let properties = root.members?.last(where: { $0.key == "properties" })?.value else {
            return inserting("\"properties\": {\"\(key)\": \(raw)}", into: root, in: text)
        }
        guard let members = properties.members else { return nil }
        if let member = members.last(where: { $0.key == key }) { return replacing(member.value.range, in: text, with: raw) }
        return inserting("\"\(key)\": \(raw)", into: properties, in: text)
    }

    /// `text` with `member` first in `object`, on the line its first member is on and indented as that
    /// is (after it with a space where that member has one after its colon, and none in a compact
    /// text), or, in an empty one, on a line of its own one step in from the object's line when the
    /// text has lines, else inside the braces.
    private static func inserting(_ member: String, into object: JSONNode, in text: String) -> String {
        let utf8 = Array(text.utf8)
        let inside = object.range.lowerBound + 1..<object.range.upperBound - 1
        guard let first = object.members?.first else {
            guard utf8.contains(UInt8(ascii: "\n")) else { return replacing(inside, in: text, with: member) }
            let outer = indentation(ofLineAt: object.range.lowerBound, in: utf8)
            return replacing(inside, in: text, with: "\n\(outer)\(step(in: utf8))\(member)\n\(outer)")
        }
        var space = String(decoding: utf8[inside.lowerBound..<first.keyRange.lowerBound], as: UTF8.self)
        if space.isEmpty, utf8[first.keyRange.upperBound..<first.value.range.lowerBound].contains(UInt8(ascii: " ")) { space = " " }
        return replacing(first.keyRange.lowerBound..<first.keyRange.lowerBound, in: text, with: "\(member),\(space)")
    }

    /// `text` without its root `properties`' `$color` members, each with its comma and the space
    /// before the next member's key; the text itself when there are none, nil when it isn't a JSON
    /// object.
    private static func removed(from text: String) -> String? {
        var text = text
        // One a pass, the last first: a schema holds one, and rarely two.
        while true {
            guard let root = try? JSONReader.read(text), root.isObject else { return nil }
            guard let properties = root["properties"], let members = properties.members,
                  let i = members.lastIndex(where: { $0.key == key }) else { return text }
            let member = members[i]
            if i + 1 < members.count {
                text = replacing(member.keyRange.lowerBound..<members[i + 1].keyRange.lowerBound, in: text, with: "")
            } else if i > 0 {
                text = replacing(members[i - 1].value.range.upperBound..<member.value.range.upperBound, in: text, with: "")
            } else {
                text = replacing(properties.range.lowerBound + 1..<properties.range.upperBound - 1, in: text, with: "")
            }
        }
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

    // MARK: Text

    private static func replacing(_ range: Range<Int>, in text: String, with new: String) -> String {
        let utf8 = Array(text.utf8)
        return String(decoding: utf8[..<range.lowerBound], as: UTF8.self) + new + String(decoding: utf8[range.upperBound...], as: UTF8.self)
    }

    private static func slice(_ range: Range<Int>, of text: String) -> String {
        String(decoding: Array(text.utf8)[range], as: UTF8.self)
    }

    /// The spaces and tabs a line starts with: the line `offset` is on.
    private static func indentation(ofLineAt offset: Int, in utf8: [UInt8]) -> String {
        var start = offset
        while start > 0, utf8[start - 1] != UInt8(ascii: "\n") { start -= 1 }
        var end = start
        while end < utf8.count, utf8[end] == UInt8(ascii: " ") || utf8[end] == UInt8(ascii: "\t") { end += 1 }
        return String(decoding: utf8[start..<end], as: UTF8.self)
    }

    /// One step of indentation, as the text's first indented line has it: two spaces in a text that
    /// has none.
    private static func step(in utf8: [UInt8]) -> String {
        var i = 0
        while i < utf8.count {
            if utf8[i] == UInt8(ascii: "\n") {
                var end = i + 1
                while end < utf8.count, utf8[end] == UInt8(ascii: " ") || utf8[end] == UInt8(ascii: "\t") { end += 1 }
                if end > i + 1 { return String(decoding: utf8[(i + 1)..<end], as: UTF8.self) }
            }
            i += 1
        }
        return "  "
    }
}
