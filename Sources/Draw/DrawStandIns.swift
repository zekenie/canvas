import Canvas
import CoreGraphics
import DrawScript
import Geometry
import Topology

// Edges through stand-ins. An arrow can't leave its board, and a shape many arrows point at needs no
// arrow from each: a stand-in (Topology's, `registry.standIns`: a pill that stands for a shape, so an
// arrow into it is an arrow into the shape) is put beside what the edge starts from, on the board the
// run draws on, standing for the end that's on another board. `draw` knows no kind of stand-in: it
// asks what stands in, and for which shapes, as Topology says (`StandIns`), and the kind makes its own.
//
// An edge goes through a stand-in when its statement says so (`via: <kind>`, the kind to put beside
// the start, standing for the end) or when `goesThroughStandIn` says so, for the end that's off the
// board the run draws on. The stand-in is a new shape of the run, placed as any new shape is (beside
// the shape on the board, right of it when that's the start, left of it when it's the end, or on the
// side the edge names for it), drawn before the arrow. An arrow already on the board between the
// near end and a stand-in whose record stands for exactly the far end is that edge, so a run again
// draws neither a second arrow nor a second stand-in, and `delete edge` takes the arrow, and the
// stand-in if that leaves it with none, as `delete "X"` takes one X's arrows leave with none. It's
// found on whichever board it is: the run draws there (`DrawBoard.swift`), by the same `edgeMatches`.

/// Which end of an edge: the start, or the end.
enum EdgePlace {
    case from, to

    var other: EdgePlace { self == .from ? .to : .from }
}

/// A shape an edge names that's on a board other than the one the run draws on.
struct FarShape {
    let record: AnyShapeRecord
    let board: BoardID
}

/// What an edge's end names: a shape on the board the run draws on (one the board has, or the item
/// of one the script draws), or one elsewhere in the file.
enum EdgeEndFound {
    case here(ShapeID, item: Int?)
    case away(FarShape)

    var id: ShapeID {
        switch self {
        case .here(let id, _): id
        case .away(let far): far.record.id
        }
    }
}

/// The stand-in a run makes for an edge: its shape (an item of the run), which end of the edge it
/// stands for, and its kind.
struct NewStandIn {
    let id: ShapeID
    let place: EdgePlace
    let kind: ShapeKind
    /// The edge reuses a stand-in that was there, or an earlier edge of the run made (`share:`), and
    /// the title of the shape it is beside, when the edge named it (`share: "A"`).
    var shared = false
    var sharedWith: String?
}

/// A stand-in the run made for an edge, for `share:` to find: the shape it stands for, the container
/// the edge's other end was in when it was made, and its kind.
struct MadeStandIn {
    let id: ShapeID
    let stoodFor: ShapeID
    let container: ShapeID?
    let kind: ShapeKind
}

/// An end of an edge, as the decision whether the edge goes through a stand-in reads it.
struct EdgeEnd {
    let record: AnyShapeRecord
    let board: BoardID
}

/// A connection on the board that is an edge as written: how the arrow reaches the ends.
struct EdgeMatch {
    let connection: BoardConnection
    /// The end of the edge the arrow reaches through a stand-in, and that stand-in: nil for an arrow
    /// drawn straight between the ends.
    let standIn: (place: EdgePlace, id: ShapeID, kind: ShapeKind)?
    /// Whether the arrow runs the other way round from the edge as written: `<->` finds one drawn so.
    let reversed: Bool
}

extension Drawing {
    // MARK: The decision

    /// Whether an edge goes through a stand-in when its statement doesn't say (`via:`): the one place
    /// that decides, and the place to grow. Today an edge whose ends are on different boards does,
    /// since an arrow can't leave its board: it's drawn into (or out of) a stand-in for the end that's
    /// off the board the run draws on, beside the end that's on it. Whatever else makes two shapes not
    /// really connectable (how far apart they are, their kinds) is for this function to say, and
    /// nothing else decides.
    static func goesThroughStandIn(from: EdgeEnd, to: EdgeEnd) -> Bool {
        from.board != to.board
    }

    /// The kind a stand-in for `target` is made as: the first, in plugin order, that can be made to
    /// stand for a shape and admits this one; nil if none does.
    func standInKind(for target: AnyShapeRecord) -> ShapeKind? {
        guard let standIns else { return nil }
        return standIns.makers.first { standIns.admits($0, target) }
    }

    /// The kind `via:` names, if it's one that can be made to stand for a shape.
    func standInKind(named word: String, _ statement: Statement, written: String) throws(DrawError) -> ShapeKind {
        try Self.standInKind(named: word, among: standIns, statement, written: written)
    }

    /// The same for whoever has the registry's stand-ins and no run (`canvas measure`).
    static func standInKind(named word: String, among standIns: StandIns?, _ statement: Statement,
                            written: String) throws(DrawError) -> ShapeKind {
        let makers = standIns?.makers ?? []
        guard let kind = makers.first(where: { $0.rawValue == word }) else {
            let key = EdgeKey.via.rawValue
            guard !makers.isEmpty else {
                throw DrawError(statement, .invalidValue, "\(written): \(key): \(word) isn't a kind of shape that stands for others",
                                hint: "no kind here is put beside a shape it stands for: leave \(key): out")
            }
            let guess = Suggestions.closest(to: word, among: makers.map(\.rawValue), limit: 1).first
            throw DrawError(statement, .invalidValue, "\(written): \(key): \(word) isn't a kind of shape that stands for others",
                            hint: (guess.map { "did you mean \($0)? " } ?? "") + "\(key): takes \(makers.map(\.rawValue).joined(separator: "|"))")
        }
        return kind
    }

    /// What to say when an arrow can't go to a shape on another board: a shape can be reached through a
    /// stand-in only if one can be made to stand for it, which a kind says only of some shapes (a
    /// reference, of a public one): a change that's a person's to make, so they're asked. Nil where
    /// nothing makes stand-ins, or there's no shape to say.
    static func standInHint(for titles: [String], _ standIns: StandIns?) -> String? {
        guard let standIns, !titles.isEmpty, let first = standIns.makers.first else { return nil }
        var needs: [String] = []
        for word in standIns.makers.compactMap({ standIns.needs($0) }) where !needs.contains(word) { needs.append(word) }
        let split = "split the script into a run for each board"
        let named = listed(titles.map(quoted), or: true)
        guard let need = needs.first else {
            return "an arrow can't leave its board: it goes into \(indefinite(first)) standing for the shape on the other board, which can't stand for \(named); \(split)"
        }
        return "an arrow can't leave its board: it goes into \(indefinite(first)) standing for the shape on the other board, and only "
            + "\(indefinite(listed(needs, or: true))) shape can be stood for; ask the user to make \(named) \(need), or \(split)"
    }

    // MARK: Shapes elsewhere in the file

    /// The shape called `title` on a board other than the one the run draws on, among those the app
    /// can show (not on a board a delete of this script takes); nil if none is. One on the board the
    /// window shows is the one, as everywhere; two or more on one board, or on several none of which is
    /// the one shown, are `ambiguous_title` (`FileNames.beyond`, which a text's names are found by too).
    func farShape(called title: String, _ statement: Statement) throws(DrawError) -> FarShape? {
        guard let fileNames, let places = fileNames.places[title] else { return nil }
        let taken = deletedShapes.isEmpty ? [] : Set(editor.file.subtree(ownedBy: deletedShapes))
        switch fileNames.beyond(title, among: places.filter { $0.board != target.board && !taken.contains($0.board) }) {
        case .none:
            return nil
        case .ambiguous(let message):
            throw DrawError(statement, .ambiguousTitle, message, hint: FileNames.oneEach)
        case .shape(let place):
            return editor.file.record(place.id).map { FarShape(record: $0, board: place.board) }
        }
    }

    // MARK: Which connections are an edge

    /// What a connection's end is, for telling which edge it draws: the shape itself, or, if it's a
    /// stand-in whose record stands for exactly one shape (a direct one: a query may stand for several,
    /// so it never matches), that shape, and the stand-in. `standIns` is what stands in for what, nil
    /// where nothing does.
    private static func effective(_ id: ShapeID, in document: CanvasDocument,
                                  _ standIns: StandIns?) -> (id: ShapeID, standIn: (id: ShapeID, kind: ShapeKind)?) {
        guard let standIns, let record = document[id],
              case .shapes(let named)? = standIns.forwarding(of: record), let first = named.first, first != id,
              named.allSatisfy({ $0 == first }) else { return (id, nil) }
        return (first, (id, record.kind))
    }

    /// The connections among `connections` (a board's, as `document` has them) that are the edge from
    /// `from` to `to` (either way round, if `bothHeads`): drawn straight between them, or between one
    /// and a stand-in whose record stands for exactly the other. Never one between two stand-ins. The
    /// one rule for which arrows are an edge, whichever board it's asked of (the board the run draws on,
    /// or one it's choosing among: `Drawing.board(for:in:)`).
    static func edgeMatches(from: ShapeID, to: ShapeID, bothHeads: Bool, among connections: [BoardConnection],
                            in document: CanvasDocument, standIns: StandIns?) -> [EdgeMatch] {
        var found: [EdgeMatch] = []
        for connection in connections {
            // Only an arrow that has one of the ends can be the edge, straight or through a stand-in
            // at its other end.
            guard connection.from == from || connection.from == to || connection.to == from || connection.to == to else { continue }
            let a = effective(connection.from, in: document, standIns), b = effective(connection.to, in: document, standIns)
            guard a.standIn == nil || b.standIn == nil else { continue }
            let forward = a.id == from && b.id == to
            let backward = bothHeads && from != to && a.id == to && b.id == from
            guard forward || backward else { continue }
            var standIn: (place: EdgePlace, id: ShapeID, kind: ShapeKind)?
            if let pill = a.standIn {
                standIn = (forward ? .from : .to, pill.id, pill.kind)
            } else if let pill = b.standIn {
                standIn = (forward ? .to : .from, pill.id, pill.kind)
            }
            found.append(EdgeMatch(connection: connection, standIn: standIn, reversed: !forward))
        }
        return found
    }

    /// The same for the board the run draws on, by the stand-ins it knows.
    func edgeMatches(from: ShapeID, to: ShapeID, bothHeads: Bool, among connections: [BoardConnection],
                     in document: CanvasDocument) -> [EdgeMatch] {
        Self.edgeMatches(from: from, to: to, bothHeads: bothHeads, among: connections, in: document, standIns: standIns)
    }

    /// The kinds of what a connection's end stands for, if it's a stand-in standing for one shape:
    /// what a connection to it is made by (it takes what the shape does), none for any other end.
    /// `document` is the board as the run leaves it, the shape stood for found there, else anywhere
    /// in the file.
    func standsFor(_ id: ShapeID, in document: CanvasDocument) -> [ShapeKind] {
        let end = Self.effective(id, in: document, standIns)
        guard end.standIn != nil, let kind = document[end.id]?.kind ?? editor.file.record(end.id)?.kind else { return [] }
        return [kind]
    }

    /// The shape a connection's end stands for, if the end is a stand-in whose record stands for
    /// exactly one: found in `document`, else anywhere in the file.
    func standsForShape(_ id: ShapeID, in document: CanvasDocument) -> AnyShapeRecord? {
        let end = Self.effective(id, in: document, standIns)
        guard end.standIn != nil else { return nil }
        return document[end.id] ?? editor.file.record(end.id)
    }

    /// The stand-in at one end of a connection, if its record stands for exactly one shape.
    func standIn(at id: ShapeID, in document: CanvasDocument) -> (id: ShapeID, kind: ShapeKind)? {
        Self.effective(id, in: document, standIns).standIn
    }

    // MARK: Routing an edge

    /// What an edge goes through, if the run makes a stand-in for it: nil when it's drawn straight
    /// (both ends on the board, and no `via:`), or an arrow like it is drawn already between the near
    /// end and a stand-in for the far one (it's found as the run applies). Else the stand-in is added to
    /// the run as a shape of its own, placed beside the end that stays: the end that's off the board
    /// the run draws on is stood for, or, with `via:`, the end.
    mutating func routeEdge(_ edge: EdgeStatement, _ statement: Statement, written: String, from: EdgeEndFound, to: EdgeEndFound,
                            fromTitle: String, toTitle: String, via: ShapeKind?) throws(DrawError) -> NewStandIn? {
        let drawnTo = "\(written) is drawn to"
        let key = EdgeKey.via.rawValue
        let stoodFor: EdgePlace
        switch (from, to) {
        case (.away(let far), .away):
            throw severalBoards(fromTitle, on: far.board, statement, for: drawnTo)
        case (.away, .here):
            stoodFor = .from
        case (.here, .away):
            stoodFor = .to
        case (.here, .here):
            guard via != nil else {
                // Nothing here sends it through a stand-in, so there is none to share: but an edge drawn
                // through one already is the edge, and a run again says so (`connect`).
                if edge.share != nil {
                    let drawn = boardConnections().filter { !deleted.contains($0.record.id) }
                    guard edgeMatches(from: from.id, to: to.id, bothHeads: edge.bothHeads, among: drawn, in: target.document).contains(where: { $0.standIn != nil }) else {
                        let key = EdgeKey.share.rawValue, kind = standInKinds.first
                        throw DrawError(statement, .invalidValue,
                                        "\(written): \(key): is for an edge that goes through \(kind.map(indefinite) ?? "a stand-in"), and this one is drawn straight",
                                        hint: (kind.map { "write \(EdgeKey.via.rawValue): \($0) to put one beside its start, or " } ?? "") + "leave \(key): out")
                    }
                }
                return nil
            }
            stoodFor = .to
        }

        // Drawn already: between the near end and a stand-in that stands for exactly the other. It's the
        // edge whatever the stand-in's shape can be stood for now, and whether `via:` says so, so it's
        // looked for before anything is decided: a run again is `unchanged` (`connect`).
        let drawn = boardConnections().filter { !deleted.contains($0.record.id) }
        let matches = edgeMatches(from: from.id, to: to.id, bothHeads: edge.bothHeads, among: drawn, in: target.document)
        if matches.contains(where: { $0.standIn != nil }) { return nil }

        // `via:` puts the stand-in for the end beside the start, which isn't on this board.
        if let via, case .away(let far) = from {
            throw severalBoards(fromTitle, on: far.board, statement, for: drawnTo,
                                hint: "\(key): puts \(indefinite(via)) for the edge's end beside its start, which is on another board: write the edge in a run that draws there, or leave \(key): out")
        }
        let nearPlace = stoodFor.other
        guard case .here(let nearID, let nearItem) = nearPlace == .from ? from : to else {
            throw DrawError(statement, .internal, "\(written) has no end on the board it's drawn on")
        }
        let nearTitle = nearPlace == .from ? fromTitle : toTitle, standTitle = stoodFor == .from ? fromTitle : toTitle

        // The ends as shapes, each with the board it's on.
        func end(_ found: EdgeEndFound) -> EdgeEnd? {
            switch found {
            case .here(let id, let item): (item.map { items[$0].record } ?? target.document[id]).map { EdgeEnd(record: $0, board: target.board) }
            case .away(let far): EdgeEnd(record: far.record, board: far.board)
            }
        }
        guard let fromEnd = end(from), let toEnd = end(to) else {
            throw DrawError(statement, .internal, "\(written) names a shape that isn't on any board")
        }
        let standEnd = stoodFor == .from ? fromEnd : toEnd

        // Whether it goes through one, and as which kind.
        let kind: ShapeKind
        if let via {
            guard let standIns, standIns.admits(via, standEnd.record) else {
                let needs = standIns?.needs(via)
                throw DrawError(statement, .invalidValue,
                                needs.map { "\(written): \(key): \(via) can't stand for \(quoted(standTitle)): only \(indefinite($0)) shape can be stood for" }
                                          ?? "\(written): \(key): \(via) can't stand for \(quoted(standTitle))",
                                hint: (needs.map { "ask the user to make \(quoted(standTitle)) \($0), or " } ?? "") + "leave \(key): out")
            }
            kind = via
        } else {
            guard Self.goesThroughStandIn(from: fromEnd, to: toEnd) else {
                throw severalBoards(standTitle, on: standEnd.board, statement, for: drawnTo)
            }
            guard let found = standInKind(for: standEnd.record) else {
                throw severalBoards(standTitle, on: standEnd.board, statement, for: drawnTo, hint: Self.standInHint(for: [standTitle], standIns))
            }
            kind = found
        }

        // Drawn straight already, which `via:` has asked to be through one: left as it is (`connect` says).
        guard matches.isEmpty else { return nil }

        // `share:` reuses a stand-in for the same end rather than make another; a named host that has none
        // is refused, never silently given a stand-in of its own. Said by the edge's row (`shared`).
        let container = containerOfEnd(nearID, item: nearItem)
        if let share = edge.share,
           let found = try sharedStandIn(share, for: standEnd.record, kind: kind, near: (nearID, nearItem), container: container,
                                         written: written, standTitle: standTitle, nearTitle: nearTitle, statement) {
            return NewStandIn(id: found.id, place: stoodFor, kind: kind, shared: true, sharedWith: found.host)
        }

        // Said by the edge's row alone (`via`), with `via:` or without: a warning for each edge between
        // boards would bury the warnings that need reading.
        let id = try addStandIn(kind, for: standEnd.record, called: standTitle, beside: nearID, item: nearItem, title: nearTitle,
                                nearIs: nearPlace, side: nearPlace == .from ? edge.fromSide : edge.toSide, statement)
        madeStandIns.append(MadeStandIn(id: id, stoodFor: standEnd.record.id, container: container, kind: kind))
        return NewStandIn(id: id, place: stoodFor, kind: kind)
    }

    // MARK: Sharing a stand-in

    /// The kinds that can be made to stand for a shape, by name, for a message.
    private var standInKinds: [String] { (standIns?.makers ?? []).map(\.rawValue) }

    /// The innermost container of an end that stays on the board, a shape of the board or of the run: the
    /// frame it is in (a shape the script draws `in` one, else where a shape restated sits), nil for the
    /// board outside frames. Where a shape the script places lands by its placements isn't known here.
    private func containerOfEnd(_ id: ShapeID, item: Int?) -> ShapeID? {
        let kinds = registry.containingKinds
        guard !kinds.isEmpty else { return nil }
        if let item {
            if let holder = items[item].holder { return holder.id }
            return items[item].existing.flatMap { target.document.container(of: $0.id, containingKinds: kinds) }
        }
        return target.document.container(of: id, containingKinds: kinds)
    }

    /// The shape a stand-in stands for: one this run made, or one the board has (a direct one, standing
    /// for exactly one shape).
    private func standingFor(_ id: ShapeID) -> ShapeID? {
        if let made = madeStandIns.first(where: { $0.id == id }) { return made.stoodFor }
        let end = Self.effective(id, in: target.document, standIns)
        return end.standIn == nil ? nil : end.id
    }

    /// The board's direct stand-ins by the shape each stands for, in document order: found in one pass
    /// the first time `share` asks.
    private mutating func boardStandIns(for stoodFor: ShapeID) -> [ShapeID] {
        if boardStandInsByEnd == nil {
            var found: [ShapeID: [ShapeID]] = [:]
            for record in target.document.shapes {
                let end = Self.effective(record.id, in: target.document, standIns)
                if end.standIn != nil { found[end.id, default: []].append(record.id) }
            }
            boardStandInsByEnd = found
        }
        return boardStandInsByEnd?[stoodFor] ?? []
    }

    /// The stand-in `share` names, if there is one: for `share: true`, a direct stand-in of `kind` for the
    /// same end, in the same container as the end that stays, which the board has (the first) or an
    /// earlier edge of the run made; for `share: "A"`, the one A's own arrow goes into, A being in that
    /// container. Nil for `share: true` with none; a named host with none is refused.
    private mutating func sharedStandIn(_ share: EdgeShare, for end: AnyShapeRecord, kind: ShapeKind, near: (id: ShapeID, item: Int?),
                                        container: ShapeID?, written: String, standTitle: String, nearTitle: String,
                                        _ statement: Statement) throws(DrawError) -> (id: ShapeID, host: String?)? {
        let key = EdgeKey.share.rawValue
        let kinds = registry.containingKinds
        switch share {
        case .any:
            for pill in boardStandIns(for: end.id) where !deleted.contains(pill) {
                guard let record = target.document[pill], record.kind == kind,
                      (kinds.isEmpty ? nil : target.document.container(of: pill, containingKinds: kinds)) == container else { continue }
                return (pill, nil)
            }
            if let made = madeStandIns.first(where: { $0.stoodFor == end.id && $0.kind == kind && $0.container == container }) {
                return (made.id, nil)
            }
            return nil
        case .beside(let host):
            let title = try folded(host, statement)
            var hostID: ShapeID?, hostItem: Int?
            if let index = itemByTitle[title] {
                hostID = items[index].record.id
                hostItem = index
            } else if unresolved.contains(title) {
                throw skip()
            } else if let record = try boardShape(called: title, statement) {
                hostID = record.id
            }
            guard let hostID else { throw notFound(title, statement, for: "\(written): \(key): names", elsewhere: false) }
            guard hostID != near.id else {
                throw DrawError(statement, .invalidValue, "\(written): \(key): \(quoted(title)) is the edge's own end",
                                hint: "name another shape whose arrow goes into the reference, or write \(key): true")
            }
            guard containerOfEnd(hostID, item: hostItem) == container else {
                throw DrawError(statement, .invalidValue, "\(written): \(key): \(quoted(title)) and \(quoted(nearTitle)) aren't in the same container",
                                hint: "a reference is shared by shapes in one frame, or none: put them in the same one, or leave \(key): out")
            }
            func stands(_ pill: ShapeID) -> Bool {
                standingFor(pill) == end.id && (madeStandIns.first { $0.id == pill }?.kind ?? target.document[pill]?.kind) == kind
            }
            // The host's arrows: those of the run (a reference it made or shared), then the board's.
            for other in edges {
                guard let standIn = other.standIn, standIn.kind == kind, (standIn.place == .from ? other.to : other.from) == hostID, stands(standIn.id) else { continue }
                return (standIn.id, title)
            }
            for pill in connected(to: hostID) where !deleted.contains(pill) && stands(pill) { return (pill, title) }
            throw DrawError(statement, .invalidValue, "\(written): \(key): \(quoted(title)) has no \(kind) to \(quoted(standTitle)) beside it",
                            hint: "draw an edge between \(quoted(title)) and \(quoted(standTitle)) above this line, in this run or an earlier one; or write \(key): true, or leave \(key): out")
        }
    }

    /// Adds a stand-in for `target`, called `label`, as a new shape of the run beside the shape `near`
    /// (on the board, or the item of one the script draws): right of it where it's the start of the
    /// edge, left of it where it's the end, or on the side the edge names for it; where a run before left
    /// a column of stand-ins there, at the end of it (`columnEnd`). It's placed as any new shape is,
    /// kept clear of what's there, and put down in or out of the containers it lands on; those beside
    /// one shape on one side are a list, `LayoutProblem.impliedListStep` apart.
    private mutating func addStandIn(_ kind: ShapeKind, for target: AnyShapeRecord, called label: String, beside near: ShapeID, item: Int?,
                                     title nearTitle: String, nearIs place: EdgePlace, side: EdgeSide?,
                                     _ statement: Statement) throws(DrawError) -> ShapeID {
        guard let standIns, let record = standIns.make(kind, standingFor: target.id, label: label), let size = record.box?.size else {
            throw DrawError(statement, .internal, "\(indefinite(kind)) couldn't be made to stand for \(quoted(label))")
        }
        let direction: Direction = switch side {
        case .left?: .left
        case .right?: .right
        case .top?: .above
        case .bottom?: .below
        case nil: place == .from ? .right : .left
        }
        let found: ShapeItem.Found
        if let item {
            found = .item(item)
        } else if let nearRecord = self.target.document[near] {
            found = .shape(nearRecord)
        } else {
            throw DrawError(statement, .internal, "\(quoted(nearTitle)) isn't on the board the reference is drawn on")
        }
        var clauses = [Clause(relation: .direction(direction), targets: [Target(.title(nearTitle))])]
        var targets: [[ShapeItem.Found]] = [[found]]
        if let end = columnEnd(beside: near, item: item, direction) {
            // Next in the column: a step past its end, lined up with it as the list was.
            let named = standInName(end), step = Gap.units(LayoutProblem.impliedListStep)
            let way: Direction = direction == .above ? .above : .below
            clauses = [Clause(relation: .direction(way), targets: [Target(.title(named))], gap: step,
                              written: Clause.written(.direction(way), naming: [named], gap: step))]
            let line: AlignSide? = switch direction {
            case .right: .left
            case .left: .right
            default: nil
            }
            if let line {
                clauses.append(Clause(relation: .level(line), targets: [Target(.title(named))], written: Clause.written(.level(line), naming: [named])))
            }
            targets = clauses.map { _ in [.shape(end)] }
        }
        var standIn = ShapeItem(statement: statement, shape: ShapeStatement(word: kind.rawValue, clauses: clauses), kind: kind, title: nil,
                                existing: nil, record: record, size: size, room: size)
        standIn.targets = targets
        standIn.standsFor = label
        items.append(standIn)
        return record.id
    }

    // MARK: Joining a column

    /// The end of the column of stand-ins a run before left beside `near` on the side `direction`
    /// names, which a new one there joins: of the stand-ins an arrow on the board joins to it (each
    /// standing for one shape), those wholly on that side of it, lined up as a list beside it lines
    /// its members up (left edges right of it, right edges left of it, middles above and below it), on
    /// the line nearest it whose stand-ins reach across from its middle, as a list drawn beside it does
    /// (one dragged off elsewhere isn't beside it); and of those, the lowest (above it, the topmost),
    /// which the new one goes past. Nil for none, and wherever this run moves `near` (a shape it draws,
    /// places or carries in a container it moves) or that end, which wouldn't be beside it any more.
    private mutating func columnEnd(beside near: ShapeID, item: Int?, _ direction: Direction) -> AnyShapeRecord? {
        if let item, items[item].moves { return nil }
        guard let nearBox = target.shapes.geometry(of: near)?.bounds, nearBox.isFinite, !movesWithRun(near) else { return nil }
        let slack: CGFloat = 0.5
        var beside: [(record: AnyShapeRecord, box: CGRect)] = []
        for other in connected(to: near) {
            guard !deleted.contains(other), standIn(at: other, in: target.document) != nil, let record = target.document[other],
                  !beside.contains(where: { $0.record.id == other }),
                  let box = target.shapes.geometry(of: other)?.bounds, box.isFinite else { continue }
            let wholly = switch direction {
            case .right: box.minX >= nearBox.maxX - slack
            case .left: box.maxX <= nearBox.minX + slack
            case .below: box.minY >= nearBox.maxY - slack
            default: box.maxY <= nearBox.minY + slack
            }
            if wholly { beside.append((record, box)) }
        }
        /// Where a stand-in's box is across the column, and how far from `near` it is.
        func line(_ box: CGRect) -> (across: CGFloat, distance: CGFloat) {
            switch direction {
            case .right: (box.minX, box.minX - nearBox.maxX)
            case .left: (box.maxX, nearBox.minX - box.maxX)
            case .below: (box.midX, box.minY - nearBox.maxY)
            default: (box.midX, nearBox.minY - box.maxY)
            }
        }
        for nearest in beside.sorted(by: { line($0.box).distance < line($1.box).distance }) {
            let column = beside.filter { abs(line($0.box).across - line(nearest.box).across) <= slack }
            let span = column.reduce(CGRect.null) { $0.union($1.box) }
            let across = direction == .right || direction == .left ? span.minY <= nearBox.midY && nearBox.midY <= span.maxY
                : span.minX <= nearBox.midX && nearBox.midX <= span.maxX
            guard across else { continue }
            let end = direction == .above ? column.min { $0.box.minY < $1.box.minY } : column.max { $0.box.maxY < $1.box.maxY }
            guard let end, !movesWithRun(end.record.id) else { return nil }
            return end.record
        }
        return nil
    }

    /// A stand-in on the board, as a message names it: `the reference to "Auth"`, by the title of what it
    /// stands for, else where it is.
    func standInName(_ record: AnyShapeRecord) -> String {
        guard let stoodFor = standsForShape(record.id, in: target.document),
              let title = Drawing.title(of: stoodFor, names: names, naming: naming, registry: registry) else {
            return "the \(Drawing.location(of: record, in: target.shapes))"
        }
        return "the \(record.kind) to \(quoted(title))"
    }
}
