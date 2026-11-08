import Canvas
import CoreGraphics
import DrawScript
import Topology

// Arrows a move would leave across boards. An arrow can't leave its board, and a move onto another board lets go of every end
// that is bound across the edge (`Transaction.move(_:to:)`: tldraw leaves such an arrow unbound too). A move that keeps them
// reaches the far end through a pill, as `StandInRoute.placePill` does for a pick: an arrow goes where its start goes. If the
// start moves, so does the arrow, and its end is a pill for what stays, beside the start where it lands; if the end moves, the
// arrow stays and its end is a pill for what moved, beside the start where it is. On the board the arrow ends up on, a pill that
// is there for the same shape is reused, and the shape itself if it is there, rather than a new pill.
//
// The core does the moving: an arrow bound only to shapes that move rides along (`Transaction.rodeAlong`), so this only
// re-points ends, before and after the move, inside the one transaction. Nothing here names a kind: the connector kind, its ends
// and the pill kind are the registry's (`drawEdges`, `standsIn`).

/// The arrows a move of shapes from `source` to `destination` would leave across the edge, and what to write so they cross it
/// through pills instead: planned from the editor as it is (nothing is written), then written in the move's transaction
/// (`rebind(in:)` before `Transaction.move`, `Rebound.finish(in:)` right after it).
///
/// An arrow is one of the connector kind (`drawEdges`) bound at both ends, one end among the shapes that move (or are carried
/// with them) and one not. A read-only arrow, and an end no kind admits (a private shape: a move never makes a shape public), are
/// not planned: the move lets them go as it does without this. An end at a row keeps it: re-pointed to a pill for the row's shape,
/// the row stays on the binding (a key to a column, through a pill for its table), and a row that stands alone (an endpoint) gets
/// a pill of its own, as ⌘L's pick and `canvas draw` make them.
@MainActor
public struct CrossingArrows {
    /// One arrow's end, re-pointed.
    fileprivate struct Repoint {
        let arrow: ShapeID
        /// What the arrow's far end is bound to now: the shape that stays (or moves), or the pill that stands for it.
        let old: ShapeID
        /// What it is bound to before the move, on the arrow's board: a shape, or a pill (new, or one that only carries the arrow).
        let carrier: ShapeID
        /// What it is bound to after the move, when `carrier` is a stand-in only to make the arrow ride and goes: a shape or a
        /// pill the destination had already.
        let after: ShapeID?
    }

    private let source: BoardID
    private let destination: BoardID
    private let registry: Registry
    /// The pills to put in, each first on `source` with the arrows: whether it goes with them in the move (a pill for the
    /// destination, or a stand-in that only carries an arrow across), and whether it is a new pill, landed where it goes
    /// (`placed`), or such a stand-in.
    private let pills: [(record: AnyShapeRecord, moves: Bool, placed: Bool)]
    private let repoints: [Repoint]

    /// Plans what a move of `movers` (the shapes moved with what they hold) from `source` to `destination` writes, the shapes
    /// translated by `delta`; nil for none: nothing makes connections or stands in, no arrow crosses, or none can be kept.
    /// `label` is what a new pill says of the shape it stands for.
    public init?(moving movers: Set<ShapeID>, from source: BoardID, to destination: BoardID, by delta: CGPoint,
                 label: @escaping (AnyShapeRecord) -> String, in editor: CanvasEditor) {
        let registry = editor.registry
        guard source != destination, let route = StandInRoute(registry), let edging = registry.drawEdging,
              let connector = edging.kind(registry), editor.canShow(source), editor.canShow(destination) else { return nil }
        let sourceDoc = editor.contents(of: source)
        var crossing: [AnyShapeRecord] = [], ends: [ShapeID: (from: ShapeID, to: ShapeID)] = [:]
        for record in sourceDoc.shapes where record.kind == connector && !record.isOpaque {
            guard let found = edging.ends(record, registry), movers.contains(found.from) != movers.contains(found.to),
                  !editor.isReadOnly(record, in: sourceDoc) else { continue }
            crossing.append(record)
            ends[record.id] = found
        }
        guard !crossing.isEmpty else { return nil }
        var plan = Plan(editor: editor, route: route, movers: movers, source: source, destination: destination, delta: delta,
                        sourceDoc: sourceDoc, label: label)
        for record in crossing {
            guard let end = ends[record.id] else { continue }
            // The row the far end is at, which the end keeps wherever it is re-pointed (the binding's part rides `remappingReferences`).
            let row = record.boundParts(in: registry).first { $0.shape == end.to }?.part
            plan.add(record.id, from: end.from, to: end.to, row: row)
        }
        guard !plan.repoints.isEmpty else { return nil }
        self.source = source
        self.destination = destination
        self.registry = registry
        pills = plan.pills
        repoints = plan.repoints
    }

    /// What `rebind(in:)` did: the shapes the move takes along beside the ones asked for, and what is left to write after it.
    @MainActor
    public struct Rebound {
        /// New pills for the destination, and the stand-ins that make arrows ride: move these too (`Transaction.move`).
        public let along: Set<ShapeID>
        /// The new pills among them, which are where they land already: translate them with nothing, settle them with the shapes moved.
        public let placed: Set<ShapeID>
        fileprivate let later: [Repoint]
        fileprivate let carriers: Set<ShapeID>
        /// The new pills that stay on the origin (for an arrow whose end moves): put down by the in-or-out rule once the shapes
        /// have gone, so a container that moves cannot take one with it.
        fileprivate let staying: [ShapeID]
        fileprivate let source: BoardID
        fileprivate let destination: BoardID
        fileprivate let registry: Registry

        /// Right after the move: arrows that rode on a stand-in are bound to a pill or shape that was on the destination already,
        /// and the stand-ins are gone.
        public func finish(in transaction: inout Transaction) {
            for each in later {
                guard let after = each.after else { continue }
                CrossingArrows.repoint(each, from: each.carrier, to: after, on: destination, in: &transaction, registry: registry)
            }
            if !carriers.isEmpty { transaction.delete(carriers, on: destination) }
            if !staying.isEmpty { _ = transaction.settle(staying, on: source) }
        }
    }

    /// Before the move, in its transaction: the pills in (on the board shown, then on `source`, so each arrow and the pill it
    /// is bound to are on one board), and the arrows' ends re-pointed. Nothing else changes.
    public func rebind(in transaction: inout Transaction) -> Rebound {
        let shown = transaction.board
        var along: Set<ShapeID> = [], placed: Set<ShapeID> = [], failed: Set<ShapeID> = [], carriers: Set<ShapeID> = []
        var staying: [ShapeID] = []
        for pill in pills {
            let id = pill.record.id
            transaction.insert(pill.record)
            guard transaction.document[id] != nil else {
                failed.insert(id)
                continue
            }
            guard shown == source || transaction.move([id], to: source) else {
                transaction.delete([id])
                failed.insert(id)
                continue
            }
            if pill.moves {
                along.insert(id)
                if pill.placed { placed.insert(id) } else { carriers.insert(id) }
            } else {
                staying.append(id)
            }
        }
        var later: [Repoint] = []
        for each in repoints where !failed.contains(each.carrier) {
            Self.repoint(each, from: each.old, to: each.carrier, on: source, in: &transaction, registry: registry)
            if each.after != nil { later.append(each) }
        }
        return Rebound(along: along, placed: placed, later: later, carriers: carriers, staying: staying, source: source, destination: destination, registry: registry)
    }

    /// The arrow on `board` with the end bound to `old` bound to `new` instead (`remappingReferences`: the anchor stays), as the
    /// transaction has it.
    private static func repoint(_ each: Repoint, from old: ShapeID, to new: ShapeID, on board: BoardID, in transaction: inout Transaction, registry: Registry) {
        let document = transaction.contents(of: board)
        guard let record = document[each.arrow],
              let remapped = record.remappingReferences({ $0 == old ? new : $0 }, in: ShapeContext(document: document, registry: registry)) else { return }
        transaction.update(each.arrow, on: board) { $0 = remapped }
    }

    // MARK: Planning

    /// The decisions for every crossing arrow, in order, with what they share: the pills made for a shape serve every arrow that
    /// needs one, and each lands past the last beside the same start.
    @MainActor
    private struct Plan {
        let editor: CanvasEditor
        let route: StandInRoute
        let movers: Set<ShapeID>
        let source: BoardID
        let destination: BoardID
        let delta: CGPoint
        let sourceDoc: CanvasDocument
        let destDoc: CanvasDocument
        let label: (AnyShapeRecord) -> String
        let kinds: Set<ShapeKind>
        let makers: [ShapeKind]
        let canInsert: Bool

        var pills: [(record: AnyShapeRecord, moves: Bool, placed: Bool)] = []
        var repoints: [Repoint] = []
        /// The pills this plan puts on the destination (`new`) and keeps on the origin (`away`), by the shape (and the row, for a pill
        /// for a row) each stands for.
        private var new: [PartAddress: ShapeID] = [:], away: [PartAddress: ShapeID] = [:], carriers: [ShapeID: ShapeID] = [:]
        /// The last pill planned beside each start: the next goes past it.
        private var last: [ShapeID: CGRect] = [:]
        /// The boxes of the pills planned on each board: what the next on that board keeps clear of.
        private var planned: [BoardID: [CGRect]] = [:]
        private var sourceIndex: StandInRoute.Index?
        private var destPills: [ShapeID: [ShapeID]]?
        private var destContainers: [(ShapeID, CGRect)]?
        /// The container each start lands in on the destination (nil: none), by start.
        private var finalContainers: [ShapeID: ShapeID?] = [:]
        private var sourceSide: Surroundings?
        private var destSide: Surroundings?
        private var movedBoxes: [CGRect]?

        init(editor: CanvasEditor, route: StandInRoute, movers: Set<ShapeID>, source: BoardID, destination: BoardID, delta: CGPoint,
             sourceDoc: CanvasDocument, label: @escaping (AnyShapeRecord) -> String) {
            self.editor = editor
            self.route = route
            self.movers = movers
            self.source = source
            self.destination = destination
            self.delta = delta
            self.sourceDoc = sourceDoc
            destDoc = editor.contents(of: destination)
            self.label = label
            kinds = editor.registry.containingKinds
            makers = editor.registry.standIns.makers
            // A pill goes in on the board shown, and moves to the arrow's board from there.
            canInsert = !editor.isReadOnly(board: editor.board)
        }

        /// Plans one arrow: the arrow goes where its start goes, so the end that is not the start is the one re-pointed. `part` is the
        /// row the end is at, if it is at one: kept on the binding wherever the end goes, and a pill of its own when it stands alone.
        mutating func add(_ arrow: ShapeID, from start: ShapeID, to end: ShapeID, row part: PartID?) {
            let startMoves = movers.contains(start)
            // An end that is a pill is the shape it stands for.
            let subject = route.stoodFor(end, in: sourceDoc)?.shape ?? end
            guard subject != start, let far = editor.shape(inFile: subject), let board = editor.file.board(containing: subject) else { return }
            let kind = route.kind(for: far, fulfilling: false, among: makers)?.kind
            // A row that stands alone (an endpoint) is stood for by a pill of its own; any other (a column) by its shape's.
            let named = part.flatMap { part in editor.registry.parts(of: far)?.first { $0.id == part } }
            let row = named?.standsAlone == true && kind.map(editor.registry.standIns.makesRows) == true ? named : nil
            let key = PartAddress(subject, part: row?.id)
            func repoint(to carrier: ShapeID, after: ShapeID? = nil) { repoints.append(Repoint(arrow: arrow, old: end, carrier: carrier, after: after)) }
            if startMoves {
                // On the destination: the shape if it is there, a pill for it already there, else a new one beside the start.
                if movers.contains(subject) || board == destination {
                    if let carrier = carrier(for: subject, standing: far, in: kind) { repoint(to: carrier, after: subject) }
                    return
                }
                guard let kind else { return }
                let holder = finalContainer(of: start)
                if let have = destinationPills(for: subject).first(where: {
                    destDoc[$0]?.kind == kind && route.row(of: $0, in: destDoc) == row?.id && containerOf($0) == holder
                }) {
                    if let carrier = carrier(for: subject, standing: far, in: kind) { repoint(to: carrier, after: have) }
                } else if let made = new[key] {
                    repoint(to: made)
                } else if let made = newPill(for: far, row: row, kind: kind, beside: start, startMoves: true, container: holder) {
                    new[key] = made
                    repoint(to: made)
                }
            } else {
                // On the origin, where the arrow stays: the shape if it is still there, a pill there already, else a new one.
                if board == source && !movers.contains(subject) {
                    repoint(to: subject)
                    return
                }
                guard let kind else { return }
                let holder = kinds.isEmpty ? nil : sourceDoc.container(of: start, containingKinds: kinds)
                if let have = route.existing(for: subject, row: row?.id, kind: kind, sharing: .any, near: start, in: sourceDoc, excluding: movers,
                                             index: index()) {
                    repoint(to: have)
                } else if let made = away[key] {
                    repoint(to: made)
                } else if let made = newPill(for: far, row: row, kind: kind, beside: start, startMoves: false, container: holder) {
                    away[key] = made
                    repoint(to: made)
                }
            }
        }

        private func containerOf(_ pill: ShapeID) -> ShapeID? {
            kinds.isEmpty ? nil : destDoc.container(of: pill, containingKinds: kinds)
        }

        private mutating func index() -> StandInRoute.Index {
            if let sourceIndex { return sourceIndex }
            let made = route.index(of: sourceDoc)
            sourceIndex = made
            return made
        }

        private mutating func destinationPills(for subject: ShapeID) -> [ShapeID] {
            if destPills == nil { destPills = route.pills(in: destDoc) }
            return destPills?[subject] ?? []
        }

        /// A pill that only carries an arrow across, standing for `subject`, in the destination's coordinates nowhere in particular:
        /// it is gone as the move is done. One for each shape the arrows reach.
        private mutating func carrier(for subject: ShapeID, standing far: AnyShapeRecord, in kind: ShapeKind?) -> ShapeID? {
            if let kept = carriers[subject] { return kept }
            guard canInsert, let maker = kind ?? makers.first, let made = editor.registry.standIns.make(maker, standingFor: subject, label: "") else { return nil }
            carriers[subject] = made.id
            pills.append((made, true, false))
            return made.id
        }

        /// Where the start will be container-wise once it lands: its own container if that moves with it, else the container of the
        /// destination its middle lands in.
        private mutating func finalContainer(of start: ShapeID) -> ShapeID? {
            guard !kinds.isEmpty else { return nil }
            if let held = sourceDoc[start]?.container, movers.contains(held) { return held }
            if let known = finalContainers[start] { return known }
            guard let box = finalBox(of: start) else { return nil }
            let middle = CGPoint(x: box.midX, y: box.midY)
            var found: ShapeID?
            for (id, frame) in destinationContainers() where frame.contains(middle) { found = id }
            finalContainers[start] = .some(found)
            return found
        }

        /// The destination's containers and their frames, in order, read once however many arrows ask.
        private mutating func destinationContainers() -> [(ShapeID, CGRect)] {
            if let destContainers { return destContainers }
            let made = destDoc.shapes.compactMap { record -> (ShapeID, CGRect)? in
                guard editor.registry.isContainer(record), let frame = editor.frame(inFile: record.id) ?? record.box else { return nil }
                return (record.id, frame)
            }
            destContainers = made
            return made
        }

        private func isReadOnly(_ id: ShapeID, in document: CanvasDocument) -> Bool {
            document[id].map { editor.isReadOnly($0, in: document) } ?? false
        }

        /// Where a shape that moves will be, to the frame it is laid out in.
        private func finalBox(of shape: ShapeID) -> CGRect? {
            (editor.frame(inFile: shape) ?? sourceDoc[shape]?.box).map { $0.offsetBy(dx: delta.x, dy: delta.y) }
        }

        /// A new pill for `far`, landed beside `start` (the start of the arrow, where it lands if it moves), clear of the shapes
        /// moved and of the pills planned already; its id, or nil where it can't be put down (no room, or a read-only frame it
        /// would sit in).
        private mutating func newPill(for far: AnyShapeRecord, row: PartName? = nil, kind: ShapeKind, beside start: ShapeID, startMoves: Bool,
                                      container: ShapeID?) -> ShapeID? {
            let standIns = editor.registry.standIns
            guard canInsert, var made = row.map({ standIns.make(kind, standingFor: far.id, row: $0.id, label: $0.name) })
                    ?? standIns.make(kind, standingFor: far.id, label: label(far)) else { return nil }
            let board = startMoves ? destination : source
            guard let surroundings = surroundings(on: board) else { return nil }
            editor.registry.standIns.seat(&made, at: .file(container: container, board: board), in: surroundings.reading.shapes)
            guard let size = made.box?.size else { return nil }
            let nearBox = startMoves ? finalBox(of: start) : nil
            let spot: StandInSpot, against: CGRect?
            if let previous = last[start] {
                spot = StandInSpot(near: start, direction: .right, after: start, step: LayoutProblem.impliedListStep, level: .left)
                against = previous
            } else if startMoves {
                guard let nearBox else { return nil }
                spot = StandInSpot(near: start, direction: .right, step: GapName.normal.value)
                against = nearBox
            } else {
                spot = route.spot(beside: start, edgeIs: .from, side: nil, in: surroundings.reading, staying: { !movers.contains($0) }, index: index())
                against = nil
            }
            var avoiding = planned[board] ?? []
            if startMoves { avoiding += movedFrames() }
            let landing = against.map { route.landing(of: size, at: spot, against: $0, in: surroundings, avoiding: avoiding) }
                ?? route.landing(of: size, at: spot, in: surroundings, avoiding: avoiding)
            // A pill that would sit in a frame nobody may change goes unmade, rather than stopping the move.
            guard let landing, !landing.above.contains(where: { isReadOnly($0, in: startMoves ? destDoc : sourceDoc) }) else { return nil }
            made.box = landing.rect
            planned[board, default: []].append(landing.rect)
            last[start] = landing.rect
            pills.append((made, startMoves, true))
            return made.id
        }

        /// The boxes of what moves, where they will be: what a pill landing beside one of them keeps clear of.
        private mutating func movedFrames() -> [CGRect] {
            if let movedBoxes { return movedBoxes }
            let boxes = movers.compactMap { finalBox(of: $0) }
            movedBoxes = boxes
            return boxes
        }

        /// The board read once, with the moving shapes left out of the origin's.
        private mutating func surroundings(on board: BoardID) -> Surroundings? {
            if board == destination, let destSide { return destSide }
            if board == source, let sourceSide { return sourceSide }
            let size = CGSize(width: 1, height: 1)
            let made = board == source
                ? Surroundings(on: board, moving: size, carrying: Array(movers.filter { sourceDoc[$0] != nil }), held: [], in: editor)
                : Surroundings(on: board, moving: size, in: editor)
            if board == source { sourceSide = made } else { destSide = made }
            return made
        }
    }
}
