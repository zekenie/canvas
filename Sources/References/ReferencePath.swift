import Boards
import Canvas
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
        let above = paths.containers(of: target)
        // Inside nothing, it has no path until it's put somewhere, which changes it: a change the
        // row hears of already, as one to the shape it names.
        guard !above.isEmpty else {
            forgetPath(of: reference)
            return []
        }
        let own = paths.containers(of: reference)
        notePath(of: reference, readFrom: Set(above).union(own))
        return Self.pathBeyond(own, above).map { paths.node($0).name }
    }

    /// The containers of a shape (`above`, outermost first) that a viewer inside `own` is not inside too: what
    /// they share from the root down is left out.
    static func pathBeyond<Link: Equatable>(_ own: [Link], _ above: [Link]) -> ArraySlice<Link> {
        above.dropFirst(zip(above, own).prefix { $0 == $1 }.count)
    }

    /// What a pill made to stand for `target` says of where it is, beside its name, from where the pill sits
    /// (`StandInSeat`): the containers the shape is inside that the pill isn't, outermost first, joined as a path
    /// says them, as the pill draws them (`placeOfTarget`); nil for none. A seat in the file is read through the
    /// state's paths (each container called as every path calls one); a written one (a measure's) is the names it
    /// gives, what they share from the top left out.
    static func place(of target: ShapeID, at seat: StandInSeat, in context: ShapeContext) -> String? {
        let names: [String]
        switch seat {
        case .file(let container, let board):
            guard let state = context.service(ReferenceState.self) else { return nil }
            names = state.placeNames(of: target, seatedIn: container, on: board)
        case .written(let shape, let seat):
            names = Array(pathBeyond(seat, shape))
        }
        return names.isEmpty ? nil : names.joined(separator: ShapePath.separator)
    }

    /// The names of the containers `target` is inside that a pill in `container` (a frame), or directly on `board`,
    /// isn't inside too, outermost first: what the pill shows of where the shape is (`placeOfTarget` reads the
    /// pill's own containers, which are these once it sits there).
    func placeNames(of target: ShapeID, seatedIn container: ShapeID?, on board: BoardID) -> [String] {
        let above = paths.containers(of: target)
        let own = container.map { paths.containers(of: $0) + [$0] } ?? board.owner.map { paths.containers(of: $0) + [$0] } ?? []
        return Self.pathBeyond(own, above).map { paths.node($0).name.text }
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
