import Canvas
import Connections
import CoreGraphics

// What any plugin may say about arrows: what an end may bind to (tldraw's canBind,
// `ArrowBindingRules`), and an arrow drawn for a port's drag (`beginArrow`, which
// `ArrowPortsPlugin` calls). The arrow code reads no channel: `ArrowPortsPlugin`'s binding
// rule does.

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
    /// The shapes it's judged among: the editor's, or a transaction's (what its other end is bound
    /// to, what holds what).
    public let shapes: ShapeContext
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
    /// Whether every plugin's rule (`ArrowBindingRules`) lets `end` of `arrow` bind to `shape` among
    /// `shapes`, as they're asked while an end binds by pointer: for a plugin that binds an arrow's
    /// ends itself (one made without a drag), with the arrow as it will be (what plugins add to it set
    /// first). True with no rules.
    public func arrowMayBind(_ arrow: AnyShapeRecord, _ end: ArrowEnd, to shape: AnyShapeRecord, in shapes: ShapeContext) -> Bool {
        let query = ArrowBindingQuery(arrow: arrow, end: end, shape: shape, registry: self, shapes: shapes)
        return query.isAllowed(by: contributions(to: ArrowBindingRules.self).map(\.value))
    }
}

/// Rules for which ends bind a part of the shape they're bound to (a row: `PartedShape`), from any plugin: an end re-aimed
/// or drawn onto a shape some rule says this of binds the row under it (the nearest by height), and is drawn at that row's
/// side; with none, it binds the shape as a whole, as an end always has. A list.
public enum ArrowPartRules {}

extension ArrowPartRules: ExtensionPoint {
    public typealias Contribution = @MainActor (ArrowBindingQuery) -> Bool
    public static var owner: PluginID { .arrows }
}

extension PluginRegistrar {
    /// A rule for which arrow ends bind a part of their shape (`ArrowPartRules`): asked of the shape under an end, as the
    /// pointer moves.
    public mutating func arrowPartRule(_ rule: @escaping @MainActor (ArrowBindingQuery) -> Bool) {
        contribute(rule, to: ArrowPartRules.self)
    }
}

extension Registry {
    /// Whether some plugin's rule (`ArrowPartRules`) says `end` of `arrow` binds a part of `shape`, among `shapes`.
    public func arrowBindsPart(_ arrow: AnyShapeRecord, _ end: ArrowEnd, of shape: AnyShapeRecord, in shapes: ShapeContext) -> Bool {
        let query = ArrowBindingQuery(arrow: arrow, end: end, shape: shape, registry: self, shapes: shapes)
        return contributions(to: ArrowPartRules.self).contains { $0.value(query) }
    }
}

extension ShapeContext {
    /// Whether an arrow can bind to this shape: it's there, it's closed, and it isn't an arrow. Asked
    /// of the document it's for: the editor's, or a transaction's (`transaction.shapes`), which has
    /// the shapes the transaction inserted.
    public func canBindArrow(to id: ShapeID) -> Bool { Connectables(shapes: self)[id] != nil }
}

/// A drag drawing an arrow for a port's drag (`beginArrow`): where its end may bind, what finishes it once it
/// has, and what is told once the arrow is finished.
@MainActor
struct ArrowConnecting {
    let canBind: @MainActor (AnyShapeRecord) -> Bool
    /// Whether its end binds a row of a shape it may bind to (the connection's channel is on that shape's parts).
    var bindsPart: @MainActor (AnyShapeRecord) -> Bool = { _ in false }
    let complete: @MainActor (inout AnyShapeRecord, ShapeID) -> Void
    /// Called with the arrow after the transaction that completed it and before the press ends, so what it
    /// changes is the press's step (`ArrowPortsPlugin` has Types read what the arrow is and give it a type).
    /// Nil: only the relationships are told the drag is over (`connectionReleased`).
    var finished: (@MainActor (ShapeID) -> Void)? = nil
    /// Where the arrow starts while its end is anywhere but back on the shape it starts from: the shape's middle; or, for a
    /// drag from a row's dot, that row (and a drag back onto the shape binds another of its rows: a key from a column to a
    /// column of its own table, never a loop).
    let start: ArrowBinding
    /// The side of that shape the drag left from (the dot's): an end back on the shape makes the arrow a loop there.
    let side: PortSide
}

extension CanvasEditor {
    /// Whether an arrow can bind to this shape: it's there, it's closed, and it isn't an arrow
    /// (`ShapeContext.canBindArrow(to:)`, of the editor's document).
    public func canBindArrow(to id: ShapeID) -> Bool { shapeContext.canBindArrow(to: id) }

    /// An arrow drawn from `shape` for a port's drag (`ArrowPortsPlugin`'s), from its dot on `side`: its start bound to
    /// the shape, aiming at its center (imprecise), and its end at `origin` (world units), then
    /// following the pointer and binding by tldraw's rules, as a re-aimed end does, but only to
    /// shapes `canBind` accepts, looking through the rest. Bound back to `shape`, it is the loop it will be, on `side`
    /// (`ArrowConnections.loop`), and leaving it again it starts from the center as before. Released bound, `complete` finishes it (in the transaction that does, with the shape
    /// its end is bound to) and `finished` hears of it, still in the press; released free, or on Escape, it's deleted, so nothing is drawn. The
    /// selection and the tool are left alone. Returns the session that drags it, for the caller to
    /// hand the drag to; nil if an arrow can't bind to `shape`, or the board takes no shapes
    /// (`isBoardReadOnly`: its transaction would drop the arrow).
    func beginArrow(from shape: ShapeID, part: PartID? = nil, side: PortSide, at origin: CGPoint,
                    canBind: @escaping @MainActor (AnyShapeRecord) -> Bool,
                    bindsPart: @escaping @MainActor (AnyShapeRecord) -> Bool = { _ in false },
                    complete: @escaping @MainActor (inout AnyShapeRecord, ShapeID) -> Void,
                    finished: (@MainActor (ShapeID) -> Void)? = nil) -> (any Session)? {
        guard !isBoardReadOnly, canBindArrow(to: shape), let targeting = service(ArrowTargeting.self) else { return nil }
        targeting.cancelPreciseTimer()
        var start = ArrowBinding(shapeID: shape, normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false)
        if let part, let bound = ArrowConnections.binding(to: shape, part: part, side: side == .left ? .left : .right, in: shapeContext) {
            start = bound
        }
        let arrow = ShapeRecord(Arrow(start: .bound(start), end: .free(origin)))
        transact("Add Arrow") { $0.insert(arrow) }
        let connecting = ArrowConnecting(canBind: canBind, bindsPart: bindsPart, complete: complete, finished: finished, start: start, side: side)
        return ArrowHandleDragSession(arrowID: arrow.id, handle: .terminal(.end), handleOffset: .zero, isPrecise: false,
                                      targeting: targeting, connecting: connecting)
    }
}
