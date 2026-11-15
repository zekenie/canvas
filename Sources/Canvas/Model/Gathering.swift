import CoreGraphics

// Putting a new shape of a kind that owns boards down where shapes are, taking them onto its board
// (`CanvasEditor.place(_:taking:)`: Subboards' Create Subboard): the sibling of putting a container down
// around them (Enclosing.swift), for the same shapes.

extension Transaction {
    /// Puts `owner`, a new box shape of a kind that owns boards (`BoardOwning`), down where shapes on this
    /// board are, and moves them onto its board under their ids, where they are (`move(_:to:)`): those of
    /// `ids` with a box, but what's in another of them (it goes with that one), as `enclose` holds them,
    /// with what they hold and what's bound to them alone (an arrow between two of them); a binding
    /// across the edge is let go of where it's drawn, and a name kept. `owner` keeps its box's size, its
    /// top-left corner at the top-left corner of the frames they're laid out in, in the innermost container
    /// they're all in, kept `Style.containerGap` inside that one's edge where it fits there
    /// (`Settlement.kept(_:inside:)`, as Transform keeps a turned shape in its container), and in the stack
    /// where the lowest of them was, so it covers nothing beside them that was above them all. Then
    /// it's settled as a placement is (`settle(_:)`): one that reaches into another container is nudged out
    /// of it, and one too big for its own goes as the in-or-out rule says.
    ///
    /// Returns what settling nudged, by how far. Nil when `owner` isn't a box shape of a kind that owns
    /// boards or none of `ids` has a box, and, all or nothing for read-only shapes, when one that would
    /// move is read-only (one of them, what it holds, a read-only shape bound to them alone, which the
    /// move would leave behind let go of both ends, as the container channel's turn would; or the board)
    /// or a read-only container would take `owner`, noted in `refusedShapes`: by then `owner` may be in,
    /// so the caller gives the transaction up (`editor.transactWhole`).
    mutating func gather(_ ids: [ShapeID], onto owner: AnyShapeRecord) -> [ShapeID: CGPoint]? {
        let kinds = registry.containingKinds
        guard registry.boardOwningKinds.contains(owner.kind), let size = owner.box?.size,
              let found = putDown(for: ids), let lowest = found.held.first else { return nil }
        let held = found.held, parent = found.parent
        let stuck = held.filter { holds($0) }
        guard stuck.isEmpty else {
            refused.formUnion(stuck.map(\.id))
            return nil
        }
        // The frames they're laid out in, read from one context before anything changes.
        var bounds = CGRect.null
        do {
            let context = shapes
            for record in held {
                if let frame = context.frame(of: record) { bounds = bounds.union(frame) }
            }
        }
        guard !bounds.isNull else { return nil }
        // What a move would leave behind (a read-only arrow between two of them) is named among what moves,
        // so that it refuses the move rather than being left let go of.
        var moving = Set(held.map(\.id))
        moving.formUnion(readOnlyShapes(boundOnlyTo: moving.union(held.flatMap { document.descendants(of: $0.id, containingKinds: kinds) })))
        // Kept in the container they're all in, where it fits there, as a turned shape is kept in its own.
        var frame = CGRect(origin: bounds.origin, size: size)
        if let edge = parent.flatMap({ document[$0]?.box }) { frame = Settlement.kept(frame, inside: edge) }
        var record = owner
        record.box = frame
        record.container = parent
        insert(record)
        guard document[record.id] != nil else { return nil }
        move(record.id, below: lowest.id)
        guard move(moving, toBoardOwnedBy: record.id) else { return nil }
        guard case .settled(let nudges) = settle([record.id]) else { return nil }
        return nudges
    }
}
