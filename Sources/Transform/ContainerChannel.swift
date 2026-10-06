import Canvas
import CoreGraphics

/// The container channel: a kind whose shapes hold shapes (`ShapeContaining`: a frame) may offer it, and a
/// target that takes it is handed the container, and what it held, to put somewhere else (a subboard's own
/// board). What Frames and Subboards meet in, so that neither names the other.
public enum ContainerChannel {}

/// A container coming through the container channel: its id, its frame, and what it holds, at any depth,
/// with what's bound only to those (an arrow between two of its notes): what a target that takes containers
/// moves, wherever it puts what the container held.
public struct TurningContainer: Sendable {
    public let id: ShapeID
    public let frame: CGRect
    public let held: Set<ShapeID>
}

extension ContainerChannel: TransformChannel {
    public static var name: String { "container" }

    /// A kind that holds shapes.
    public static func admits(_ kind: TransformKind) -> Bool { kind.definition is any ShapeContaining }

    /// The container, if it's on the transaction's board, a container the core goes by, with a frame. What it
    /// holds is read when its turn comes: the shapes in it at any depth, which are fewer by what a container
    /// among them that turned before it (they turn innermost first) took onto its own board, and every shape
    /// bound to some of those and to nothing else, which goes with them (an arrow between two of its notes). A
    /// shape bound to anything that stays, the container included, or to nothing, stays.
    public static func source(of id: ShapeID, in transaction: Transaction) -> TurningContainer? {
        let context = transaction.shapes, registry = context.registry, document = transaction.document
        guard let record = document[id], registry.isContainer(record), let frame = record.box else { return nil }
        let inside = Set(document.descendants(of: id, containingKinds: registry.containingKinds))
        var held = inside
        if !inside.isEmpty {
            for shape in document.shapes where registry.referencingKinds.contains(shape.kind) && shape.id != id {
                if shape.isBound(onlyTo: inside, in: context) { held.insert(shape.id) }
            }
        }
        return TurningContainer(id: id, frame: frame, held: held)
    }
}
