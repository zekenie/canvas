import Canvas
import CoreGraphics
import Draw
import Mentions
import Topology

// Relating a note to another from a row, near and far: the writers of a relationship (`relate`, `unrelate`) and the
// verdict on a note a pick would reach (`farVerdict`). A relationship reaches another board by ending on a pill that
// stands for the far note, so a far pick is one transaction: the far note made what the pill's kind may stand for if it
// is not (the kind says how), the pill reused or put down where `canvas draw` puts one (`StandInRoute`), and the
// arrow. Types learns no pill kind and no publicness: the kind, the word for what the note must be and the
// making of it are the stand-in kind's.

extension TypesStyle {
    /// The step a pick in a row takes.
    public static let addRelationship = "Add Relationship"
    /// The step a delete in a row takes.
    public static let removeRelationship = "Remove Relationship"
    /// What a list's line says of a note a pick makes what a pill may stand for: `will be made public`.
    public static func willBeMade(_ needs: String) -> String { "will be made \(needs)" }
}

/// What a pick of a note would take, asked of a note anywhere in the file.
public enum FarVerdict: Sendable, Equatable {
    /// On the board shown: an arrow straight to it.
    case here
    /// On another board and a pill can stand for it as it is: nothing is written on its board.
    case reads
    /// On another board, and a pill can stand for it once it is made what the kind needs (`needs`: `public`): the
    /// pick makes it so in the same step, and the list says so first.
    case fulfils(needs: String)
    /// Not to be picked: its board is read-only or it is locked and would have to be changed, no kind can stand for
    /// it, or it is on no board.
    case cannot
}

/// `farVerdict(of:)` for many notes: the route, the file and what a board says of itself are read once, so a note costs
/// its own record and not its board's path (made for a commit: it keeps the file as it was then).
@MainActor
final class FarVerdicts {
    let editor: CanvasEditor
    let route: StandInRoute?
    private let file: CanvasFile
    private let makers: [ShapeKind]
    private let standIns: StandIns
    /// What a board gives each of its notes: its contents, and whether a note on it can be shown and written (nil: it
    /// cannot be shown). Made when first asked.
    private var boards: [BoardID: (contents: CanvasDocument, readOnly: Bool)?] = [:]

    init(_ editor: CanvasEditor) {
        self.editor = editor
        route = StandInRoute(editor.registry)
        file = editor.file
        standIns = editor.registry.standIns
        makers = route == nil ? [] : standIns.makers
    }

    /// The kind of pill a note on another board is stood for by, and whether the note must be changed first.
    func kind(for far: AnyShapeRecord) -> (kind: ShapeKind, fulfils: Bool)? { route?.kind(for: far, fulfilling: true, among: makers) }

    private func board(_ id: BoardID) -> (contents: CanvasDocument, readOnly: Bool)? {
        if let kept = boards[id] { return kept }
        let made = editor.canShow(id) ? (contents: file[id], readOnly: editor.isReadOnly(board: id)) : nil
        boards[id] = .some(made)
        return made
    }

    func verdict(of shape: ShapeID) -> FarVerdict {
        guard let board = file.board(containing: shape) else { return .cannot }
        if board == editor.board { return .here }
        guard let held = self.board(board), let far = held.contents[shape] else { return .cannot }
        let readOnly = { self.editor.isReadOnly(far, in: held.contents) || held.readOnly }
        // With one kind that stands in, a note that cannot be written is picked as it is or not at all: whether it could
        // be made what the kind needs is not asked (it would be a copy of the note and the kind's rules, for the same no).
        if makers.count == 1, !standIns.admits(makers[0], far), readOnly() { return .cannot }
        guard let found = kind(for: far) else { return .cannot }
        if !found.fulfils { return .reads }
        if readOnly() { return .cannot }
        return .fulfils(needs: standIns.needs(found.kind) ?? "")
    }
}

extension CanvasEditor {
    /// What a pick of `shape` takes: an arrow straight to it (`here`), a pill that reads it as it is (`reads`), a pill
    /// after the note is made what the kind needs (`fulfils`), or no pick (`cannot`).
    public func farVerdict(of shape: ShapeID) -> FarVerdict { FarVerdicts(self).verdict(of: shape) }
}

/// The step a relation writer takes.
public enum RelationStep: @unchecked Sendable {
    /// Its own: a plain step, named for what was done (two picks in a row are two steps).
    case own
    /// Inside an open card: joined to the card's held step, named and held by the core. The key is the card's `id`.
    case card(key: AnyHashable)

    func name(_ own: String) -> String? {
        if case .own = self { own } else { nil }
    }

    var key: AnyHashable? {
        if case .card(let key) = self { key } else { nil }
    }
}

extension CanvasEditor {
    /// Relates `note` to `other` in `row`: an arrow of the row's relationship type between them, in one step
    /// ("Add Relationship"), made as `canvas draw` makes an edge (`registry.drawConnection`) and given the type. The
    /// arrow runs by the row's side: from `note` where the row is on the `from` side, else into it, whichever note
    /// the person was on. Nothing is written to either note.
    ///
    /// A note on another board is related through a pill on the board shown that stands for it: the pill this note
    /// already has an arrow into for it is reused, else one is put down where a draw run puts it, and the far note is
    /// made what the pill's kind needs in the same step (`farVerdict`). Admission is asked again as the step leaves
    /// the far note, so a note made private since the list was drawn is refused.
    ///
    /// A row that allows only one relationship (its rule: `row.rule.onlyOne`) is replaced by the pick: the relationship the note
    /// holds in the row goes in the same step (its values with it, and the pill it empties), whichever board it is on, and a
    /// locked one refuses the whole pick. A row that does not has the pick added.
    ///
    /// Returns the arrow; nil, with nothing changed and no step, when nothing makes connections, the board or the
    /// note is read-only (the core refuses it, and the note shakes), the note is not on the board shown, the other is
    /// the note itself or cannot be picked, the row's type is no relationship type, or the step was refused.
    @discardableResult
    public func relate(_ note: ShapeID, to other: ShapeID, in row: RelationshipRow, step: RelationStep = .own) -> ShapeID? {
        let type = row.key.type
        guard registry.drawsConnections, note != other, file.board(containing: note) == board, document[note] != nil,
              types?.graph.relationshipTypes.contains(type) == true else {
            if document[note] != nil { refuseChanges(to: [note]) }
            return nil
        }
        if isReadOnly(note) || isBoardReadOnly {
            refuseChanges(to: [note])
            return nil
        }
        let verdicts = FarVerdicts(self)
        let from = (relationships?.graph.drawSide(of: row, picking: other) ?? row.drawSide) == .from
        var pill: (record: AnyShapeRecord, above: [ShapeID])?
        var reused: ShapeID?
        var kind: ShapeKind?
        var fulfil = false
        var standingFor: (from: [ShapeKind], to: [ShapeKind]) = ([], [])
        switch verdicts.verdict(of: other) {
        case .cannot:
            refuseChanges(to: [note])
            return nil
        case .here:
            break
        case .reads, .fulfils:
            guard let route = verdicts.route, let far = shape(inFile: other), let found = verdicts.kind(for: far) else {
                refuseChanges(to: [note])
                return nil
            }
            kind = found.kind
            fulfil = found.fulfils
            standingFor = from ? ([], [far.kind]) : ([far.kind], [])
            if let existing = route.existing(for: other, kind: found.kind, sharing: .host(note), near: note, in: document) {
                reused = existing
            } else {
                // The pill the far note is stood for by, made as a draw run makes it (saying where the note is, when another shape
                // has its title), and where a draw run puts it.
                let label = registry.mentionAppearance(of: far)?.label ?? ""
                guard var made = registry.standIns.make(found.kind, standingFor: other, label: label) else {
                    refuseChanges(to: [note])
                    return nil
                }
                route.seat(&made, beside: note, in: self)
                guard let size = made.box?.size, let surroundings = Surroundings(on: board, moving: size, in: self) else {
                    refuseChanges(to: [note])
                    return nil
                }
                let spot = route.spot(beside: note, edgeIs: from ? .from : .to, side: nil, in: surroundings.reading)
                guard let landing = route.landing(of: size, at: spot, in: surroundings) else {
                    refuseChanges(to: [note])
                    return nil
                }
                made.box = landing.rect
                pill = (made, landing.above)
            }
        }
        // A row that allows one relationship is replaced by a pick: the one it holds goes in the same step, with the pill it empties
        // (a locked one refuses the whole pick). A second arrow drawn by hand is never taken away; the note carries the issue.
        let replaced = row.rule.onlyOne ? (relationships?.relations(of: note, in: row).map(\.arrow) ?? []) : []
        // Whole or not at all (`transactWhole`): any refusal, the core's or the pick's own, commits nothing, leaves no
        // step, and shakes the note whose row asked.
        return transactWhole(step.name(TypesStyle.addRelationship), coalescing: step.key, shaking: [note]) { transaction in
            if !replaced.isEmpty { try Self.unrelateBody(&transaction, replaced, registry: registry, keeping: reused.map { [$0] } ?? []) }
            var end = other
            if let kind {
                if fulfil { transaction.update(inFile: other) { _ = registry.standIns.fulfil(kind, &$0) } }
                // Asked again as the step leaves the far note: it may have gone private or away since the list was drawn.
                guard let farBoard = transaction.board(containing: other), let record = transaction.contents(of: farBoard)[other],
                      registry.standIns.admits(kind, record) else { throw Transaction.Refused() }
                if let reused {
                    end = reused
                } else if let pill {
                    transaction.insert(pill.record)
                    guard transaction.document[pill.record.id] != nil else { throw Transaction.Refused() }
                    guard case .settled = transaction.settle([pill.record.id]) else { throw Transaction.Refused() }
                    for above in pill.above {
                        guard let mine = transaction.document.index(of: pill.record.id), let theirs = transaction.document.index(of: above), theirs > mine else { continue }
                        transaction.move(pill.record.id, above: above)
                    }
                    end = pill.record.id
                }
            }
            let (start, finish) = from ? (note, end) : (end, note)
            guard var arrow = registry.drawConnection(from: start, to: finish, in: transaction.shapes, standingFor: standingFor),
                  registry.relates(arrow.kind), registry.isTypeable(arrow.kind) else { throw Transaction.Refused() }
            arrow[IsAProperty.self] = [TypeLink(type)]
            transaction.insert(arrow)
            guard transaction.document[arrow.id] != nil else { throw Transaction.Refused() }
            return arrow.id
        }
    }

    /// Takes these relationships away, in one step ("Remove Relationship"): each arrow with its values and the pills the
    /// delete leaves with no arrow, on whichever board they are, the board shown or another, as one step on the board
    /// shown (a far arrow is deleted without showing its board, and Undo returns both boards). A pill another arrow
    /// still runs to stays. True once they are gone.
    ///
    /// A locked or read-only arrow or pill, or a board that cannot change, refuses the whole delete: nothing is
    /// deleted, no step is made, and `shaking` (the note whose row asked) shakes; with none named, nothing shakes.
    @discardableResult
    public func unrelate(_ arrows: [ShapeID], shaking note: ShapeID? = nil, step: RelationStep = .own) -> Bool {
        let present = arrows.filter { shape(inFile: $0) != nil }
        guard !present.isEmpty else {
            if let note { refuseChanges(to: [note]) }
            return false
        }
        let registry = registry
        let removed: Void? = transactWhole(step.name(TypesStyle.removeRelationship), coalescing: step.key, shaking: note.map { [$0] } ?? []) { transaction in
            try Self.unrelateBody(&transaction, present, registry: registry)
        }
        return removed != nil
    }

    /// The delete itself, for a writer that has a transaction of its own: the arrows grouped by the board they are on,
    /// the pills each board's delete leaves with no arrow added, and the core's delete across boards. Throws
    /// (`Transaction.Refused`) when the core refuses any shape, so the caller's `transactWhole` commits nothing.
    static func unrelateBody(_ transaction: inout Transaction, _ arrows: [ShapeID], registry: Registry, keeping kept: Set<ShapeID> = []) throws {
        var byBoard: [BoardID: Set<ShapeID>] = [:]
        for arrow in arrows { if let board = transaction.board(containing: arrow) { byBoard[board, default: []].insert(arrow) } }
        var doomed = Set(arrows)
        if let route = StandInRoute(registry) {
            // A pill the caller is about to draw an arrow to stays, though the arrows deleted were its last.
            for (board, ids) in byBoard { doomed.formUnion(route.emptied(by: ids, in: transaction.contents(of: board)).filter { !kept.contains($0) }) }
        }
        transaction.delete(inFile: doomed)
        guard transaction.refusedShapes.isEmpty else { throw Transaction.Refused() }
    }
}
