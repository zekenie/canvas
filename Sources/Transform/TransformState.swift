import Canvas
import CoreGraphics

/// What transforms know of an editor: what a shape can be turned into, and turning shapes. Per editor
/// (so per window), and it keeps nothing per shape: each kind's targets are worked out once (the
/// registry is frozen), and what a shape can become is asked of its record each time, so
/// `boardDidChange` is overridden with nothing.
@MainActor
public final class TransformState {
    private unowned let editor: CanvasEditor
    /// What each kind can be turned into, as the registry has it.
    private var targetsByKind: [ShapeKind: [ShapeKind]] = [:]

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    /// The kinds a shape can be turned into now, in plugin order (`registry.turnTargets(of:)`); none for
    /// a shape that isn't on the board shown, or is kept aside.
    public func targets(of id: ShapeID) -> [ShapeKind] {
        guard let record = editor.document[id], !record.isOpaque else { return [] }
        if let known = targetsByKind[record.kind] { return known }
        let found = editor.registry.turnTargets(of: record.kind)
        targetsByKind[record.kind] = found
        return found
    }

    /// Whether a shape can be turned into `kind` now: it's on the board shown and not kept aside, it
    /// isn't of that kind, and its kind offers the channel `kind` takes. A read-only shape can: turning
    /// it is refused, and it shakes.
    public func canTurn(_ id: ShapeID, into kind: ShapeKind) -> Bool { targets(of: id).contains(kind) }

    /// Turns these shapes (those that `canTurn`, each once) into `kind`, in one undo step, "Turn into
    /// Subboard": innermost first (the deepest in containers, then back to front), so a container
    /// that turns inside another has turned, and moved what it held, by the time the outer one reads
    /// what it holds. Each is turned as its target says, through what its channel hands it. A shape
    /// keeps the container it's in: one that comes out larger and hangs over it is shifted inside it,
    /// `Settlement.gap` in, where it fits, so the in-or-out rule, which judges by area, can't put it
    /// out. Then they're put down as a placement is (`transaction.settle`): one that reaches into
    /// another container is nudged out of it, and one too large for its own goes as the rule says;
    /// what moved glides there.
    ///
    /// All or nothing for read-only shapes (`editor.transactWhole`): if any of them, or anything the
    /// target moves, is read-only (locked, or in a locked container), or a read-only container would
    /// take one of them, nothing changes, no step is made, and services hear which were refused
    /// (`editor.refuseChanges(to:)`: they shake). Once one is refused no other target runs (the turn
    /// is thrown away), but every read-only one among them is still found, so each shakes. A target
    /// whose turn throws turns nothing too. Returns whether it turned any.
    @discardableResult
    public func turn(_ ids: [ShapeID], into kind: ShapeKind) -> Bool {
        guard let target = editor.registry.contributions(to: TransformTargets.self, for: kind).first else { return false }
        var seen = Set<ShapeID>()
        let document = editor.document, kinds = editor.registry.containingKinds
        let turning = ids.filter { canTurn($0, into: kind) && seen.insert($0).inserted }
            .map { (id: $0, depth: document.containers(of: $0, containingKinds: kinds).count, index: document.index(of: $0) ?? 0) }
            .sorted { ($0.depth, $1.index) > ($1.depth, $0.index) }
            .map(\.id)
        guard !turning.isEmpty else { return false }
        // All or nothing (`transactWhole`): a refusal leaves no step, and the refused shake once it's out.
        let turned = editor.transactWhole("Turn into \(target.label)") { transaction -> (ids: [ShapeID], nudges: [ShapeID: CGPoint]) in
            var done: [ShapeID] = [], refused: Set<ShapeID> = []
            for id in turning {
                guard let record = transaction.document[id] else { continue }
                if transaction.isReadOnly(record) {
                    refused.insert(id)
                } else if refused.isEmpty, transaction.refusedShapes.isEmpty, try target.turn(id, &transaction) {
                    done.append(id)
                }
            }
            guard refused.isEmpty, transaction.refusedShapes.isEmpty else { throw Transaction.Refused(refused) }
            let shifts = Self.keepInContainers(done, in: &transaction)
            let nudges = transaction.settle(done).nudges
            return (done, nudges.merging(shifts) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) })
        }
        guard let turned else { return false }
        editor.glide(turned.nudges)
        return !turned.ids.isEmpty
    }

    /// Shifts each turned shape that hangs over the container it's in back inside it, `Settlement.gap`
    /// in, if it fits there, with what it holds: how far each moved, for the glide.
    private static func keepInContainers(_ ids: [ShapeID], in transaction: inout Transaction) -> [ShapeID: CGPoint] {
        let kinds = transaction.shapes.registry.containingKinds
        var shifts: [ShapeID: CGPoint] = [:]
        for id in ids {
            let document = transaction.document
            guard let record = document[id], let box = transaction.shapes.frame(of: record), let container = document.container(of: record, containingKinds: kinds),
                  let edge = document[container]?.box else { continue }
            let room = edge.insetBy(dx: Settlement.gap, dy: Settlement.gap)
            guard box.width <= room.width, box.height <= room.height else { continue }
            let shift = CGPoint(x: min(max(box.minX, room.minX), room.maxX - box.width) - box.minX,
                                y: min(max(box.minY, room.minY), room.maxY - box.height) - box.minY)
            guard shift != .zero else { continue }
            transaction.translate([id], by: shift)
            for moved in [id] + document.descendants(of: id, containingKinds: kinds) { shifts[moved] = shift }
        }
        return shifts
    }
}

extension TransformState: EditorService {}

extension CanvasEditor {
    /// What this editor's shapes can be turned into, and turning them; nil without `TransformPlugin`.
    public var transforms: TransformState? { service(TransformState.self) }
}
