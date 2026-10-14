import Canvas
import CoreGraphics
import Draw

/// One shape a command moves: on the board shown, with a box. Each command asks its rule again before it
/// moves anything (what it was given may have changed since the line was typed): a target it no longer
/// takes moves nothing.
@MainActor
struct Move {
    let editor: CanvasEditor
    let block: Block

    /// Nil for a shape that isn't on the board shown, is kept aside, or has no box.
    init?(_ id: ShapeID, in editor: CanvasEditor) {
        guard editor.document[id] != nil, let block = Block([id], in: editor) else { return nil }
        self.editor = editor
        self.block = block
    }

    private var id: ShapeID { block.shapes[0].id }

    /// `/move-to`: into the frame the line names, on its board, or onto the subboard's board, anywhere.
    func into(_ target: ShapeID) {
        guard let destination = Destination(of: id, into: target, in: editor),
              let surroundings = Surroundings(on: destination.board, moving: block, in: editor) else { return }
        switch destination {
        case .container(let container, on: _):
            if let landing = surroundings.inside(container) { block.commit(landing) }
        case .board:
            block.commit(surroundings.anywhere())
        }
    }

    /// `/move-near`: beside the shape the line names, on its board.
    func near(_ target: ShapeID) {
        guard admitsNear(target, for: id, in: editor), let board = editor.file.board(containing: target),
              let surroundings = Surroundings(on: board, moving: block, in: editor),
              let found = surroundings.reading.document[target], !found.isOpaque,
              let landing = surroundings.near(target) else { return }
        block.commit(landing)
    }
}

/// Shapes that move together, as one: on one board of the file the editor can show, each with a box and
/// not kept aside, back to front, less those another of them holds (it takes them along). Where they
/// land is worked out for the box around them all (`box`), and they keep where they are to each other.
@MainActor
struct Block {
    let editor: CanvasEditor
    /// Back to front.
    let shapes: [AnyShapeRecord]
    /// The board they're on.
    let board: BoardID
    /// The box around them all: the frames they are laid out in (`editor.frame(inFile:)`, which a shape on
    /// a board that isn't shown has too), so where they land makes room for what is drawn.
    let box: CGRect
    /// What the containers among them hold, at any depth, which goes with them.
    let carried: Set<ShapeID>

    /// Nil for no shapes, shapes on more than one board, or on one the editor can't show, and for a
    /// shape kept aside or with no box.
    init?(_ ids: [ShapeID], in editor: CanvasEditor) {
        let file = editor.file
        guard let first = ids.first, let board = file.board(containing: first), editor.canShow(board) else { return nil }
        let document = editor.contents(of: board), kinds = editor.registry.containingKinds
        var records: [AnyShapeRecord] = []
        for id in Set(ids) {
            guard let record = document[id], !record.isOpaque, record.box != nil else { return nil }
            records.append(record)
        }
        let carried = kinds.isEmpty ? [] : Set(records.flatMap { document.descendants(of: $0.id, containingKinds: kinds) })
        records = records.filter { !carried.contains($0.id) }.sorted { (document.index(of: $0.id) ?? 0) < (document.index(of: $1.id) ?? 0) }
        self.editor = editor
        shapes = records
        self.board = board
        box = records.compactMap { editor.frame(inFile: $0.id) ?? $0.box }.reduce(CGRect.null) { $0.union($1) }
        self.carried = carried
    }

    var ids: Set<ShapeID> { Set(shapes.map(\.id)) }

    /// Moves the shapes where they land, with what they hold, in one transaction, one undo step ("Move"),
    /// with the core's tools as draw's commit uses them, each by where the box around them lands less
    /// where it is. Landing on their own board: `translate` (on it, `translate(_:by:on:)`, if it isn't the
    /// board shown), raised above what they're put over that paints above them (`move(_:above:on:)`), and
    /// put down by the in-or-out rule (`settle(_:on:)`). Landing on another board: moved there first
    /// (`move(_:to:)`, or `move(_:from:to:)` off a board that isn't shown), so what's bound to them across
    /// the edge lets go where it's drawn, then moved as far there and put down there. `finish` runs last,
    /// in the same transaction (the table of contents' restack), and throws to drop it all. All or nothing: a read-only shape in the
    /// way (one of them, a locked frame that would take them, the locked owner of the board they'd go
    /// onto, a locked shape a frame would take there) throws out of the transaction, so nothing changes
    /// and no step is made, and the refused shapes are heard (`editor.refuseChanges(to:)`: they shake).
    /// Landed on the board shown, from it, a shape being typed in that moved is put down (editing ends,
    /// what was typed kept), as a `canvas draw` that moves it puts it down, and what moved glides there
    /// from where it was; the camera stays where it is. Moved onto another board, the shapes are gone
    /// from the board shown (the core ends their editing), and nothing glides.
    func commit(_ landing: Landing, finish: (inout Transaction) throws -> Void = { _ in }) {
        let ids = ids, editor = editor, source = board, target = landing.board, shown = editor.board, kinds = editor.registry.containingKinds
        let delta = CGPoint(x: landing.rect.minX - box.minX, y: landing.rect.minY - box.minY)
        let order = shapes.map(\.id)
        let nudges: [ShapeID: CGPoint]
        do {
            nudges = try editor.transact(MovingStyle.stepName) { transaction -> [ShapeID: CGPoint] in
                if target != source {
                    // Onto the board first, so what's bound to them across the edge lets go where it's drawn (an
                    // arrow's end stays where the shape was, as after a cut), then where they go there.
                    let moved = source == shown ? transaction.move(ids, to: target) : transaction.move(ids, from: source, to: target)
                    guard moved else { throw Refused(shapes: transaction.refusedShapes) }
                }
                // What the move took along (an arrow bound only to them) goes as far as they do.
                transaction.translate(ids.union(transaction.rodeAlong), by: delta, on: target)
                guard transaction.refusedShapes.isEmpty else { throw Refused(shapes: transaction.refusedShapes) }
                if target == source {
                    // Raised over what they're put on that paints above any of them, together, in their order.
                    for above in landing.above {
                        let there = transaction.contents(of: target)
                        guard let theirs = there.index(of: above), order.contains(where: { (there.index(of: $0) ?? .max) < theirs }) else { continue }
                        var anchor = above
                        for id in order {
                            transaction.move(id, above: anchor, on: target)
                            anchor = kinds.isEmpty ? id : transaction.contents(of: target).descendants(of: id, containingKinds: kinds).last ?? id
                        }
                    }
                }
                switch transaction.settle(ids, on: target) {
                case .settled(let nudges):
                    try finish(&transaction)
                    return target == shown ? nudges : [:]
                case .refused:
                    throw Refused(shapes: transaction.refusedShapes)
                }
            }
        } catch let refusal as Refused {
            if !refusal.shapes.isEmpty { editor.refuseChanges(to: refusal.shapes) }
            return
        } catch {
            return
        }
        guard target == shown, source == shown else { return }
        var moved: [ShapeID: CGPoint] = [:]
        if delta != .zero { for each in ids.union(carried) { moved[each] = delta } }
        for (each, nudge) in nudges { moved[each] = moved[each].map { CGPoint(x: $0.x + nudge.x, y: $0.y + nudge.y) } ?? nudge }
        if let editing = editor.editingShapeID, let by = moved[editing], by != .zero { editor.endEditing(discarding: false) }
        editor.glide(moved)
    }
}

/// What leaves a move a read-only shape stood in the way of, or that can't put the shapes where they
/// were to go: nothing changes.
struct Refused: Error {
    let shapes: Set<ShapeID>
}
