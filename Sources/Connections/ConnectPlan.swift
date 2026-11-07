import Canvas

// What a pick of ⌘L's picker means. By default a pick is a plain connection from the shape the picker was opened on to the shape
// picked (the step "Connect"). A kind that means more by it says so, once, keyed by the kind the picker was opened on
// (`ConnectPicks`): which picks it admits, and what an admitted pick is (a `ConnectPlan`: the step's name, the two ends, and what
// to write first). Connections names no such kind.

/// One end of a connection: a shape. (A part of a shape, a row, joins it when a shape has parts.)
public struct ConnectEnd: Hashable, Sendable {
    public var shape: ShapeID

    public init(_ shape: ShapeID) { self.shape = shape }
}

/// A pick asked of `ConnectPicks`: the shape the picker was opened on, and the shape picked (the same shape, for Itself).
public struct ConnectPick: Sendable {
    public var from: ConnectEnd
    public var to: ConnectEnd

    public init(from: ConnectEnd, to: ConnectEnd) {
        self.from = from
        self.to = to
    }
}

/// What a pick does: the step it is, named for what a person would call it ("Connect", "Add Key Column"), the two ends of the
/// arrow, and, when the arrow needs something written first, the writing, in the same step.
public struct ConnectPlan {
    /// The undo step: the connection and what the hooks do to it, and `prepare`.
    public var step: String
    public var from: ConnectEnd
    public var to: ConnectEnd
    /// Written in the step before the arrow is made (a key column inserted, say), given the step's transaction, returning the
    /// ends the arrow then joins. Throws `Transaction.Refused` to refuse the whole pick.
    public var prepare: (@MainActor (inout Transaction) throws -> (from: ConnectEnd, to: ConnectEnd))?

    public init(step: String = "Connect", from: ConnectEnd, to: ConnectEnd,
                prepare: (@MainActor (inout Transaction) throws -> (from: ConnectEnd, to: ConnectEnd))? = nil) {
        self.step = step
        self.from = from
        self.to = to
        self.prepare = prepare
    }
}

/// What a kind means by a pick in ⌘L's picker, for the shapes of one kind it is opened on: at most one a kind. A kind with no
/// contribution connects the shapes plainly.
public struct ConnectPicksContribution {
    /// Whether the picker offers this pick at all (the list leaves out what it does not admit).
    let admits: @MainActor (ConnectPick, CanvasEditor) -> Bool
    /// What an admitted pick is; nil refuses it (the source shakes and nothing is written).
    let plan: @MainActor (ConnectPick, CanvasEditor) -> ConnectPlan?
}

public enum ConnectPicks {}

extension ConnectPicks: KeyedExtensionPoint {
    public typealias Contribution = ConnectPicksContribution
    public static var owner: PluginID { .ports }
    public static func uniqueKeys(of _: ConnectPicksContribution, for target: ShapeTarget) -> [AnyHashable] { [target] }
    public static func summary(of _: ConnectPicksContribution, for target: ShapeTarget) -> String { "connect picks" + (target == .any ? "" : " → \(target)") }
}

extension ShapeRegistrar {
    /// What a pick in ⌘L's picker, opened on a shape of this kind, means: `admitting` says which picks are offered, `plan` what an
    /// offered pick is (`ConnectPlan`; nil refuses). One contribution a kind.
    public mutating func connectPicks(admitting: @escaping @MainActor (ConnectPick, CanvasEditor) -> Bool = { _, _ in true },
                                      _ plan: @escaping @MainActor (ConnectPick, CanvasEditor) -> ConnectPlan?) {
        contribute(ConnectPicksContribution(admits: admitting, plan: plan), to: ConnectPicks.self)
    }
}

extension PluginRegistrar {
    /// The same for a kind another plugin registers.
    public mutating func connectPicks<K: ShapeProps>(_ kind: K.Type,
                                                      admitting: @escaping @MainActor (ConnectPick, CanvasEditor) -> Bool = { _, _ in true },
                                                      _ plan: @escaping @MainActor (ConnectPick, CanvasEditor) -> ConnectPlan?) {
        contribute(ConnectPicksContribution(admits: admitting, plan: plan), to: ConnectPicks.self, for: .kind(K.kind))
    }
}

extension CanvasEditor {
    /// What the kind of `source` means by a pick of `target` in the picker: its contribution's plan, else a plain connection.
    /// `.refused` where the kind's own rule gives no plan.
    func connectPlan(from source: ShapeID, to target: ShapeID) -> ConnectPlanning {
        let pick = ConnectPick(from: ConnectEnd(source), to: ConnectEnd(target))
        guard let kind = document[source]?.kind, let contribution = registry.contributions(to: ConnectPicks.self, for: kind).first else {
            return .plan(ConnectPlan(from: pick.from, to: pick.to))
        }
        guard contribution.admits(pick, self), let plan = contribution.plan(pick, self) else { return .refused }
        return .plan(plan)
    }

    /// Whether the picker offers a pick of `target` from `source`.
    func connectPicksAdmit(from source: ShapeID, to target: ShapeID) -> Bool {
        guard let kind = document[source]?.kind, let contribution = registry.contributions(to: ConnectPicks.self, for: kind).first else { return true }
        return contribution.admits(ConnectPick(from: ConnectEnd(source), to: ConnectEnd(target)), self)
    }
}

enum ConnectPlanning {
    case plan(ConnectPlan)
    case refused
}
