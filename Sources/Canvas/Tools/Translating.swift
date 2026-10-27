import CoreGraphics
import Geometry

/// Every shape in `ids` follows the pointer from where it was when the drag began, in one
/// transaction per drag event (tldraw's Translating, without cloning). While ⇧ is held, it keeps to
/// one axis, the one the pointer has come further along since the press (tldraw's), and stays where
/// it began along the other; pressing or letting go of ⇧ takes effect at once. Boxes move
/// by their frame; `CustomTranslation` kinds by their own rules, after the boxes; anything else
/// stays put. What a container moved holds (`ShapeContaining`: a frame) moves with it, at any depth,
/// read-only or not, once whether it's in `ids` or not. Read-only shapes stay put too (and what's in
/// them), and the rest move without them (as tldraw's translating leaves locked shapes out); once
/// the pointer is past the drag threshold, services hear that they were refused, once. Where the
/// pointer puts them is the translation adjuster's to change, if a plugin claims it
/// (`registrar.translationAdjuster`: Snapping's snaps them to other shapes), and it draws what it
/// shows with the session. Escape puts back what the drag moved, and only that: a box's origin, a
/// `CustomTranslation` kind's whole record from before its begin. Placing a shape starts one; so may
/// any tool (dragging a selection).
///
/// With containers about, past the drag threshold, each drag event outlines the container what's
/// dragged would go into (the hint), unless it's read-only; and the release settles what was dropped
/// (`Transaction.settle`: in or out, nudged fully in or out across an edge), in the press's step, a
/// container dropped taking in what it lands on (`settle(container:)`), and what's nudged glides there
/// (`CanvasEditor.glide`). A read-only container (a locked frame) takes nothing: dropped into one,
/// what was dragged goes back where it was, gliding from where it was dropped, and the press leaves
/// no step.
@MainActor
public final class TranslatingSession {
    private let origin: CGPoint                                  // world units, at the press
    private let before: [AnyShapeRecord]                         // for Escape, from before any begin
    private let custom: Set<ShapeID>                             // moved by their own rules
    /// What moves of what was asked for, but what's carried in a container that moves: what's
    /// dropped (settled) at the release.
    private let roots: [ShapeID]
    /// What moves only because a container that moves holds it: read-only or not, it goes along.
    private let carried: Set<ShapeID>
    /// Each box, where it was when the drag began, and the pointer's offset from it.
    private let frames: [(id: ShapeID, start: CGPoint, grabOffset: CGPoint)]
    private let moves: [@MainActor (CGPoint, inout Transaction) -> Void]
    /// The read-only shapes left where they are, until services hear of them.
    private var refused: Set<ShapeID>
    private let adjuster: (any TranslationAdjuster)?
    /// The last drag event's pointer, to move again from when held keys change.
    private var last: Pointer?
    /// How far the last drag event moved what moves, in world units.
    private var moved = CGPoint.zero
    /// Whether the pointer has gone past the drag threshold from the press: a release before that is
    /// a click, which settles nothing.
    private var isPastThreshold = false
    /// The containers on the board what's dragged could go into, found at the first event past the
    /// threshold: nil until then, empty without any.
    private var sites: [ShapeID]?
    /// The container outlined as the hint (`editor.hintedShapeID`).
    private var hinted: ShapeID?

    /// `origin` is where the drag began, in world units. Every `beginTranslation` runs now, and then
    /// the translation adjuster's `begin`, if a plugin claims it.
    public init(ids: [ShapeID], from origin: CGPoint, in editor: CanvasEditor) {
        let document = editor.document, registry = editor.registry, kinds = registry.containingKinds
        var seen: Set<ShapeID> = []
        let asked = ids.filter { seen.insert($0).inserted }.compactMap { document[$0] }
        let held = Set(asked.lazy.filter { editor.isReadOnly($0.id) }.map(\.id))
        let free = asked.filter { !held.contains($0.id) }, freeIDs = Set(free.map(\.id))
        // A shape asked for inside another that moves is carried by it.
        let roots = free.filter { record in
            kinds.isEmpty || !record.namesContainer
                || !document.containers(of: record.id, containingKinds: kinds).contains(where: freeIDs.contains)
        }
        var carried: Set<ShapeID> = [], carriedOrder: [ShapeID] = []
        if !kinds.isEmpty, document.namesContainers {
            for root in roots {
                for id in document.descendants(of: root.id, containingKinds: kinds) where carried.insert(id).inserted { carriedOrder.append(id) }
            }
        }
        let rootIDs = Set(roots.map(\.id))
        let before = roots + carriedOrder.filter { !rootIDs.contains($0) }.compactMap { document[$0] }
        let moving = Set(before.map(\.id))
        var frames: [(id: ShapeID, start: CGPoint, grabOffset: CGPoint)] = []
        var custom: Set<ShapeID> = []
        // Every begin in one transaction, committed before the first move. For boxes alone
        // nothing changes, so nothing commits.
        let moves = editor.transact("Move") { tx in
            tx.carrying = carried
            return before.compactMap { record -> (@MainActor (CGPoint, inout Transaction) -> Void)? in
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
        self.roots = roots.map(\.id)
        self.carried = carried
        self.frames = frames
        self.moves = moves
        self.refused = held.subtracting(carried)
        adjuster = before.isEmpty ? nil : registry.translationAdjuster?(editor, TranslationStart(ids: before.map(\.id), origin: origin))
    }
}

extension TranslatingSession: Session {
    /// The canvas scrolls at its edges while it runs.
    public var scrollsAtEdges: Bool { true }

    public func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        last = pointer
        if !isPastThreshold, pointer.view.distance(to: editor.camera.toView(origin)) > Style.dragThreshold { isPastThreshold = true }
        // A click on a read-only shape (a lone box follows the pointer from the press) isn't a try
        // to move it; a drag is.
        if !refused.isEmpty, isPastThreshold {
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
        self.moved = moved
        editor.transact("Move") { tx in
            tx.carrying = carried
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
        if isPastThreshold { outlineTarget(in: editor) }
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

    /// The release, past the drag threshold, settles what was dropped (in the press's step, as it
    /// ends after this), and what that nudges glides there; a read-only container refusing it sends
    /// what was dragged back, gliding from where it was dropped, and the press comes to nothing.
    public func end(_ pointer: Pointer, in editor: CanvasEditor) {
        clearHint(in: editor)
        guard isPastThreshold, !roots.isEmpty, !editor.registry.containingKinds.isEmpty else { return }
        let roots = roots
        let settlement = editor.transact("Move") { $0.settle(roots) }
        switch settlement {
        case .settled(let nudges):
            editor.glide(nudges)
        case .refused:
            putBack(in: editor)
            let back = CGPoint(x: -moved.x, y: -moved.y)
            editor.glide(Dictionary(before.map { ($0.id, back) }, uniquingKeysWith: { first, _ in first }))
        }
    }

    /// Escape (tldraw): every shape back where it was before the drag. A box's origin only, so
    /// what else changed while it moved stays (a plugin writing the shape meanwhile, as a schema
    /// card's sync does); a kind moved by its own rules, its whole record from before
    /// `beginTranslation`, which may change more than where it is (an arrow's precise ends).
    public func cancel(in editor: CanvasEditor) -> Bool {
        clearHint(in: editor)
        putBack(in: editor)
        return true
    }

    public func draw(in context: OverlayContext) { adjuster?.draw(in: context) }

    /// What the drag moved, back where it was before it (Escape's, and a refused drop's).
    private func putBack(in editor: CanvasEditor) {
        editor.transact("Move") { tx in
            tx.carrying = carried
            for record in before {
                if custom.contains(record.id) {
                    tx.update(record.id) { $0 = record }
                } else if let origin = record.box?.origin {
                    tx.update(record.id) { $0.box?.origin = origin }
                }
            }
        }
    }

    /// Outlines the container what's dragged would go into (the hint), as the board is now: by the
    /// in-or-out rule over what was asked for that moves, judged by the container each came from as
    /// the release judges them, among the containers that don't move; none for a read-only one, none
    /// where the groups would go different ways, or none at all. The containers are found once, so each event
    /// costs what they are, not the board.
    private func outlineTarget(in editor: CanvasEditor) {
        let kinds = editor.registry.containingKinds
        guard !kinds.isEmpty else { return }
        let document = editor.document
        if sites == nil {
            let moving = Set(before.map(\.id))
            sites = document.shapes.lazy.filter { kinds.contains($0.kind) && !$0.isOpaque && !moving.contains($0.id) }.map(\.id)
        }
        guard let sites, !sites.isEmpty else { return }
        // Judged as the release settles them: by the container each came from, the hint showing
        // where they'd go only when every group would go there.
        var groups: [ShapeID?: [CGRect]] = [:]
        let context = editor.shapeContext
        for id in roots {
            guard let record = document[id], let box = context.frame(of: record) else { continue }
            groups[document.container(of: record, containingKinds: kinds), default: []].append(box)
        }
        let found = ContainerRule.sites(sites, excluding: [], in: document, containingKinds: kinds)
        let targets = Set(groups.values.map { ContainerRule.target(of: $0, among: found) })
        var target = targets.count == 1 ? targets.first! : nil
        if let id = target, editor.isReadOnly(id) { target = nil }
        guard target != hinted else { return }
        hinted = target
        editor.hintedShapeID = target
    }

    /// Takes the hint down: the drag is over (and a placement's that ends it its own way).
    func clearHint(in editor: CanvasEditor) {
        guard hinted != nil else { return }
        if editor.hintedShapeID == hinted { editor.hintedShapeID = nil }
        hinted = nil
    }
}

/// A shape just placed (`editor.place`), or shapes placed together (`editor.placeLater`), while the press
/// that placed them lasts: they follow the pointer as a `TranslatingSession` moves them (snapping, ⇧
/// keeping them to an axis), whatever the placement, and on the release they settle
/// (`Transaction.settle`: into the container holding most of them, or out, nudged across an edge, gliding
/// there; a container placed takes in what it lands on), and an editing placement's one shape is edited
/// (a click's at once, as far as anyone can tell), where it is, with no glide. A read-only container (a
/// locked frame) takes nothing: placed into one, they're taken away, as Escape takes them, and services
/// hear the container refused (it shakes). Escape takes them away again and puts back what the undo
/// participants kept before the press (what was selected, which placing replaced), so the press comes to
/// nothing, where a drag's Escape puts what it moved back. Only that: what others committed during the
/// press stays.
@MainActor
final class PlacingSession {
    private let ids: [ShapeID]
    private let move: TranslatingSession
    private let edits: Bool
    private let before: [ObjectIdentifier: any Sendable]

    init(_ ids: [ShapeID], from point: CGPoint, edits: Bool, restoring before: [ObjectIdentifier: any Sendable], in editor: CanvasEditor) {
        self.ids = ids
        self.edits = edits && ids.count == 1
        self.before = before
        move = TranslatingSession(ids: ids, from: point, in: editor)
    }
}

extension PlacingSession: Session {
    var scrollsAtEdges: Bool { true }

    func drag(_ pointer: Pointer, in editor: CanvasEditor) { move.drag(pointer, in: editor) }

    func end(_ pointer: Pointer, in editor: CanvasEditor) {
        move.clearHint(in: editor)
        let ids = ids
        let settlement = editor.registry.containingKinds.isEmpty ? Settlement.settled(nudges: [:]) : editor.transact { $0.settle(ids) }
        switch settlement {
        case .refused:
            takeAway(in: editor)
        case .settled(var nudges):
            // Its editing view is laid out where it is.
            if edits, let id = ids.first { nudges[id] = nil }
            editor.glide(nudges)
            if edits, let id = ids.first { editor.beginEditing(id) }
        }
    }

    func cancel(in editor: CanvasEditor) -> Bool {
        move.clearHint(in: editor)
        takeAway(in: editor)
        return true
    }

    func modifiersChanged(_ modifiers: Modifiers, in editor: CanvasEditor) { move.modifiersChanged(modifiers, in: editor) }

    func draw(in context: OverlayContext) { move.draw(in: context) }

    /// The shapes gone, and what the participants kept before the press back: the press comes to
    /// nothing.
    private func takeAway(in editor: CanvasEditor) {
        editor.transact { $0.delete(Set(ids)) }
        editor.undoHistory.restore(before)
    }
}

/// A drag that moves shapes (a `TranslatingSession`), as it begins: what the plugin that adjusts it
/// is given (`registrar.translationAdjuster`).
public struct TranslationStart: Sendable {
    /// What it moves, in the order it was given, then what the containers among them hold, which goes
    /// with them, back to front: read-only shapes are left out (they stay put), but for what a
    /// container carries.
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
