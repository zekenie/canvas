import CanvasRPC
import CoreGraphics
import Foundation
import Palette

// A shape's parts: the rows of a kind made of rows (a table's columns, an enum's values), each with an id of the
// shape's own that a copy keeps, so another shape can one day name a row of it as it names the shape. The core
// knows what a part is and never which kinds have them, as it knows shapes and never which kinds exist: a kind
// says its parts from its record (`PartedShape`) and where each is in its kept geometry (`ShapeGeometry.parts`).
// Nothing binds a part yet; what names one (an arrow's end, a mention, a pill) comes with the rows that need it.

/// A part's identity, the shape's own: two words, as `ShapeID` is, written as a UUID string. Unique within its
/// shape, not the file: a copy of the shape keeps its parts' ids, so what names a part names it by its shape and it.
public struct PartID: Hashable, Sendable, CustomStringConvertible {
    private let high: UInt64
    private let low: UInt64

    public init(_ rawValue: UUID = UUID()) {
        (high, low) = withUnsafeBytes(of: rawValue.uuid) { ($0.loadUnaligned(as: UInt64.self), $0.loadUnaligned(fromByteOffset: 8, as: UInt64.self)) }
    }

    /// The UUID it is.
    public var rawValue: UUID {
        var uuid: uuid_t = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        withUnsafeMutableBytes(of: &uuid) { bytes in
            bytes.storeBytes(of: high, as: UInt64.self)
            bytes.storeBytes(of: low, toByteOffset: 8, as: UInt64.self)
        }
        return UUID(uuid: uuid)
    }

    public var description: String { rawValue.uuidString }
}

/// As the UUID's string, wherever a part's id is written: in a board, in a row's props.
extension PartID: Codable {
    public init(from decoder: any Decoder) throws {
        self.init(try decoder.singleValueContainer().decode(UUID.self))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension PartID: SchemaDescribed {
    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        definitions.core("part-id", of: Self.self) { _ in
            ["type": "string", "format": "uuid", "description": "A part of its shape (a row), the shape's own: a copy keeps it."]
        }
    }
}

/// A shape, or one part of it. Nil part: the shape as a whole. Not `ShapeNaming`, for the reason a `ShapeID` isn't:
/// a binding holds it, and a name of a part is a value of its own that holds one.
public struct PartAddress: Hashable, Sendable, Codable, CustomStringConvertible {
    public var shape: ShapeID
    public var part: PartID?

    public init(_ shape: ShapeID, part: PartID? = nil) {
        self.shape = shape
        self.part = part
    }

    public var description: String { part.map { "\(shape)/\($0)" } ?? shape.description }
}

extension PartAddress: SchemaDescribed {
    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        definitions.core("part-address", of: Self.self) { definitions in
            let shape = ShapeID.schema(in: &definitions), part = PartID.schema(in: &definitions)
            return ["type": "object",
             "properties": ["shape": .object(shape), "part": .object(part)],
             "required": ["shape"],
             "additionalProperties": false,
             "description": "A shape, or one part of it (a row)."]
        }
    }
}

/// What a part is called and what kind of part it is, from its shape's record (`PartedShape.parts(of:)`): the one
/// source every reader of rows goes by (a picker, a pill, Find, VoiceOver).
public struct PartName: Hashable, Sendable {
    public var id: PartID
    /// Its whole name: "customer_id", "pending".
    public var name: String
    /// What kind of part it is, in words, capitalized: "Column", "Value".
    public var kindWord: String
    /// What leads it where it's listed: a symbol (an SF Symbol's name), a word in a chip, or nothing.
    public var lead: PartLead
    /// Whether it stands alone, so a pill for it is a pill for it (an endpoint), or is read with its shape (a
    /// column, "id in orders").
    public var standsAlone: Bool
    /// False for a part nothing is bound to, which heads rows (an API's path prefix): no end of a connection, by a drag, ⌘L or a
    /// name (`PartFrame.isConnectable` is the same on the board).
    public var isConnectable: Bool
    /// Whether it is all its shape is (an endpoint taken out of its API: one shape, one row), so a list that names shapes and rows
    /// lists it once, as its row (the `@` picker and ⌘L both); and the shape as a whole is that row wherever it is mentioned or
    /// stood for: drawn as the row (`MentionResolution.whole`), and moved with it (`moveParts` takes a key with no part) when the
    /// shape goes into another shape as a row. An API's endpoint, which is one of its shape's rows, is not, whether or not it's the
    /// only one.
    public var isItsShape: Bool

    public init(id: PartID, name: String, kindWord: String, lead: PartLead = .none, standsAlone: Bool = false, isConnectable: Bool = true,
                isItsShape: Bool = false) {
        self.id = id
        self.name = name
        self.kindWord = kindWord
        self.lead = lead
        self.standsAlone = standsAlone
        self.isConnectable = isConnectable
        self.isItsShape = isItsShape
    }
}

/// What leads a part where it's listed.
public enum PartLead: Hashable, Sendable {
    case none
    /// An SF Symbol's name: a key for a primary key.
    case symbol(String)
    /// A word in a chip of a color, white on it: a method in its color (an endpoint's `POST`), the same in both appearances.
    case chip(String, fill: RGB)
}

/// Where one part is on the board shown, in world units: what an arrow will meet, and what a ring will go round.
public struct PartFrame: Hashable, Sendable {
    public var id: PartID
    /// As wide as the shape at the row, so its left and right edges are the shape's.
    public var rect: CGRect
    /// False for a part the shape shows none of (a row folded away): `rect` is then what it shows in its place.
    public var isShown: Bool
    /// False for a part nothing is bound to, which heads rows and is no end of a connection (a path prefix's header): it shows
    /// no port's dots, and an end let go on it binds the nearest part that is one.
    public var isConnectable: Bool

    public init(id: PartID, rect: CGRect, isShown: Bool = true, isConnectable: Bool = true) {
        self.id = id
        self.rect = rect
        self.isShown = isShown
        self.isConnectable = isConnectable
    }
}

/// A shape's parts where they are, in reading order, and looked up by id: kept with the rest of its geometry, so a
/// part's rect is worked out once with it. A part the list doesn't have is gone.
public struct PartFrames: Sendable, Equatable, RandomAccessCollection {
    public let frames: [PartFrame]
    /// The parts shown, in the order of `frames`: top to bottom, whatever a part folded away stands at. What a search by
    /// height halves, since a hidden part's rect is a line another part has.
    public let shownFrames: [PartFrame]
    private let index: [PartID: Int]

    public init(_ frames: [PartFrame] = []) {
        self.frames = frames
        shownFrames = frames.allSatisfy(\.isShown) ? frames : frames.filter(\.isShown)
        var index: [PartID: Int] = [:]
        index.reserveCapacity(frames.count)
        for (offset, frame) in frames.enumerated() where index[frame.id] == nil { index[frame.id] = offset }
        self.index = index
    }

    public var startIndex: Int { frames.startIndex }
    public var endIndex: Int { frames.endIndex }
    public subscript(position: Int) -> PartFrame { frames[position] }

    /// The part with this id; nil for one the shape doesn't have.
    public func frame(_ id: PartID) -> PartFrame? { index[id].map { frames[$0] } }

    /// The part shown, of those an end may be bound to (`isConnectable`), whose rect is nearest `y` across (inside it, or the
    /// nearest edge's): what a point dropped on the shape meets. Nil with none shown.
    public func frame(nearestY y: CGFloat) -> PartFrame? {
        var best: PartFrame?, nearest = CGFloat.infinity
        for frame in frames where frame.isShown && frame.isConnectable {
            let distance = y < frame.rect.minY ? frame.rect.minY - y : y > frame.rect.maxY ? y - frame.rect.maxY : 0
            if distance < nearest { (best, nearest) = (frame, distance) }
        }
        return best
    }

    public static func == (a: Self, b: Self) -> Bool { a.frames == b.frames }
}
