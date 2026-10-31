import Canvas
import DetailPanel
import Topology

/// "9 of 63" on a warning line: where a shape is among a scope's stops, said on the line of an issue whose source has a scope
/// that knows its candidates (`IssueScope.candidates`), so a rule's count and its warnings' lines both begin that rule's walk,
/// the line at its own shape. With that scope's walk running the place is the walk's (`IssueWalk.place(of:source:)`); with none it
/// is the shape's place among the candidates in board order, kept here.
extension IssueWalk {
    /// The line's extra button, after the issue's own: titled with the place and the count ("9 of 63", so a line is the same
    /// as another only when it says the same), a click beginning the scope's walk at this shape, or with that scope's walk
    /// running going to this shape's stop. Nil for an issue with no source, a source whose scope doesn't know its candidates
    /// (or is gone), the walk's current stop (the band says it), and a shape with no place.
    func lineAction(for issue: ValidationIssue, of shape: ShapeID) -> DetailStatusAction? {
        guard let source = issue.source, let scope = editor.registry.issueScope(for: source, in: editor), scope.candidates != nil else { return nil }
        // The walk's current stop, whichever scope's walk runs: the band says where it is, and a click would replace the walk.
        if isRunning, let row = currentRow, row.shape == shape, row.key.source == source { return nil }
        let place: IssuePlace
        if runs(scope, containing: issue) {
            guard let walkPlace = self.place(of: shape, source: source) else { return nil }
            place = walkPlace
        } else {
            guard let kept = linePlaces.place(of: shape, in: scope, editor: editor) else { return nil }
            place = kept
        }
        // The title is what makes the line draw again (a line is the same as another when its buttons' titles are), so the closure
        // a line keeps may be the one drawn before the walk began or ended: it decides when it is clicked, from the live walk.
        return DetailStatusAction(IssueWalkStyle.count(place)) { [weak self] in
            guard let self else { return }
            if runs(scope, containing: issue), self.place(of: shape, source: source) != nil {
                go(to: shape, source: source)
            } else {
                begin(scope, at: .shape(shape))
            }
        }
    }

    /// Whether the walk running is the walk of `scope`: the same scope, or (a rule reworded is the same walk under the old id,
    /// while the scope made now has the new one) one other than every issue's that includes the issue.
    private func runs(_ scope: IssueScope, containing issue: ValidationIssue) -> Bool {
        guard let running = self.scope else { return false }
        return running.id == scope.id || (running.id != IssueScope.all.id && running.includes(issue))
    }
}

/// The places of shapes among scopes' candidates, in board order, one list a scope. A list is kept against the candidates it was
/// made from (the set itself: a candidate that came or went makes it again) and let go by a commit that could change the order
/// the candidates stand in (`ChangeSet.mayHaveChangedBoardOrder`: one that added, removed or restacked shapes, reached another
/// board, replaced the document, or put a shape in another container, which changes the keys of what is inside it; a move of a
/// box and an edit change no board order). Status lines are read again on every document change, so a line asks this and finds its list kept.
@MainActor
final class IssueLinePlaces {
    private struct Places {
        let candidates: Set<ShapeID>
        let number: [ShapeID: Int]
    }

    private var kept: [AnyHashable: Places] = [:]

    func place(of shape: ShapeID, in scope: IssueScope, editor: CanvasEditor) -> IssuePlace? {
        guard let candidates = scope.candidates?(editor), candidates.contains(shape) else { return nil }
        if let places = kept[scope.id], places.candidates == candidates { return places.number[shape].map { IssuePlace(number: $0, total: places.number.count) } }
        guard let snapshot = editor.topology?.snapshot() else { return nil }
        let ordered = candidates.compactMap { id in snapshot.boardOrderKey(of: id).map { (id, $0) } }.sorted { $0.1 < $1.1 }
        let places = Places(candidates: candidates, number: Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($1.0, $0 + 1) }))
        kept[scope.id] = places
        return places.number[shape].map { IssuePlace(number: $0, total: places.number.count) }
    }

    /// Lets go of the lists a commit could have put in another order (`ChangeSet.mayHaveChangedBoardOrder`, the predicate the
    /// walk's rows go by too). `file` is the file as the commit leaves it.
    func commitDidSettle(_ changes: ChangeSet, in file: CanvasFile) {
        guard !kept.isEmpty, changes.mayHaveChangedBoardOrder(in: file) else { return }
        kept = [:]
    }

    func removeAll() { kept = [:] }
}
