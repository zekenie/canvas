import CoreGraphics
import Geometry

/// Every shape in `ids` follows the pointer from where it was when the drag began, in one
/// transaction per drag event (tldraw's Translating, without cloning). While ⇧ is held, it keeps to
/// one axis, the one the pointer has come further along since the press (tldraw's), and stays where
/// it began along the other; pressing or letting go of ⇧ takes effect at once. Boxes move
/// by their frame; `CustomTranslation` kinds by their own rules, after the boxes; anything else
/// stays put. Read-only shapes stay put too, and the rest move without them (as tldraw's translating
/// leaves locked shapes out); once the pointer is past the drag threshold, services hear that they
/// were refused, once. Where the pointer puts them is the translation adjuster's to change, if a
/// plugin claims it (`registrar.translationAdjuster`: Snapping's snaps them to other shapes), and it
/// draws what it shows with the session. Escape puts back what the drag moved, and only that: a box's
/// origin, a `CustomTranslation` kind's whole record from before its begin. Placing a shape starts
/// one; so may any tool (dragging a selection).
@MainActor
public final class TranslatingSession {
    private let origin: CGPoint                                  // world units, at the press
    private let before: [AnyShapeRecord]                         // for Escape, from before any begin
    private let custom: Set<ShapeID>                             // moved by their own rules
    /// Each box, where it was when the drag began, and the pointer's offset from it.
    private let frames: [(id: ShapeID, start: CGPoint, grabOffset: CGPoint)]
    private let moves: [@MainActor (CGPoint, inout Transaction) -> Void]
    /// The read-only shapes left where they are, until services hear of them.
    private var refused: Set<ShapeID>
    private let adjuster: (any TranslationAdjuster)?
    /// The last drag event's pointer, to move again from when held keys change.
    private var last: Pointer?

    /// `origin` is where the drag began, in world units. Every `beginTranslation` runs now, and then
    /// the translation adjuster's `begin`, if a plugin claims it.
    public init(ids: [ShapeID], from origin: CGPoint, in editor: CanvasEditor) {
        let refused = Set(ids.filter { editor.isReadOnly($0) })
        let before = ids.compactMap { editor.document[$0] }.filter { !refused.contains($0.id) }
        let moving = Set(before.map(\.id)), registry = editor.registry
        var frames: [(id: ShapeID, start: CGPoint, grabOffset: CGPoint)] = []
        var custom: Set<ShapeID> = []
        // Every begin in one transaction, committed before the first move. For boxes alone
        // nothing changes, so nothing commits.
        let moves = editor.transact("Move") { tx in
            before.compactMap { record -> (@MainActor (CGPoint, inout Transaction) -> Void)? in
                if let definition = registry.definition(for: record.kind) as? any CustomTranslation {
                    custom.insert(record.id)
                    return definition.erasedBeginTranslation(of: record, movingWith: moving, in: &tx)
                }
                if let box = record.box { frames.append((record.id, box.origin, origin - box.origin)) }
                return nil
            }
        }
        self.origin = origin
        self.before = before
        self.custom = custom
        self.frames = frames
        self.moves = moves
        self.refused = refused
        adjuster = before.isEmpty ? nil : registry.translationAdjuster?(editor, TranslationStart(ids: before.map(\.id), origin: origin))
    }
}

extension TranslatingSession: Session {
    /// The canvas scrolls at its edges while it runs.
    public var scrollsAtEdges: Bool { true }

    public func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        last = pointer
        // A click on a read-only shape (a lone box follows the pointer from the press) isn't a try
        // to move it; a drag is.
        if !refused.isEmpty, pointer.view.distance(to: editor.camera.toView(origin)) > Style.dragThreshold {
            let ids = refused
            refused = []
            editor.refuseChanges(to: ids)
        }
        guard !before.isEmpty else { return }
        var delta = pointer.world - origin
        // ⇧ keeps it to the axis the pointer has come further along; along the other it stays.
        let axis: TranslationAxis? = pointer.modifiers.contains(.shift) ? (abs(delta.x) < abs(delta.y) ? .y : .x) : nil
        delta = axis?.keeping(delta) ?? delta
        var moved = adjuster?.adjust(delta, along: axis, for: pointer, in: editor) ?? delta
        moved = axis?.keeping(moved) ?? moved
        editor.transact("Move") { tx in
            for frame in frames {
                // On an axis the adjuster leaves alone, `pointer.world − grabOffset`, not `start +
                // delta`: the two differ in the last bit for some fractional points. This is the
                // POC's box drag, and Characterization pins it. On an axis it changes, exactly what
                // it says, from where the box began: a box snapped to an edge lands on it. On the
                // axis ⇧ holds still, where it began.
                let follows = pointer.world - frame.grabOffset
                tx.moveBox(frame.id, to: CGPoint(x: axis == .y ? frame.start.x : (moved.x == delta.x ? follows.x : frame.start.x + moved.x),
                                                 y: axis == .x ? frame.start.y : (moved.y == delta.y ? follows.y : frame.start.y + moved.y)))
            }
            for move in moves { move(moved, &tx) }
        }
    }

    /// Held keys changed mid-drag: the move is made again where the pointer is, without its moving,
    /// with an adjuster, which may read them (⌘ lets Snapping's shapes follow the pointer exactly),
    /// or when ⇧ came or went (it keeps to an axis, or stops).
    public func modifiersChanged(_ modifiers: Modifiers, in editor: CanvasEditor) {
        guard var pointer = last, adjuster != nil || modifiers.contains(.shift) != pointer.modifiers.contains(.shift) else { return }
        pointer.world = editor.camera.toWorld(pointer.view)
        pointer.modifiers = modifiers
        drag(pointer, in: editor)
    }

    /// Escape (tldraw): every shape back where it was before the drag. A box's origin only, so
    /// what else changed while it moved stays (a plugin writing the shape meanwhile, as a schema
    /// card's sync does); a kind moved by its own rules, its whole record from before
    /// `beginTranslation`, which may change more than where it is (an arrow's precise ends).
    public func cancel(in editor: CanvasEditor) -> Bool {
        editor.transact("Move") { tx in
            for record in before {
                if custom.contains(record.id) {
                    tx.update(record.id) { $0 = record }
                } else if let origin = record.box?.origin {
                    tx.update(record.id) { $0.box?.origin = origin }
                }
            }
        }
        return true
    }

    public func draw(in context: OverlayContext) { adjuster?.draw(in: context) }
}

/// A shape just placed (`editor.place`), while the press that placed it lasts: it follows the pointer
/// as a `TranslatingSession` moves it (snapping, ⇧ keeping it to an axis), whatever its placement,
/// and on the release an editing placement's shape is edited (a click's at once, as far as anyone
/// can tell). Escape takes the shape away again and puts back what the undo participants kept before
/// the press (what was selected, which placing replaced), so the press comes to nothing, where a
/// drag's Escape puts what it moved back. Only that: what others committed during the press stays.
@MainActor
final class PlacingSession {
    private let id: ShapeID
    private let move: TranslatingSession
    private let edits: Bool
    private let before: [ObjectIdentifier: any Sendable]

    init(_ id: ShapeID, from point: CGPoint, edits: Bool, restoring before: [ObjectIdentifier: any Sendable], in editor: CanvasEditor) {
        self.id = id
        self.edits = edits
        self.before = before
        move = TranslatingSession(ids: [id], from: point, in: editor)
    }
}

extension PlacingSession: Session {
    var scrollsAtEdges: Bool { true }

    func drag(_ pointer: Pointer, in editor: CanvasEditor) { move.drag(pointer, in: editor) }

    func end(_ pointer: Pointer, in editor: CanvasEditor) {
        if edits { editor.beginEditing(id) }
    }

    func cancel(in editor: CanvasEditor) -> Bool {
        editor.transact { $0.delete([id]) }
        editor.undoHistory.restore(before)
        return true
    }

    func modifiersChanged(_ modifiers: Modifiers, in editor: CanvasEditor) { move.modifiersChanged(modifiers, in: editor) }

    func draw(in context: OverlayContext) { move.draw(in: context) }
}

/// A drag that moves shapes (a `TranslatingSession`), as it begins: what the plugin that adjusts it
/// is given (`registrar.translationAdjuster`).
public struct TranslationStart: Sendable {
    /// What it moves, in the order it was given: read-only shapes are left out (they stay put).
    public let ids: [ShapeID]
    /// Where it was pressed, in world units: each drag event's delta is how far the pointer has come
    /// from here.
    public let origin: CGPoint
}

/// The axis a drag that moves shapes keeps to while ⇧ is held (`TranslatingSession`): `.x`, it moves
/// only side to side; `.y`, only up and down.
public enum TranslationAxis: Sendable, Hashable {
    case x, y

    /// `delta` along this axis alone: zero across it.
    public func keeping(_ delta: CGPoint) -> CGPoint {
        self == .x ? CGPoint(x: delta.x, y: 0) : CGPoint(x: 0, y: delta.y)
    }
}

/// Where a drag that moves shapes (`TranslatingSession`) puts them, if not under the pointer: made
/// as the drag begins by the plugin that claims it (`registrar.translationAdjuster`; Snapping's,
/// which snaps what moves to other shapes), and kept for as long as the drag lasts.
@MainActor
public protocol TranslationAdjuster: AnyObject {
    /// How far to move the shapes on this drag event, in world units, given how far the pointer has
    /// come since the press (`delta`): `delta` itself to leave them following the pointer. On an axis
    /// given back as it came, boxes follow the pointer exactly as they would with no adjuster; on one
    /// it changes, each box moves by exactly what it returns from where it began. While ⇧ keeps the
    /// drag to one axis, `axis` says which, `delta` is zero across it, and what it gives back across it
    /// is ignored: what moves stays there, so it neither moves nor guides that way. Asked again, with
    /// the same pointer, when held keys change.
    func adjust(_ delta: CGPoint, along axis: TranslationAxis?, for pointer: Pointer, in editor: CanvasEditor) -> CGPoint
    /// Draws what it shows while the drag runs (guides), in world units, above the world overlays.
    func draw(in context: OverlayContext)
}
