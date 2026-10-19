import CanvasRPC
/// One step in a kind's history: rewrites one shape's props, as JSON, from the version before it
/// to its own. A kind lists its steps as `static let migrations` beside `static let kind`; the
/// list's length is the kind's version, which boards record.
///
/// The rules, since boards on disk depend on them: append only (a shipped step never changes or
/// goes away; its position is its version); pure and deterministic (a step sees only this shape's
/// props: no registry, no other shapes, no clock, no randomness), so every copy of the app
/// migrates a board the same way; and up only. Any change to how a kind's props encode needs a
/// step: a member renamed, removed or retyped, a changed unit or meaning, a new member (even one
/// with a default, which reads without a step, but see `init(_:)`). A step removes what it retires:
/// a member it leaves behind is no longer the kind's, and reading drops it.
public struct PropsMigration: Sendable {
    /// Says what the step does, for error messages.
    public let name: String
    let body: @Sendable (inout JSONObject) throws -> Void
    /// Set for `handOver`: the member it moves, and to what.
    let handOver: HandOver?

    struct HandOver: Sendable {
        let member: String
        let key: PropertyKey
        /// The property's version the member is at: pinned, so later steps of the property's never
        /// change what this step hands over.
        let version: Int
    }

    public init(_ name: String, _ body: @escaping @Sendable (_ props: inout JSONObject) throws -> Void) {
        self.name = name
        self.body = body
        handOver = nil
    }

    /// A step that rewrites nothing: a new member with a default, which boards from before it read
    /// as the default. It still takes a version, so that an older app doesn't read a board this
    /// version wrote as its own version (and drop the member), and so each version has its fixture.
    public init(_ name: String) {
        self.init(name) { _ in }
    }

    private init(name: String, handOver: HandOver) {
        self.name = name
        self.handOver = handOver
        body = { $0[handOver.member] = nil }
    }

    /// A step that hands one of the kind's own members over to an added property the kind now opts
    /// into, as the value it was, which that property reads at `version` (and then migrates, like
    /// any value of it): `.handOver("title", to: TitleProperty.self)`. The kind no longer
    /// has the member; its shapes have the property. A member that's missing, or null, hands nothing
    /// over: the shape has the property's default, as with any shape of a kind that opts in.
    public static func handOver<P: ShapeProperty>(_ member: String, to _: P.Type, version: Int = 0) -> PropsMigration {
        PropsMigration(name: "\(member) becomes the \(P.key) property", handOver: HandOver(member: member, key: P.key, version: version))
    }
}

extension ShapeProps {
    /// No steps: version 0.
    public static var migrations: [PropsMigration] { [] }

    /// How many steps the kind's props have been through: what a board records for this kind.
    public static var version: Int { migrations.count }
}
