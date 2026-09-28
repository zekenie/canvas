import AppKit
import Canvas

// Values that name shapes loosely (`ShapeNaming`), and kinds that hold them in every way a value
// can: what core tests of names use, never a real vertical's.

/// A name of a shape that may outlive it, as a mention in text is: the smallest `ShapeNaming`
/// leaf, coded by hand as the shape's id.
public struct Citation: Hashable, Sendable {
    public var shape: ShapeID
    public init(_ shape: ShapeID) { self.shape = shape }

    /// How often any citation has been walked or renamed: a test that something never looks at
    /// names counts them before and after.
    nonisolated(unsafe) public static var visits = 0
}

extension Citation: Codable {
    public init(from decoder: any Decoder) throws {
        shape = try decoder.singleValueContainer().decode(ShapeID.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(shape)
    }
}

extension Citation: SchemaDescribed {
    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        definitions.reference("citation", of: Self.self) { _ in
            ["type": "string", "format": "uuid", "description": "A shape it names, which may be gone."]
        }
    }
}

extension Citation: ShapeNaming {
    public func forEachNamedShape(_ body: (ShapeID) -> Void) {
        Self.visits += 1
        body(shape)
    }

    public func renamingShapes(_ rename: (ShapeID) -> ShapeID?) -> Citation {
        Self.visits += 1
        return Citation(rename(shape) ?? shape)
    }
}

/// A note in a memo: a struct that holds names, so it adopts `ShapeNaming`, with nothing to write.
public struct MemoNote: SchemaDefined, Hashable {
    public static let properties = Properties<MemoNote>(definition: "memo-note") {
        Property("text", \.text)
        Property("cites", \.cites)
    }
    public var text: String
    public var cites: [Citation]
    public init(_ text: String, cites: [Citation] = []) {
        self.text = text
        self.cites = cites
    }
}

extension MemoNote {
    public init() { self.init("") }
}

extension MemoNote: ShapeNaming {}

/// A box whose props name shapes in a struct in a list (`notes`), an optional (`lead`) and a
/// dictionary (`sources`), beside text that names none. Its props don't adopt `ShapeNaming`: the
/// core walks a kind's props by their list. Its plugin gives it `CitationsProperty` too.
public struct Memo: BoxShapeProps {
    public static let kind: ShapeKind = "memo"
    public static let properties = Properties<Memo> {
        Property("frame", \.frame).required()
        Property("text", \.text)
        Property("notes", \.notes)
        Property("lead", \.lead)
        Property("sources", \.sources)
    }
    public var frame: CGRect
    public var text: String
    public var notes: [MemoNote]
    public var lead: Citation?
    public var sources: [String: Citation]
    public init(_ frame: CGRect = .zero, text: String = "", notes: [MemoNote] = [], lead: Citation? = nil,
                sources: [String: Citation] = [:]) {
        self.frame = frame
        self.text = text
        self.notes = notes
        self.lead = lead
        self.sources = sources
    }
}

extension Memo {
    public init() { self.init(.zero) }
}

/// Citations given to a shape: an added property whose value names shapes. Only the shapes given
/// some have it.
public enum CitationsProperty {}

extension CitationsProperty: ShapeProperty {
    public static let key: PropertyKey = "citations"
    public static var defaultValue: Set<Citation>? { nil }
}

/// A tag (as `Tag`, bound to its target through `ShapeReferencing`) that also names a shape
/// loosely: a kind that both binds and names.
public struct CitingTag: ShapeProps {
    public static let kind: ShapeKind = "citing-tag"
    public static let properties = Properties<CitingTag> {
        Property("target", \.target)
        Property("cite", \.cite)
    }
    public var target: ShapeID?
    public var cite: Citation?
    public init(target: ShapeID?, cite: Citation? = nil) {
        self.target = target
        self.cite = cite
    }
}

extension CitingTag {
    public init() { self.init(target: nil) }
}

struct MemoDefinition {}

extension MemoDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Memo>, in context: RenderContext) {}
}

struct CitingTagDefinition {}

extension CitingTagDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<CitingTag>, in context: RenderContext) {}
    func geometry(of shape: ShapeRecord<CitingTag>, in context: ShapeContext) -> ShapeGeometry {
        ShapeGeometry(outline: [], bounds: .zero, isClosed: false)
    }
}

extension CitingTagDefinition: ShapeReferencing {
    /// Its target, as a tag's; what it cites is a name, which the core renames.
    func remappingReferences(of shape: ShapeRecord<CitingTag>, _ map: (ShapeID) -> ShapeID?, in _: ShapeContext) -> CitingTag? {
        CitingTag(target: shape.props.target.flatMap(map), cite: shape.props.cite)
    }
}

/// "memo" and "citing-tag" kinds, and the "citations" added property, which memos opt into.
public struct NamingPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "naming" }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(CitationsProperty.self)
        registrar.shape(MemoDefinition()) { memo in memo.optIn(to: CitationsProperty.self) }
        registrar.shape(CitingTagDefinition())
    }
}
