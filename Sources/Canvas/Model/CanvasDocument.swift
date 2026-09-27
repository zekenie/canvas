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

    private mutating func reindex(from start: Int) {
        for index in start..<shapes.count { indices[shapes[index].id] = index }
    }
}
