import Canvas
import Topology

// Reading an end: what an arrow's end is, from records and the file alone, so the answer is a function of
// the commit and exact under undo. A relationship reaches another board by ending on a pill that stands
// for a note there, so the pill's every state is read here, once, for the check's words, a row's pill,
// the far writer and the fit.

extension RelationshipIndex {
    /// What one end is. Not kept: its readers keep what they make of it, and a rename, a re-point, a
    /// privacy change and a deletion all reach them through the edges.
    ///
    /// - A shape that is no stand-in is `.note`; so is a direct pill that is live and admitted (its shape is
    ///   there and the kind may stand for it now).
    /// - A direct pill whose shape is in no board is `.gone`; on a board the app cannot show, or kept aside,
    ///   `.unavailable`; there, and the kind may not stand for it now, `.notAdmitted`, saying what it needs.
    /// - A pill that finds shapes (several named, or an answer provided) is `.query`; one that stands for
    ///   nothing is `.empty`. A shape that is not there is `.free`.
    ///
    /// The name kept for a pill that is gone, unavailable or finds shapes is what its kind says it calls them
    /// (`StandIns.calls`).
    public func reading(ofEnd literal: ShapeID) -> EndReading {
        guard let editor, let record = editor.shape(inFile: literal) else { return .free }
        let standIns = self.standIns
        guard standInKinds.contains(record.kind) else { return .note(literal) }
        let called = standIns.calls(record)
        guard let forwarding = standIns.forwarding(of: record) else { return .empty }
        guard case .shapes(let named) = forwarding else { return .query(called: called) }
        var distinct: [ShapeID] = []
        for id in named where !distinct.contains(id) { distinct.append(id) }
        guard let target = distinct.first else { return .empty }
        guard distinct.count == 1 else { return .query(called: called) }
        switch editor.topology?.forwarding(of: literal) {
        case .record(let live)? where live == [target]:
            return .note(target)
        default:
            switch editor.topology?.end(target) {
            case .missing?, nil: return .gone(called: called)
            case .unavailable?: return .unavailable(called: called)
            case .live?: return .notAdmitted(target, needs: standIns.needs(record.kind) ?? "")
            }
        }
    }

    /// A connection's two ends, read; nil when it is not bound at both ends, or is not of a kind that
    /// relates. The literal ends, the recorded view.
    public func subjects(of connection: ShapeID) -> ConnectionReading? {
        guard let editor, let record = editor.shape(inFile: connection), editor.registry.relates(record.kind),
              let edge = editor.topology?.edges(carriedBy: connection, view: .literal).first(where: \.isConnection) else { return nil }
        return ConnectionReading(from: ReadEnd(literal: edge.source, reading: reading(ofEnd: edge.source)),
                                 to: ReadEnd(literal: edge.target, reading: reading(ofEnd: edge.target)))
    }
}
