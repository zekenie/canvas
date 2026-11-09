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
        plan.crossing = Set(crossing.map(\.id))
        for record in crossing {
            guard let end = ends[record.id] else { continue }
            // The row the far end is at, which the end keeps wherever it is re-pointed (the binding's part rides `remappingReferences`),
            // and the row the start is at, which the pill's line leaves from.
            let bound = record.boundParts(in: registry)
            let row = bound.first { $0.shape == end.to }?.part
            plan.add(record.id, from: end.from, to: end.to, row: row, startRow: bound.first { $0.shape == end.from }?.part)
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

    /// What a crossing arrow's line is, for where its pill goes: the arrow, the row its start is at (if one), and whether it is a
    /// line between rows (a key: the far row on the binding of a pill for its shape).
    fileprivate struct Line {
        let arrow: ShapeID
        let startRow: PartID?
        let level: Bool
    }

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
        /// The arrows this plan re-points: their labels are not where they are now once they are.
        var crossing: Set<ShapeID> = []
        /// The pills this plan puts on the destination (`new`) and keeps on the origin (`away`), by the shape (and the row, for a pill
        /// for a row) each stands for.
        private var new: [PartAddress: ShapeID] = [:], away: [PartAddress: ShapeID] = [:], carriers: [ShapeID: ShapeID] = [:]
        /// The last pill planned beside each start: the next goes past it.
        private var last: [ShapeID: CGRect] = [:]
        /// The runs this plan has planned from each start to a pill it puts down, with the label each will carry where it will be
        /// (estimated: halfway along the straight run, the size the arrow's label is drawn now, its channel's title): what a pill
        /// planned after keeps its own run and label clear of, as it does of the arrows the move leaves as they are.
        private var runs: [ShapeID: [(from: CGPoint, to: CGPoint, label: CGRect?)]] = [:]
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
        /// `startRow` is the row the start is at, if one: a pill already there is reused only where the line from that row to it
        /// crosses no shape (else a fresh one is put down), and a pill for a row on the binding (a key) lands level with it first.
        mutating func add(_ arrow: ShapeID, from start: ShapeID, to end: ShapeID, row part: PartID?, startRow: PartID? = nil) {
            let startMoves = movers.contains(start)
            // An end that is a pill is the shape it stands for.
            let subject = route.stoodFor(end, in: sourceDoc)?.shape ?? end
            guard subject != start, let far = editor.shape(inFile: subject), let board = editor.file.board(containing: subject) else { return }
            let kind = route.kind(for: far, fulfilling: false, among: makers)?.kind
            // A row that stands alone (an endpoint) is stood for by a pill of its own; any other (a column) by its shape's.
            let named = part.flatMap { part in editor.registry.parts(of: far)?.first { $0.id == part } }
            let row = named?.standsAlone == true && kind.map(editor.registry.standIns.makesRows) == true ? named : nil
            let key = PartAddress(subject, part: row?.id)
            // A line between rows (the far row rides the binding): its pill lands level with the start's row first.
            let line = Line(arrow: arrow, startRow: startRow, level: part != nil && row == nil)
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
                }), joinsClean(line, from: start, startMoves: true, to: have) {
                    if let carrier = carrier(for: subject, standing: far, in: kind) { repoint(to: carrier, after: have) }
                } else if let made = new[key], joinsClean(line, from: start, startMoves: true, toPlanned: made) {
                    repoint(to: made)
                } else if let made = newPill(for: far, row: row, kind: kind, beside: start, startMoves: true, container: holder, line: line) {
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
                                             index: index()), joinsClean(line, from: start, startMoves: false, to: have) {
                    repoint(to: have)
                } else if let made = away[key], joinsClean(line, from: start, startMoves: false, toPlanned: made) {
                    repoint(to: made)
                } else if let made = newPill(for: far, row: row, kind: kind, beside: start, startMoves: false, container: holder, line: line) {
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
        /// would sit in). A pill for a line between rows (a key) lands where its line from the start's row is clean, level with
        /// the row first (`Surroundings.landing(of:joinedFrom:of:)`), as a key's pill does; failing that, and for any other, in
        /// the column beside the start, far enough out that the label its arrow carries (a channel's pill) shows with its line
        /// either side of it, and a pill below another far enough down that their labels, halfway along, don't touch.
        private mutating func newPill(for far: AnyShapeRecord, row: PartName? = nil, kind: ShapeKind, beside start: ShapeID, startMoves: Bool,
                                      container: ShapeID?, line: Line? = nil) -> ShapeID? {
            let standIns = editor.registry.standIns
            guard canInsert, var made = row.map({ standIns.make(kind, standingFor: far.id, row: $0.id, label: $0.name) })
                    ?? standIns.make(kind, standingFor: far.id, label: label(far)) else { return nil }
            let board = startMoves ? destination : source
            guard let surroundings = surroundings(on: board) else { return nil }
            editor.registry.standIns.seat(&made, at: .file(container: container, board: board), in: surroundings.reading.shapes)
            guard let size = made.box?.size else { return nil }
            let nearBox = startMoves ? finalBox(of: start) : nil
            var avoiding = planned[board] ?? []
            if startMoves { avoiding += movedFrames().filter { $0 != nearBox } }
            if let line, line.level, let rowRect = rowRect(line, of: start, startMoves: startMoves),
               let bounds = startMoves ? nearBox : surroundings.reading.shapes.geometry(of: start)?.bounds,
               let clean = surroundings.landing(of: size, joinedFrom: rowRect, of: start, bounds: bounds, avoiding: avoiding, level: true,
                                                labels: labels(at: start, startMoves: startMoves), inView: false),
               !clean.above.contains(where: { isReadOnly($0, in: startMoves ? destDoc : sourceDoc) }) {
                made.box = clean.rect
                planned[board, default: []].append(clean.rect)
                pills.append((made, startMoves, true))
                return made.id
            }
            // The label the arrow carries (a channel's pill), as it is drawn now: the line shows either side of it.
            let label = line.flatMap { sourceSurroundings()?.reading.shapes.geometry(of: $0.arrow)?.label }
            let gap = max(GapName.normal.value, label.map { $0.width + 2 * PlacingStyle.labelEndRoom } ?? 0)
            let below = max(LayoutProblem.impliedListStep, label.map { 2 * ($0.height + PlacingStyle.labelSpacing) - size.height } ?? 0)
            var spot: StandInSpot, against: CGRect?
            if let previous = last[start] {
                spot = StandInSpot(near: start, direction: .right, after: start, step: below, level: .left)
                against = previous
            } else if startMoves {
                guard let nearBox else { return nil }
                spot = StandInSpot(near: start, direction: .right, step: gap)
                against = nearBox
            } else {
                spot = route.spot(beside: start, edgeIs: .from, side: nil, in: surroundings.reading, staying: { !movers.contains($0) }, index: index())
                spot.step = spot.after == nil ? max(spot.step, gap) : max(spot.step, below)
                against = nil
            }
            var landing = against.map { route.landing(of: size, at: spot, against: $0, in: surroundings, avoiding: avoiding) }
                ?? route.landing(of: size, at: spot, in: surroundings, avoiding: avoiding)
            // Clear of the lines and labels already at the start (connect new-3 and new-4): a pill whose run, or whose label halfway
            // along it, would lie on another arrow's line or label from the start (a calls line under the reads pill) goes farther
            // out along its side, a label's room at a time, as far as `PlacingStyle.pillSteps` times; none clear, where it was.
            let from = runStart(line, of: start, startMoves: startMoves)
            let others = linesAndLabels(at: start, startMoves: startMoves)
            let theirs = others.labels + (runs[start] ?? []).compactMap(\.label)
            let theirLines = others.lines + (runs[start] ?? []).map { [$0.from, $0.to] }
            func clear(_ rect: CGRect) -> Bool {
                guard let from else { return true }
                let to = CGPoint(x: rect.minX, y: rect.midY)
                let own = label.map { CGRect(x: (from.x + to.x - $0.width) / 2, y: (from.y + to.y - $0.height) / 2, width: $0.width, height: $0.height) }
                if theirs.contains(where: { Surroundings.crosses(from, to, $0.insetBy(dx: 1, dy: 1)) || (own?.intersects($0) ?? false) }) { return false }
                guard let own else { return true }
                let kept = own.insetBy(dx: -PlacingStyle.labelClearance, dy: -PlacingStyle.labelClearance)
                return !theirLines.contains { points in zip(points, points.dropFirst()).contains { Surroundings.crosses($0, $1, kept) } }
            }
            if let first = landing, !clear(first.rect) {
                let room = (label?.width ?? GapName.normal.value) + PlacingStyle.labelEndRoom
                let startBounds = startMoves ? nearBox : surroundings.reading.shapes.geometry(of: start)?.bounds
                // Farther along the column, then a column farther out beside the start, each a label's room at a time.
                var tries: [(StandInSpot, CGRect?)] = (1...PlacingStyle.pillSteps).map { step in
                    var farther = spot
                    farther.step += room * CGFloat(step)
                    return (farther, against)
                }
                if let previous = last[start] {
                    // Below the last pill of the column, shifted out: its label clears what runs down from the row.
                    tries += (1...PlacingStyle.pillSteps).map { step in
                        (StandInSpot(near: start, direction: .right, after: start, step: below, level: .left), previous.offsetBy(dx: room * CGFloat(step), dy: 0))
                    }
                } else if let startBounds {
                    tries += (1...PlacingStyle.pillSteps).map { step in
                        (StandInSpot(near: start, direction: .right, step: gap + room * CGFloat(step)), startBounds)
                    }
                }
                for (next, at) in tries {
                    let out = at.map { route.landing(of: size, at: next, against: $0, in: surroundings, avoiding: avoiding) }
                        ?? route.landing(of: size, at: next, in: surroundings, avoiding: avoiding)
                    guard let out else { continue }
                    let end = CGPoint(x: out.rect.minX, y: out.rect.midY)
                    let crossesPill = from.map { from in (planned[board] ?? []).contains { Surroundings.crosses(from, end, $0.insetBy(dx: 1, dy: 1)) } } ?? false
                    if clear(out.rect), !crossesPill {
                        landing = out
                        break
                    }
                }
            }
            // A pill that would sit in a frame nobody may change goes unmade, rather than stopping the move.
            guard let landing, !landing.above.contains(where: { isReadOnly($0, in: startMoves ? destDoc : sourceDoc) }) else { return nil }
            made.box = landing.rect
            planned[board, default: []].append(landing.rect)
            last[start] = landing.rect
            pills.append((made, startMoves, true))
            if let from {
                let to = CGPoint(x: landing.rect.minX, y: landing.rect.midY)
                let own = label.map { CGRect(x: (from.x + to.x - $0.width) / 2, y: (from.y + to.y - $0.height) / 2, width: $0.width, height: $0.height) }
                runs[start, default: []].append((from, to, own))
            }
            return made.id
        }

        /// Where a run from `start` to a pill beside it on its right begins: the right end of the row it leaves from, else the
        /// middle of the start's right side, where the start will be. Nil for a start with nothing drawn.
        private mutating func runStart(_ line: Line?, of start: ShapeID, startMoves: Bool) -> CGPoint? {
            if let line, let row = rowRect(line, of: start, startMoves: startMoves) { return CGPoint(x: row.maxX, y: row.midY) }
            let bounds = startMoves ? finalBox(of: start) : surroundings(on: source)?.reading.shapes.geometry(of: start)?.bounds
            return bounds.map { CGPoint(x: $0.maxX, y: $0.midY) }
        }

        /// The lines (each as its outline's points) and labels of the arrows at `start` this move leaves as they are, where they are
        /// drawn: what a pill planned beside the start keeps its run and its label off.
        private mutating func linesAndLabels(at start: ShapeID, startMoves: Bool) -> (lines: [[CGPoint]], labels: [CGRect]) {
            guard let surroundings = surroundings(on: source) else { return ([], []) }
            let offset = startMoves ? delta : .zero
            var lines: [[CGPoint]] = [], labels: [CGRect] = []
            for tie in index().tied[start] ?? [] where !crossing.contains(tie.arrow) {
                guard let geometry = surroundings.reading.shapes.geometry(of: tie.arrow) else { continue }
                lines.append(Self.drawn(geometry.outline).map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) })
                if let label = geometry.label { labels.append(label.offsetBy(dx: offset.x, dy: offset.y)) }
            }
            return (lines, labels)
        }

        /// The row of `start` a line leaves from, where it will be (moved by the move's offset where the start moves).
        private func rowRect(_ line: Line, of start: ShapeID, startMoves: Bool) -> CGRect? {
            guard let part = line.startRow, let rect = editor.reading(of: source)?.shapes.geometry(of: start)?.parts.frame(part)?.rect else { return nil }
            return startMoves ? rect.offsetBy(dx: delta.x, dy: delta.y) : rect
        }

        /// Whether `line` from `start`'s row to the pill `pill` already on the board it ends up on crosses no shape (the shapes moved
        /// where they land among them): a pill is reused only then. A line from no row (an end at a shape as a whole) always is.
        private mutating func joinsClean(_ line: Line, from start: ShapeID, startMoves: Bool, to pill: ShapeID) -> Bool {
            guard line.startRow != nil, let rowRect = rowRect(line, of: start, startMoves: startMoves),
                  let surroundings = surroundings(on: startMoves ? destination : source),
                  let box = surroundings.reading.shapes.geometry(of: pill)?.bounds else { return true }
            let bounds = startMoves ? finalBox(of: start) : surroundings.reading.shapes.geometry(of: start)?.bounds
            return surroundings.joinsClean(rowRect, of: start, bounds: bounds, to: box, standIn: pill,
                                           avoiding: (startMoves ? movedFrames() : []) + (planned[startMoves ? destination : source] ?? []).filter { $0 != box },
                                           labels: labels(at: start, startMoves: startMoves), level: line.level)
        }

        /// The same for a pill this plan puts down already (for another arrow of the same shape).
        private mutating func joinsClean(_ line: Line, from start: ShapeID, startMoves: Bool, toPlanned made: ShapeID) -> Bool {
            guard line.startRow != nil, let rowRect = rowRect(line, of: start, startMoves: startMoves),
                  let box = pills.first(where: { $0.record.id == made })?.record.box,
                  let surroundings = surroundings(on: startMoves ? destination : source) else { return true }
            let bounds = startMoves ? finalBox(of: start) : surroundings.reading.shapes.geometry(of: start)?.bounds
            return surroundings.joinsClean(rowRect, of: start, bounds: bounds, to: box,
                                           avoiding: (startMoves ? movedFrames() : []) + (planned[startMoves ? destination : source] ?? []).filter { $0 != box },
                                           labels: labels(at: start, startMoves: startMoves), level: line.level)
        }

        /// The labels the arrows at `start` that this move leaves as they are carry (the ones that cross are re-pointed, and their
        /// labels are not where they are now), where they will be: a pill's line keeps clear of them.
        private mutating func labels(at start: ShapeID, startMoves: Bool) -> [CGRect] {
            guard let surroundings = surroundings(on: source) else { return [] }
            let offset = startMoves ? delta : .zero
            return (index().tied[start] ?? []).compactMap { tie in
                crossing.contains(tie.arrow) ? nil : surroundings.reading.shapes.geometry(of: tie.arrow)?.label?.offsetBy(dx: offset.x, dy: offset.y)
            }
        }

        /// The origin read, for what an arrow carries as it is drawn there now (its label).
        private mutating func sourceSurroundings() -> Surroundings? { surroundings(on: source) }

        /// The boxes of what moves, where they will be: what a pill landing beside one of them keeps clear of.
        private mutating func movedFrames() -> [CGRect] {
            if let movedBoxes { return movedBoxes }
            let boxes = movers.compactMap { finalBox(of: $0) }
            movedBoxes = boxes
            return boxes
        }

        /// An arrow's line as it is drawn, from its outline: three points (its start, the middle of its arc and its end) are the arc
        /// through them, a point every sixteenth of the way along; any other outline as it is.
        static func drawn(_ outline: [CGPoint]) -> [CGPoint] {
            guard outline.count == 3 else { return outline }
            let (a, b, c) = (outline[0], outline[1], outline[2])
            let d = 2 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
            guard abs(d) > 1e-6 else { return outline }
            let aa = a.x * a.x + a.y * a.y, bb = b.x * b.x + b.y * b.y, cc = c.x * c.x + c.y * c.y
            let center = CGPoint(x: (aa * (b.y - c.y) + bb * (c.y - a.y) + cc * (a.y - b.y)) / d,
                                 y: (aa * (c.x - b.x) + bb * (a.x - c.x) + cc * (b.x - a.x)) / d)
            let radius = hypot(a.x - center.x, a.y - center.y)
            func angle(_ p: CGPoint) -> CGFloat { atan2(p.y - center.y, p.x - center.x) }
            // From a's angle to c's, the way that passes b's.
            let start = angle(a), through = angle(b), end = angle(c)
            func sweep(_ from: CGFloat, _ to: CGFloat) -> CGFloat { var s = to - from; while s < 0 { s += 2 * .pi }; return s }
            let total = sweep(start, through) <= sweep(start, end) ? sweep(start, end) : sweep(start, end) - 2 * .pi
            return (0...16).map { step in
                let t = start + total * CGFloat(step) / 16
                return CGPoint(x: center.x + radius * cos(t), y: center.y + radius * sin(t))
            }
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
