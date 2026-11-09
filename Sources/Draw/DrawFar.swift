import Canvas
import CoreGraphics
import Topology

// Reaching a shape on another board: an arrow can't leave its board, so a far end is a pill on the board shown that stands
// for the far shape. Which shapes can be reached and what a pick of one takes (`FarVerdict`), and where the pill goes and how
// it is put down (`StandInRoute.placePill`), written once for whatever picks a far shape: Types' relationship rows, Connections'
// ⌘L picker, and later a move. `canvas draw` makes its pills in `DrawStandIns`, by the same route (`StandInRoute`), so a pick
// and a script leave the same pill in the same place. Nothing here names a kind: the stand-in kind, the word for what the far
// shape must be (`public`) and the making of it are the kind's (`standsIn`).

/// What a pick of a shape would take, asked of a shape anywhere in the file.
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

    /// What a list's line says of a shape a pick makes what a pill may stand for: `will be made public`.
    public static func willBeMade(_ needs: String) -> String { "will be made \(needs)" }
}

/// `farVerdict(of:)` for many shapes: the route, the file and what a board says of itself are read once, so a shape costs
/// its own record and not its board's path (made for a commit: it keeps the file as it was then).
@MainActor
public final class FarVerdicts {
    public let editor: CanvasEditor
    public let route: StandInRoute?
    private let file: CanvasFile
    private let makers: [ShapeKind]
    private let standIns: StandIns
    /// What a board gives each of its shapes: its contents, and whether a shape on it can be shown and written (nil: it
    /// cannot be shown). Made when first asked.
    private var boards: [BoardID: (contents: CanvasDocument, readOnly: Bool)?] = [:]

    public init(_ editor: CanvasEditor) {
        self.editor = editor
        route = StandInRoute(editor.registry)
        file = editor.file
        standIns = editor.registry.standIns
        makers = route == nil ? [] : standIns.makers
    }

    /// The kind of pill a shape on another board is stood for by, and whether the shape must be changed first.
    public func kind(for far: AnyShapeRecord) -> (kind: ShapeKind, fulfils: Bool)? { route?.kind(for: far, fulfilling: true, among: makers) }

    private func board(_ id: BoardID) -> (contents: CanvasDocument, readOnly: Bool)? {
        if let kept = boards[id] { return kept }
        let made = editor.canShow(id) ? (contents: file[id], readOnly: editor.isReadOnly(board: id)) : nil
        boards[id] = .some(made)
        return made
    }

    public func verdict(of shape: ShapeID) -> FarVerdict {
        guard let board = file.board(containing: shape) else { return .cannot }
        if board == editor.board { return .here }
        guard let held = self.board(board), let far = held.contents[shape] else { return .cannot }
        let readOnly = { self.editor.isReadOnly(far, in: held.contents) || held.readOnly }
        // With one kind that stands in, a shape that cannot be written is picked as it is or not at all: whether it could
        // be made what the kind needs is not asked (it would be a copy of the shape and the kind's rules, for the same no).
        if makers.count == 1, !standIns.admits(makers[0], far), readOnly() { return .cannot }
        guard let found = kind(for: far) else { return .cannot }
        if !found.fulfils { return .reads }
        if readOnly() { return .cannot }
        return .fulfils(needs: standIns.needs(found.kind) ?? "")
    }
}

extension CanvasEditor {
    /// What a pick of `shape` takes: an arrow straight to it (`here`), a pill that reads it as it is (`reads`), a pill
    /// after the shape is made what the kind needs (`fulfils`), or no pick (`cannot`).
    public func farVerdict(of shape: ShapeID) -> FarVerdict { FarVerdicts(self).verdict(of: shape) }
}

/// The pill a far shape is reached through, decided and not yet written: reused, or made and landed where a draw run puts one.
/// Written in a transaction (`claim`, then `put`).
@MainActor
public struct PlacedPill {
    /// The shape on another board.
    public let far: ShapeID
    /// The kind of pill that stands for it.
    public let kind: ShapeKind
    /// The far shape's own kind: what the arrow's end is read as (`drawConnection(standingFor:)`).
    public let farKind: ShapeKind
    /// Whether the far shape must be made what the kind needs first.
    public let fulfils: Bool
    /// The pill of this kind already on the board that is reused, if one is.
    public let reused: ShapeID?
    let made: AnyShapeRecord?
    let above: [ShapeID]

    /// What the pill's end stands for in the arrow, when the shape the pill is beside is at `place` of the edge.
    public func standingFor(whenNearIs place: EdgePlace) -> (from: [ShapeKind], to: [ShapeKind]) {
        place == .from ? ([], [farKind]) : ([farKind], [])
    }

    /// Makes the far shape what the kind needs, if it is not (it is changed only then), and asks for its admission again as the
    /// step leaves it: it may have gone private or away since the list was drawn. Throws `Transaction.Refused`.
    public func claim(in transaction: inout Transaction, registry: Registry) throws {
        if fulfils { transaction.update(inFile: far) { _ = registry.standIns.fulfil(kind, &$0) } }
        guard let farBoard = transaction.board(containing: far), let record = transaction.contents(of: farBoard)[far],
              registry.standIns.admits(kind, record) else { throw Transaction.Refused() }
    }

    /// The pill that ends the arrow: the one reused, else the new one put down, settled and above what it was landed past.
    /// Throws `Transaction.Refused`.
    public func put(in transaction: inout Transaction) throws -> ShapeID {
        if let reused { return reused }
        guard let made else { throw Transaction.Refused() }
        transaction.insert(made)
        guard transaction.document[made.id] != nil else { throw Transaction.Refused() }
        guard case .settled = transaction.settle([made.id]) else { throw Transaction.Refused() }
        for above in above {
            guard let mine = transaction.document.index(of: made.id), let theirs = transaction.document.index(of: above), theirs > mine else { continue }
            transaction.move(made.id, above: above)
        }
        return made.id
    }
}

extension StandInRoute {
    /// The pill that reaches `far`, a shape on another board, from `near`, a shape of the board shown that is `place` of the edge:
    /// the one `sharing` finds on the board, else a new one made for it (called `label`, told where it sits: `seat`) and landed
    /// where a draw run lands one (`spot`, `landing`), clear of `avoiding` too. Nil where no kind can stand for the shape, or
    /// nothing can be put down beside `near`. Nothing is written: the caller does it in a transaction (`PlacedPill`).
    ///
    /// `row`: a pill for that row of `far` (a row that stands alone: an endpoint), reused only where one stands for the same row,
    /// made by the kind's row maker (`standsIn(makesRow:)`); a pill for `far` where the kind makes none. A row that doesn't stand alone (a
    /// column) is reached through a pill for its shape, `row` nil, its name on the arrow's binding.
    ///
    /// `reading`: the board as a transaction in progress leaves it, where a pill is looked for to reuse (one an earlier pick of the
    /// same step put down); the editor's board as it is, without. A caller in such a step passes the boxes it has put down as `avoiding`.
    ///
    /// `planned`: the box `near` has in that step where it is a shape the step put down (a row taken out into a shape of its own),
    /// which the board doesn't show yet: the pill is landed against that box.
    ///
    /// `from`: the row of `near` the arrow is joined to (a column's key, an endpoint's call): the pill lands where its line from that
    /// row is clean (`Surroundings.landing(of:joinedFrom:of:)`: below `near`, then right, then left level with the row), and as
    /// draw lands one where no spot is. The row and `near` are measured on `reading` where the caller is in a step, so a row the
    /// step adds, and a shape it grows, count.
    public func placePill(standingFor far: ShapeID, row: PartID? = nil, label: String, beside near: ShapeID, from nearRow: PartID? = nil,
                          edgeIs place: EdgePlace, sharing: Sharing, avoiding: [CGRect] = [], reading: CanvasDocument? = nil,
                          planned: CGRect? = nil, verdicts: FarVerdicts, in editor: CanvasEditor) -> PlacedPill? {
        guard let record = editor.shape(inFile: far), let found = verdicts.kind(for: record) else { return nil }
        let standIns = editor.registry.standIns
        // A kind that makes no pill for a row stands for the row's shape, the row on the binding.
        let row = row.flatMap { standIns.makesRows(found.kind) ? $0 : nil }
        if let existing = existing(for: far, row: row, kind: found.kind, sharing: sharing, near: near, in: reading ?? editor.document) {
            return PlacedPill(far: far, kind: found.kind, farKind: record.kind, fulfils: found.fulfils, reused: existing, made: nil, above: [])
        }
        guard var made = row.map({ standIns.make(found.kind, standingFor: far, row: $0, label: label) }) ?? standIns.make(found.kind, standingFor: far, label: label)
        else { return nil }
        seat(&made, beside: near, in: editor)
        guard let size = made.box?.size, let surroundings = Surroundings(on: editor.board, moving: size, in: editor) else { return nil }
        // The row and `near` as the step leaves them (a column or an endpoint it adds is not on the board shown yet, and a table it
        // adds rows to is taller), not as the board shows them.
        let after = ShapeContext(document: reading ?? editor.document, registry: editor.registry, camera: surroundings.reading.shapes.camera)
        if let nearRow, let geometry = after.geometry(of: near), let line = geometry.parts.frame(nearRow)?.rect,
           let clean = surroundings.landing(of: size, joinedFrom: line, of: near, bounds: planned ?? geometry.bounds, avoiding: avoiding) {
            made.box = clean.rect
            return PlacedPill(far: far, kind: found.kind, farKind: record.kind, fulfils: found.fulfils, reused: nil, made: made, above: clean.above)
        }
        let spot = spot(beside: near, edgeIs: place, side: nil, in: surroundings.reading)
        guard let landing = planned.map({ landing(of: size, at: spot, against: $0, in: surroundings, avoiding: avoiding) })
                ?? landing(of: size, at: spot, in: surroundings, avoiding: avoiding) else { return nil }
        made.box = landing.rect
        return PlacedPill(far: far, kind: found.kind, farKind: record.kind, fulfils: found.fulfils, reused: nil, made: made, above: landing.above)
    }
}
