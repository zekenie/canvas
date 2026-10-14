import Canvas
import CoreGraphics
import DrawScript
import Foundation
import Geometry
import Queries

// Applying a placed script, in one transaction: the deletes, the shapes (each after every script
// shape it's drawn inside or on, or in, new ones added on top, restated ones updated in place and
// raised above a shape they're moved inside or on, or a zone they sit in where they land; a
// container moved taking what it holds along); then the edges, through DrawEdges, against the board
// as the transaction has it (so an end may be new), before the shapes are put down so that what puts them
// down judges by a transaction that holds them (the room a shape takes can depend on an arrow, and
// `Drawing.layOut()` made the same arrows to give it); then, with every one where it goes, each put down as
// by hand, settled in or out of the containers it's over (`Transaction.settle`), those that hold no
// shapes first, then the containers. Then what it did, read from the transaction's
// document, and what it should say: each shape's issues (DrawChecks), the issues it brought to shapes it
// did not write (DrawBrought.swift), pushes, nudges, near misses, edges whose side faces away, shapes out of view. Anything wrong throws, and the transaction
// commits nothing.

extension Drawing {
    func apply(to transaction: inout Transaction, reveals: Bool) throws(DrawError) -> DrawResult {
        var changes: [DrawChange] = []
        var warnings = notes
        let before = target.shapes
        // The connections this run deletes, with where their rows are: a report may add members to these and warn.
        var goneRows: [(row: Int, line: Int, name: String, record: AnyShapeRecord, written: JSONObject?)] = []

        // Deletes, and what they took.
        if !deleted.isEmpty { transaction.delete(deleted) }
        if let kept = deleted.first(where: { transaction.document[$0] != nil }), let delete = deletes.first(where: { item in
            item.shape?.id == kept || item.connections.contains { $0.record.id == kept } || item.loose.contains { $0.id == kept }
        }) {
            throw DrawError(delete.statement, .readOnly, "something kept \(named(target.document[kept]!)) from being deleted",
                            hint: "leave it out of the script")
        }
        for delete in deletes {
            if let shape = delete.shape {
                let title = Drawing.title(of: shape, names: names, naming: naming, registry: registry)
                // Its id is said when the statement named it so: the shape is gone, and nothing else would say which it was.
                var row = DrawChange(line: delete.statement.line, did: .deleted, kind: shape.kind.rawValue, title: title)
                // Not a stand-in the delete left with no arrow, that the statement did not name.
                if case .delete(.shape(.id(let text))) = delete.statement.body, UUID(uuidString: text).map(ShapeID.init) == shape.id {
                    row.id = shape.id.description
                }
                changes.append(row)
                // What went with it, unasked: said, as a delete's connections are.
                if delete.boardShapes > 0 {
                    let more = delete.boards > 1 ? ", and \(delete.boards - 1) more under it" : ""
                    let what = delete.boardShapes == 1 ? "the shape on it is"
                        : "the \(delete.boardShapes) shapes on \(delete.boards > 1 ? "them" : "it") are"
                    warnings.append(DrawWarning(line: delete.statement.line,
                                                "\(title.map(quoted) ?? named(shape)) held a board\(more): \(what) deleted with it"))
                }
            }
            // The ends a `delete edge` wrote as ids, as written: a row calls such an end so, and says which shape it was.
            var writtenIDs: [ShapeID: String] = [:]
            if case .delete(.edges(let from, let to, _, _)) = delete.statement.body {
                for name in [from, to] { if case .id(let text) = name, let uuid = UUID(uuidString: text) { writtenIDs[ShapeID(uuid)] = name.written } }
            }
            for connection in delete.connections {
                let from = end(connection.from, in: before, written: writtenIDs), to = end(connection.to, in: before, written: writtenIDs)
                var row = DrawChange(line: delete.statement.line, did: .deleted, kind: connection.record.kind.rawValue, from: from.name, to: to.name)
                row.fromID = from.id?.description
                row.toID = to.id?.description
                row.via = (standIn(at: connection.from, in: before.document) ?? standIn(at: connection.to, in: before.document))?.kind.rawValue
                // Nothing written for a `delete edge` that names no identity (a pair's every arrow goes); `[:]` for the rest.
                var named = delete.shape != nil
                if case .delete(let statement) = delete.statement.body, statement.writesIdentity { named = true }
                goneRows.append((changes.count, delete.statement.line, "\(Keyword.delete.rawValue) \(Keyword.edge.rawValue) \(from.said) \(EdgeArrow.forward.rawValue) \(to.said)",
                                 connection.record, named ? [:] : nil))
                changes.append(row)
            }
            // One with an end left free joins no two shapes to name.
            for connection in delete.loose {
                changes.append(DrawChange(line: delete.statement.line, did: .deleted, kind: connection.kind.rawValue))
            }
        }

        // Shapes, each after what it's drawn inside or on, or in, so it paints above it: every one
        // where it goes first, then each put down as by hand, against the board as the run leaves
        // it, never against where another shape it moves was.
        let order = applyOrder()
        for index in order {
            let item = items[index]
            if let existing = item.existing {
                // Raised while it can be: before a change that locks it, or after one that unlocks
                // it. One read-only before and after is as it was (placing refused any real change
                // to it), and stays where it paints.
                if !transaction.isReadOnly(existing) {
                    raise(item, in: &transaction)
                    update(item, existing, in: &transaction)
                } else {
                    update(item, existing, in: &transaction)
                    if let now = transaction.document[existing.id], !transaction.isReadOnly(now) { raise(item, in: &transaction) }
                }
            } else {
                guard isNew(item.record.id, in: transaction) else {
                    throw DrawError(item.statement, .internal, "\(subject(of: item)) came out a shape already drawn")
                }
                transaction.insert(item.record)
                guard transaction.document[item.record.id] != nil else {
                    throw DrawError(item.statement, .internal, "\(subject(of: item)) couldn't go on the board")
                }
                raise(item, in: &transaction)
            }
        }
        // Edges, before the settle, so it judges by a transaction that holds them: an end gives its type's notes a
        // row, and the settle reads the notes at the size they will have (`Drawing.layOut()` made the same
        // arrows, laid in, to give `room`).
        var edgeRows: [(EdgeItem, Connected)] = []
        if let edging, let edgeKind, !edges.isEmpty {
            var drawn = Drawing.connections(in: transaction.document, kind: edgeKind, edging: edging, registry: registry)
            let place = Dictionary(drawn.enumerated().map { ($1.record.id, $0) }, uniquingKeysWith: { first, _ in first })
            // The connections that join each pair, either way: the board's, then the run's own as it makes them
            // (Topology holds neither of the run's), so the second of a pair is made apart from the first. The same
            // list `provisionalConnections()` keeps (there by the arrows it lays out), so the arrow laid out is the
            // arrow drawn.
            var pairs = Drawing.pairArrows(of: drawn)
            for edge in edges {
                let row = try connect(edge, among: drawn, beside: pairs, edging: edging, kind: edgeKind, in: &transaction)
                if row.did == .connected { pairs[[row.ends.from, row.ends.to], default: []].append(row.record.id) }
                edgeRows.append((edge, row))
                // An arrow a statement changed is the arrow the next statement finds: a plain one that took
                // a type is no longer the pair's plain arrow, so a second typed statement draws its own
                // (`provisionalConnections()` does the same).
                if row.did == .reconnected, let index = place[row.record.id], let ends = edging.ends(row.record, registry) {
                    drawn[index] = BoardConnection(record: row.record, from: ends.from, to: ends.to)
                }
            }
        }
        // Put down: new, moved by a placement, or resized where it is; once there's a container on
        // the board to put them in or out of (settling looks at the whole board, so a board without
        // one isn't looked at for each). The shapes that hold none go down first, each into the
        // container it lands in, then the containers, each taking in what it lands on, so what's
        // put down in one goes along if it's nudged.
        var nudges: [ShapeID: CGPoint] = [:]
        if !registry.containingKinds.isEmpty, transaction.document.shapes.contains(where: registry.isContainer) {
            let holding = order.filter { registry.isContainer(items[$0].record) }
            for index in order.filter({ !registry.isContainer(items[$0].record) }) + holding {
                let item = items[index]
                if let existing = item.existing, !item.moves, item.record.box?.size == existing.box?.size { continue }
                try settle(item, in: &transaction, nudges: &nudges, warnings: &warnings)
            }
        }

        // What it did, and what it should say, read from one context taken once every write is done (a context
        // is a snapshot, and anything worked out over one is worked out again for the next).
        let shapes = transaction.shapes
        var changed: [(line: Int, name: String, record: AnyShapeRecord)] = []
        // Each row a plugin may report on: where it is in `changes`, the shape, what its statement wrote.
        var reported: [(row: Int, line: Int, name: String, record: AnyShapeRecord, written: JSONObject?, bothHeads: Bool)] = []
        var outside = 0
        for item in items {
            guard let now = transaction.document[item.record.id] else {
                throw DrawError(item.statement, .internal, "\(subject(of: item)) isn't on the board after all")
            }
            // Where it is and how much room it takes once the run has committed: its origin as the
            // transaction leaves it, at the size the layout gave it (`ShapeItem.room`), which is what
            // `canvas measure` says of the statement.
            let at = now.box.map { CGRect(origin: $0.origin, size: item.room) }
            var row = DrawChange(line: item.statement.line, did: .created, kind: item.kind.rawValue,
                                 title: naming?.name(now, registry), id: now.id.description, at: at)
            if let existing = item.existing {
                if item.rename != nil {
                    row.did = .renamed
                    row.was = item.title
                } else if now.box != existing.box {
                    row.did = .moved
                } else if now != existing {
                    row.did = .updated
                } else {
                    row.did = .unchanged
                }
            } else if let nearMiss = item.nearMiss, let title = item.title {
                warnings.append(DrawWarning(line: item.statement.line,
                                            "created \(quoted(title)); the board has \(quoted(nearMiss)) — to change that one, write its title exactly"))
            }
            if let view, let at {
                row.inView = view.intersects(at)
                if !view.intersects(at), item.free != nil, row.did != .unchanged { outside += 1 }
            }
            if !item.pushedPast.isEmpty { row.pushedPast = item.pushedPast }
            if row.did != .unchanged { changed.append((item.statement.line, subject(of: item), now)) }
            reported.append((changes.count, item.statement.line, subject(of: item), now, row.did == .unchanged ? nil : item.written, false))
            changes.append(row)
        }
        for (edge, connected) in edgeRows {
            let record = connected.record
            var row = DrawChange(line: edge.statement.line, did: connected.did, kind: record.kind.rawValue, from: edge.fromName.plain, to: edge.toName.plain)
            // An end the statement named by id says which shape that was.
            row.fromID = edge.fromName.id?.description
            row.toID = edge.toName.id?.description
            row.via = connected.via?.rawValue
            if connected.shared { row.shared = true }
            row.sharedWith = connected.sharedWith
            let properties = record.propertiesJSON ?? [:]
            for key in edging?.attributes ?? [] {
                if let value = properties[key], value != .null { row.attributes[key] = value }
            }
            let edgeName = "\(Keyword.edge.rawValue) \(edge.edge.written)"
            reported.append((changes.count, edge.statement.line, edgeName, record,
                             connected.did == .unchanged ? nil : edge.settings.filter { registry.drawValueWriters[$0.key] != nil }, edge.edge.bothHeads))
            changes.append(row)
            if connected.did != .unchanged { changed.append((edge.statement.line, edgeName, record)) }
            warnings += facingAway(edge, ends: connected.ends, in: shapes)
        }

        // What it should say.
        for item in items {
            guard let now = transaction.document[item.record.id] else { continue }
            warnings += namingWarnings(of: now, item, in: transaction)
        }
        // What each shape's row says it still has to fix, for a warning not to say it again.
        var rowsSay: [ShapeID: Set<String>] = [:]
        if let reporting = registry.drawReporting {
            let declared = Set(reporting.members)
            for shape in reported {
                let report = reporting.report(shape.record, shape.written, shapes, shape.bothHeads)
                if !report.problems.isEmpty {
                    changes[shape.row].problems = report.problems
                    rowsSay[shape.record.id, default: []].formUnion(report.problems.map(\.message))
                }
                changes[shape.row].members = report.members.filter { declared.contains($0.key) }
                for issue in report.warnings {
                    warnings.append(DrawWarning(line: shape.line, shape.name, issue: issue))
                }
            }
            // A deleted connection is a record the transaction no longer has: its members and warnings, no problems.
            for gone in goneRows {
                let report = reporting.report(gone.record, gone.written, shapes, false)
                changes[gone.row].members = report.members.filter { declared.contains($0.key) }
                for issue in report.warnings {
                    warnings.append(DrawWarning(line: gone.line, gone.name, issue: issue))
                }
            }
        }
        for (line, name, record) in changed {
            // What the shape still needs is no warning of a shape the run wrote: its row's `problems` say it.
            for issue in issues(of: record, in: shapes) where !issue.isIncomplete {
                warnings.append(DrawWarning(line: line, name, issue: issue))
            }
        }
        // And every issue the run brought to a shape it did not write (DrawBrought.swift).
        // A shape a statement restated as it is has a row too: what its `problems` say it still needs is not said again.
        warnings += brought(by: transaction, before: before, after: shapes, written: changed.map { ($0.line, $0.record.id) },
                            restated: rowsSay)
        if outside > 0, !reveals {
            warnings.append(DrawWarning(line: nil, "\(outside) \(outside == 1 ? "shape" : "shapes") landed outside the view — --reveal brings them into view"))
        }

        let rows = changes.enumerated().sorted { ($0.element.line, $0.offset) < ($1.element.line, $1.offset) }.map(\.element)
        let said = warnings.enumerated().sorted { ($0.element.line ?? .max, $0.offset) < ($1.element.line ?? .max, $1.offset) }.map(\.element)
        return DrawResult(changes: rows, warnings: said, nudges: nudges)
    }

    /// A restated shape as the statement leaves it: what it says, and where it's placed. A
    /// container placed elsewhere takes what it holds along (`translate`), while it can move: after a
    /// change that unlocks it, before one that locks it. A shape that isn't placed stays where it is
    /// now (a container this run moved may have taken it along), at its size.
    private func update(_ item: ShapeItem, _ existing: AnyShapeRecord, in transaction: inout Transaction) {
        guard let now = transaction.document[existing.id] else { return }
        var record = item.record
        if !item.moves, let at = now.box?.origin { record.box?.origin = at }
        guard item.moves, registry.isContainer(existing), let from = now.box?.origin, let to = record.box?.origin, from != to else {
            if record != now { transaction.update(existing.id) { $0 = record } }
            return
        }
        if transaction.isReadOnly(now) {
            var staying = record
            staying.box?.origin = from
            transaction.update(existing.id) { $0 = staying }
        }
        transaction.translate([existing.id], by: to - from)
        if let moved = transaction.document[existing.id], moved != record { transaction.update(existing.id) { $0 = record } }
    }

    /// Puts a shape down as a person would (`Transaction.settle`): into the container holding most
    /// of it, nudged wholly in over its edge, or out of those it reaches into, which is said, and what
    /// it nudged kept for the glide. A container put down takes in what it lands on, and what it holds
    /// over its edge goes wholly in or out: said too, as what moved that the script didn't name. A
    /// read-only container (a locked frame) takes nothing: the run is refused.
    private func settle(_ item: ShapeItem, in transaction: inout Transaction, nudges: inout [ShapeID: CGPoint],
                        warnings: inout [DrawWarning]) throws(DrawError) {
        guard !registry.containingKinds.isEmpty else { return }
        let id = item.record.id
        let before = transaction.document[id]?.box.map { CGRect(origin: $0.origin, size: item.room) }
        switch transaction.settle([id]) {
        case .refused(let container):
            let named = transaction.document[container].map { self.named($0) } ?? "a container"
            // A stand-in has no placement of its own to change: where it goes is the side of what it's beside.
            let clear = item.standsFor == nil ? "place it clear of \(named)"
                : "name another side for it with \(EdgeKey.from.rawValue): or \(EdgeKey.to.rawValue): to put it clear of \(named)"
            throw DrawError(item.statement, .readOnly, "\(subject(of: item)) would go in \(named), which is read-only (locked, say)",
                            hint: "\(clear), or ask the user to unlock it")
        case .settled(let moved):
            for (shape, delta) in moved { nudges[shape] = (nudges[shape] ?? .zero) + delta }
            let own = moved[id] ?? .zero
            // What else moved: not what it took along (by as much as it went), but what it took in or
            // let out across its edge.
            let others = moved.filter { $0.key != id && $0.value != own }.count
            if others > 0 {
                warnings.append(DrawWarning(line: item.statement.line,
                                            "\(others == 1 ? "a shape" : "\(others) shapes") over the edge of \(subject(of: item)) \(others == 1 ? "was" : "were") nudged wholly in or out of it"))
            }
            guard let before, own != .zero, let after = transaction.document[id]?.box.map({ CGRect(origin: $0.origin, size: item.room) }) else { return }
            // Said of each container whose edge it was over as it was put down.
            for container in transaction.document.shapes where container.id != id && registry.isContainer(container) {
                guard let edge = container.box, Self.overlaps(before, edge), !before.contains(edge), !edge.contains(before) else { continue }
                let way = edge.contains(after) ? "in" : "out"
                warnings.append(DrawWarning(line: item.statement.line,
                                            "\(subject(of: item)) was over the edge of \(self.named(container)), so it was nudged \(way)"))
            }
        }
    }

    /// An edge as drawn: the connection, what was done to it, the shapes it joins as the edge is written
    /// (a stand-in at an end that's stood for), and the kind of stand-in it goes through, if it does.
    struct Connected {
        let record: AnyShapeRecord
        let did: DrawChange.Did
        let ends: (from: ShapeID, to: ShapeID)
        let via: ShapeKind?
        /// It runs to a stand-in shared with another edge (`share:`), and beside whom, if it was named.
        var shared = false
        var sharedWith: String?
    }

    /// The arrow an edge statement makes: the connection as it will stand, found and changed as the statement
    /// says, or new. It only reads: what `connect` puts in the transaction, and what `layOut()` lays in beforehand
    /// (`Drawing.provisionalConnections()`), so the two are one function. `matches` are the pair's arrows the
    /// statement addresses; `document` holds the ends (the transaction's, or the ends alone) and `shapes` is a
    /// context over it. `pairs` names the connections that join each pair of shapes: a new arrow between a pair is
    /// made beside them (`EdgeRequest.beside`), which the maker reads from `document`, so it holds them (the
    /// transaction's does; the ends alone are given them), and the two callers hold the same ones.
    func connection(for edge: EdgeItem, matches: [EdgeMatch], beside pairs: [Set<ShapeID>: [ShapeID]], edging: DrawEdging,
                    kind: ShapeKind, in document: CanvasDocument, shapes: ShapeContext) throws(DrawError) -> (record: AnyShapeRecord, ends: (from: ShapeID, to: ShapeID), reversed: Bool) {
        let statement = edge.statement, written = "\(Keyword.edge.rawValue) \(edge.edge.written)"
        let arrow = edge.edge.bothHeads ? EdgeArrow.both.rawValue : EdgeArrow.forward.rawValue
        let pair = "\(edge.fromName.said) \(arrow) \(edge.toName.said)"
        guard matches.count < 2 else {
            let vocabulary = KindVocabulary(kind, in: registry)
            let keys = edging.identity.filter(vocabulary.isAttribute).map { "\($0):" }
            let hint: String
            if let identity = edge.identity {
                let said = edge.edge.attributes.filter { identity.written[$0.key] != nil }.map { "\($0.key): \($0.value.written)" }
                hint = "write delete edge \(([pair] + said).joined(separator: " ")) above this line to replace them"
            } else if keys.isEmpty {
                hint = "write delete edge \(pair) above this line to replace them"
            } else {
                hint = "write \(keys.joined(separator: " or ")) to say which, or delete edge \(pair) above this line to replace them"
            }
            throw DrawError(statement, .ambiguousEdge, "\(pair) is drawn \(matches.count) times", hint: hint)
        }
        let match = matches.first
        // `via:` says what the edge goes through, which an arrow drawn another way isn't: it's drawn,
        // and left as it is, for the person to say if it should go.
        if let via = edge.edge.via, let match, match.standIn?.place != .to {
            let how = match.standIn.map { "through \(indefinite($0.kind)) to \(edge.fromName.said)" } ?? "straight to \(edge.toName.said)"
            throw DrawError(statement, .invalidValue, "the edge \(pair) is drawn \(how)",
                            hint: "write delete edge \(pair) above this line to draw it through \(indefinite(via))")
        }
        guard match == nil || edge.standIn == nil else {
            throw DrawError(statement, .internal, "\(written) came out drawn already, with a stand-in made for it")
        }
        // The shapes it joins, as drawn or as it's to be.
        let ends = match.map { ($0.connection.from, $0.connection.to) } ?? edge.bound
        guard document[ends.0] != nil, document[ends.1] != nil else {
            throw DrawError(statement, .internal, "\(written) came out joining a shape that isn't on the board")
        }
        func side(_ side: EdgeSide?) -> EdgeRequest.Side? { side.flatMap { EdgeRequest.Side(rawValue: $0.rawValue) } }
        // Asked the way the edge is drawn, when `<->` finds one drawn the other way.
        let reversed = match?.reversed ?? false
        var request = EdgeRequest(from: ends.0, to: ends.1, fromSide: side(edge.edge.fromSide), toSide: side(edge.edge.toSide),
                                  bothHeads: edge.edge.bothHeads, attributes: edge.attributes, fromName: edge.fromName.said,
                                  toName: edge.toName.said, written: edge.edge.written,
                                  fromStandsFor: standsFor(ends.0, in: document), toStandsFor: standsFor(ends.1, in: document),
                                  beside: pairs[[ends.0, ends.1]] ?? [])
        if reversed {
            swap(&request.fromSide, &request.toSide)
            swap(&request.fromName, &request.toName)
        }
        func make(changing existing: AnyShapeRecord?) throws(DrawError) -> AnyShapeRecord {
            do throws(DrawError) {
                return try edging.make(request, existing, shapes)
            } catch {
                throw DrawError(error.message, reason: error.reason, hint: error.hint,
                                line: statement.line, statement: statement.text)
            }
        }
        var made = try make(changing: match?.connection.record)
        guard made.kind == kind else {
            throw DrawError(statement, .internal, "\(written) came out \(indefinite(made.kind)), not \(indefinite(kind))")
        }
        // The kind's own attributes it writes (an arrow's text), set as a shape's are. What the edge
        // says as written (its heads, by its arrow) has the last word: made again, the connection
        // keeps every one of them, or one says otherwise.
        // An arrow found by what the statement writes of its identity is that already, by meaning (a
        // list of the same ids in another order): it isn't written again.
        var edgeSettings = edge.settings
        if let identity = edge.identity, let held = match?.connection.record, identity.matches(held) {
            for key in identity.written.keys { edgeSettings[key] = nil }
        }
        if !edgeSettings.isEmpty {
            // A value a property's writer joins with what the arrow holds (the connection as the maker left it).
            var settings = edgeSettings
            for (key, written) in edgeSettings {
                if let writer = registry.drawValueWriters[key] { settings[key] = writer.merge(written, made.propertiesJSON?[key]) }
            }
            do throws(ShapePropertiesError) {
                made = try registry.shape(made, setting: settings)
            } catch {
                throw DrawError(statement, .invalidValue, "\(written) can't have those attributes: \(error)")
            }
            let again = try make(changing: made).propertiesJSON ?? [:], set = made.propertiesJSON ?? [:]
            if let key = edgeSettings.keys.sorted().first(where: { again[$0] != set[$0] }) {
                let value = edge.edge.attributes.first { $0.key == key }?.value.written ?? ""
                throw DrawError(statement, .invalidValue, "\(written): \(key): \(value) isn't what the edge as written says",
                                hint: "leave \(key): out; how the edge is written (its arrow, its sides) says it")
            }
        }
        // What it's bound to is on the board as the script leaves it: nothing would ever let go of one that isn't.
        guard made.boundShapes(in: shapes).allSatisfy({ document[$0] != nil }) else {
            throw DrawError(statement, .internal, "\(written) came out bound to a shape that isn't on the board")
        }
        return (made, ends, reversed)
    }

    /// Draws one edge, or changes the one drawn (only what the statement names), or leaves it be. The
    /// one drawn is any that's the edge: straight between its ends, or between one of them and a
    /// stand-in for the other (`edgeMatches`); the edge not drawn yet is made between its ends, or, if
    /// the run made a stand-in for it, between that and the end that stays.
    private func connect(_ edge: EdgeItem, among drawn: [BoardConnection], beside pairs: [Set<ShapeID>: [ShapeID]], edging: DrawEdging,
                         kind: ShapeKind, in transaction: inout Transaction) throws(DrawError) -> Connected {
        let statement = edge.statement, written = "\(Keyword.edge.rawValue) \(edge.edge.written)"
        let document = transaction.document
        // The pair's arrows, and of them those the statement is about: all, if it writes no identity;
        // else those that hold what it writes, or, when none does, the pair's one plain arrow (which
        // takes it), or none (a new arrow).
        let matches = addressedMatches(from: edge.from, to: edge.to, bothHeads: edge.edge.bothHeads, among: drawn, in: document, identity: edge.identity)
        let (made, ends, reversed) = try connection(for: edge, matches: matches, beside: pairs, edging: edging, kind: kind, in: document,
                                                      shapes: transaction.shapes)
        let match = matches.first
        #if DEBUG
        // The arrow `layOut()` laid in is this one but for its id: a room that disagreed with the board would be a bug.
        if let provisional = edge.provisional, match == nil {
            assert(provisional.kind == made.kind && provisional.propertiesJSON == made.propertiesJSON
                   && provisional.boundShapes(in: transaction.shapes) == made.boundShapes(in: transaction.shapes),
                   "\(written) was laid out as another arrow than the one drawn")
        }
        #endif
        let through = (standIn(at: ends.0, in: document) ?? standIn(at: ends.1, in: document))?.kind
        let joined = reversed ? (from: ends.1, to: ends.0) : (from: ends.0, to: ends.1)
        let sharing = sharing(of: edge, match: match, among: drawn)
        if let existing = match?.connection.record {
            guard made.id == existing.id else { throw DrawError(statement, .internal, "\(written) came out another shape") }
            if made == existing { return Connected(record: existing, did: .unchanged, ends: joined, via: through, shared: sharing.shared, sharedWith: sharing.with) }
            if transaction.isReadOnly(existing), transaction.isReadOnly(made) {
                throw DrawError(statement, .readOnly, "\(written) is read-only (locked, say), so it stays as it is",
                                hint: "leave it out of the script, or ask the user to unlock it")
            }
            transaction.update(existing.id) { $0 = made }
            return Connected(record: transaction.document[existing.id] ?? made, did: .reconnected, ends: joined, via: through,
                             shared: sharing.shared, sharedWith: sharing.with)
        }
        guard isNew(made.id, in: transaction) else { throw DrawError(statement, .internal, "\(written) came out a shape already drawn") }
        // A board that can't change (a locked subboard's, at any depth) takes no new edge.
        guard !transaction.isBoardReadOnly else {
            throw DrawError(statement, .readOnly, "\(written) would go on \(boardName), which is read-only (locked, say)",
                            hint: "leave it out of the script, or ask the user to unlock what holds the board")
        }
        transaction.insert(made)
        guard let inserted = transaction.document[made.id] else { throw DrawError(statement, .internal, "\(written) couldn't go on the board") }
        return Connected(record: inserted, did: .connected, ends: joined, via: through, shared: sharing.shared, sharedWith: sharing.with)
    }

    /// The connections that join each pair of shapes, either way.
    static func pairArrows(of drawn: [BoardConnection]) -> [Set<ShapeID>: [ShapeID]] {
        var pairs: [Set<ShapeID>: [ShapeID]] = [:]
        for connection in drawn { pairs[[connection.from, connection.to], default: []].append(connection.record.id) }
        return pairs
    }

    /// Whether an edge's arrow runs to a stand-in shared with another (`share:`), and beside whom, if the
    /// edge named a host. A stand-in the run reused says so; for an edge drawn already (a run again) the
    /// stand-in it is drawn to is shared when an arrow from another shape runs to it too, and beside the
    /// host when the host's does.
    private func sharing(of edge: EdgeItem, match: EdgeMatch?, among drawn: [BoardConnection]) -> (shared: Bool, with: String?) {
        if let made = edge.standIn { return (made.shared, made.sharedWith) }
        guard let share = edge.edge.share, let match, let pill = match.standIn?.id else { return (false, nil) }
        let near = match.standIn?.place == .from ? edge.to : edge.from
        let users = drawn.compactMap { connection -> ShapeID? in
            guard connection.record.id != match.connection.record.id, connection.from == pill || connection.to == pill else { return nil }
            return connection.from == pill ? connection.to : connection.from
        }.filter { $0 != near }
        switch share {
        case .any:
            return (!users.isEmpty, nil)
        case .beside(.title(let written)):
            guard let title = fold(written), boardShapes(called: title).contains(where: users.contains) else { return (false, nil) }
            return (true, title)
        case .beside(.id(let text)):
            guard let uuid = UUID(uuidString: text), users.contains(ShapeID(uuid)) else { return (false, nil) }
            let host = target.document[ShapeID(uuid)].flatMap { Drawing.title(of: $0, names: names, naming: naming, registry: registry) }
            return (true, host ?? ShapeName.id(text).written)
        }
    }

    /// The script's shapes in script order, but each after every script shape (new or restated)
    /// it's drawn inside or on, or in, so that shape is added, or raised, before it's put above it;
    /// and each restated shape after the containers holding it the script restates, so one that moves
    /// takes it along before it's put where it says.
    func applyOrder() -> [Int] {
        let kinds = registry.containingKinds, document = target.document
        var restated: [ShapeID: Int] = [:]
        for index in items.indices { if let id = items[index].existing?.id { restated[id] = index } }
        var after: [Set<Int>] = items.indices.map { index in
            var needs: Set<Int> = []
            for (clause, found) in zip(items[index].shape.clauses, items[index].targets) where clause.relation == .inside || clause.relation == .on {
                for target in found {
                    if case .item(let other) = target, other != index { needs.insert(other) }
                }
            }
            if let holder = items[index].holder, let other = restated[holder.id], other != index { needs.insert(other) }
            if !kinds.isEmpty, let existing = items[index].existing {
                for container in document.containers(of: existing.id, containingKinds: kinds) {
                    if let other = restated[container], other != index { needs.insert(other) }
                }
            }
            return needs
        }
        var order: [Int] = []
        var done = Array(repeating: false, count: items.count)
        while order.count < items.count {
            // The first in script order with all it needs in; failing that (a loop), the first left.
            let next = items.indices.first { !done[$0] && after[$0].allSatisfy { done[$0] } } ?? items.indices.first { !done[$0] }!
            done[next] = true
            order.append(next)
            after[next] = []
        }
        return order
    }

    /// Puts a shape just above each shape it's drawn inside or on, and each zone it sits in where
    /// it lands, that paints above it: a restated shape moved into a zone that was drawn after it,
    /// or within one, would otherwise be hidden under it.
    private func raise(_ item: ShapeItem, in transaction: inout Transaction) {
        let id = item.record.id
        var under = item.zones
        for (clause, found) in zip(item.shape.clauses, item.targets) where clause.relation == .inside || clause.relation == .on {
            for target in found {
                switch target {
                case .item(let other): under.append(items[other].record.id)
                case .shape(let record): under.append(record.id)
                case .board, .view: continue
                }
            }
        }
        for above in under {
            guard let mine = transaction.document.index(of: id), let theirs = transaction.document.index(of: above), theirs > mine else { continue }
            transaction.move(id, above: above)
        }
    }

    /// Whether a shape can go in with this id: it's on no board of the file, but one this run
    /// deleted from this board (as a transaction takes it). Ids are unique across the file.
    private func isNew(_ id: ShapeID, in transaction: Transaction) -> Bool {
        guard transaction.document[id] == nil else { return false }
        guard let board = editor.file.board(containing: id) else { return true }
        return board == target.board && deleted.contains(id)
    }

    /// What a shape drawn names (`ShapeNaming`: a mention in a note's text) that isn't in the file
    /// as the run leaves it, or is on a board this app can't show: it's drawn anyway, and goes on
    /// naming them, which show as missing. A name of a shape on another board of the file names a
    /// shape that's there. Of a shape restated, only what the statement changed, so a script run
    /// again says nothing new.
    private func namingWarnings(of record: AnyShapeRecord, _ item: ShapeItem, in transaction: Transaction) -> [DrawWarning] {
        guard registry.namingKinds.contains(record.kind) else { return [] }
        let file = editor.file, written = Set(item.shape.attributes.map(\.key))
        let before = item.existing.flatMap(\.propertiesJSON), after = item.existing == nil ? nil : record.propertiesJSON
        // The boards this run takes with the shapes it deletes.
        let taken = Set(file.subtree(ownedBy: deleted))
        var said: [DrawWarning] = []
        record.forEachNamingValue(in: registry) { property, value in
            guard item.existing == nil || (written.contains(property) && before?[property] != after?[property]) else { return }
            var gone: [ShapeID] = [], hidden: [ShapeID] = []
            value.forEachNamedShape { id in
                guard transaction.document[id] == nil, !gone.contains(id), !hidden.contains(id) else { return }
                guard let board = file.board(containing: id), board != target.board, !taken.contains(board) else { return gone.append(id) }
                if editor.shape(inFile: id) == nil { hidden.append(id) }
            }
            // Ids, though a script never writes one: these are what it wrote into the value.
            for (ids, why) in [(gone, "that aren't in the file"), (hidden, "on boards this app can't show")] where !ids.isEmpty {
                said.append(DrawWarning(line: item.statement.line,
                                        "\(subject(of: item)): \(property) names shapes \(why): \(ids.map(\.description).joined(separator: ", ")); they show as missing",
                                        attribute: property))
            }
        }
        return said
    }

    /// What's wrong with a shape drawn: DrawChecks' issues, or without it, where it breaks its
    /// kind's schema.
    private func issues(of record: AnyShapeRecord, in shapes: ShapeContext) -> [DrawIssue] {
        if let check = registry.drawCheck { return check.check(record, shapes) }
        return registry.schemaViolations(of: record).map { DrawIssue($0.message, field: $0.property) }
    }

    /// A deleted connection's end, as a row names it: a stand-in by what it stands for, the shape the
    /// edge was written to. By its title; with none, by the id the statement wrote (`written`, with `id` the shape's), else
    /// by where it is. `said` is the same for a message.
    private func end(_ id: ShapeID, in shapes: ShapeContext, written: [ShapeID: String]) -> (name: String, said: String, id: ShapeID?) {
        guard var record = shapes.shape(id) else { return ("a shape", quoted("a shape"), nil) }
        if standIn(at: id, in: shapes.document) != nil, let stoodFor = standsForShape(id, in: shapes.document) { record = stoodFor }
        let mark = written[record.id]
        if let title = Drawing.title(of: record, names: names, naming: naming, registry: registry) {
            return (title, quoted(title), mark == nil ? nil : record.id)
        }
        if let mark { return (mark, mark, record.id) }
        let place = Drawing.location(of: record, in: shapes)
        return (place, quoted(place), nil)
    }

    /// A side an edge names that faces away from the other end: the line still leaves (or arrives
    /// on) the side that faces it (as tldraw clips an arrow at its shape's outline). The ends are the
    /// shapes the arrow joins, as the edge is written: a stand-in where an end is stood for.
    private func facingAway(_ edge: EdgeItem, ends: (from: ShapeID, to: ShapeID), in shapes: ShapeContext) -> [DrawWarning] {
        guard let a = shapes.bounds(of: [ends.from]), let b = shapes.bounds(of: [ends.to]), ends.from != ends.to else { return [] }
        func anchor(_ rect: CGRect, _ side: EdgeSide?) -> CGPoint {
            switch side {
            case .top?: CGPoint(x: rect.midX, y: rect.minY)
            case .right?: CGPoint(x: rect.maxX, y: rect.midY)
            case .bottom?: CGPoint(x: rect.midX, y: rect.maxY)
            case .left?: CGPoint(x: rect.minX, y: rect.midY)
            case nil: CGPoint(x: rect.midX, y: rect.midY)
            }
        }
        var said: [DrawWarning] = []
        for (key, side, mine, other, me, them) in [(EdgeKey.from, edge.edge.fromSide, a, anchor(b, edge.edge.toSide), edge.fromName.said, edge.toName.said),
                                                   (EdgeKey.to, edge.edge.toSide, b, anchor(a, edge.edge.fromSide), edge.toName.said, edge.fromName.said)] {
            guard let side else { continue }
            let away = switch side {
            case .left: other.x > mine.minX
            case .right: other.x < mine.maxX
            case .top: other.y > mine.minY
            case .bottom: other.y < mine.maxY
            }
            guard away else { continue }
            let dx = (other.x - mine.midX) / max(mine.width / 2, 1e-9), dy = (other.y - mine.midY) / max(mine.height / 2, 1e-9)
            let (relation, facing): (String, EdgeSide) = abs(dx) >= abs(dy) ? (dx >= 0 ? ("right of", .right) : ("left of", .left))
                : (dy >= 0 ? ("below", .bottom) : ("above", .top))
            guard facing != side else { continue }
            let does = key == .from ? "leaves \(me) by" : "arrives at \(me) on"
            said.append(DrawWarning(line: edge.statement.line,
                                    "\(key.rawValue): \(side.rawValue): \(them) is \(relation) \(me), so the line \(does) its \(facing.rawValue) side — name a side that faces \(them), or leave \(key.rawValue): out"))
        }
        return said
    }
}
