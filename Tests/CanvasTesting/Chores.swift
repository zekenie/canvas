import AppKit
import Canvas

/// A box with a property of every sort a schema has, for tests that read shapes by their schemas
/// (queries' attributes): `status`, one of four words (a `SchemaCases`); `estimate`, a whole number
/// at least 0 that may be missing; `ratio`, a number; `due`, an instant that may be missing; `tags`,
/// a list of text; `note`, text; and `meta`, an object. Its kind is called a "Task" (its label), so
/// what's said about kinds by their labels has one that isn't its id. Apart from `FixturesPlugin`,
/// so the registry reports tests pin don't change.
public struct Chore: BoxShapeProps {
    public static let kind: ShapeKind = "chore"
    public static let properties = Properties<Chore>(title: "Chore") {
        Property("frame", \.frame).required()
        Property("status", \.status)
        Property("estimate", \.estimate).minimum(0)
        Property("ratio", \.ratio)
        Property("due", \.due)
        Property("tags", \.tags)
        Property("note", \.note)
        Property("meta", \.meta)
    }

    /// Where a chore is.
    public enum Status: String, Codable, Sendable, SchemaCases {
        case todo, doing, blocked, done
        public var schemaTitle: String { rawValue.capitalized }
    }

    /// Who a chore is for, and how big it is: an object in its props.
    public struct Meta: SchemaDefined, Hashable {
        public static let properties = Properties<Meta> {
            Property("owner", \.owner)
            Property("size", \.size)
        }
        public var owner: String
        public var size: Int
        public init(owner: String, size: Int = 0) {
            self.owner = owner
            self.size = size
        }
    }

    public var frame: CGRect
    public var status: Status
    public var estimate: Int?
    public var ratio: Double
    public var due: Date?
    public var tags: [String]
    public var note: String
    public var meta: Meta

    public init(_ frame: CGRect, status: Status = .todo, estimate: Int? = nil,
                ratio: Double = 0, due: Date? = nil, tags: [String] = [], note: String = "", meta: Meta = Meta(owner: "")) {
        self.frame = frame
        self.status = status
        self.estimate = estimate
        self.ratio = ratio
        self.due = due
        self.tags = tags
        self.note = note
        self.meta = meta
    }
}

extension Chore {
    public init() { self.init(.zero) }
}

extension Chore.Meta {
    public init() { self.init(owner: "", size: 0) }
}

/// Whether a shape is flagged: an added true|false with no default, so only the shapes it's set on
/// have one (absent until then, as a lock is).
public enum Flagged {}

extension Flagged: ShapeProperty {
    public static let key: PropertyKey = "flag"
    public static var defaultValue: Bool? { nil }
}

struct ChoreDefinition {}

extension ChoreDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<Chore>, in context: RenderContext) {
        context.fillWithShadow(CGPath(rect: shape.frame, transform: nil), shape.props.status == .done ? .systemGreen : .systemGray)
    }
}

/// Chores ("chore", called a Task), no tool, and `Flagged`, which chores hold.
public struct ChoresPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "chores" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.declare(Flagged.self)
        registrar.shape(ChoreDefinition()) { chore in
            chore.label("Task", systemImage: "checklist")
            chore.optIn(to: Flagged.self)
        }
    }
}
