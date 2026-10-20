import Boards
import Canvas
import Topology

// Where a reference's original is, as its row in the table of contents says it before its name:
// "Alpha › Beta › Checkout".

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
        guard let topology = editor.topology else { return [] }
        // Each nearest first, so what they share is at their ends.
        let above = topology.ancestors(of: target)
        // Inside nothing, it has no path until it's put somewhere, which changes it: a change the
        // row hears of already, as one to the shape it names.
        guard !above.isEmpty else {
            forgetPath(of: reference)
            return []
        }
        let own = topology.ancestors(of: reference)
        notePath(of: reference, readFrom: Set(above).union(own))
        var shared = 0
        while shared < above.count, shared < own.count, above[above.count - 1 - shared] == own[own.count - 1 - shared] { shared += 1 }
        let registry = editor.registry
        return above.dropLast(shared).reversed().compactMap { id in
            editor.shape(inFile: id).map { registry.containerName(of: $0) }
        }
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
