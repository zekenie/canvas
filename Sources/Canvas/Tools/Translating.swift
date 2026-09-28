import CoreGraphics
import Geometry

/// Every shape in `ids` follows the pointer from where it was when the drag began, in one
/// transaction per drag event (tldraw's Translating, without cloning, snapping or the axis lock).
/// Boxes move by their frame; `CustomTranslation` kinds by their own rules, after the boxes;
/// anything else stays put. Read-only shapes stay put too, and the rest move without them (as
/// tldraw's translating leaves locked shapes out); once the pointer is past the drag threshold,
/// services hear that they were refused, once. Escape puts back what the drag moved, and only
/// that: a box's origin, a `CustomTranslation` kind's whole record from before its begin. Placing
/// a shape starts one; so may any tool (dragging a selection).
@MainActor
public final class TranslatingSession {
    private let origin: CGPoint                                  // world units, at the press
    private let before: [AnyShapeRecord]                         // for Escape, from before any begin
    private let custom: Set<ShapeID>                             // moved by their own rules
    private let frames: [(id: ShapeID, grabOffset: CGPoint)]
    private let moves: [@MainActor (CGPoint, inout Transaction) -> Void]
    /// The read-only shapes left where they are, until services hear of them.
    private var refused: Set<ShapeID>

    /// `origin` is where the drag began, in world units. Every `beginTranslation` runs now.
    public init(ids: [ShapeID], from origin: CGPoint, in editor: CanvasEditor) {
        let refused = Set(ids.filter { editor.isReadOnly($0) })
        let before = ids.compactMap { editor.document[$0] }.filter { !refused.contains($0.id) }
        let moving = Set(before.map(\.id)), registry = editor.registry
        var frames: [(id: ShapeID, grabOffset: CGPoint)] = []
        var custom: Set<ShapeID> = []
        // Every begin in one transaction, committed before the first move. For boxes alone
        // nothing changes, so nothing commits.
        let moves = editor.transact("Move") { tx in
            before.compactMap { record -> (@MainActor (CGPoint, inout Transaction) -> Void)? in
                if let definition = registry.definition(for: record.kind) as? any CustomTranslation {
                    custom.insert(record.id)
                    return definition.erasedBeginTranslation(of: record, movingWith: moving, in: &tx)
                }
                if let box = record.box { frames.append((record.id, origin - box.origin)) }
                return nil
            }
        }
        self.origin = origin
        self.before = before
        self.custom = custom
        self.frames = frames
        self.moves = moves
        self.refused = refused
    }
}

extension TranslatingSession: Session {
    public func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        // A click on a read-only shape (a lone box follows the pointer from the press) isn't a try
        // to move it; a drag is.
        if !refused.isEmpty, pointer.view.distance(to: editor.camera.toView(origin)) > Style.dragThreshold {
            let ids = refused
            refused = []
            editor.refuseChanges(to: ids)
        }
        guard !before.isEmpty else { return }
        let delta = pointer.world - origin
        editor.transact("Move") { tx in
            // `pointer.world − grabOffset`, not `start + delta`: the two differ in the last bit
            // for some fractional points. This is the POC's box drag, and Characterization pins it.
            for (id, grabOffset) in frames { tx.moveBox(id, to: pointer.world - grabOffset) }
            for move in moves { move(delta, &tx) }
        }
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
}
