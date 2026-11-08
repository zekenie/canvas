import AppKit
import Canvas
import CoreGraphics
import Selection

// Rows moved as wholes, any kind's written as lines: within a shape (⌥↑ ⌥↓ on rows selected as items), into another shape
// of a kind that takes them, or out on their own into a new shape (the kind's take-out: a new table, its `id uuid pk`
// first). One function moves them (`moveRows`), and a paste of rows lands through the same steps (`pasteRows`); each is one
// step the kind's noun names ("Move Column", "Move Columns to New Table"), all or nothing (a read-only source or target
// refuses it, and shakes). A row keeps its id where it goes, a new one only where the target already holds that id; what's
// bound to a row moved to another shape is bound to it there through the core's `moveParts`, which tells `PartsMoved` (a
// mention of the row, a pill for it, on any board), and a new shape is settled where it lands (a table dropped in a database
// goes in it). The rows moved end selected as items of their shape (Selection's), or a new shape's name is edited at once.

/// Where rows go.
public enum RowPlace: Hashable, Sendable {
    /// Among a shape's rows, before `before` (nil: after the last); the same shape reorders.
    case into(ShapeID, before: PartID?)
    /// A shape of their own (the kind's take-out), its top-left at a world point.
    case board(origin: CGPoint)
    /// A shape of their own, put down beside these shapes as Insert puts one (the insertion spot), or in the view with none.
    case beside([ShapeID])
}

/// One kind's rows moved as wholes, erased: what moves need of the kind's model whatever its props. Only `lineRows(_:)`
/// makes one.
@MainActor
public struct LineRowsMoving {
    /// What its rows are called: the steps' noun.
    public let noun: LineNoun
    /// Whether its shapes take rows of a kind (its own always).
    let takes: @MainActor (ShapeKind) -> Bool
    /// A shape's rows, in order; nil for a record of another kind.
    let rows: @MainActor (AnyShapeRecord) -> [PartID]?
    /// The shape holding only these of its rows, in their order, untitled: what rows on the pasteboard are (the carrier).
    let carrier: @MainActor (AnyShapeRecord, [PartID]) -> AnyShapeRecord?
    /// The shape without these rows.
    let removing: @MainActor (AnyShapeRecord, Set<PartID>) -> AnyShapeRecord?
    /// The shape with a carrier's rows put in at an index, each renamed as the map says (a row whose id it holds already).
    let inserting: @MainActor (AnyShapeRecord, AnyShapeRecord, Int, [PartID: PartID]) -> AnyShapeRecord?
    /// The shape with these rows, in their order, put at an index among the rest.
    let reordering: @MainActor (AnyShapeRecord, [PartID], Int) -> AnyShapeRecord?
    /// A carrier's rows in a shape of their own, under a new id (the kind's take-out: a table's `id uuid pk` first).
    let takeOut: @MainActor (AnyShapeRecord) -> AnyShapeRecord?
    /// Whether a shape taken out has its name typed at once.
    let editsTitle: Bool
    /// A carrier's rows as their lines print, one a line: what goes on the pasteboard as text beside them.
    let lines: @MainActor (AnyShapeRecord, CanvasEditor) -> [String]

    public init(noun: LineNoun, takes: @escaping @MainActor (ShapeKind) -> Bool, rows: @escaping @MainActor (AnyShapeRecord) -> [PartID]?,
                carrier: @escaping @MainActor (AnyShapeRecord, [PartID]) -> AnyShapeRecord?,
                removing: @escaping @MainActor (AnyShapeRecord, Set<PartID>) -> AnyShapeRecord?,
                inserting: @escaping @MainActor (AnyShapeRecord, AnyShapeRecord, Int, [PartID: PartID]) -> AnyShapeRecord?,
                reordering: @escaping @MainActor (AnyShapeRecord, [PartID], Int) -> AnyShapeRecord?,
                takeOut: @escaping @MainActor (AnyShapeRecord) -> AnyShapeRecord?, editsTitle: Bool,
                lines: @escaping @MainActor (AnyShapeRecord, CanvasEditor) -> [String]) {
        self.noun = noun
        self.takes = takes
        self.rows = rows
        self.carrier = carrier
        self.removing = removing
        self.inserting = inserting
        self.reordering = reordering
        self.takeOut = takeOut
        self.editsTitle = editsTitle
        self.lines = lines
    }

    /// A shape's rows' ids, in order; nil for a record of another kind.
    public func rowIDs(of record: AnyShapeRecord) -> [PartID]? { rows(record) }
}

/// The kinds whose rows move as wholes: one a kind (`lineRows(_:)`). Owner LineRows.
public enum LineRowsMoves {}

extension LineRowsMoves: KeyedExtensionPoint {
    public typealias Contribution = LineRowsMoving
    public static var owner: PluginID { .lineRows }
    public static func uniqueKeys(of _: LineRowsMoving, for target: ShapeTarget) -> [AnyHashable] { [target] }
    public static func summary(of contribution: LineRowsMoving, for target: ShapeTarget) -> String {
        "row moves (\(contribution.noun.plural)) → \(target)"
    }
}

extension Registry {
    /// How a kind's rows move as wholes, for a kind written as lines.
    public func rowMoving(of kind: ShapeKind) -> LineRowsMoving? { contributions(to: LineRowsMoves.self, for: kind).first }
}

/// The names of the steps rows moved as wholes make, from the kind's noun.
@MainActor
public enum RowSteps {
    /// "Move Column", "Move Columns".
    public static func move(_ noun: LineNoun, count: Int) -> String { "Move \(title(noun, count))" }
    /// "Move Columns to New Table".
    public static func takeOut(_ noun: LineNoun, count: Int, into kind: ShapeKind, in registry: Registry) -> String {
        "Move \(title(noun, count)) to New \(registry.label(of: kind).name)"
    }
    /// "Paste Columns".
    public static func paste(_ noun: LineNoun, count: Int) -> String { "Paste \(title(noun, count))" }
    /// "Cut Columns", and what went along: "Cut Columns and 2 Arrows".
    public static func cut(_ noun: LineNoun, count: Int, along: [KindCount], in registry: Registry) -> String {
        counted("Cut \(title(noun, count))", along: along, in: registry)
    }

    /// "2 Arrows left out": what a cut took with its rows and a paste could not bring back (its other end isn't on the board).
    public static func leftOut(_ along: [KindCount], in registry: Registry) -> String {
        let parts = along.filter { $0.count > 0 }.map { item in
            let label = registry.label(of: item.kind).name
            return "\(item.count) \(item.count == 1 ? label : DeleteSteps.plural(label))"
        }
        return "\(DeleteSteps.list(parts)) left out"
    }

    /// "Column" or "Columns".
    static func title(_ noun: LineNoun, _ count: Int) -> String { count == 1 ? noun.title : noun.pluralTitle }

    /// `name` and what went along, each kind counted even for one: "Delete Column and 1 Arrow".
    public static func counted(_ name: String, along: [KindCount], in registry: Registry) -> String {
        let counted = along.filter { $0.count > 0 }
        guard !counted.isEmpty else { return name }
        let parts = counted.map { item in
            let label = registry.label(of: item.kind).name
            return "\(item.count) \(item.count == 1 ? label : DeleteSteps.plural(label))"
        }
        return "\(name) and \(DeleteSteps.list(parts))"
    }
}

extension CanvasEditor {
    /// Moves `rows` of `shape` (those it holds, in its order) to `place`, as one step the kind's noun names, keeping their
    /// ids (a new one only where the target holds that id already), and returns the shape they're in now: within the shape
    /// they go before `before` as a block ("Move Column"; a place inside the block is no move); into another shape of a kind
    /// that takes them, what's bound to them is bound to them there (`moveParts`, which tells `PartsMoved`); out on their own
    /// into the kind's take-out, put down at the origin or beside shapes as Insert puts one, settled ("Move Columns to New
    /// Table": a table landing in a database goes in it), selected, its name typed at once where the kind says so (what's
    /// typed is the same step). The rows end selected as items of their shape. All or nothing: a read-only source or target,
    /// a read-only container that would take the new shape, or a read-only board refuses it, and what was tried shakes. Nil
    /// for no move.
    @discardableResult
    public func moveRows(_ rows: [PartID], of shape: ShapeID, to place: RowPlace, coalescing key: AnyHashable? = nil) -> ShapeID? {
        guard let record = document[shape], let moving = registry.rowMoving(of: record.kind) else { return nil }
        let order = moving.rows(record) ?? []
        let wanted = Set(rows)
        let ids = order.filter(wanted.contains)
        guard !ids.isEmpty else { return nil }
        if case .into(let target, let before) = place, target == shape {
            return reorderRows(ids, of: shape, before: before, order: order, moving: moving, coalescing: key) ? shape : nil
        }
        guard let carrier = moving.carrier(record, ids) else { return nil }
        let step: String = if case .into = place { RowSteps.move(moving.noun, count: ids.count) } else {
            RowSteps.takeOut(moving.noun, count: ids.count, into: record.kind, in: registry)
        }
        return landRows(carrier, source: shape, arrows: [], moves: true, at: place, step: step, coalescing: key)?.shape
    }

    /// ⌥↑ (-1) ⌥↓ (+1): `rows` of `shape` moved a place as a block, past the row shown before the first or after the last, so a
    /// press of a folded shape changes what it shows: rows its fold hides are stepped over, and a closed header takes the
    /// rows it hides along. Nothing at the ends. Held or repeated, one step (`coalescing`).
    @discardableResult
    public func moveRows(_ rows: [PartID], of shape: ShapeID, by delta: Int, coalescing key: AnyHashable? = nil) -> Bool {
        guard let record = document[shape], let moving = registry.rowMoving(of: record.kind) else { return false }
        let order = moving.rows(record) ?? []
        let shown = shapeContext.layoutInput(LineRowsLayout.shown, of: record)
        var block = Set(rows)
        if let shown {
            // A closed header moves with the rows behind it.
            for (index, id) in order.enumerated() where block.contains(id) {
                let line = shown.line(standingFor: index)
                guard case .header(let header, _) = shown.lines[line], header == index else { continue }
                for other in order.indices where other != index && shown.line(standingFor: other) == line { block.insert(order[other]) }
            }
        }
        let indices = order.indices.filter { block.contains(order[$0]) }
        guard let first = indices.first, let last = indices.last else { return false }
        func isShown(_ index: Int) -> Bool { shown?.isShown(index) ?? true }
        let before: PartID?
        if delta < 0 {
            guard let above = (0..<first).last(where: { !block.contains(order[$0]) && isShown($0) }) else { return false }
            before = order[above]
        } else {
            guard let below = ((last + 1)..<order.count).first(where: { !block.contains(order[$0]) && isShown($0) }) else { return false }
            // Past a closed header, past what it hides.
            var after = below + 1
            if let shown { while after < order.count, shown.line(standingFor: after) == shown.line(standingFor: below) { after += 1 } }
            before = after < order.count ? order[after] : nil
        }
        return moveRows(Array(block), of: shape, to: .into(shape, before: before), coalescing: key ?? AnyHashable(RowMoveRun(shape: shape, rows: Set(rows)))) != nil
    }

    /// The rows as a block before `before` in their shape: one step, the rows selected as items after (unless the shape is
    /// edited, whose session keeps its own).
    private func reorderRows(_ ids: [PartID], of shape: ShapeID, before: PartID?, order: [PartID], moving: LineRowsMoving,
                             coalescing key: AnyHashable?) -> Bool {
        let moved = Set(ids)
        if let before, moved.contains(before) { return false }
        let rest = order.filter { !moved.contains($0) }
        let index = before.flatMap { rest.firstIndex(of: $0) } ?? rest.count
        var next = rest
        next.insert(contentsOf: ids, at: index)
        guard next != order else { return false }
        let step = RowSteps.move(moving.noun, count: ids.count)
        let done: Bool? = transactWhole(step, coalescing: key, shaking: [shape]) { transaction in
            guard let fresh = transaction.document[shape], let reordered = moving.reordering(fresh, ids, index) else { throw Transaction.Refused([shape]) }
            transaction.update(shape) { $0 = reordered }
            return true
        }
        guard done == true else { return false }
        if editingShapeID != shape { selectItems(ids.map(AnyHashable.init), of: shape) }
        announce(step)
        return true
    }

    /// Puts a carrier's rows down at `place`, as one step `step`: from `source` (taken out of it) when they move, with
    /// `arrows` (a paste's, bound to the carrier's rows) bound to where the rows landed, an arrow whose other end isn't on
    /// the board shown left out; `moves` says the rows are the same rows (a move, a cut's paste), so what's bound to them or
    /// names them follows (`moveParts`), and the arrows keep their ids where the file doesn't use them. Returns the shape
    /// they're in.
    func landRows(_ carrier: AnyShapeRecord, source: ShapeID?, arrows: [AnyShapeRecord], far: [FarArrow] = [], moves: Bool, at place: RowPlace, step: String,
                  coalescing key: AnyHashable? = nil) -> (shape: ShapeID, rows: [PartID])? {
        guard let moving = registry.rowMoving(of: carrier.kind) else { return nil }
        let rows = moving.rows(carrier) ?? []
        guard !rows.isEmpty else { return nil }
        guard !isBoardReadOnly else {
            refuseChanges(to: Set([source, board.owner].compactMap { $0 }))
            return nil
        }
        // Where they land, and what each row's id is there.
        enum Landing {
            case into(ShapeID, index: Int, renaming: [PartID: PartID])
            case out(AnyShapeRecord)
        }
        let landing: Landing
        switch place {
        case .into(let target, let before):
            guard let held = document[target], let into = registry.rowMoving(of: held.kind), into.takes(carrier.kind), held.kind == carrier.kind else { return nil }
            let order = (into.rows(held) ?? []).filter { target != source || !rows.contains($0) }
            let taken = Set(order)
            var renaming: [PartID: PartID] = [:]
            for row in rows where taken.contains(row) { renaming[row] = PartID() }
            landing = .into(target, index: before.flatMap { order.firstIndex(of: $0) } ?? order.count, renaming: renaming)
        case .board(let origin):
            guard var made = moving.takeOut(carrier) else { return nil }
            made = placed(made, at: origin)
            landing = .out(made)
        case .beside(let shapes):
            guard let made = moving.takeOut(carrier), let size = laidOutSize(of: made),
                  let frame = insertionFrame(of: size, beside: shapes.filter { document[$0] != nil }) else { return nil }
            landing = .out(placed(made, at: frame.origin))
        }
        let destination: ShapeID
        let renaming: [PartID: PartID]
        switch landing {
        case .into(let target, _, let map):
            destination = target
            renaming = map
        case .out(let made):
            destination = made.id
            renaming = [:]
        }
        let landed = rows.map { renaming[$0] ?? $0 }
        // What a refusal shakes is what the transaction heard refused and what the body names (the source, the target, the container
        // that would not take a shape put down): the new shape isn't there yet to shake.
        var left: [KindCount] = []
        let body = { [self] () -> [ShapeID: CGPoint]? in
            left = []
            return transactWhole(step, coalescing: key) { transaction -> [ShapeID: CGPoint] in
                if let source, let fresh = transaction.document[source], let from = registry.rowMoving(of: fresh.kind) {
                    guard let without = from.removing(fresh, Set(rows)) else { throw Transaction.Refused([source]) }
                    transaction.update(source) { $0 = without }
                }
                switch landing {
                case .into(let target, let index, let renaming):
                    guard let fresh = transaction.document[target], let into = registry.rowMoving(of: fresh.kind),
                          let filled = into.inserting(fresh, carrier, index, renaming) else { throw Transaction.Refused([target]) }
                    transaction.update(target) { $0 = filled }
                case .out(let made):
                    transaction.insert(made)
                }
                var moved: [PartAddress: PartAddress] = [:]
                for row in rows { moved[PartAddress(carrier.id, part: row)] = PartAddress(destination, part: renaming[row] ?? row) }
                // A paste's arrows, bound to the rows where they landed; one whose other end isn't here is left out (and said), and
                // one bound to a row of another shape that is gone since is bound to that shape as a whole, as taking the row out does.
                var put: [ShapeID] = []
                func leaveOut(_ arrow: AnyShapeRecord) {
                    if let at = left.firstIndex(where: { $0.kind == arrow.kind }) { left[at].count += 1 } else { left.append(KindCount(kind: arrow.kind, count: 1)) }
                }
                for arrow in arrows {
                    guard var bound = arrow.movingParts(in: registry, { moved[$0] ?? $0 }) ?? Optional(arrow) else { continue }
                    guard bound.boundParts(in: registry).allSatisfy({ transaction.document[$0.shape] != nil }) else {
                        leaveOut(arrow)
                        continue
                    }
                    bound = bound.movingParts(in: registry, { address in
                        guard let part = address.part, let held = transaction.document[address.shape], let names = registry.parts(of: held),
                              !names.contains(where: { $0.id == part }) else { return address }
                        return PartAddress(address.shape)
                    }) ?? bound
                    if !moves || !file.isUnused(bound.id) || transaction.document[bound.id] != nil { bound = bound.copy(as: ShapeID()) }
                    transaction.insert(bound)
                    put.append(bound.id)
                }
                // A cut's keys that reached its rows through a pill on another board are put back on that board, bound as they
                // were; `moveParts` then follows them to where the rows went, through the pill or to it as a whole.
                if moves {
                    for key in far {
                        let there = transaction.contents(of: key.board)
                        guard transaction.mayWrite(on: key.board), there[key.record.id] == nil, file.isUnused(key.record.id),
                              key.record.boundParts(in: registry).allSatisfy({ there[$0.shape] != nil }) else {
                            leaveOut(key.record)
                            continue
                        }
                        transaction.insert(key.record, on: key.board)
                    }
                    transaction.moveParts(moved)
                }
                guard case .out = landing else { return [:] }
                switch transaction.settle([destination] + put) {
                case .settled(let nudges): return nudges
                case .refused(let container): throw Transaction.Refused([container])
                }
            }
        }
        var out = false
        if case .out = landing { out = true }
        let editsTitle = out && moving.editsTitle
        var nudges: [ShapeID: CGPoint]?
        if editsTitle {
            // The name typed into the new shape is the same step.
            undoHistory.group(step) {
                nudges = body()
                if let nudges { finishLanding(destination, landed: landed, out: true, editsTitle: true, nudges: nudges) }
            }
        } else {
            nudges = body()
            if let nudges { finishLanding(destination, landed: landed, out: out, editsTitle: false, nudges: nudges) }
        }
        guard nudges != nil else { return nil }
        announce(left.isEmpty ? step : "\(step), \(RowSteps.leftOut(left, in: registry))")
        return (destination, landed)
    }

    /// What a landing leaves: the new shape selected and brought into view, its name typed where the kind says so; else the
    /// rows selected as items of their shape.
    private func finishLanding(_ shape: ShapeID, landed: [PartID], out: Bool, editsTitle: Bool, nudges: [ShapeID: CGPoint]) {
        if out {
            // A shape whose name is typed at once is laid out where it is, under its editing view.
            var nudges = nudges
            if editsTitle { nudges[shape] = nil }
            glide(nudges)
            selectedShapeIDs = [shape]
            revealIfOffscreen([shape])
            if editsTitle {
                beginEditing(shape)
                return
            }
        }
        if editingShapeID != shape { selectItems(landed.map(AnyHashable.init), of: shape) }
    }

    /// `record` with its box's top-left at `origin`.
    private func placed(_ record: AnyShapeRecord, at origin: CGPoint) -> AnyShapeRecord {
        guard let box = record.box else { return record }
        var moved = record
        moved.box = CGRect(origin: origin, size: box.size)
        return moved
    }

    /// How big `record` is laid out, as a shape of its own.
    private func laidOutSize(of record: AnyShapeRecord) -> CGSize? {
        ShapeContext(document: CanvasDocument(shapes: [record]), registry: registry).bounds(of: [record.id])?.size ?? record.box?.size
    }
}

/// Moves of one block of rows, repeated, coalesced into one step.
struct RowMoveRun: Hashable {
    let shape: ShapeID
    let rows: Set<PartID>
}
