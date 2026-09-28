import Foundation

/// A board of a file (`CanvasFile`): the root, or the board a shape owns, named by that shape's id.
/// Written "root" or the owner's UUID, wherever a board is named outside the file (view memory,
/// and later the agents' CLI).
public struct BoardID: Hashable, Sendable, CustomStringConvertible {
    /// The shape that owns the board; nil for the file's root board.
    public let owner: ShapeID?

    public static let root = BoardID(rawOwner: nil)

    /// The board `owner` owns.
    public init(owner: ShapeID) { self.init(rawOwner: owner) }

    private init(rawOwner: ShapeID?) { owner = rawOwner }

    /// "root", or an owner's UUID; nil for anything else.
    public init?(_ text: String) {
        if text == Self.root.description {
            self = .root
        } else if let uuid = UUID(uuidString: text) {
            self.init(owner: ShapeID(uuid))
        } else {
            return nil
        }
    }

    public var isRoot: Bool { owner == nil }

    public var description: String { owner?.description ?? "root" }
}

/// As its description: "root" or the owner's UUID.
extension BoardID: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let text = try container.decode(String.self)
        guard let board = BoardID(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(text) names no board: it's neither \"root\" nor a UUID")
        }
        self = board
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
