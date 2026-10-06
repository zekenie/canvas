import Canvas

// Kept apart from SwiftUI, whose `Transaction` is another type.

/// Where a drop in the table of contents puts shapes: on a board, in a container there or on it
/// directly, and where in its stack. On a frame's row it's in the frame, in front of what it holds;
/// on a subboard's row, on that board, in front of what it holds; above or below a row, beside that
/// row's shape, in front of it (and what it holds) or behind it.
public struct ContentsPlace: Hashable, Sendable {
    public enum Position: Hashable, Sendable {
        /// In front of everything there.
        case front
        /// Just in front of a shape there, and of what it holds.
        case inFront(of: ShapeID)
        /// Just behind a shape there.
        case behind(ShapeID)
    }

    public let board: BoardID
    public let container: ShapeID?
    public let position: Position

    public init(board: BoardID, container: ShapeID?, position: Position) {
        self.board = board
        self.container = container
        self.position = position
    }

    /// The shape it's beside, for `inFront(of:)` and `behind(_:)`.
    public var neighbor: ShapeID? {
        switch position {
        case .front: nil
        case .inFront(of: let id), .behind(let id): id
        }
    }
}

extension ContentsPlace {
    /// Restacks those of `ids` in this place (on its board, in its container directly) where it
    /// says, keeping their order among themselves: in front of everything else there, or in front of
    /// its neighbor and all it holds, or just behind it; a container takes what it holds along, so
    /// one of them another holds goes with that one. What `ContentsMoves`' contributor does once it
    /// has moved shapes here, in the same transaction.
    @MainActor
    public func restack(_ ids: [ShapeID], in transaction: inout Transaction, containingKinds kinds: Set<ShapeKind>) {
        let document = transaction.contents(of: board)
        let mine = ids.filter { document[$0] != nil && document.container(of: $0, containingKinds: kinds) == container }
        let held = Set(mine.flatMap { document.descendants(of: $0, containingKinds: kinds) })
        let ordered = mine.filter { !held.contains($0) }.sorted { (document.index(of: $0) ?? 0) < (document.index(of: $1) ?? 0) }
        guard !ordered.isEmpty else { return }
        /// The topmost of a shape and what it holds, at any depth, as the transaction has them now.
        func top(of id: ShapeID, in transaction: Transaction) -> ShapeID {
            kinds.isEmpty ? id : transaction.contents(of: board).descendants(of: id, containingKinds: kinds).last ?? id
        }
        var anchor: ShapeID
        switch position {
        case .front:
            // The topmost shape there that stays, else the container itself.
            let moving = Set(ordered).union(held)
            let there = container.map { document.descendants(of: $0, containingKinds: kinds) } ?? document.shapes.map { $0.id }
            guard let topmost = there.last(where: { !moving.contains($0) }) ?? container else { return }
            anchor = topmost
        case .inFront(of: let neighbor):
            anchor = top(of: neighbor, in: transaction)
        case .behind(let neighbor):
            anchor = neighbor
            for id in ordered.reversed() {
                transaction.move(id, below: anchor, on: board)
                anchor = id
            }
            return
        }
        for id in ordered {
            transaction.move(id, above: anchor, on: board)
            anchor = top(of: id, in: transaction)
        }
    }
}
