import Canvas
import CoreGraphics
import Draw
import Mentions
import Selection

/// The shapes a command moves, as one block: on the board shown, with a box, kept where they are to each
/// other. Each command asks its rule again before it moves anything (what it was given may have changed
/// since the line was typed): a target it no longer takes moves nothing.
@MainActor
struct Move {
    let editor: CanvasEditor
    /// The shapes the command acts on, as it was given them.
    let ids: [ShapeID]
    let block: Block

    /// Nil for no shapes, and for a shape that isn't on the board shown, is kept aside, or has no box.
    init?(_ ids: [ShapeID], in editor: CanvasEditor) {
        guard !ids.isEmpty, ids.allSatisfy({ editor.document[$0] != nil }), let block = Block(ids, in: editor) else { return nil }
        self.editor = editor
        self.ids = ids
        self.block = block
    }

    /// `/move-to`: into the frame the line names, on its board, or onto the subboard's board, anywhere; the
    /// drop Move To ▸ and the table of contents make of them (`Drop`), landed and committed as theirs, in
    /// one step, so the three refuse and land alike.
    func into(_ target: ShapeID) {
        guard let place = movePlace(of: target, in: editor) else { return }
        Drop(ids, to: place, in: editor)?.commit()
    }

    /// `/move-near`: beside the shape the line names, on its board.
    func near(_ target: ShapeID) {
        guard admitsNear(target, for: ids, in: editor), let board = editor.file.board(containing: target),
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
    /// onto, a locked shape a frame would take there) gives the whole move up (`transactWhole`), so
    /// nothing changes and no step is made, and the refused shapes are heard (`editor.refuseChanges(to:)`:
    /// they shake).
    /// Landed on the board shown, from it, a shape being typed in that moved is put down (editing ends,
    /// what was typed kept), as a `canvas draw` that moves it puts it down, and what moved glides there
    /// from where it was. Moved onto another board, the shapes are gone from the board shown (the core
    /// ends their editing), and nothing glides. Then the editor goes where they went (`follow`), so
    /// the person is never left where they were.
    func commit(_ landing: Landing, finish: (inout Transaction) throws -> Void = { _ in }) {
        let ids = ids, editor = editor, source = board, target = landing.board, shown = editor.board, kinds = editor.registry.containingKinds
        let delta = CGPoint(x: landing.rect.minX - box.minX, y: landing.rect.minY - box.minY)
        let order = shapes.map(\.id)
        // Where the person is and what they have selected before the move: what going after the shapes is a step back to.
        let start = editor.navigationStart, selected = editor.selectedShapeIDs, revision = editor.revision
        // The arrows that would cross the edge, kept through reference pills: an arrow goes where its start goes (planned from
        // the board as it is, written in the transaction below).
        let rebinding = target == source ? nil : CrossingArrows(moving: ids.union(carried), from: source, to: target, by: delta,
                                                                  label: { [registry = editor.registry] in registry.mentionAppearance(of: $0)?.label ?? "" }, in: editor)
        let committed = editor.transactWhole(MovingStyle.stepName) { transaction -> [ShapeID: CGPoint] in
            var placed: Set<ShapeID> = []
            if target != source {
                // The ends of the arrows that cross are pointed at pills first (new pills in, on the origin), so an arrow that goes
                // with its start is bound only to shapes that move and rides along, and one that stays is bound to what stays.
                let rebound = rebinding?.rebind(in: &transaction)
                // Onto the board first, so what's bound to them across the edge lets go where it's drawn (an
                // arrow's end stays where the shape was, as after a cut), then where they go there.
                let asked = ids.union(rebound?.along ?? [])
                let moved = source == shown ? transaction.move(asked, to: target) : transaction.move(asked, from: source, to: target)
                guard moved else { throw Transaction.Refused() }
                // An arrow that rode on a stand-in is bound to what the destination had, and the stand-in goes.
                rebound?.finish(in: &transaction)
                placed = rebound?.placed ?? []
            }
            // What the move took along (an arrow bound only to them) goes as far as they do.
            transaction.translate(ids.union(transaction.rodeAlong), by: delta, on: target)
            guard transaction.refusedShapes.isEmpty else { throw Transaction.Refused() }
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
            // The shapes are put down alone, so the pills they bring do not weigh in the verdict on where they belong; the new pills
            // are where they land, put down after them, not moved with them.
            guard case .settled(var nudges) = transaction.settle(ids, on: target) else { throw Transaction.Refused() }
            if !placed.isEmpty {
                guard case .settled(let pillNudges) = transaction.settle(placed, on: target) else { throw Transaction.Refused() }
                nudges.merge(pillNudges) { first, _ in first }
            }
            try finish(&transaction)
            return target == shown ? nudges : [:]
        }
        // A move that lands where the shapes are commits nothing: nowhere to go, and editing goes on.
        guard let nudges = committed, editor.revision != revision else { return }
        if target == shown, source == shown {
            var moved: [ShapeID: CGPoint] = [:]
            if delta != .zero { for each in ids.union(carried) { moved[each] = delta } }
            for (each, nudge) in nudges { moved[each] = moved[each].map { CGPoint(x: $0.x + nudge.x, y: $0.y + nudge.y) } ?? nudge }
            if let editing = editor.editingShapeID, let by = moved[editing], by != .zero { editor.endEditing(discarding: false) }
            editor.glide(moved)
        }
        follow(onto: target, from: start, selected: selected)
    }

    /// Goes where the shapes went, as one step back to where the person was (`start`: the board, the
    /// selection and the camera before the move): onto another board, that board is shown with them
    /// selected there; on the board shown, they're selected; either way what was selected stays so
    /// where it holds them all (an arrow that rode along with them too). Then the shapes that moved,
    /// and only they (not a selected shape that stayed where it was), are brought into view if they
    /// aren't in it, at the zoom the camera has (`revealIfOffscreen`), since a move isn't a link
    /// followed to read what it names, which `goTo` brings to a readable zoom. Landed in view with
    /// nothing more selected, nothing moves and no step is made. Without the Selection plugin there's
    /// no step back and nothing is selected: their board is shown and they're brought into view.
    private func follow(onto target: BoardID, from start: NavigationStart?, selected: [ShapeID]) {
        let editor = editor, file = editor.file, moved = shapes.map(\.id)
        let kept = selected.filter { file.board(containing: $0) == target }
        let landed = ids.isSubset(of: kept) ? kept : moved
        let go = {
            guard editor.showBoard(target, selecting: landed) else { return }
            editor.revealIfOffscreen(moved)
        }
        if let start { editor.navigate(from: start, go) } else { go() }
    }
}
