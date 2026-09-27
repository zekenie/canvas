import CoreGraphics
import Geometry

/// Every shape in `ids` follows the pointer from where it was when the drag began, in one
/// transaction per drag event (tldraw's Translating, without cloning, snapping or the axis lock).
/// Boxes move by their frame; `CustomTranslation` kinds by their own rules, after the boxes;
/// anything else stays put. Escape puts them all back.
@MainActor
final class TranslatingSession {
    private let origin: CGPoint                                  // world units, at the press
    private let before: [AnyShapeRecord]                         // for Escape, from before any begin
    private let frames: [(id: ShapeID, grabOffset: CGPoint)]
    private let moves: [@MainActor (CGPoint, inout Transaction) -> Void]

    init(ids: [ShapeID], from origin: CGPoint, in editor: CanvasEditor) {
        let before = ids.compactMap { editor.document[$0] }
        let moving = Set(ids), registry = editor.registry
        var frames: [(id: ShapeID, grabOffset: CGPoint)] = []
        // Every begin in one transaction, committed before the first move. For boxes alone
        // nothing changes, so nothing commits.
        let moves = editor.transact { tx in
            before.compactMap { record -> (@MainActor (CGPoint, inout Transaction) -> Void)? in
                if let custom = registry.definition(for: record.kind) as? any CustomTranslation {
                    return custom.erasedBeginTranslation(of: record, movingWith: moving, in: &tx)
                }
                if let box = record.box { frames.append((record.id, origin - box.origin)) }
                return nil
            }
        }
        self.origin = origin
        self.before = before
        self.frames = frames
        self.moves = moves
    }
}

extension TranslatingSession: Session {
    var hidesSelectionIndicator: Bool { true }

    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        let delta = pointer.world - origin
        editor.transact { tx in
            // `pointer.world − grabOffset`, not `start + delta`: the two differ in the last bit
            // for some fractional points. This is the POC's box drag, and Characterization pins it.
            for (id, grabOffset) in frames { tx.update(id) { $0.box?.origin = pointer.world - grabOffset } }
            for move in moves { move(delta, &tx) }
        }
    }

    /// Escape (tldraw): every shape back to its record from before the drag, including what
    /// `beginTranslation` changed (an arrow's precise ends).
    func cancel(in editor: CanvasEditor) -> Bool {
        editor.transact { tx in
            for record in before { tx.update(record.id) { $0 = record } }
        }
        return true
    }
}
