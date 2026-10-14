import Canvas
import DrawScript

// What a run brings to shapes it did not write. A run's warnings say every issue of the shapes its statements
// changed; a statement can also break a shape it never names (a second relationship drawn at a note whose row
// allows one, a type restated so that a value an instance holds is wrong). So, once every write is done, the run
// asks its check which other shapes to look at (`DrawCheck.touched`, given what the transaction did so far), takes
// each one's issues as the run found the board and as it leaves it, by the same `check` it asks of its own shapes,
// and warns of each issue that is new. What a run mends it does not say. Draw knows no rule: with no check, or one
// that names no shapes, a run says what it said.

extension Drawing {
    /// The most shapes a run says it brought an issue to; the rest it counts.
    static let broughtLimit = 20

    /// The issues the run brought to shapes it did not write, as warnings: of each shape `DrawCheck.touched` names
    /// for the transaction's writes, and each the run changed with no statement of its own (what a delete let go of;
    /// never one it only moved), on any board of the file, every issue it has as the transaction leaves it and had
    /// not as the run found it (compared by message, field and level). `written` are the shapes the run's
    /// statements changed, with their lines: their issues are among the warnings already, so none is said here.
    /// `restated` are, of the shapes a statement wrote whether or not it changed them, the words of the `problems` their
    /// rows carry: what one still needs (an issue of that level) and its row says is not a warning as well; its other
    /// issues are said as any.
    /// A shape is named as a message names a board shape (its title, else its id, else, for an arrow or a pill that no script can name, its kind and where it is; and, on a board other
    /// than the run's, `on "Area"'s board`), in the order of
    /// those names, at most `broughtLimit` of them and then a count of the rest; the line is the statement's whose
    /// writes alone reach the shape, none where several statements' do.
    func brought(by transaction: Transaction, before: ShapeContext, after shapes: ShapeContext,
                 written: [(line: Int, id: ShapeID)], restated: [ShapeID: Set<String>]) -> [DrawWarning] {
        guard let check = registry.drawCheck, let touched = check.touched else { return [] }
        let pending = transaction.pending
        guard !pending.shapeIDs.isEmpty || !pending.elsewhere.isEmpty else { return [] }
        var looked = touched(pending, shapes)
        looked.formUnion(pending.added)
        looked.formUnion(pending.changed.subtracting(pending.moved))
        looked.formUnion(pending.elsewhere)
        for (_, id) in written { looked.remove(id) }
        guard !looked.isEmpty else { return [] }

        // Each board's shapes as the run found them and as it leaves them, made once: a shape on another board is
        // checked against its own board's.
        var found: [BoardID: (document: CanvasDocument, shapes: ShapeContext)] = [target.board: (target.document, before)]
        var left: [BoardID: (document: CanvasDocument, shapes: ShapeContext)] = [target.board: (transaction.document, shapes)]
        func asFound(_ board: BoardID) -> (document: CanvasDocument, shapes: ShapeContext) {
            if let kept = found[board] { return kept }
            let document = editor.contents(of: board)
            let made = (document, before.over(document))
            found[board] = made
            return made
        }
        func asLeft(_ board: BoardID) -> (document: CanvasDocument, shapes: ShapeContext) {
            if let kept = left[board] { return kept }
            let document = transaction.contents(of: board)
            let made = (document, shapes.over(document))
            left[board] = made
            return made
        }

        var broken: [(name: String, id: ShapeID, issues: [DrawIssue])] = []
        let file = editor.file
        for id in looked {
            guard let board = transaction.board(containing: id) else { continue }
            let now = asLeft(board)
            guard let record = now.document[id] else { continue }
            let has = check.check(record, now.shapes)
            guard !has.isEmpty else { continue }
            var had: [DrawIssue: Int] = [:]
            if let board = file.board(containing: id) {
                let was = asFound(board)
                if let record = was.document[id] { for issue in check.check(record, was.shapes) { had[issue, default: 0] += 1 } }
            }
            let new = has.filter { issue in
                guard let count = had[issue], count > 0 else { return !(issue.isIncomplete && restated[id]?.contains(issue.message) == true) }
                had[issue] = count - 1
                return false
            }
            if !new.isEmpty { broken.append((brokenName(record, on: board, shapes: now.shapes), id, new)) }
        }
        guard !broken.isEmpty else { return [] }
        broken.sort { ($0.name, $0.id.description) < ($1.name, $1.id.description) }
        let said = broken.prefix(Self.broughtLimit)

        // The statement that brought each: the one whose own writes reach the shape, when one does alone.
        var lines: [Int: Set<ShapeID>] = [:]
        for (line, id) in written { lines[line, default: []].insert(id) }
        for delete in deletes {
            var ids = Set(delete.connections.map(\.record.id)).union(delete.loose.map(\.id))
            if let shape = delete.shape {
                ids.insert(shape.id)
                // The shapes on the boards it owns go with it, by the same statement.
                if delete.boards > 0 { for board in file.subtree(ownedBy: [shape.id]) { ids.formUnion(file[board].shapes.map(\.id)) } }
            }
            lines[delete.statement.line, default: []].formUnion(ids)
        }
        let wanted = Set(said.map(\.id))
        var reaching: [ShapeID: Set<Int>] = [:]
        for (line, ids) in lines {
            let part = pending.restricted(to: ids)
            guard !part.shapeIDs.isEmpty || !part.elsewhere.isEmpty else { continue }
            for id in touched(part, shapes) where wanted.contains(id) { reaching[id, default: []].insert(line) }
        }

        var warnings: [DrawWarning] = []
        for shape in said {
            let by = reaching[shape.id] ?? []
            let line = by.count == 1 ? by.first : nil
            for issue in shape.issues {
                warnings.append(DrawWarning(line: line, shape.name, issue: issue))
            }
        }
        let more = broken.count - said.count
        if more > 0 {
            let ask = check.rest.map { ": ask \($0)" } ?? ""
            warnings.append(DrawWarning(line: nil, "and \(more) more \(more == 1 ? "shape now has" : "shapes now have") issues\(ask)"))
        }
        return warnings
    }

    /// A shape the run broke, named for a message: by its title; with none, by its id as a script writes it, which a later
    /// script can name it by (an arrow and a pill, that a script cannot name, by their kind and where they are on their own
    /// board); and, when that is not the run's board, which board.
    private func brokenName(_ record: AnyShapeRecord, on board: BoardID, shapes: ShapeContext) -> String {
        guard let title = Drawing.title(of: record, names: names, naming: naming, registry: registry) else {
            let place = registry.drawCanName(record.kind) ? ShapeName.id(record.id.description).written : Drawing.location(of: record, in: shapes)
            return board == target.board ? place : "\(place) on \(FileNames.named(board, in: editor, naming: naming))"
        }
        return quoted(title)
    }
}
