import Canvas
import CoreGraphics
import Draw
import TableOfContents

/// Shapes the table of contents drops somewhere they aren't (`ContentsMoves`): into a frame (its row, or
/// among the rows it holds), onto a subboard's board (its row, or among its board's rows), or out of the
/// frames they're in (among the rows of one they're in, at any depth, or the board's). They move as one
/// block, keeping where they are to each other, placed as the commands place a shape: into a frame as
/// `/move-to` puts one there, onto a board as `/move-to` puts one on a subboard's, and out of frames
/// beside the outermost one they leave, as `/move-near` puts one beside it. Then, in the same step,
/// every shape dropped is restacked where the drop says (`ContentsPlace.restack`). From any board the
/// list shows rows of (a subboard's open under its row), onto any.
@MainActor
struct Drop {
    let editor: CanvasEditor
    /// Every shape dropped, those already in the place too: they're restacked together.
    let dropped: [ShapeID]
    /// Those that move: the dropped shapes not in the place yet.
    let block: Block
    let place: ContentsPlace
    let way: Way

    enum Way: Equatable {
        /// Into a container, as `/move-to` puts a shape in a frame.
        case into(ShapeID)
        /// Onto another board, as `/move-to` puts a shape on a subboard's board.
        case onto
        /// Out of the containers they're in, beside the outermost they leave, as `/move-near` puts a shape
        /// beside it, kept within the container they go to, if they go to one.
        case beside(ShapeID, within: ShapeID?)
    }

    /// Nil for a drop that doesn't move them: shapes the table of contents doesn't drag together (on
    /// several boards, kept aside, with no box) or that can't change (read-only); all already in the
    /// place; a place that goes with them (in one of them, beside one, or on a board one of them, or
    /// a shape in one, owns: `goesWith`); a board the editor can't show, or that's read-only (a locked
    /// subboard's, at any depth); a container that's read-only or too small for the box around them
    /// (moving in from elsewhere). Cheap: the
    /// table of contents asks it as a drag moves over its rows, and it lays nothing out.
    init?(_ ids: [ShapeID], to place: ContentsPlace, in editor: CanvasEditor) {
        guard let all = Block(ids, in: editor), editor.canShow(place.board) else { return nil }
        let registry = editor.registry, kinds = registry.containingKinds
        let source = all.board, here = editor.contents(of: source)
        guard all.shapes.allSatisfy({ !editor.isReadOnly(inFile: $0.id) }) else { return nil }
        let movers = all.shapes.filter { source != place.board || here.container(of: $0.id, containingKinds: kinds) != place.container }
        guard let first = movers.first, let block = Block(movers.map(\.id), in: editor),
              !goesWith([place.container, place.neighbor].compactMap { $0 }, onto: place.board, moving: all.ids.union(all.carried), in: editor)
        else { return nil }
        if place.board != source, editor.isReadOnly(board: place.board) { return nil }
        if let container = place.container {
            let there = editor.contents(of: place.board)
            guard let holder = there[container], !holder.isOpaque, registry.isContainer(holder), let frame = holder.box,
                  !editor.isReadOnly(inFile: container) else { return nil }
            if source == place.board, let left = Self.outermostLeft(first.id, for: container, in: here, kinds: kinds) {
                way = .beside(left, within: container)
            } else {
                guard block.box.width <= frame.width, block.box.height <= frame.height else { return nil }
                way = .into(container)
            }
        } else if source == place.board {
            guard let left = Self.outermostLeft(first.id, for: nil, in: here, kinds: kinds) else { return nil }
            way = .beside(left, within: nil)
        } else {
            way = .onto
        }
        self.editor = editor
        dropped = all.shapes.map(\.id)
        self.block = block
        self.place = place
    }

    /// Moves the block where it lands, and restacks every shape dropped where the drop says, in one step,
    /// Move (`Block.commit`). Landing worked out now, against the boards as they are. Where the in-or-out
    /// rule leaves them out of the place (no room there clear of what's in it: put down over a frame in
    /// it, which takes them), nothing changes: a drop puts them where it says, or nowhere.
    func commit() {
        guard let surroundings = Surroundings(on: place.board, moving: block, in: editor) else { return }
        let landing: Landing?
        switch way {
        case .into(let container): landing = surroundings.inside(container)
        case .onto: landing = surroundings.anywhere()
        case .beside(let left, within: let holder): landing = surroundings.near(left, within: holder)
        }
        guard let landing else { return }
        let place = place, dropped = dropped, moved = block.ids, kinds = editor.registry.containingKinds
        block.commit(landing) { transaction in
            let there = transaction.contents(of: place.board)
            guard moved.allSatisfy({ there[$0] != nil && there.container(of: $0, containingKinds: kinds) == place.container }) else {
                throw Refused(shapes: [])
            }
            place.restack(dropped, in: &transaction, containingKinds: kinds)
        }
    }

    /// The outermost container `shape` leaves going to `destination` (nil: its board directly) where that's
    /// one it's in, at any depth: the one it's in that's directly in `destination`. Nil when it isn't in
    /// `destination`, so it goes into it rather than out.
    static func outermostLeft(_ shape: ShapeID, for destination: ShapeID?, in document: CanvasDocument, kinds: Set<ShapeKind>) -> ShapeID? {
        let chain = document.containers(of: shape, containingKinds: kinds)        // the nearest first
        guard let destination else { return chain.last }
        guard let at = chain.firstIndex(of: destination), at > 0 else { return nil }
        return chain[at - 1]
    }
}
