import Canvas
import CoreGraphics

// What other plugins may say about arrows, without Arrows knowing why: what an end may bind to
// (tldraw's canBind), and an arrow drawn for their own gesture (a port's drag, through the
// ArrowPorts bridge). Arrows never learns what a channel is.

/// Rules for what an arrow's end may bind to (tldraw's canBind), from any plugin: an end binds only
/// to a shape every rule allows, and looks through the rest to the shapes behind, as it's drawn,
/// re-aimed or moved. With none, an end binds to any shape it can. A list.
public enum ArrowBindingRules {}

extension ArrowBindingRules: ExtensionPoint {
    public typealias Contribution = @MainActor (ArrowBindingQuery) -> Bool
    public static var owner: PluginID { .arrows }
}

/// What a rule is asked: whether `end` of `arrow` may bind to `shape`.
@MainActor
public struct ArrowBindingQuery {
    /// The arrow as it is: its props and what plugins add to it.
    public let arrow: AnyShapeRecord
    public let end: ArrowEnd
    /// A shape under the end.
    public let shape: AnyShapeRecord
    public let registry: Registry
}

extension ArrowBindingQuery {
    /// Whether every one of `rules` allows it: an end binds only then, however it binds.
    func isAllowed(by rules: [ArrowBindingRules.Contribution]) -> Bool { rules.allSatisfy { $0(self) } }
}

extension PluginRegistrar {
    /// A rule for what an arrow's end may bind to (`ArrowBindingRules`): asked only of the shapes
    /// under the end, so it may look things up, but it's asked as the pointer moves.
    public mutating func arrowBindingRule(_ rule: @escaping @MainActor (ArrowBindingQuery) -> Bool) {
        contribute(rule, to: ArrowBindingRules.self)
    }
}

extension Registry {
    /// Whether every plugin's rule (`ArrowBindingRules`) lets `end` of `arrow` bind to `shape`, as
    /// they're asked while an end binds by pointer: for a plugin that binds an arrow's ends itself
    /// (one made without a drag), with the arrow as it will be (what plugins add to it set first).
    /// True with no rules.
    public func arrowMayBind(_ arrow: AnyShapeRecord, _ end: ArrowEnd, to shape: AnyShapeRecord) -> Bool {
        let query = ArrowBindingQuery(arrow: arrow, end: end, shape: shape, registry: self)
        return query.isAllowed(by: contributions(to: ArrowBindingRules.self).map(\.value))
    }
}

extension ShapeContext {
    /// Whether an arrow can bind to this shape: it's there, it's closed, and it isn't an arrow. Asked
    /// of the document it's for: the editor's, or a transaction's (`transaction.shapes`), which has
    /// the shapes the transaction inserted.
    public func canBindArrow(to id: ShapeID) -> Bool { Connectables(shapes: self)[id] != nil }
}

/// A drag drawing an arrow for another plugin's gesture (`beginArrow`): where its end may bind, and
/// what finishes it once it has.
@MainActor
struct ArrowConnecting {
    let canBind: @MainActor (AnyShapeRecord) -> Bool
    let complete: @MainActor (inout AnyShapeRecord, ShapeID) -> Void
}

extension CanvasEditor {
    /// Whether an arrow can bind to this shape: it's there, it's closed, and it isn't an arrow
    /// (`ShapeContext.canBindArrow(to:)`, of the editor's document).
    public func canBindArrow(to id: ShapeID) -> Bool { shapeContext.canBindArrow(to: id) }

    /// An arrow drawn from `shape` for another plugin's gesture (a port's drag), as the arrow tool
    /// draws one once past the drag threshold: its start bound to the shape, aiming at its center
    /// (imprecise), and its end at `origin` (world units), then following the pointer and binding by
    /// tldraw's rules, as the tool's does, but only to shapes `canBind` accepts, looking through the
    /// rest. Released bound, `complete` finishes it (in the transaction that does, with the shape
    /// its end is bound to); released free, or on Escape, it's deleted, so nothing is drawn. The
    /// selection and the tool are left alone. Returns the session that drags it, for the caller to
    /// hand the drag to; nil if an arrow can't bind to `shape`.
    public func beginArrow(from shape: ShapeID, at origin: CGPoint, canBind: @escaping @MainActor (AnyShapeRecord) -> Bool,
                           complete: @escaping @MainActor (inout AnyShapeRecord, ShapeID) -> Void) -> (any Session)? {
        guard canBindArrow(to: shape), let targeting = service(ArrowTargeting.self) else { return nil }
        targeting.cancelPreciseTimer()
        let start = ArrowBinding(shapeID: shape, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)
        let arrow = ShapeRecord(Arrow(start: .bound(start), end: .free(origin)))
        transact("Add Arrow") { $0.insert(arrow) }
        return ArrowHandleDragSession(arrowID: arrow.id, handle: .terminal(.end), isCreating: true, handleOffset: .zero, isPrecise: false,
                                      targeting: targeting, connecting: ArrowConnecting(canBind: canBind, complete: complete))
    }
}
