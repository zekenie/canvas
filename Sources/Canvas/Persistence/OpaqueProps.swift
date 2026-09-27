/// The props of a shape a board keeps but the app can't use: its kind isn't installed, it's from a
/// newer version of its kind, or it didn't load. Kept exactly as the JSON it was, at the version it
/// was, and written back that way. Nothing draws, hits, selects or edits it: definitions see only
/// their own props type, and horizontals that go through every shape skip `isOpaque` records.
struct OpaqueProps: ShapeProps {
    /// Never a record's kind: the record keeps the one it came with.
    static let kind = ShapeKind(rawValue: "")
    var json: JSONValue
    /// The version of its kind `json` is at.
    var version: Int

    init(json: JSONValue, version: Int) {
        self.json = json
        self.version = version
    }

    // As its JSON. (The board codec writes the version beside it.)
    init(from decoder: any Decoder) throws {
        json = try JSONValue(from: decoder)
        version = 0
    }

    func encode(to encoder: any Encoder) throws { try json.encode(to: encoder) }
}

extension AnyShapeRecord {
    /// A shape as a board reads it: `props` are `kind`'s own type, or opaque.
    init(id: ShapeID, kind: ShapeKind, props: any ShapeProps, stackingKey: StackingKey?) {
        self.id = id
        self.kind = kind
        self.props = props
        self.stackingKey = stackingKey
    }

    /// Kept aside by the board it came from: its kind isn't installed, it's from a newer version of
    /// its kind, or it didn't load. It keeps its place in the stack and is saved as it was, but
    /// nothing draws, hits, selects or edits it.
    public var isOpaque: Bool { props is OpaqueProps }

    var opaqueProps: OpaqueProps? { props as? OpaqueProps }
}
