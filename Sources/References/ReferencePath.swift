import Boards
import Canvas
import Chrome
import Topology

// Where a reference's original is, as its row in the table of contents says it before its name:
// "Alpha › Beta › Checkout", through Boards' `ShapePaths`.

extension ReferenceState {
    /// The path a direct reference's row shows before the name of the shape it stands for: the shapes
    /// that shape is inside, outermost first (Topology's tree: the frames it's in, the owner of its
    /// board, the frames that one is in, and so on up; the root is never one), less those the
    /// reference is inside too, so the row says only where the shape is from where the reference is:
    /// nothing for a shape in the same frame or on the same board as it, or above it. Each is called
    /// as every path calls a container (Boards' `registry.containerName(of:)`: its title, else what
    /// its kind is called, which the row shows fainter).
    ///
    /// The path is read from shapes the row isn't of, so which were read is noted, for
    /// `rowsAffected(by:)` to name the row when a commit changes one (`pathSources`).
    func rowPath(of reference: ShapeID, to target: ShapeID) -> [ContainerName] {
        #if DEBUG
        pathsRead += 1
        #endif
        let above = paths.containers(of: target), own = paths.containers(of: reference)
        var path = Self.pathBeyond(own, above).map { paths.node($0).name }
        // As the pill says it: a shape on another board than the reference, where no container on the way opens one, is led
        // by its board (the file's name for the top board, else its owner's).
        if !path.contains(where: \.opensBoard), let there = editor.file.board(containing: target), there != editor.file.board(containing: reference) {
            path.insert(leadName(of: there), at: 0)
        }
        // Inside nothing and on the reference's board, it has no path until it's put somewhere, which changes it: a change
        // the row hears of already, as one to the shape it names. Inside what the reference is inside too, it has none yet,
        // but one of those containers moved out of the others gives it one: they're read from all the same.
        guard !above.isEmpty || !path.isEmpty else {
            forgetPath(of: reference)
            return []
        }
        notePath(of: reference, readFrom: Set(above).union(own))
        return path
    }

    /// The containers of a shape (`above`, outermost first) that a viewer inside `own` is not inside too: what
    /// they share from the root down is left out.
    static func pathBeyond<Link: Equatable>(_ own: [Link], _ above: [Link]) -> ArraySlice<Link> {
        above.dropFirst(zip(above, own).prefix { $0 == $1 }.count)
    }

    /// What a pill made to stand for `target` says of where it is, over its name, from where the pill sits
    /// (`StandInSeat`): the steps of the containers the shape is inside that the pill isn't, outermost first, the board
    /// that leads when the shape is on another and none of them opens one (`placeOfTarget`); nil for none. A seat in the
    /// file is read through the state's paths (each container called as every path calls one); a written one (a measure's)
    /// is the names it gives, what they share from the top left out, those it says open a board in their own weight, and the board that leads as in the file.
    static func place(of reference: ReferenceTarget, at seat: StandInSeat, in context: ShapeContext) -> [PlaceStep]? {
        let target = reference.id
        let steps: [PlaceStep]
        switch seat {
        case .file(let container, let board):
            guard let state = context.service(ReferenceState.self) else { return nil }
            // A pill for a row says the shape it's in last.
            steps = state.placeSteps(of: target, seatedIn: container, on: board) + state.rowStep(of: reference)
        case .written(let shape, let seat, let opening, let root):
            guard let state = context.service(ReferenceState.self) else { return nil }
            var names = Array(pathBeyond(seat, shape))
            var boards = opening
            // As in the file, a shape on another board than the pill, with no step that opens one, is led by its board: the
            // card that owns it (the last of its containers that opens a board), else the top board, by the file's name.
            if !names.contains(where: opening.contains) {
                /// The containers up to the one that owns the board a shape is on: none for the top board.
                func board(_ names: [String]) -> [String] { names.lastIndex(where: opening.contains).map { Array(names[...$0]) } ?? [] }
                let there = board(shape)
                if there != board(seat) {
                    // The top board by the open file's name, as the pill drawn there says it; "Board" as Boards says it with none.
                    let lead = there.last ?? (root.isEmpty ? state.editor.name(of: .root) : root)
                    names.insert(lead, at: 0)
                    boards.insert(lead)
                }
            }
            steps = names.map { PlaceStep(name: $0, opensBoard: boards.contains($0)) }
        }
        return steps.isEmpty ? nil : steps
    }

    /// What a pill that is picked to stand for `target` will say of where it is, from where it sits (a pick fits the pill to it).
    func placeOfPick(from pill: ShapeID, _ target: ShapeID) -> [PlaceStep] {
        placeSteps(of: target, beyond: paths.containers(of: pill), from: editor.file.board(containing: pill), noting: false)
    }

    /// The steps `target` is from a pill in `container` (a frame), or directly on `board`: what the pill shows of where
    /// the shape is (`placeOfTarget` reads the pill's own containers, which are these once it sits there).
    func placeSteps(of target: ShapeID, seatedIn container: ShapeID?, on board: BoardID) -> [PlaceStep] {
        let own = container.map { paths.containers(of: $0) + [$0] } ?? board.owner.map { paths.containers(of: $0) + [$0] } ?? []
        return placeSteps(of: target, beyond: own, from: board, noting: false)
    }

    /// Keeps which shapes the row of `reference` read its path from, in place of those it read before.
    private func notePath(of reference: ShapeID, readFrom shapes: Set<ShapeID>) {
        pathSources.set(shapes, for: reference)
    }

    /// Lets go of what the row of `reference` read its path from: the reference changed or went, and
    /// a row made for it again notes what it reads then.
    func forgetPath(of reference: ShapeID) {
        pathSources.forget(reference)
    }
}
