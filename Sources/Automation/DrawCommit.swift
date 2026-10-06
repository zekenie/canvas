import Canvas
import CanvasRPC
import CoreGraphics
import DrawScript
import Geometry

// Applying a placed script, in one transaction: the deletes, the shapes (each after every script
// shape it's drawn inside or on, or in, new ones added on top, restated ones updated in place and
// raised above a shape they're moved inside or on, or a zone they sit in where they land; a
// container moved taking what it holds along), each put down as by hand, settled in or out of the
// containers it's over (`Transaction.settle`), then the edges, through DrawEdges, against the board
// as the transaction has it (so an end may be new). Then what it did, read from the transaction's
// document, and what it should say: each shape's issues (DrawChecks), pushes, nudges, near misses,
// edges whose side faces away, shapes out of view. Anything wrong throws, and the transaction
// commits nothing.

extension Drawing {
    func apply(to transaction: inout Transaction, reveals: Bool) throws(AutomationError) -> DrawResult {
        var changes: [DrawChange] = []
        var warnings = notes
        let before = target.shapes

        // Deletes, and what they took.
        if !deleted.isEmpty { transaction.delete(deleted) }
        if let kept = deleted.first(where: { transaction.document[$0] != nil }), let delete = deletes.first(where: { item in
            item.shape?.id == kept || item.connections.contains { $0.record.id == kept } || item.loose.contains { $0.id == kept }
        }) {
            throw AutomationError(delete.statement, .readOnly, "something kept \(named(target.document[kept]!)) from being deleted",
                                  hint: "leave it out of the script")
        }
        for delete in deletes {
            if let shape = delete.shape {
                let title = Drawing.title(of: shape, names: names, naming: naming, registry: registry)
                changes.append(DrawChange(line: delete.statement.line, did: .deleted, kind: shape.kind.rawValue, title: title))
                // What went with it, unasked: said, as a delete's connections are.
                if delete.boardShapes > 0 {
                    let more = delete.boards > 1 ? ", and \(delete.boards - 1) more under it" : ""
                    let what = delete.boardShapes == 1 ? "the shape on it is"
                        : "the \(delete.boardShapes) shapes on \(delete.boards > 1 ? "them" : "it") are"
                    warnings.append(DrawWarning(line: delete.statement.line,
                                                "\(title.map(quoted) ?? named(shape)) held a board\(more): \(what) deleted with it"))
                }
            }
            for connection in delete.connections {
                changes.append(DrawChange(line: delete.statement.line, did: .deleted, kind: connection.record.kind.rawValue,
                                          from: end(connection.from, in: before), to: end(connection.to, in: before)))
            }
            // One with an end left free joins no two shapes to name.
            for connection in delete.loose {
                changes.append(DrawChange(line: delete.statement.line, did: .deleted, kind: connection.kind.rawValue))
            }
        }

        // Shapes, each after what it's drawn inside or on, or in, so it paints above it; each put
        // down as by hand, once there's a container on the board to put it down in or out of
        // (settling looks at the whole board, so a board without one isn't looked at for each).
        var nudges: [ShapeID: CGPoint] = [:]
        var settles = !registry.containingKinds.isEmpty && transaction.document.shapes.contains(where: registry.isContainer)
        for index in applyOrder() {
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
                // Put down again: moved by a placement, or resized where it is.
                if settles, item.moves || item.record.box?.size != existing.box?.size {
                    try settle(item, in: &transaction, nudges: &nudges, warnings: &warnings)
                }
            } else {
                guard isNew(item.record.id, in: transaction) else {
                    throw AutomationError(item.statement, .internal, "\(subject(of: item)) came out a shape already drawn")
                }
                transaction.insert(item.record)
                guard transaction.document[item.record.id] != nil else {
                    throw AutomationError(item.statement, .internal, "\(subject(of: item)) couldn't go on the board")
                }
                raise(item, in: &transaction)
                if registry.isContainer(item.record) { settles = true }
                if settles { try settle(item, in: &transaction, nudges: &nudges, warnings: &warnings) }
            }
        }

        // Edges.
        var edgeRows: [(EdgeItem, AnyShapeRecord, DrawChange.Did)] = []
        if let edging, let edgeKind, !edges.isEmpty {
            let drawn = Drawing.connections(in: transaction.document, kind: edgeKind, edging: edging, registry: registry)
            for edge in edges {
                let (record, did) = try connect(edge, among: drawn, edging: edging, kind: edgeKind, in: &transaction)
                edgeRows.append((edge, record, did))
            }
        }

        // What it did.
        var changed: [(line: Int, name: String, record: AnyShapeRecord)] = []
        var outside = 0
        for item in items {
            guard let now = transaction.document[item.record.id] else {
                throw AutomationError(item.statement, .internal, "\(subject(of: item)) isn't on the board after all")
            }
            var row = DrawChange(line: item.statement.line, did: .created, kind: item.kind.rawValue,
                                 title: naming?.name(now, registry), at: now.box)
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
            if let view, let at = now.box {
                row.inView = view.intersects(at)
                if !view.intersects(at), item.free != nil, row.did != .unchanged { outside += 1 }
            }
            if !item.pushedPast.isEmpty { row.pushedPast = item.pushedPast }
            if row.did != .unchanged { changed.append((item.statement.line, subject(of: item), now)) }
            changes.append(row)
        }
        for (edge, record, did) in edgeRows {
            var row = DrawChange(line: edge.statement.line, did: did, kind: record.kind.rawValue, from: edge.fromTitle, to: edge.toTitle)
            let properties = record.propertiesJSON ?? [:]
            for key in edging?.attributes ?? [] {
                if let value = properties[key], value != .null { row.attributes[key] = JSON(value) }
            }
            changes.append(row)
            if did != .unchanged { changed.append((edge.statement.line, "\(Keyword.edge.rawValue) \(edge.edge.written)", record)) }
            warnings += facingAway(edge, in: transaction.shapes)
        }

        // What it should say.
        for item in items {
            guard let now = transaction.document[item.record.id] else { continue }
            warnings += namingWarnings(of: now, item, in: transaction)
        }
        for (line, name, record) in changed {
            for issue in issues(of: record, in: transaction.shapes) {
                warnings.append(DrawWarning(line: line, "\(name): \(issue.message)", severity: issue.isError ? .error : .warning, attribute: issue.field))
            }
        }
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
                        warnings: inout [DrawWarning]) throws(AutomationError) {
        guard !registry.containingKinds.isEmpty else { return }
        let id = item.record.id
        let before = transaction.document[id]?.box
        switch transaction.settle([id]) {
        case .refused(let container):
            let named = transaction.document[container].map { self.named($0) } ?? "a container"
            throw AutomationError(item.statement, .readOnly, "\(subject(of: item)) would go in \(named), which is read-only (locked, say)",
                                  hint: "place it clear of \(named), or ask the user to unlock it")
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
            guard let before, own != .zero, let after = transaction.document[id]?.box else { return }
            // Said of each container whose edge it was over as it was put down.
            for container in transaction.document.shapes where container.id != id && registry.isContainer(container) {
                guard let edge = container.box, Self.overlaps(before, edge), !before.contains(edge), !edge.contains(before) else { continue }
                let way = edge.contains(after) ? "in" : "out"
                warnings.append(DrawWarning(line: item.statement.line,
                                            "\(subject(of: item)) was over the edge of \(self.named(container)), so it was nudged \(way)"))
            }
        }
    }

    /// Draws one edge, or changes the one drawn (only what the statement names), or leaves it be.
    private func connect(_ edge: EdgeItem, among drawn: [BoardConnection], edging: DrawEdging, kind: ShapeKind,
                         in transaction: inout Transaction) throws(AutomationError) -> (AnyShapeRecord, DrawChange.Did) {
        let statement = edge.statement, written = "\(Keyword.edge.rawValue) \(edge.edge.written)"
        let matches = drawn.filter { ($0.from == edge.from && $0.to == edge.to) || (edge.edge.bothHeads && $0.from == edge.to && $0.to == edge.from) }
        guard matches.count < 2 else {
            let arrow = edge.edge.bothHeads ? EdgeArrow.both.rawValue : EdgeArrow.forward.rawValue
            let pair = "\(quoted(edge.fromTitle)) \(arrow) \(quoted(edge.toTitle))"
            throw AutomationError(statement, .ambiguousEdge, "\(pair) is drawn \(matches.count) times",
                                  hint: "write delete edge \(pair) above this line to replace them")
        }
        let match = matches.first
        // Asked the way the edge is drawn, when `<->` finds one drawn the other way.
        let reversed = match.map { $0.from == edge.to && $0.to == edge.from && edge.from != edge.to } ?? false
        func side(_ side: EdgeSide?) -> EdgeRequest.Side? { side.flatMap { EdgeRequest.Side(rawValue: $0.rawValue) } }
        var request = EdgeRequest(from: edge.from, to: edge.to, fromSide: side(edge.edge.fromSide), toSide: side(edge.edge.toSide),
                                  bothHeads: edge.edge.bothHeads, attributes: edge.attributes, fromName: quoted(edge.fromTitle),
                                  toName: quoted(edge.toTitle), written: edge.edge.written)
        if reversed {
            swap(&request.from, &request.to)
            swap(&request.fromSide, &request.toSide)
            swap(&request.fromName, &request.toName)
        }
        func make(changing existing: AnyShapeRecord?) throws(AutomationError) -> AnyShapeRecord {
            do throws(AutomationError) {
                return try edging.make(request, existing, transaction.shapes)
            } catch {
                throw AutomationError(error.message, reason: error.reason, hint: error.hint, invalidParams: error.isInvalidParams,
                                      line: statement.line, statement: statement.text)
            }
        }
        var made = try make(changing: match?.record)
        guard made.kind == kind else {
            throw AutomationError(statement, .internal, "\(written) came out \(indefinite(made.kind)), not \(indefinite(kind))")
        }
        // The kind's own attributes it writes (an arrow's text), set as a shape's are. What the edge
        // says as written (its heads, by its arrow) has the last word: made again, the connection
        // keeps every one of them, or one says otherwise.
        if !edge.settings.isEmpty {
            do throws(ShapePropertiesError) {
                made = try registry.shape(made, setting: edge.settings)
            } catch {
                throw AutomationError(statement, .invalidValue, "\(written) can't have those attributes: \(error)")
            }
            let again = try make(changing: made).propertiesJSON ?? [:], set = made.propertiesJSON ?? [:]
            if let key = edge.settings.keys.sorted().first(where: { again[$0] != set[$0] }) {
                let value = edge.edge.attributes.first { $0.key == key }?.value.written ?? ""
                throw AutomationError(statement, .invalidValue, "\(written): \(key): \(value) isn't what the edge as written says",
                                      hint: "leave \(key): out; how the edge is written (its arrow, its sides) says it")
            }
        }
        // What it's bound to is on the board as the script leaves it: nothing would ever let go of one that isn't.
        let document = transaction.document
        guard made.boundShapes(in: transaction.shapes).allSatisfy({ document[$0] != nil }) else {
            throw AutomationError(statement, .internal, "\(written) came out bound to a shape that isn't on the board")
        }
        if let existing = match?.record {
            guard made.id == existing.id else { throw AutomationError(statement, .internal, "\(written) came out another shape") }
            if made == existing { return (existing, .unchanged) }
            if transaction.isReadOnly(existing), transaction.isReadOnly(made) {
                throw AutomationError(statement, .readOnly, "\(written) is read-only (locked, say), so it stays as it is",
                                      hint: "leave it out of the script, or ask the user to unlock it")
            }
            transaction.update(existing.id) { $0 = made }
            return (transaction.document[existing.id] ?? made, .reconnected)
        }
        guard isNew(made.id, in: transaction) else { throw AutomationError(statement, .internal, "\(written) came out a shape already drawn") }
        // A board that can't change (a locked subboard's, at any depth) takes no new edge.
        guard !transaction.isBoardReadOnly else {
            throw AutomationError(statement, .readOnly, "\(written) would go on \(boardName), which is read-only (locked, say)",
                                  hint: "leave it out of the script, or ask the user to unlock what holds the board")
        }
        transaction.insert(made)
        guard let inserted = transaction.document[made.id] else { throw AutomationError(statement, .internal, "\(written) couldn't go on the board") }
        return (inserted, .connected)
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

    /// A deleted connection's end, as a row names it.
    private func end(_ id: ShapeID, in shapes: ShapeContext) -> String {
        guard let record = shapes.shape(id) else { return "a shape" }
        return Drawing.title(of: record, names: names, naming: naming, registry: registry) ?? Drawing.location(of: record, in: shapes)
    }

    /// A side an edge names that faces away from the other end: the line still leaves (or arrives
    /// on) the side that faces it (as tldraw clips an arrow at its shape's outline).
    private func facingAway(_ edge: EdgeItem, in shapes: ShapeContext) -> [DrawWarning] {
        guard let a = shapes.bounds(of: [edge.from]), let b = shapes.bounds(of: [edge.to]), edge.from != edge.to else { return [] }
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
        for (key, side, mine, other, me, them) in [(EdgeKey.from, edge.edge.fromSide, a, anchor(b, edge.edge.toSide), edge.fromTitle, edge.toTitle),
                                                   (EdgeKey.to, edge.edge.toSide, b, anchor(a, edge.edge.fromSide), edge.toTitle, edge.fromTitle)] {
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
            let does = key == .from ? "leaves \(quoted(me)) by" : "arrives at \(quoted(me)) on"
            said.append(DrawWarning(line: edge.statement.line,
                                    "\(key.rawValue): \(side.rawValue): \(quoted(them)) is \(relation) \(quoted(me)), so the line \(does) its \(facing.rawValue) side — name a side that faces \(quoted(them)), or leave \(key.rawValue): out"))
        }
        return said
    }
}
