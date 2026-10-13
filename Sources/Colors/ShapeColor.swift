import Canvas
import Foundation
import Palette

/// A color a shape holds: one of the named colors, by its name (`blue`, or a name the file added),
/// or a value of its own (`#4465E9`). On a board it's one string. A name is kept as written and
/// found whatever its case; what it looks like is the palette's to say (`ColorBook`), so changing a
/// file's color's value recolors every shape that names it and rewrites none.
public enum ShapeColor: Hashable, Sendable {
    case named(String)
    case value(RGB)

    /// The media type the string has in a kind's schema (`contentMediaType`): what draw and queries
    /// read a color by.
    public static let mediaType = "text/x-canvas-color"

    /// A color as it's written: a hex value (`#4465E9`, `#46E`), else a name, on one line with the
    /// spaces at its ends dropped. Nil for nothing, and for what starts `#` and isn't a hex value.
    public init?(_ text: String) {
        let name = Self.folded(text)
        if name.isEmpty { return nil }
        if name.hasPrefix("#") {
            guard let value = RGB(hexString: name) else { return nil }
            self = .value(value)
        } else {
            self = .named(name)
        }
    }

    /// How it's written: the name, or the value as `#RRGGBB`.
    public var text: String {
        switch self {
        case .named(let name): name
        case .value(let value): value.hexString
        }
    }

    /// The name, for a named one.
    public var name: String? {
        if case .named(let name) = self { return name }
        return nil
    }

    /// A name on one line: each run of whitespace one space, none at its ends.
    public static func folded(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// What two spellings of one name share: a name is found whatever its case.
    public static func key(of name: String) -> String {
        folded(name).lowercased()
    }
}

extension ShapeColor: Codable {
    /// Any string reads: what isn't a hex value is a name, which the file has or lacks. A board
    /// written by hand is never refused for its color.
    public init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        self = ShapeColor(text) ?? .named(Self.folded(text))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(text)
    }
}

extension ShapeColor: SchemaDescribed {
    public static func schema(in _: inout SchemaDefinitions) -> JSONObject {
        ["type": "string", "contentMediaType": .string(mediaType)]
    }
}
