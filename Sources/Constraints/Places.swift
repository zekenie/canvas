import Canvas
import Topology

// Where constraints live and whom they reach. A constraint is a place's: a frame's (directly in it), a subboard's (its
// board's top level) or the root's. A shape is held to the constraints of the place it's directly in (`children`) and
// of every place above it in Topology's one containment tree, boards included (`descendants`). Two ways to climb that
// tree: the file as committed, through Topology (the index's), and the file as a transaction leaves it, through its
// reading (admission's, a placement's fit, a run's check), where Topology's answers would be of the file before.

/// Where a constraint comes from, among a place's: the place's own list (the root's, for the root), or a list it has
/// from elsewhere, by the shape that holds that list (a type).
public enum ConstraintOrigin: Hashable, Sendable {
    case own
    case inherited(ShapeID)
}

/// One constraint as a place has it: the place's holder (a frame or a subboard, by its shape, or the root), where the
/// constraint comes from and the constraint itself. What a shape breaks, what an issue's source names, what the walk
/// walks: named by value, so it's the same constraint while the place has it.
public struct PlacedConstraint: Hashable, Sendable {
    /// The frame or subboard whose place it is (a subboard's: its board's top level), or the root.
    public let place: ConstraintTarget
    public let origin: ConstraintOrigin
    public let constraint: Constraint

    public init(place: ConstraintTarget, origin: ConstraintOrigin, constraint: Constraint) {
        self.place = place
        self.origin = origin
        self.constraint = constraint
    }

    /// Whether it reaches a shape `depth` places under its own: 0, directly in it.
    func reaches(depth: Int) -> Bool { constraint.reach == .descendants || depth == 0 }
}

extension ConstraintTarget {
    /// The holder of a place: a container, a board's owner, the root for the root's top level.
    init(_ place: ShapePlace) {
        switch place {
        case .container(let id): self = .shape(id)
        case .board(let board): self = board.owner.map(ConstraintTarget.shape) ?? .root
        }
    }
}

/// The containment tree as a transaction leaves it (or as committed, for a try), read through its reading: a shape's
/// parent is the container it names (one of a kind that holds shapes, on its board), else its board's owner.
@MainActor
struct ReadingPlaces {
    let reading: LayoutReading
    let registry: Registry

    func record(_ id: ShapeID) -> AnyShapeRecord? { reading.shape(inFile: id) }

    /// The place a shape is directly in.
    func place(of record: AnyShapeRecord) -> ShapePlace? {
        guard let board = reading.board(containing: record.id) else { return nil }
        if let container = container(of: record, on: board) { return .container(container) }
        return .board(board)
    }

    /// The holders of the places a shape in `place` is inside, nearest first (the place's own, at depth 0), the root
    /// last.
    func chain(from place: ShapePlace) -> [ConstraintTarget] {
        var holders: [ConstraintTarget] = [], seen: Set<ShapeID> = []
        var current: ShapeID?
        switch place {
        case .container(let id): current = id
        case .board(let board): current = board.owner
        }
        while let id = current, seen.insert(id).inserted {
            holders.append(.shape(id))
            current = parent(of: id)
        }
        holders.append(.root)
        return holders
    }

    /// The shape directly above `id`: its container, else its board's owner; nil on the root in no container.
    private func parent(of id: ShapeID) -> ShapeID? {
        guard let record = record(id), let board = reading.board(containing: id) else { return nil }
        return container(of: record, on: board) ?? board.owner
    }

    /// The container a shape names, if that is a shape of a kind that holds shapes, on the same board.
    private func container(of record: AnyShapeRecord, on board: BoardID) -> ShapeID? {
        guard let id = record.container, let held = self.record(id), !held.isOpaque, registry.containingKinds.contains(held.kind),
              reading.board(containing: id) == board else { return nil }
        return id
    }
}

extension AnyShapeRecord {
    /// Whether two records of a shape say the same but where it is: its box, its container and its place in the
    /// stack aside. What a standing query's answer of the one holds for the other.
    func isSame(asIgnoringPlace other: AnyShapeRecord) -> Bool {
        var mine = copy(as: id)
        mine.box = other.box
        return mine == other.copy(as: other.id)
    }
}
