import Canvas
import CoreGraphics

/// One shape a command moves: on the board shown, with a box. Each command asks its rule again before it
/// moves anything (what it was given may have changed since the line was typed): a target it no longer
/// takes moves nothing.
@MainActor
struct Move {
    let editor: CanvasEditor
    let shape: AnyShapeRecord
    let box: CGRect

    /// Nil for a shape that isn't on the board shown, is kept aside, or has no box.
    init?(_ id: ShapeID, in editor: CanvasEditor) {
        guard let shape = editor.document[id], !shape.isOpaque, let box = shape.box else { return nil }
        self.editor = editor
        self.shape = shape
        self.box = box
    }

    /// `/move-to`: into the frame the line names, on its board, or onto the subboard's board, anywhere.
    func into(_ target: ShapeID) {
        guard let destination = Destination(of: shape.id, into: target, in: editor),
              let surroundings = Surroundings(on: destination.board, moving: shape, in: editor) else { return }
        switch destination {
        case .container(let container, on: _):
            if let landing = surroundings.inside(container) { commit(landing) }
        case .board:
            commit(surroundings.anywhere())
        }
    }

    /// `/move-near`: beside the shape the line names, on its board.
    func near(_ target: ShapeID) {
        guard admitsNear(target, for: shape.id, in: editor), let board = editor.file.board(containing: target),
              let surroundings = Surroundings(on: board, moving: shape, in: editor),
              let found = surroundings.reading.document[target], !found.isOpaque,
              let landing = surroundings.near(target) else { return }
        commit(landing)
    }

    /// Moves the shape where it lands, with what it holds, in one transaction, one undo step ("Move"),
    /// with the core's tools as draw's commit uses them. Landing on the board shown: `translate` by where
    /// it lands less where it is, raised above what it's put over that paints above it
    /// (`move(_:above:)`), and put down by the in-or-out rule (`settle`). Landing on another board: moved
    /// there first (`move(_:to:)`), so what's bound to it across the edge lets go where it's drawn, then
    /// moved as far there (`translate(_:by:on:)`) and put down there (`settle(_:on:)`). All or nothing: a
    /// read-only shape in the way (the shape, a locked frame that would take it, the locked owner of the
    /// board it would go onto, a locked shape a frame would take there) throws out of the transaction, so
    /// nothing changes and no step is made, and the refused shapes are heard (`editor.refuseChanges(to:)`:
    /// they shake). Landed on the board shown, a shape being typed in that moved is put down (editing
    /// ends, what was typed kept), as a `canvas draw` that moves it puts it down, and what moved glides
    /// there from where it was; the camera stays where it is. Moved onto another board, the shape is gone
    /// from the board shown (the core ends its editing), and nothing glides.
    private func commit(_ landing: Landing) {
        let id = shape.id, editor = editor, shown = landing.board == editor.board
        let delta = CGPoint(x: landing.rect.minX - box.minX, y: landing.rect.minY - box.minY)
        let kinds = editor.registry.containingKinds
        let carried = kinds.isEmpty ? [] : editor.document.descendants(of: id, containingKinds: kinds)
        let nudges: [ShapeID: CGPoint]
        do {
            nudges = try editor.transact(MovingStyle.stepName) { transaction -> [ShapeID: CGPoint] in
                guard shown else {
                    // Onto the board first, so what's bound to it across the edge lets go where it's drawn (an
                    // arrow's end stays where the shape was, as after a cut), then where it goes there.
                    guard transaction.move([id], to: landing.board) else { throw Refused(shapes: transaction.refusedShapes) }
                    transaction.translate([id], by: delta, on: landing.board)
                    guard transaction.refusedShapes.isEmpty else { throw Refused(shapes: transaction.refusedShapes) }
                    if case .refused = transaction.settle([id], on: landing.board) { throw Refused(shapes: transaction.refusedShapes) }
                    return [:]
                }
                transaction.translate([id], by: delta)
                guard transaction.refusedShapes.isEmpty else { throw Refused(shapes: transaction.refusedShapes) }
                for above in landing.above {
                    guard let mine = transaction.document.index(of: id), let theirs = transaction.document.index(of: above), theirs > mine else { continue }
                    transaction.move(id, above: above)
                }
                switch transaction.settle([id]) {
                case .settled(let nudges): return nudges
                case .refused: throw Refused(shapes: transaction.refusedShapes)
                }
            }
        } catch let refusal as Refused {
            if !refusal.shapes.isEmpty { editor.refuseChanges(to: refusal.shapes) }
            return
        } catch {
            return
        }
        guard shown else { return }
        var moved: [ShapeID: CGPoint] = [:]
        if delta != .zero { for each in [id] + carried { moved[each] = delta } }
        for (each, nudge) in nudges { moved[each] = moved[each].map { CGPoint(x: $0.x + nudge.x, y: $0.y + nudge.y) } ?? nudge }
        if let editing = editor.editingShapeID, let by = moved[editing], by != .zero { editor.endEditing(discarding: false) }
        editor.glide(moved)
    }
}

/// What leaves a move a read-only shape stood in the way of: nothing changes.
private struct Refused: Error {
    let shapes: Set<ShapeID>
}
