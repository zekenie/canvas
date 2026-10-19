import Canvas
import CoreGraphics

/// The container channel: a kind whose shapes hold shapes (`ShapeContaining`: a frame) may offer it, and a
/// target that takes it is handed the container, and what it held, to put somewhere else (a subboard's own
/// board). What Frames and Subboards meet in, so that neither names the other.
public enum ContainerChannel {}

/// A container coming through the container channel: its id, its frame, and what it holds, at any depth:
/// what a target that takes containers moves, wherever it puts what the container held (the move takes
/// along the arrows bound only to those: an arrow between two of its notes), and the read-only shapes
/// bound only to those, which the move would leave behind: named, so that the turn is refused whole for them
/// as for a read-only shape inside.
public struct TurningContainer: Sendable {
    public let id: ShapeID
    public let frame: CGRect
    public let inside: Set<ShapeID>
}

extension ContainerChannel: TransformChannel {
    public static var name: String { "container" }

    /// A kind that holds shapes.
    public static func admits(_ kind: RegisteredKind) -> Bool { kind.adopts((any ShapeContaining).self) }

    /// The container, if it's on the transaction's board, a container the core goes by, with a frame. What it
    /// holds is read when its turn comes: the shapes in it at any depth, which are fewer by what a container
    /// among them that turned before it (they turn innermost first) took onto its own board. An arrow bound
    /// to some of those and to nothing else goes with them when they move (`Transaction.move(_:to:)`); one
    /// bound to anything that stays, the container included, or to nothing, stays. But a read-only one bound
    /// only to those is named among them: a move leaves it behind, let go of both ends, and a turn leaves
    /// nothing read-only behind that way, so it is refused, and the shape shakes.
    public static func source(of id: ShapeID, in transaction: Transaction) -> TurningContainer? {
        let context = transaction.shapes, registry = context.registry, document = transaction.document
        guard let record = document[id], registry.isContainer(record), let frame = record.box else { return nil }
        var inside = Set(document.descendants(of: id, containingKinds: registry.containingKinds))
        if !inside.isEmpty {
            let held = inside
            for shape in document.shapes where registry.referencingKinds.contains(shape.kind) && shape.id != id
                && transaction.isReadOnly(shape) && shape.isBound(onlyTo: held, in: context) {
                inside.insert(shape.id)
            }
        }
        return TurningContainer(id: id, frame: frame, inside: inside)
    }
}
