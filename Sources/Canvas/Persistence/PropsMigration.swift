/// One step in a kind's history: rewrites one shape's props, as JSON, from the version before it
/// to its own. A kind lists its steps as `static let migrations` beside `static let kind`; the
/// list's length is the kind's version, which boards record.
///
/// The rules, since boards on disk depend on them: append only (a shipped step never changes or
/// goes away; its position is its version); pure and deterministic (a step sees only this shape's
/// props: no registry, no other shapes, no clock, no randomness), so every copy of the app
/// migrates a board the same way; and up only. Any change to how a kind's props encode needs a
/// step: a member renamed, removed or retyped, a changed unit or meaning, a new member that isn't
/// optional (Swift's synthesized `Codable` ignores defaults when a member is missing).
public struct PropsMigration: Sendable {
    /// Says what the step does, for error messages.
    public let name: String
    let body: @Sendable (inout JSONObject) throws -> Void

    public init(_ name: String, _ body: @escaping @Sendable (_ props: inout JSONObject) throws -> Void) {
        self.name = name
        self.body = body
    }
}

extension ShapeProps {
    /// No steps: version 0.
    public static var migrations: [PropsMigration] { [] }

    /// How many steps the kind's props have been through: what a board records for this kind.
    public static var version: Int { migrations.count }
}
