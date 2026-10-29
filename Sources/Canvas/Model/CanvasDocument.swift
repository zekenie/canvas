/// Every shape on a canvas, back to front: in ascending order of their stacking keys. A value:
/// `Transaction` is how it changes.
///
/// A copy shares what it holds with the original until one of them changes it, and then only the
/// part the change reaches is copied (`ShapeStack`), so a transaction on a big board costs what it
/// changes, and holding the board as it was before a commit costs what that commit wrote.
public struct CanvasDocument: Equatable, Sendable {
    /// The shapes, back to front, with where each is, so lookups by id are constant time: hit testing,
    /// drawing and arrow binding look shapes up by id for every shape.
    public private(set) var shapes: ShapeStack
    /// The shapes that name each container (`AnyShapeRecord.container`), by container: as the board
    /// keeps them, usable or not, kept by every change, so what a container holds costs what it
    /// holds, never the board (Containment.swift).
    private(set) var members: [ShapeID: Set<ShapeID>] = [:]

    /// The shapes back to front, as given. Their stacking keys are kept if they already rise in
    /// that order; otherwise every shape gets a fresh one, in order.
    public init(shapes: [AnyShapeRecord] = []) {
        self.init(keyed: ShapeStack(Self.withRisingKeys(shapes)))
    }

    /// The same shapes, kept as they are if their stacking keys already rise.
    public init(shapes: ShapeStack) {
        self.init(keyed: Self.keysRise(shapes) ? shapes : ShapeStack(Self.withRisingKeys(Array(shapes))))
    }

    /// `shapes`, whose keys rise.
    private init(keyed shapes: ShapeStack) {
        self.shapes = shapes
        for record in shapes where record.namesContainer { members[record.container!, default: []].insert(record.id) }
    }

    /// The shapes, each with a fresh key, in order, unless their keys rise already.
    private static func withRisingKeys(_ shapes: [AnyShapeRecord]) -> [AnyShapeRecord] {
        guard !keysRise(shapes) else { return shapes }
        var shapes = shapes
        var previous: StackingKey?
        for i in shapes.indices {
            let key = StackingKey.between(previous, nil)
            shapes[i].stackingKey = key
            previous = key
        }
        return shapes
    }

    /// Whether every shape has a key, each above the one before.
    static func keysRise(_ shapes: some Sequence<AnyShapeRecord>) -> Bool {
        var previous: StackingKey?
        for record in shapes {
            guard let key = record.stackingKey, previous.map({ $0 < key }) ?? true else { return false }
            previous = key
        }
        return true
    }

    public subscript(id: ShapeID) -> AnyShapeRecord? {
        shapes.record(for: id)
    }

    public func index(of id: ShapeID) -> Int? {
        shapes.position(of: id)
    }

    public static func == (a: Self, b: Self) -> Bool { a.shapes == b.shapes }

    /// `record`'s key must be above every other.
    mutating func append(_ record: AnyShapeRecord) {
        shapes.append(record)
        if record.namesContainer { link(record.id, from: nil, to: record.container) }
    }

    /// Keeps the shape's key.
    mutating func replace(at index: Int, with record: AnyShapeRecord) {
        let old = shapes[index]
        if old.containerBits != record.containerBits { link(record.id, from: old.container, to: record.container) }
        shapes.replace(at: index, with: record)
    }

    /// The shape now names `new` as its container, and no longer `old`.
    private mutating func link(_ id: ShapeID, from old: ShapeID?, to new: ShapeID?) {
        guard old != new else { return }
        if let old, members[old]?.remove(id) != nil, members[old]?.isEmpty == true { members[old] = nil }
        if let new { members[new, default: []].insert(id) }
    }

    /// `key` must be above every other.
    mutating func moveToEnd(from index: Int, key: StackingKey) {
        var moved = shapes[index]
        moved.stackingKey = key
        shapes.move(from: index, to: shapes.count - 1, as: moved)
    }

    /// `key` must be below every other.
    mutating func moveToStart(from index: Int, key: StackingKey) {
        var moved = shapes[index]
        moved.stackingKey = key
        shapes.move(from: index, to: 0, as: moved)
    }

    /// `to` is where the shape ends up: its index once moved. `key` must fall between its new
    /// neighbors' keys.
    mutating func move(from: Int, to: Int, key: StackingKey) {
        var moved = shapes[from]
        moved.stackingKey = key
        shapes.move(from: from, to: to, as: moved)
    }

    mutating func remove(_ ids: Set<ShapeID>) {
        for id in ids { if let index = shapes.position(of: id), shapes[index].namesContainer { link(id, from: shapes[index].container, to: nil) } }
        shapes.remove(ids)
    }

    /// Moves the shapes at `block` (ascending indices), in their order among themselves, to just
    /// above the shape at `anchor` (an index not in `block`), or to the bottom for nil, giving them
    /// `keys`, which must rise from above the anchor's key to below the key of the shape after it
    /// that stays. One pass over the shapes between, however many move: a container restacked with
    /// what it holds.
    mutating func move(_ block: [Int], above anchor: Int?, keys: [StackingKey]) {
        precondition(block.count == keys.count, "a key for each shape moved")
        var moved: [AnyShapeRecord] = []
        moved.reserveCapacity(block.count)
        for (index, key) in zip(block, keys) {
            var record = shapes[index]
            record.stackingKey = key
            moved.append(record)
        }
        shapes.move(block, above: anchor, as: moved)
        assert(Self.keysRise(shapes), "a block moved out of order")
    }

    /// Puts each change's `after` record in place of its `before` (removing it where `after` is nil,
    /// adding it where `before` is), in the order of the records' stacking keys, exactly as they
    /// are: ids, keys, props, metadata, added and kept values, opaque records. What undo and redo do,
    /// so none of a transaction's rules apply (no normalizing, nothing read-only, nothing refused).
    /// The document must hold every `before` (debug builds check it).
    ///
    /// A delta that keeps every shape and its key (a move, an edit, a lock) replaces records where
    /// they are, in time proportional to the changes; one that adds, removes or restacks shapes
    /// makes the stack again from the first shape it changes.
    public mutating func apply(_ delta: DocumentDelta) {
        #if DEBUG
        for (id, change) in delta.changes {
            assert(self[id] == change.before, "applying a delta to a document that doesn't hold its record before for \(id)")
        }
        #endif
        var leaving = Set<ShapeID>(), departing: [ShapeID] = []
        var arriving: [AnyShapeRecord] = []
        var lowest = shapes.count
        for (id, change) in delta.changes {
            if change.before?.containerBits != change.after?.containerBits { link(id, from: change.before?.container, to: change.after?.container) }
            if let before = change.before, let after = change.after, before.stackingKey == after.stackingKey, let index = shapes.position(of: id) {
                shapes.replace(at: index, with: after)
                continue
            }
            if change.before != nil, let index = shapes.position(of: id) {
                leaving.insert(id)
                lowest = min(lowest, index)
                if change.after == nil { departing.append(id) }
            }
            if let after = change.after { arriving.append(after) }
        }
        guard !leaving.isEmpty || !arriving.isEmpty else { return }
        // A record always has a key once in a document; one without (impossible) goes on top.
        arriving.sort { a, b in
            guard let b = b.stackingKey else { return a.stackingKey != nil }
            return a.stackingKey.map { $0 < b } ?? false
        }
        // The stack is made again from the first place a shape leaves or one comes (the first shape above
        // the lowest key arriving, or the end).
        let start = min(lowest, arriving.first.map { insertionIndex(for: $0.stackingKey) } ?? lowest)
        var merged: [AnyShapeRecord] = []
        merged.reserveCapacity(shapes.count - start + arriving.count)
        var j = 0
        // Whether the next shape's key must be checked against the last merged: the shapes that were there rise among
        // themselves, so only those next to one that arrived are.
        var check = true
        // A few ids are compared with each shape's, a longer list is hashed.
        let few = leaving.count <= 8 ? Array(leaving) : nil
        for existing in shapes.records(in: start..<shapes.count) where !(few?.contains(existing.id) ?? leaving.contains(existing.id)) {
            while j < arriving.count, Self.isBelow(arriving[j], existing) {
                merged.append(Self.fitted(arriving[j], after: merged.last?.stackingKey, before: existing.stackingKey))
                check = true
                j += 1
            }
            merged.append(check ? Self.fitted(existing, after: merged.last?.stackingKey, before: nil) : existing)
            check = false
        }
        while j < arriving.count {
            merged.append(Self.fitted(arriving[j], after: merged.last?.stackingKey, before: nil))
            j += 1
        }
        shapes.replaceSubrange(start..<shapes.count, with: merged, departing: departing)
        assert(Self.keysRise(shapes), "applying a delta left the stack out of order")
    }

    /// Puts each of `records`, shapes of the board with other stacking keys, where its key goes: the stack made again
    /// from the lowest place one leaves or comes to up to the highest, in one pass however many there are. What a
    /// restack of several shapes ends with (`StackReplay`); the keys must rise as the shapes that stay are.
    mutating func restack(_ records: [AnyShapeRecord]) {
        guard !records.isEmpty else { return }
        var leaving = Set<ShapeID>(), start = shapes.count, end = 0
        for record in records {
            guard let index = shapes.position(of: record.id) else { preconditionFailure("restacking a shape the board doesn't hold") }
            leaving.insert(record.id)
            start = min(start, index)
            end = max(end, index + 1)
        }
        let arriving = records.sorted(by: Self.isBelow)
        start = min(start, insertionIndex(for: arriving[0].stackingKey))
        end = max(end, insertionIndex(for: arriving[arriving.count - 1].stackingKey))
        var merged: [AnyShapeRecord] = []
        merged.reserveCapacity(end - start)
        var next = 0
        for existing in shapes.records(in: start..<end) where !leaving.contains(existing.id) {
            while next < arriving.count, Self.isBelow(arriving[next], existing) {
                merged.append(arriving[next])
                next += 1
            }
            merged.append(existing)
        }
        merged.append(contentsOf: arriving[next...])
        shapes.replaceSubrange(start..<end, with: merged)
        assert(Self.keysRise(shapes), "a restack left the stack out of order")
    }

    /// Whether `arriving` goes below `existing`: a key that doesn't compare goes above.
    private static func isBelow(_ arriving: AnyShapeRecord, _ existing: AnyShapeRecord) -> Bool {
        guard let key = arriving.stackingKey, let other = existing.stackingKey else { return false }
        return key < other
    }

    /// `record`, with a key that rises above `previous`: a board must always save, so a key that doesn't (impossible
    /// while undo and redo take the steps in order) gets one of its own, between its neighbors'.
    private static func fitted(_ record: AnyShapeRecord, after previous: StackingKey?, before next: StackingKey?) -> AnyShapeRecord {
        guard let previous, record.stackingKey.map({ !(previous < $0) }) ?? true else { return record }
        assertionFailure("applying a delta put two shapes at stacking key \(previous)")
        var fixed = record
        fixed.stackingKey = StackingKey.between(previous, next.flatMap { previous < $0 ? $0 : nil })
        return fixed
    }

    /// Where a record with `key` goes: the index of the first shape above it (by binary search).
    private func insertionIndex(for key: StackingKey?) -> Int {
        guard let key else { return shapes.count }
        var low = 0, high = shapes.count
        while low < high {
            let mid = (low + high) / 2
            if let other = shapes[mid].stackingKey, other < key { low = mid + 1 } else { high = mid }
        }
        return low
    }
}
