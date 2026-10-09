import Canvas
import Foundation
import Topology

// A shape is a type's instance by naming the type: `is`, an added property, the types a shape is, in
// the order they were added (a later one wins where two say the same). Types holds the list and
// derives the `is-a` edge from it; it knows no kind, a kind opts in (`typeable()`).

/// One entry of a shape's `is`: the type it is, named by the type's shape id. A name, not a binding
/// (`ShapeNaming`): a copy of an instance copied with its type is an instance of the copy, one
/// copied alone stays an instance of the original, and a type that is deleted leaves the name
/// behind, pointing nowhere until the delete is undone. A wrapper of the id and not the id itself,
/// which must not name shapes (an arrow's bindings are ids, and are not names); coded by hand as the
/// bare uuid string.
public struct TypeLink: Hashable, Sendable {
    public var shape: ShapeID

    public init(_ shape: ShapeID) { self.shape = shape }

    /// The media type draw and queries read a list of these by (`contentMediaType`): the entries are
    /// shapes, written there by their titles.
    public static let mediaType = "text/x-canvas-type"
}

extension TypeLink: Codable {
    public init(from decoder: any Decoder) throws {
        shape = try decoder.singleValueContainer().decode(ShapeID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(shape)
    }
}

extension TypeLink: SchemaDescribed {
    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        definitions.reference("type-link", of: Self.self) { _ in
            ["type": "string", "format": "uuid", "contentMediaType": .string(mediaType),
             "description": "A type it is, by the id of the shape that is the type, which may be gone."]
        }
    }
}

extension TypeLink: ShapeNaming {
    public func forEachNamedShape(_ body: (ShapeID) -> Void) { body(shape) }

    public func renamingShapes(_ rename: (ShapeID) -> ShapeID?) -> TypeLink {
        TypeLink(rename(shape) ?? shape)
    }
}

/// What a shape is: an ordered list of the types it is, in the order they were added, none twice
/// (`uniqueItems`). Empty is none, so emptying the list takes the property off the shape. Added to
/// the kinds that opt in (`typeable()`).
public enum IsAProperty {}

extension IsAProperty: ShapeProperty {
    public static let key: PropertyKey = "is"
    public static var defaultValue: [TypeLink]? { nil }
    public static func isNone(_ value: [TypeLink]) -> Bool { value.isEmpty }
    public static var keywords: PropertyKeywords<[TypeLink]> {
        PropertyKeywords()
            .description("The types the shape is, by the ids of the shapes that are them, in the order they were added: a later one wins where two say the same.")
            .keywords(["uniqueItems": true])
    }
}

/// The edge from a shape to each type it is, a root, derived from `is` (Topology's property rule):
/// one per entry, in the slot `is`, from the shape that holds the list to the type it names (an
/// entry that names a stand-in is forwarded to what it stands for, as every edge into one is).
public enum IsAEdge {}

extension IsAEdge: EdgeType {
    public static let id: EdgeTypeID = "is-a"
    public static let summary: String? = "from a shape to each type it is, in the order of its list"
}

extension ShapeRegistrar {
    /// This kind's shapes can be instances of types: each may hold `is`, the types it is. Needs
    /// `typeWords` (`TypeWords.check`): a shape's types are typed on a line of its words (`/is-a`).
    public mutating func typeable() {
        optIn(to: IsAProperty.self)
    }
}

extension Registry {
    /// Whether the kind's shapes can be instances of types (`typeable()`).
    public func isTypeable(_ kind: ShapeKind) -> Bool {
        properties(for: kind).contains(IsAProperty.key)
    }
}
