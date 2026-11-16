import CoreGraphics
import Geometry

// What a place takes in, and what a placement puts down there: two generic points the core asks and
// knows nothing more of. A place may refuse shapes coming into it from somewhere else (`Admission`,
// `registrar.admission`), as a read-only container does; and a shape a person places is handed, where
// it lands, to whatever would write it to suit that place (`PlacementFit`, `registrar.placementFit`).

/// Where a shape is on a board: directly in a container there, or on the board in no container (its top
/// level). A shape in a container in a container is in the inner one.
public enum ShapePlace: Hashable, Sendable {
    /// Directly in this container (a shape of a `ShapeContaining` kind).
    case container(ShapeID)
    /// On this board in no container.
    case board(BoardID)
}

/// Shapes about to come into places from somewhere else, as a plugin that judges what a place takes is
/// asked about them (`registrar.admission`): wherever a shape is put in a container, or on a board's top
/// level, from another place or new to the file (a drop, a placement settled, `setContainer`, a container
/// put down or resized over it, what `move(_:to:)` took onto another board put down there, an insert that
/// comes with a container). Judged by where it ends up from where it was when the transaction began:
/// never for a shape staying there, or only passing through a place on the way back to it, nor for one
/// a deletion lets go of (it stays, in the container above), nor for what has no box (an arrow: it's in
/// no container, and goes where what it's bound to goes). Asked only while some plugin judges.
@MainActor
public struct Admission {
    /// One shape coming into a place.
    public struct Arrival {
        /// The shape as it would be put: in the container it comes into (`container`), or in none.
        public let record: AnyShapeRecord
        /// The place it leaves: where it was when the transaction began (on whichever board it was then),
        /// not where the transaction has had it on the way; nil for a shape new to the file (`isNew`), and
        /// for one that comes back to it from where nothing says (`Transaction.treatAsMoved`: a cut's,
        /// pasted).
        public let from: ShapePlace?
        /// The place it comes into.
        public let to: ShapePlace
        /// What it holds on its board, at any depth, back to front, which comes with it: nothing new to
        /// it, since it stays in it, but into whatever it comes into. What a board it owns holds is read
        /// through `context.reading`, as the rest of the file is.
        public let carried: [ShapeID]
        /// Whether the shape is made here, new to the file (a placement, a paste's copy, a draw, a
        /// placement's shape put down earlier in the press that settles it), rather than moved (a drop, a
        /// move, a cut's shapes pasted back: `Transaction.treatAsMoved`).
        public let isNew: Bool
    }

    /// What a plugin says of the arrivals.
    public enum Verdict: Equatable, Sendable {
        /// They may come in.
        case admits
        /// None of them comes in: the change is refused as a read-only container's is (nothing changes,
        /// `refusedShapes`, `Settlement.refused`), and `shaking` shake (`EditorService.didRefuseChanges`):
        /// the shape whose rule refused, or, for a rule no shape holds, the arrivals themselves (empty
        /// says that). `saying`, if any, is what VoiceOver hears once the refusal is heard ("Backlog
        /// accepts only tasks."), never for a try (`isChange` false).
        case refuses(shaking: Set<ShapeID>, saying: String?)
    }

    /// Every shape coming in, in the order they're put down.
    public let arrivals: [Arrival]
    /// The board they're on, and the file, as the transaction leaves them before they come in (with its
    /// `reading`); the editor's committed file for a try.
    public let context: ShapeContext
    /// Whether a change is being made (a release, a command, a commit), or it's only tried (a drag's
    /// hint, `editor.admits`): a plugin says only real refusals.
    public let isChange: Bool
}

/// A shape a person just placed (a tool's click or drag, Insert, Return, a double-click, shapes placed
/// later), as a plugin that writes it to suit where it landed is handed it (`registrar.placementFit`):
/// in the placement's own step, once settling has said where it goes. Never for a paste, a duplicate, a
/// draw or any insert that isn't a placement.
@MainActor
public struct PlacementFit {
    /// The shape as placed, settled where it goes, or as the plugin before this one wrote it.
    public let record: AnyShapeRecord
    /// The place settling put it in.
    public let place: ShapePlace
    /// Whether the placement may make it another kind (`Placement.kindIsOpen`: a double-click's); a tool
    /// keeps its kind, and an answer of another kind is then ignored.
    public let kindIsOpen: Bool
    /// Its board, and the file, as the placement's transaction leaves them (with its `reading`).
    public let context: ShapeContext
}

extension Admission {
    /// Where a shape asked about comes from: made here, or moved from a place (nil where nothing says).
    enum Whence: Equatable {
        case new
        case moved(from: ShapePlace?)
    }

    /// The arrivals of `records` (on `document`, the board `board`) going to the places given: those
    /// with a box that come in from somewhere else. `whence` says where each comes from, handed the place
    /// it's in now: one moved is passed over going back where it came from (it never left), and one new
    /// here going into the container it's already in (it was put in with it, by an insert that asked).
    static func arrivals(of records: [(AnyShapeRecord, to: ShapePlace)], in document: CanvasDocument, on board: BoardID,
                         containingKinds kinds: Set<ShapeKind>, whence: (AnyShapeRecord, _ current: ShapePlace) -> Whence) -> [Arrival] {
        records.compactMap { record, place in
            guard record.box != nil else { return nil }
            let current = document.container(of: record, containingKinds: kinds).map(ShapePlace.container) ?? .board(board)
            let from: ShapePlace?, isNew: Bool
            switch whence(record, current) {
            case .new:
                if current == place, place != .board(board) { return nil }
                (from, isNew) = (nil, true)
            case .moved(let origin):
                if origin == place { return nil }
                (from, isNew) = (origin, false)
            }
            var put = record
            if case .container(let id) = place { put.container = id } else { put.container = nil }
            return Arrival(record: put, from: from, to: place,
                           carried: kinds.isEmpty ? [] : document.descendants(of: record.id, containingKinds: kinds), isNew: isNew)
        }
    }
}

extension Registry {
    /// Whether any installed plugin judges what a place takes (`registrar.admission`): without one,
    /// nothing is asked.
    var judgesAdmission: Bool { !admissionRules.isEmpty }

    /// Whether any installed plugin writes a placed shape to suit its place (`registrar.placementFit`).
    var fitsPlacements: Bool { !placementFits.isEmpty }

    /// Every judge's verdict on `arrivals`, in plugin order: the first refusal, its shapes the arrivals'
    /// where it names none; else `admits`. Nothing asked for no arrivals.
    func admission(of arrivals: [Admission.Arrival], in context: ShapeContext, isChange: Bool) -> Admission.Verdict {
        guard !arrivals.isEmpty else { return .admits }
        let ask = Admission(arrivals: arrivals, context: context, isChange: isChange)
        for judge in admissionRules {
            guard case .refuses(let shaking, let saying) = judge(ask) else { continue }
            return .refuses(shaking: shaking.isEmpty ? Set(arrivals.map(\.record.id)) : shaking, saying: saying)
        }
        return .admits
    }
}

extension Transaction {
    /// Where a shape on this board is: in the container the core goes by, or on the board directly.
    func place(of record: AnyShapeRecord) -> ShapePlace {
        document.container(of: record, containingKinds: registry.containingKinds).map(ShapePlace.container) ?? .board(board)
    }

    /// The file as it was when the transaction began, the one the editor made: what a transaction over
    /// another board, made from it, reads too, whatever it reads the rest of the file through.
    var fileBefore: FileAccess { began ?? file }

    /// Where a shape was when the transaction began: in a container on the board it was on then, or on
    /// that board directly; nil for one on no board of the file then.
    func origin(of id: ShapeID) -> ShapePlace? {
        let before = fileBefore
        guard let board = before.locate(id) else { return nil }
        let document = before.contents(board)
        guard let record = document[id] else { return nil }
        return document.container(of: record, containingKinds: registry.containingKinds).map(ShapePlace.container) ?? .board(board)
    }

    /// Where a shape on this board comes from as what judges what a place takes is told: new, inserted by
    /// this transaction and on no board of the file before it, or a placement's put down earlier in the
    /// press that settles it (`placing`); else moved, from where it was when the transaction began (nil
    /// for one that comes back to the file from where nothing says, `treatAsMoved`).
    func whence(of id: ShapeID) -> Admission.Whence {
        if placing.contains(id) { return .new }
        if movedIn.contains(id) { return .moved(from: origin(of: id)) }
        if changes.added.contains(id), fileBefore.locate(id) == nil { return .new }
        return .moved(from: origin(of: id))
    }

    /// Says that shapes this transaction puts in (`insert`) aren't made here but come back to the file from
    /// somewhere else, the shapes themselves under their ids (a cut's, pasted): what judges what a place
    /// takes is told they're moved (`Admission.Arrival.isNew` false; `from` nil, nothing saying where they
    /// were), so a place that takes in only what's made in it refuses them as it refuses a drop. Said
    /// before they're inserted, it holds for the insert's own ask too; and one no settle judges after its
    /// insert is judged where it is as the transaction ends (`judgeCrossings`), carrying what was put in it
    /// since, so a container inserted before what it holds is judged with it. Changes nothing else.
    public mutating func treatAsMoved(_ ids: some Sequence<ShapeID>) {
        guard registry.judgesAdmission else { return }
        movedIn.formUnion(ids)
    }

    /// What the plugins that judge what a place takes (`registrar.admission`) say of `records` (on this
    /// board, as they are) coming into the places given, only those with a box that come in from
    /// somewhere else asked about (`Admission.arrivals`, by `whence(of:)`): nil when they may come in (with
    /// no judge, nothing coming in, or while `enclose` holds the asks back, too); else the shapes the
    /// refusal names. With `noting`, those are noted in `refusedShapes`, so services hear them and an
    /// `editor.transactWhole` gives the whole up, and what it says is heard with them; without, the
    /// refusal is silent (a shape a resized container would take staying out, as a read-only one does).
    /// A shape moved here from another board (`move(_:to:)`) is judged by this, where it's put down, and
    /// not again as the transaction ends (`judgeCrossings`). Changes nothing else.
    mutating func refusal(of records: [(AnyShapeRecord, to: ShapePlace)], noting: Bool = true) -> Set<ShapeID>? {
        guard registry.judgesAdmission, !holdsAdmission else { return nil }
        if !crossing.isEmpty { crossing.subtract(records.map(\.0.id)) }
        let arrivals = Admission.arrivals(of: records, in: document, on: board, containingKinds: registry.containingKinds,
                                          whence: { record, _ in whence(of: record.id) })
        return refusal(of: arrivals, noting: noting)
    }

    /// `refusal(of:noting:)` of arrivals already worked out.
    mutating func refusal(of arrivals: [Admission.Arrival], noting: Bool = true) -> Set<ShapeID>? {
        guard registry.judgesAdmission, !holdsAdmission, !arrivals.isEmpty else { return nil }
        guard case .refuses(let shaking, let saying) = registry.admission(of: arrivals, in: shapes, isChange: true) else { return nil }
        if noting {
            refused.formUnion(shaking)
            if let saying { refusalNotes.append(saying) }
        }
        return shaking
    }

    /// Judges what this transaction moved onto other boards (`move(_:to:)`) and put down nowhere there
    /// since (`settle(_:on:)` judges what it puts down), and what an insert put back moved and no settle
    /// judged after (`add`'s, `crossing`): each where it is as the transaction ends, from
    /// where it was when it began, noted refused as `refusal(of:)` notes it. Whether any was refused: then
    /// the transaction commits nothing, as one whose body throws (`CanvasEditor.transact`), since what
    /// moved can't go back alone. Nothing asked with no judge, or nothing moved across.
    mutating func judgeCrossings() -> Bool {
        guard registry.judgesAdmission, !crossing.isEmpty else { return false }
        var byBoard: [BoardID: [ShapeID]] = [:]
        for id in crossing { if let board = board(containing: id) { byBoard[board, default: []].append(id) } }
        crossing = []
        var isRefused = false
        for board in byBoard.keys.sorted(by: { $0.description < $1.description }) {
            let ids = byBoard[board] ?? []
            if board == self.board {
                if judgeWhereTheyAre(ids) { isRefused = true }
            } else if var there = transaction(on: board) {
                if there.judgeWhereTheyAre(ids) { isRefused = true }
                takeRefusals(of: there)
            }
        }
        return isRefused
    }

    /// Shapes on this board judged as coming into the place each is in (`refusal(of:)`), back to front:
    /// whether they were refused.
    private mutating func judgeWhereTheyAre(_ ids: [ShapeID]) -> Bool {
        let records = ids.compactMap { document.index(of: $0) }.sorted().map { document.shapes[$0] }
        return refusal(of: records.map { ($0, to: place(of: $0)) }) != nil
    }

    /// Takes in what a transaction over another board, made from this one (`transaction(on:)`), refused and
    /// said, and what it left to judge of what moved across (`crossing`).
    mutating func takeRefusals(of there: Transaction) {
        refused.formUnion(there.refused)
        refusalNotes.append(contentsOf: there.refusalNotes)
        crossing = there.crossing
    }

    /// Hands each shape a placement just put down (`ids`, on this board) to the plugins that write it to
    /// suit where it landed (`registrar.placementFit`), in plugin order, each given the record as the one
    /// before wrote it: what comes back is written in place, under its id (its stacking key and
    /// container kept), another kind only when the placement's kind is open (`kindIsOpen`), turned
    /// (`turn(_:into:)`) with exactly the values the answer holds; an answer of another kind for a closed
    /// one is passed over. Whether any shape changed. Nothing asked with no such plugin.
    mutating func fit(_ ids: [ShapeID], kindIsOpen: Bool) -> Bool {
        guard registry.fitsPlacements else { return false }
        var changed = false
        for id in ids {
            guard let record = document[id], !record.isOpaque else { continue }
            var fitted = record
            // Asked over one context, let go before anything is written.
            do {
                let context = shapes, place = place(of: record)
                for fit in registry.placementFits {
                    guard let answer = fit(PlacementFit(record: fitted, place: place, kindIsOpen: kindIsOpen, context: context)) else { continue }
                    precondition(answer.id == id, "a placement's fit keeps the shape's id")
                    guard answer.kind == record.kind || kindIsOpen else { continue }
                    fitted = answer
                }
            }
            guard fitted != record else { continue }
            if fitted.kind != record.kind {
                guard turn(id, into: fitted) else { continue }
                update(id) { $0.added = fitted.added }
            } else {
                update(id) { $0 = fitted }
            }
            changed = true
        }
        return changed
    }

    /// Settles what a placement put down (`settle(_:)`), then fits it to where it landed (`fit`) and
    /// settles it again, since it may be laid out another size now: the nudges of both. A container among
    /// it takes in what it lands on only in the second, once it's fitted, so what it takes in comes into
    /// it as it will be (as `enclose` fits one before it holds anything); with nothing fitted and no
    /// container among it, there's no second. A refusal of either is the answer, the first changing
    /// nothing. With no plugin that fits, it's `settle(_:)`.
    mutating func settlePlaced(_ ids: [ShapeID], kindIsOpen: Bool) -> Settlement {
        guard registry.fitsPlacements else { return settle(ids) }
        let first = settle(ids, takingIn: false)
        guard case .settled(var nudges) = first else { return first }
        let fitted = fit(ids, kindIsOpen: kindIsOpen)
        guard fitted || ids.contains(where: { id in document[id].map { registry.isContainer($0) } ?? false }) else { return first }
        let again = settle(ids)
        guard case .settled(let more) = again else { return again }
        nudges.merge(more) { $0 + $1 }
        return .settled(nudges: nudges)
    }
}

extension CanvasEditor {
    /// Whether shapes on the board shown (`ids`) may come into `place` as they are, as a try: what the
    /// plugins that judge what a place takes say (`registrar.admission`, `isChange` false), only those
    /// with a box whose place changes asked about. What a drag's hint asks before it outlines a container.
    /// True with no judge, or nothing coming in. Nothing changes, and nothing is heard refused.
    public func admits(_ ids: [ShapeID], into place: ShapePlace) -> Bool { admits(ids, into: place, areNew: false) }

    /// `admits(_:into:)`, the shapes taken as new with `areNew` (a placement's, following the pointer).
    func admits(_ ids: [ShapeID], into place: ShapePlace, areNew: Bool) -> Bool {
        admits(ids, on: board, into: place, areNew: areNew)
    }

    /// `admits(_:into:)` of shapes on `source`, a board of the file shown or not, coming into a place on
    /// any board (a move onto another board's, a subboard's): what a table of contents' drop, `/move-to`
    /// and Move To ▸ ask before they offer a place, from the same arrivals `move(_:to:)` is judged by
    /// where it puts them down. Nothing changes, and nothing is heard refused.
    public func admits(_ ids: [ShapeID], on source: BoardID, into place: ShapePlace) -> Bool {
        admits(ids, on: source, into: place, areNew: false)
    }

    private func admits(_ ids: [ShapeID], on source: BoardID, into place: ShapePlace, areNew: Bool) -> Bool {
        guard registry.judgesAdmission else { return true }
        let document = contents(of: source)
        let arrivals = Admission.arrivals(of: ids.compactMap { document[$0] }.map { ($0, to: place) }, in: document, on: source,
                                          containingKinds: registry.containingKinds, whence: { _, current in areNew ? .new : .moved(from: current) })
        return registry.admission(of: arrivals, in: shapeContext, isChange: false) == .admits
    }
}
