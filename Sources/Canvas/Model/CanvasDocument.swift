/// Every shape on a canvas, back to front: in ascending order of their stacking keys. A value:
/// `Transaction` is how it changes.
public struct CanvasDocument: Equatable, Sendable {
    public private(set) var shapes: [AnyShapeRecord]
    /// Where each shape is in `shapes`, so lookups by id are constant time: hit testing, drawing
    /// and arrow binding look shapes up by id for every shape.
    private var indices: [ShapeID: Int]

    /// The shapes back to front, as given. Their stacking keys are kept if they already rise in
    /// that order; otherwise every shape gets a fresh one, in order.
    public init(shapes: [AnyShapeRecord] = []) {
        var shapes = shapes
        if !Self.keysRise(shapes) {
            var previous: StackingKey?
            for i in shapes.indices {
                let key = StackingKey.between(previous, nil)
                shapes[i].stackingKey = key
                previous = key
            }
        }
        self.shapes = shapes
        indices = Dictionary(shapes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        precondition(indices.count == shapes.count, "two shapes share an id")
    }

    /// Whether every shape has a key, each above the one before.
    static func keysRise(_ shapes: [AnyShapeRecord]) -> Bool {
        var previous: StackingKey?
        for record in shapes {
            guard let key = record.stackingKey, previous.map({ $0 < key }) ?? true else { return false }
            previous = key
        }
        return true
    }

    public subscript(id: ShapeID) -> AnyShapeRecord? {
        indices[id].map { shapes[$0] }
    }

    public func index(of id: ShapeID) -> Int? {
        indices[id]
    }

    public static func == (a: Self, b: Self) -> Bool { a.shapes == b.shapes }

    /// `record`'s key must be above every other.
    mutating func append(_ record: AnyShapeRecord) {
        indices[record.id] = shapes.count
        shapes.append(record)
    }

    /// Keeps the shape's key.
    mutating func replace(at index: Int, with record: AnyShapeRecord) { shapes[index] = record }

    /// `key` must be above every other.
    mutating func moveToEnd(from index: Int, key: StackingKey) {
        var record = shapes.remove(at: index)
        record.stackingKey = key
        shapes.append(record)
        reindex(from: index)
    }

    /// `key` must be below every other.
    mutating func moveToStart(from index: Int, key: StackingKey) {
        var record = shapes.remove(at: index)
        record.stackingKey = key
        shapes.insert(record, at: 0)
        reindex(from: 0)
    }

    /// `to` is where the shape ends up: its index once moved. `key` must fall between its new
    /// neighbors' keys.
    mutating func move(from: Int, to: Int, key: StackingKey) {
        var record = shapes.remove(at: from)
        record.stackingKey = key
        shapes.insert(record, at: to)
        reindex(from: min(from, to))
    }

    mutating func remove(_ ids: Set<ShapeID>) {
        guard let first = ids.compactMap({ indices[$0] }).min() else { return }
        shapes.removeAll { ids.contains($0.id) }
        for id in ids { indices[id] = nil }
        reindex(from: first)
    }

    /// Puts each change's `after` record in place of its `before` (removing it where `after` is nil,
    /// adding it where `before` is), in the order of the records' stacking keys, exactly as they
    /// are: ids, keys, props, metadata, added and kept values, opaque records. What undo and redo do,
    /// so none of a transaction's rules apply (no normalizing, nothing read-only, nothing refused).
    /// The document must hold every `before` (debug builds check it).
    ///
    /// A delta that keeps every shape and its key (a move, an edit, a lock) replaces records where
    /// they are, in time proportional to the changes; one that adds, removes or restacks shapes
    /// takes one pass over the stack.
    public mutating func apply(_ delta: DocumentDelta) {
        #if DEBUG
        for (id, change) in delta.changes {
            assert(self[id] == change.before, "applying a delta to a document that doesn't hold its record before for \(id)")
        }
        #endif
        var leaving = Set<ShapeID>()
        var arriving: [AnyShapeRecord] = []
        var lowest = shapes.count
        for (id, change) in delta.changes {
            if let before = change.before, let after = change.after, before.stackingKey == after.stackingKey, let index = indices[id] {
                shapes[index] = after
                continue
            }
            if change.before != nil, let index = indices[id] {
                leaving.insert(id)
                lowest = min(lowest, index)
            }
            if let after = change.after { arriving.append(after) }
        }
        guard !leaving.isEmpty || !arriving.isEmpty else { return }
        if !leaving.isEmpty {
            shapes.removeAll { leaving.contains($0.id) }
            for id in leaving { indices[id] = nil }
        }
        if !arriving.isEmpty {
            // A record always has a key once in a document; one without (impossible) goes on top.
            arriving.sort { a, b in
                guard let b = b.stackingKey else { return a.stackingKey != nil }
                return a.stackingKey.map { $0 < b } ?? false
            }
            let start = insertionIndex(for: arriving[0].stackingKey)
            lowest = min(lowest, start)
            var merged: [AnyShapeRecord] = []
            merged.reserveCapacity(shapes.count - start + arriving.count)
            var i = start, j = 0
            while i < shapes.count || j < arriving.count {
                let takeArriving: Bool
                if i == shapes.count { takeArriving = true }
                else if j == arriving.count { takeArriving = false }
                else if let key = arriving[j].stackingKey, let existing = shapes[i].stackingKey { takeArriving = key < existing }
                else { takeArriving = false }
                var record = takeArriving ? arriving[j] : shapes[i]
                if takeArriving { j += 1 } else { i += 1 }
                // A board must always save: a key that doesn't rise (impossible while undo and redo
                // take the steps in order) gets one of its own, between its neighbors.
                if let previous = merged.last?.stackingKey, record.stackingKey.map({ !(previous < $0) }) ?? true {
                    assertionFailure("applying a delta put two shapes at stacking key \(previous)")
                    let next = i < shapes.count ? shapes[i].stackingKey : j < arriving.count ? arriving[j].stackingKey : nil
                    record.stackingKey = StackingKey.between(previous, next.flatMap { previous < $0 ? $0 : nil })
                }
                merged.append(record)
            }
            shapes.replaceSubrange(start..., with: merged)
        }
        reindex(from: lowest)
        assert(Self.keysRise(shapes), "applying a delta left the stack out of order")
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

    private mutating func reindex(from start: Int) {
        for index in start..<shapes.count { indices[shapes[index].id] = index }
    }
}
