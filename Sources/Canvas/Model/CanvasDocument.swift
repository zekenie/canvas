/// Every shape on a canvas, back to front. A value: `Transaction` is how it changes.
public struct CanvasDocument: Equatable, Sendable {
    public private(set) var shapes: [AnyShapeRecord]
    /// Where each shape is in `shapes`, so lookups by id are constant time: hit testing, drawing
    /// and arrow binding look shapes up by id for every shape.
    private var indices: [ShapeID: Int]

    public init(shapes: [AnyShapeRecord] = []) {
        self.shapes = shapes
        indices = Dictionary(shapes.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        precondition(indices.count == shapes.count, "two shapes share an id")
    }

    public subscript(id: ShapeID) -> AnyShapeRecord? {
        indices[id].map { shapes[$0] }
    }

    public func index(of id: ShapeID) -> Int? {
        indices[id]
    }

    public static func == (a: Self, b: Self) -> Bool { a.shapes == b.shapes }

    mutating func append(_ record: AnyShapeRecord) {
        indices[record.id] = shapes.count
        shapes.append(record)
    }

    mutating func replace(at index: Int, with record: AnyShapeRecord) { shapes[index] = record }

    mutating func moveToEnd(from index: Int) {
        shapes.append(shapes.remove(at: index))
        reindex(from: index)
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
