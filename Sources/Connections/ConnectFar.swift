import Canvas
import CoreGraphics
import Draw
import Mentions

// A connection put down on the board shown whose other end is on another board: brought back through a pill there for that end,
// as Connect reaches a far shape (`placePill`), in the caller's step. What rows pasted on another board than the one they were
// cut from need for their arrows (LineRows' landing, which can't place a pill: Connections can, through Draw), as a move's arrows
// are kept (`CrossingArrows`) and keys reach a table across boards.

extension CanvasEditor {
    /// `connection`, about to be inserted on the board shown in `transaction`, with each end bound to a shape that isn't on that
    /// board bound instead to a pill for it there: the board's pill for that shape (or for that row, for a row that stands alone: an
    /// endpoint's own pill) where one is, else a new one landed beside `near` (a shape of the board shown, or one `transaction` put down, which the connection's other
    /// end is at), put down in `transaction`; a row of a shape that doesn't stand alone stays on the binding, through a pill for its
    /// shape (a key to a column of a table on another board). `avoiding`: the boxes of pills put down earlier in the step, which a new
    /// one keeps clear of; it gains the new pill's. Nil where an end can't be reached as it is (a pill can't stand for it without
    /// changing it: a private shape, which a paste never makes public) or the connection isn't one the connector draws.
    public func reachingFarEnds(of connection: AnyShapeRecord, beside near: ShapeID, avoiding: inout [CGRect],
                                in transaction: inout Transaction) -> AnyShapeRecord? {
        // `near` is a shape of the board, or one the step put down (a row taken out into a shape of its own): the pill lands against its box.
        let planned = document[near] == nil ? transaction.document[near]?.box : nil
        guard board == transaction.board, document[near] != nil || planned != nil, let ends = registry.connectionEnds(of: connection) else { return nil }
        var record = connection
        let bound = connection.boundParts(in: registry)
        for (end, place) in [(ends.from, EdgePlace.to), (ends.to, EdgePlace.from)] where transaction.document[end] == nil {
            let verdicts = FarVerdicts(self)
            guard let route = verdicts.route else { return nil }
            // An end bound to a pill on another board (a key to a table there through its pill) is read as what the pill stands for,
            // the row on its binding kept (or the row the pill stands for): a pill never stands for a pill (review R10).
            var far = end, row = bound.first { $0.shape == end }?.part, pillRow: PartID?
            if let board = file.board(containing: end), board != transaction.board, let stood = route.stoodFor(end, in: file[board]) {
                far = stood.shape
                pillRow = route.row(of: end, in: file[board])
                row = row ?? pillRow
            }
            // What it stands for is on this board: the end goes straight to it, on the row the pill stood for if it stood for one.
            if far != end, transaction.document[far] != nil {
                guard var direct = record.remappingReferences({ $0 == end ? far : $0 }, in: transaction.shapes) else { return nil }
                if let pillRow { direct = direct.movingParts(in: registry, { $0 == PartAddress(far) ? PartAddress(far, part: pillRow) : $0 }) ?? direct }
                record = direct
                continue
            }
            guard verdicts.verdict(of: far) == .reads, let farRecord = shape(inFile: far) else { return nil }
            let name = row.flatMap { part in registry.parts(of: farRecord)?.first { $0.id == part } }
            let label = name?.name ?? registry.mentionAppearance(of: farRecord)?.label ?? ""
            guard let placed = route.placePill(standingFor: far, row: name?.standsAlone == true ? row : nil, onBinding: name?.standsAlone == true ? nil : row,
                                               label: label, beside: near,
                                               from: bound.first { $0.shape == near }?.part, edgeIs: place, sharing: .any, avoiding: avoiding, reading: transaction.document,
                                               planned: planned, verdicts: verdicts, in: self),
                  (try? placed.claim(in: &transaction, registry: registry)) != nil, let pill = try? placed.put(in: &transaction) else { return nil }
            guard let remapped = record.remappingReferences({ $0 == end ? pill : $0 }, in: transaction.shapes) else { return nil }
            if let box = transaction.document[pill]?.box, document[pill] == nil { avoiding.append(box) }
            record = remapped
        }
        return record
    }
}
