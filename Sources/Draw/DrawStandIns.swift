import Canvas
import CanvasRPC
import CoreGraphics
import DrawScript
import FuzzyMatching
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
// board the run draws on. The stand-in is a new shape of the run, placed as any new shape is (where
// the edge's own placements and `in` say, as a shape statement's would place it; else beside the shape
// on the board, right of it when that's the start, left of it when it's the end, or on the side the
// edge names for it), drawn before the arrow. An arrow already on the board between the
// near end and a stand-in whose record stands for exactly the far end is that edge, so a run again
// draws neither a second arrow nor a second stand-in, and `delete edge` takes the arrow, and the
// stand-in if that leaves it with none, as `delete "X"` takes one X's arrows leave with none. It's
// found on whichever board it is: the run draws there (`DrawBoard.swift`), by the same `edgeMatches`.

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
/// it goes in (the one its edge names, `in "F"`, else the one the edge's other end was in when it was
/// made), and its kind.
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

/// What tells the edges of one pair apart in a statement that writes some of it: the values it gives
/// the edge kind's identity keys (`DrawEdgeIdentities`), by key, as the value writers left them (an
/// `is:` title as the id it became). Equal by meaning: a list of ids is a set, and an absent key, `null`
/// and an empty list are one "none".
struct EdgeIdentity {
    /// Every identity key of the edge kind, written or not.
    let keys: [String]
    let written: [String: JSONValue]

    /// nil when the statement writes none of the keys: it addresses the pair.
    init?(keys: [String], settings: JSONObject) {
        let written = settings.filter { keys.contains($0.key) }
        guard !written.isEmpty else { return nil }
        self.keys = keys
        self.written = written
    }

    /// What a value says, as a set: none is empty.
    static func meaning(_ value: JSONValue?) -> Set<JSONValue> {
        switch value {
        case nil, .null?: []
        case .array(let items)?: Set(items)
        case let value?: [value]
        }
    }

    /// Whether the arrow holds what the statement writes, for each key it writes.
    func matches(_ record: AnyShapeRecord) -> Bool {
        let held = record.propertiesJSON      // made at each reading: once an arrow, not once a key
        return written.allSatisfy { Self.meaning($0.value) == Self.meaning(held?[$0.key]) }
    }

    /// Whether the statement writes none: `is: null`, which addresses the plain arrow.
    var isNone: Bool { written.values.allSatisfy { Self.meaning($0).isEmpty } }

    /// Whether the arrow holds none of the kind's identity keys: a plain arrow.
    func isPlain(_ record: AnyShapeRecord) -> Bool {
        let held = record.propertiesJSON
        return keys.allSatisfy { Self.meaning(held?[$0]).isEmpty }
    }

    /// Whether another statement writes a different value for a key both write.
    func differs(from other: EdgeIdentity) -> Bool {
        written.contains { key, value in other.written[key].map { Self.meaning($0) != Self.meaning(value) } ?? false }
    }
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
        route?.kind(for: target, fulfilling: false)?.kind
    }

    /// How stand-ins are read and made, nil where nothing stands in.
    var route: StandInRoute? { standIns.map { StandInRoute($0, registry: registry) } }

    /// What the board holds that routing asks about, read the first time something asks.
    mutating func standInIndex(_ route: StandInRoute) -> StandInRoute.Index {
        if let standInIndex { return standInIndex }
        let index = route.index(of: target.document)
        standInIndex = index
        return index
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
    /// nothing makes stand-ins, or there's no shape to say. `names` are the shapes as a message calls them
    /// (a title in quotes, or an id as written).
    static func standInHint(for names: [String], _ standIns: StandIns?) -> String? {
        guard let standIns, !names.isEmpty, let first = standIns.makers.first else { return nil }
        var needs: [String] = []
        for word in standIns.makers.compactMap({ standIns.needs($0) }) where !needs.contains(word) { needs.append(word) }
        let split = "split the script into a run for each board"
        let named = listed(names, or: true)
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
        let taken = deletedShapes.isEmpty ? [] : takenBoards.boards(owned: deletedShapes, in: editor.file)
        switch fileNames.beyond(title, among: places.filter { $0.board != target.board && !taken.contains($0.board) }) {
        case .none:
            return nil
        case .ambiguous(let message, let places):
            throw DrawError(statement, .ambiguousTitle, message, hint: fileNames.pathHint(for: places))
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
        guard let stood = StandInRoute.read(id, in: document, standIns) else { return (id, nil) }
        return (stood.shape, (id, stood.kind))
    }

    /// The connections among `connections` (a board's, as `document` has them) that are the edge from
    /// `from` to `to` (either way round, if `bothHeads`): drawn straight between them, or between one
    /// and a stand-in whose record stands for exactly the other. Never one between two stand-ins. The
    /// one rule for which arrows are an edge, whichever board it's asked of (the board the run draws on,
    /// or one it's choosing among: `Drawing.board(for:in:)`). With `identity`, only those of the pair
    /// that hold what it writes (nil: any of the pair).
    static func edgeMatches(from: ShapeID, to: ShapeID, bothHeads: Bool, among connections: [BoardConnection],
                            in document: CanvasDocument, standIns: StandIns?, identity: EdgeIdentity? = nil) -> [EdgeMatch] {
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
            guard identity?.matches(connection.record) ?? true else { continue }
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
                     in document: CanvasDocument, identity: EdgeIdentity? = nil) -> [EdgeMatch] {
        Self.edgeMatches(from: from, to: to, bothHeads: bothHeads, among: connections, in: document, standIns: standIns, identity: identity)
    }

    /// The arrows of a pair an edge statement addresses (`candidates`: the pair's, by `edgeMatches`). A
    /// statement that writes no identity key addresses them all. One that writes some addresses those
    /// that hold what it writes; failing that, if what it writes isn't none and the pair has exactly
    /// one plain arrow, that arrow, which then takes it; failing that, none: a new arrow. `is: null`
    /// addresses the plain arrows alone. A run asks of the pair's arrows as the statements before it left them
    /// (`apply`): the plain arrow one statement typed is no longer plain for the next.
    static func addressed(_ candidates: [EdgeMatch], by identity: EdgeIdentity?) -> [EdgeMatch] {
        guard let identity else { return candidates }
        let exact = candidates.filter { identity.matches($0.connection.record) }
        guard exact.isEmpty, !identity.isNone else { return exact }
        let plain = candidates.filter { identity.isPlain($0.connection.record) }
        return plain.count == 1 ? plain : []
    }

    /// The arrows of the pair that a statement with this identity addresses (`addressed`).
    func addressedMatches(from: ShapeID, to: ShapeID, bothHeads: Bool, among connections: [BoardConnection],
                          in document: CanvasDocument, identity: EdgeIdentity?) -> [EdgeMatch] {
        Self.addressed(edgeMatches(from: from, to: to, bothHeads: bothHeads, among: connections, in: document), by: identity)
    }

    /// The kinds of what a connection's end stands for, if it's a stand-in standing for one shape:
    /// what a connection to it is made by (it takes what the shape does), none for any other end.
    /// `document` is the board as the run leaves it, the shape stood for found there, else among the
    /// shapes the run draws (a laid-out arrow is made over the ends alone, before they are drawn), else
    /// anywhere in the file.
    func standsFor(_ id: ShapeID, in document: CanvasDocument) -> [ShapeKind] {
        standsForShape(id, in: document).map { [$0.kind] } ?? []
    }

    /// The shape a connection's end stands for, if the end is a stand-in whose record stands for
    /// exactly one: found in `document`, else anywhere in the file.
    func standsForShape(_ id: ShapeID, in document: CanvasDocument) -> AnyShapeRecord? {
        let end = Self.effective(id, in: document, standIns)
        guard end.standIn != nil else { return nil }
        return document[end.id] ?? items.first { $0.record.id == end.id }?.record ?? editor.file.record(end.id)
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
                            fromName: EndName, toName: EndName, via: ShapeKind?, identity: EdgeIdentity?) throws(DrawError) -> NewStandIn? {
        let drawnTo = "\(written) is drawn to"
        let key = EdgeKey.via.rawValue
        let stoodFor: EdgePlace
        switch (from, to) {
        case (.away(let far), .away):
            throw severalBoards(said: fromName.said, on: far.board, statement, for: drawnTo)
        case (.away, .here):
            stoodFor = .from
        case (.here, .away):
            stoodFor = .to
        case (.here, .here):
            guard via != nil else {
                // Nothing here sends it through a stand-in, so there is none to share or to place: but an edge drawn
                // through one already is the edge, and a run again says so (`connect`).
                let placed = edge.placementWritten
                if edge.share != nil || placed != nil {
                    let drawn = boardConnections().filter { !deleted.contains($0.record.id) }
                    guard addressedMatches(from: from.id, to: to.id, bothHeads: edge.bothHeads, among: drawn, in: target.document,
                                           identity: identity).contains(where: { $0.standIn != nil }) else {
                        let kind = standInKinds.first
                        if edge.share == nil, let placed {
                            throw DrawError(statement, .invalidValue,
                                            "\(written): \(placed) places the \(kind ?? "stand-in") an edge goes through, and this one is drawn straight",
                                            hint: (kind.map { "write \(key): \($0) to put one there, or " } ?? "") + "leave \(placed) out")
                        }
                        let share = EdgeKey.share.rawValue
                        throw DrawError(statement, .invalidValue,
                                        "\(written): \(share): is for an edge that goes through \(kind.map(indefinite) ?? "a stand-in"), and this one is drawn straight",
                                        hint: (kind.map { "write \(key): \($0) to put one beside its start, or " } ?? "") + "leave \(share): out")
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
        let matches = addressedMatches(from: from.id, to: to.id, bothHeads: edge.bothHeads, among: drawn, in: target.document, identity: identity)
        if matches.contains(where: { $0.standIn != nil }) { return nil }

        // `via:` puts the stand-in for the end beside the start, which isn't on this board.
        if let via, case .away(let far) = from {
            throw severalBoards(said: fromName.said, on: far.board, statement, for: drawnTo,
                                hint: "\(key): puts \(indefinite(via)) for the edge's end beside its start, which is on another board: write the edge in a run that draws there, or leave \(key): out")
        }
        let nearPlace = stoodFor.other
        guard case .here(let nearID, let nearItem) = nearPlace == .from ? from : to else {
            throw DrawError(statement, .internal, "\(written) has no end on the board it's drawn on")
        }
        let nearName = nearPlace == .from ? fromName : toName, standName = stoodFor == .from ? fromName : toName

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
                // A stand-in at the end (a reference drawn by its query, named by its id) is stood for by none, being one.
                if let standIns, standIns.kinds.contains(standEnd.record.kind) {
                    throw DrawError(statement, .invalidValue,
                                    "\(written): \(key): \(via) can't stand for \(standName.said), \(indefinite(standEnd.record.kind)) that stands for others itself",
                                    hint: "leave \(key): out: an arrow into \(standName.said) is read as an arrow into what it stands for")
                }
                let needs = standIns?.needs(via)
                throw DrawError(statement, .invalidValue,
                                needs.map { "\(written): \(key): \(via) can't stand for \(standName.said): only \(indefinite($0)) shape can be stood for" }
                                          ?? "\(written): \(key): \(via) can't stand for \(standName.said)",
                                hint: (needs.map { "ask the user to make \(standName.said) \($0), or " } ?? "") + "leave \(key): out")
            }
            kind = via
        } else {
            guard Self.goesThroughStandIn(from: fromEnd, to: toEnd) else {
                throw severalBoards(said: standName.said, on: standEnd.board, statement, for: drawnTo)
            }
            guard let found = standInKind(for: standEnd.record) else {
                throw severalBoards(said: standName.said, on: standEnd.board, statement, for: drawnTo, hint: Self.standInHint(for: [standName.said], standIns))
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
                                         written: written, standName: standName, nearName: nearName, statement) {
            return NewStandIn(id: found.id, place: stoodFor, kind: kind, shared: true, sharedWith: found.host)
        }

        // An edge that says which of the pair's arrows it is (`is:`) and isn't drawn yet is one more
        // arrow between the same two shapes: it goes into the stand-in the near end's other arrows do
        // for this end, never another beside it (two relationships of Ann's with Acme are two arrows
        // into Ann's one pill for Acme). A statement that writes no identity key reaches none of this.
        if identity != nil, let found = hostStandIn(nearID, for: standEnd.record, kind: kind) {
            return NewStandIn(id: found, place: stoodFor, kind: kind, shared: true)
        }

        // Said by the edge's row alone (`via`), with `via:` or without: a warning for each edge between
        // boards would bury the warnings that need reading.
        // The pill is called what the shape is: its title, else what Mentions calls it (a note with none is called by its words
        // or its values), else its kind's name.
        let label = standName.title ?? farLabel(of: standEnd.record)
        let made = try addStandIn(kind, for: standEnd.record, called: label, said: standName.said, beside: nearID, item: nearItem, title: nearName.plain,
                                  nearIs: nearPlace, side: nearPlace == .from ? edge.fromSide : edge.toSide,
                                  placed: (edge.clauses, edge.container), seatedIn: container, statement)
        madeStandIns.append(MadeStandIn(id: made.id, stoodFor: standEnd.record.id, container: made.holder ?? container, kind: kind))
        return NewStandIn(id: made.id, place: stoodFor, kind: kind)
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

    /// Whether a stand-in, one this run made or one the board has, is of `kind` and stands for `end`.
    private func stands(_ pill: ShapeID, for end: ShapeID, kind: ShapeKind) -> Bool {
        standingFor(pill) == end && (madeStandIns.first { $0.id == pill }?.kind ?? target.document[pill]?.kind) == kind
    }

    /// The stand-in of `kind` for `end` that an arrow of `host` already runs into: of the run's own
    /// edges first (a stand-in one made or reused), then the board's (`StandInRoute.existing`).
    private mutating func hostStandIn(_ host: ShapeID, for end: AnyShapeRecord, kind: ShapeKind) -> ShapeID? {
        for other in edges {
            guard let standIn = other.standIn, standIn.kind == kind, (standIn.place == .from ? other.to : other.from) == host,
                  stands(standIn.id, for: end.id, kind: kind) else { continue }
            return standIn.id
        }
        guard let route else { return nil }
        return route.existing(for: end.id, kind: kind, sharing: .host(host), near: host, in: target.document, excluding: deleted,
                              index: standInIndex(route))
    }

    /// The stand-in `share` names, if there is one: for `share: true`, a direct stand-in of `kind` for the
    /// same end, in the same container as the end that stays, which the board has (the first) or an
    /// earlier edge of the run made; for `share: "A"`, the one A's own arrow goes into, A being in that
    /// container. Nil for `share: true` with none; a named host with none is refused.
    private mutating func sharedStandIn(_ share: EdgeShare, for end: AnyShapeRecord, kind: ShapeKind, near: (id: ShapeID, item: Int?),
                                        container: ShapeID?, written: String, standName: EndName, nearName: EndName,
                                        _ statement: Statement) throws(DrawError) -> (id: ShapeID, host: String?)? {
        let key = EdgeKey.share.rawValue
        switch share {
        case .any:
            if let route, let pill = route.existing(for: end.id, kind: kind, sharing: .any, container: container, in: target.document,
                                                    excluding: deleted, index: standInIndex(route)) {
                return (pill, nil)
            }
            if let made = madeStandIns.first(where: { $0.stoodFor == end.id && $0.kind == kind && $0.container == container }) {
                return (made.id, nil)
            }
            return nil
        case .beside(let host):
            var hostID: ShapeID?, hostItem: Int?
            // The host as a message calls it, and as the row (`sharedWith`) does.
            var hostSaid = "", hostPlain = ""
            switch host {
            case .path(let text):
                let path = try folded(text, statement)
                (hostSaid, hostPlain) = (path.written, path.last)
                switch try find(path: text, statement, for: "\(written): \(key): names") {
                case .item(let index)?:
                    hostID = items[index].record.id
                    hostItem = index
                case .shape(let record)?:
                    hostID = record.id
                case .board?, .view?, .origin?:
                    break
                case nil:
                    throw skip()
                }
            case .title(let text):
                let title = try folded(text, statement)
                (hostSaid, hostPlain) = (quoted(title), title)
                let drawn = itemsByTitle[title] ?? []
                if drawn.count > 1 { throw ambiguous(quoted(title), drawn.map(ShapeItem.Found.item), statement) }
                if let index = drawn.first {
                    hostID = items[index].record.id
                    hostItem = index
                } else if unresolved.contains(title) {
                    throw skip()
                } else if let record = try boardShape(called: title, statement) {
                    hostID = record.id
                }
                guard hostID != nil else { throw notFound(title, statement, for: "\(written): \(key): names", elsewhere: false) }
            case .id(let text):
                let id = try shapeID(text, statement), mark = host.written
                if let index = itemByID[id] {
                    (hostID, hostItem) = (id, index)
                    (hostSaid, hostPlain) = (items[index].title.map(quoted) ?? mark, items[index].title ?? mark)
                } else if unresolvedIDs.contains(id) {
                    throw skip()
                } else {
                    let shape = try fileShape(withID: id, written: mark, statement)
                    if isDeleted(id, on: shape.board) { throw deletedID(mark, statement, for: "\(written): \(key): names") }
                    guard shape.board == target.board else {
                        throw severalBoards(said: mark, on: shape.board, statement, for: "\(written): \(key): names")
                    }
                    hostID = id
                    let title = Drawing.title(of: shape.record, names: names, naming: naming, registry: registry)
                    (hostSaid, hostPlain) = (title.map(quoted) ?? mark, title ?? mark)
                }
            }
            guard let hostID else { throw DrawError(statement, .internal, "\(written): \(key): names no shape") }
            guard hostID != near.id else {
                throw DrawError(statement, .invalidValue, "\(written): \(key): \(hostSaid) is the edge's own end",
                                hint: "name another shape whose arrow goes into the reference, or write \(key): true")
            }
            guard containerOfEnd(hostID, item: hostItem) == container else {
                throw DrawError(statement, .invalidValue, "\(written): \(key): \(hostSaid) and \(nearName.said) aren't in the same container",
                                hint: "a reference is shared by shapes in one frame, or none: put them in the same one, or leave \(key): out")
            }
            // The host's arrows: those of the run (a reference it made or shared), then the board's.
            if let pill = hostStandIn(hostID, for: end, kind: kind) { return (pill, hostPlain) }
            throw DrawError(statement, .invalidValue, "\(written): \(key): \(hostSaid) has no \(kind) to \(standName.said) beside it",
                            hint: "draw an edge between \(hostSaid) and \(standName.said) above this line, in this run or an earlier one; or write \(key): true, or leave \(key): out")
        }
    }

    /// Adds a stand-in for `target`, called `label`, as a new shape of the run. Where its edge says
    /// where it goes (`placed`: the edge's placements and `in`), there, read and placed as a shape
    /// statement's are: kept to them, within what it's in, and pushed past what it lands on, the push
    /// said. Else beside the shape `near` (on the board, or the item of one the script draws): where
    /// `StandInRoute.spot` says, right of it where it's the start of the edge, left of it where it's
    /// the end, or on the side the edge names for it, at the end of the column of stand-ins a run
    /// before left there, kept clear of what's there, and giving way to what the script places; those
    /// beside one shape on one side are a list, `LayoutProblem.impliedListStep` apart. Either way it's
    /// put down in or out of the containers it lands on. Its id, and what holds it (`in "F"`, a frame).
    ///
    /// It's told where it sits (`StandIns.seat`: in the frame that holds it, at the top of the board an `in` names, else in
    /// `container`, the frame the shape beside it is in, else on the board), and shows where its shape is over the name, as a
    /// pick from the list does, however many shapes are called what its shape is: a pill made for one of two `index.ts` says
    /// which, and one for a title that is its shape's alone says where that is as well. Where its placements put it is a guess
    /// until it lands, as `share:`'s container is.
    private mutating func addStandIn(_ kind: ShapeKind, for target: AnyShapeRecord, called label: String, said: String, beside near: ShapeID, item: Int?,
                                     title nearTitle: String, nearIs place: EdgePlace, side: EdgeSide?,
                                     placed: (clauses: [Clause], container: ShapeName?), seatedIn container: ShapeID?,
                                     _ statement: Statement) throws(DrawError) -> (id: ShapeID, holder: ShapeID?) {
        guard let route, var record = route.standIns.make(kind, standingFor: target.id, label: label), record.box != nil else {
            throw DrawError(statement, .internal, "\(indefinite(kind)) couldn't be made to stand for \(said)")
        }
        // A program's run puts it exactly where it says, as a shape statement's shape (`DrawOptions.places`, by the edge's line).
        let exact = options.places[statement.line]
        if !placed.clauses.isEmpty || placed.container != nil || exact != nil {
            let size = record.box!.size
            var standIn = ShapeItem(statement: statement, shape: ShapeStatement(word: kind.rawValue, clauses: placed.clauses, container: placed.container),
                                    kind: kind, title: nil, existing: nil, record: record, size: size, room: size)
            standIn.standsFor = said
            standIn.exact = exact
            items.append(standIn)
            let index = items.count - 1
            try contain(index)
            // In the frame that holds it; `in` a subboard, at the top of its board; else beside the end, in its frame.
            let seat = items[index].holder?.id ?? (placed.container == nil ? container : nil)
            var seated = items[index].record
            route.standIns.seat(&seated, at: .file(container: seat, board: self.target.board), in: self.target.shapes)
            if let size = seated.box?.size {
                items[index].record = seated
                items[index].size = size
                items[index].room = size
            }
            try resolveTargets(index)
            return (record.id, items[index].holder?.id)
        }
        route.standIns.seat(&record, at: .file(container: container, board: self.target.board), in: self.target.shapes)
        let size = record.box!.size
        let found: ShapeItem.Found
        if let item {
            found = .item(item)
        } else if let nearRecord = self.target.document[near] {
            found = .shape(nearRecord)
        } else {
            throw DrawError(statement, .internal, "\(nearTitle) isn't on the board the reference is drawn on")
        }
        // Where a run before left a column of stand-ins there it goes next in it, a step past its end and
        // lined up with it as the list was; not beside a shape this run moves (it wouldn't be beside it
        // any more), nor past a stand-in it moves.
        let moves = item.map { items[$0].moves } ?? false
        let spot = route.spot(beside: near, edgeIs: place, side: side, in: self.target, excluding: deleted,
                              staying: { !moves && !self.movesWithRun($0) }, index: standInIndex(route))
        let end = spot.after.flatMap { self.target.document[$0] }
        let clauses = spot.clauses(near: nearTitle, after: end.map(standInName))
        let targets: [[ShapeItem.Found]] = end.map { end in clauses.map { _ in [.shape(end)] } } ?? [[found]]
        var standIn = ShapeItem(statement: statement, shape: ShapeStatement(word: kind.rawValue, clauses: clauses), kind: kind, title: nil,
                                existing: nil, record: record, size: size, room: size)
        standIn.targets = targets
        standIn.standsFor = said
        standIn.implied = true
        items.append(standIn)
        return (record.id, nil)
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
