import Canvas
import CoreGraphics
import DrawScript

// What's in a script's way, found fast: the board's obstacles (the shapes with a solid that the
// script doesn't move or delete, `ShapeContext.solidBounds(of:)`, each at its size as the script
// leaves it) are filed once a run, in paint order, in DrawScript's `ObstacleGrid`, which knows
// boxes only, so the solver's question (what's near this box?) costs what's near the box, however
// big the board is, and each answer is kept for the run. What the index adds is each obstacle's
// shape, for the checks and messages that need to say which one it is.

/// The board's obstacles, for one run.
@MainActor
final class ObstacleIndex {
    struct Entry {
        let record: AnyShapeRecord
        /// Its place in the document: what the layout calls it.
        let id: Int
        let rect: CGRect
    }

    /// In paint order: each one's place here is its place in `grid.obstacles`.
    let entries: [Entry]
    private let grid: ObstacleGrid

    /// `shapes` in paint order; those `excluded` aren't obstacles, and those `resized` are at the
    /// size given.
    init(_ shapes: [AnyShapeRecord], document: CanvasDocument, context: ShapeContext, excluding excluded: Set<ShapeID>,
         resized: [ShapeID: CGRect]) {
        var entries: [Entry] = []
        for record in shapes where !excluded.contains(record.id) {
            guard let rect = resized[record.id] ?? context.solidBounds(of: record.id), let id = document.index(of: record.id) else { continue }
            entries.append(Entry(record: record, id: id, rect: rect))
        }
        self.entries = entries
        grid = ObstacleGrid(entries.map { LayoutProblem.Obstacle(id: $0.id, rect: $0.rect) })
    }

    /// All of them together; nil with none.
    var bounds: CGRect? { grid.bounds }

    /// All of them together but those whose ids are `excluded`; nil with none left.
    func bounds(excluding excluded: Set<Int>) -> CGRect? {
        guard !excluded.isEmpty else { return bounds }
        let rects = entries.lazy.filter { !excluded.contains($0.id) }.map(\.rect)
        return rects.isEmpty ? nil : rects.reduce(CGRect.null) { $0.union($1) }
    }

    /// The obstacles that meet `area` (touching counts), in paint order, as the layout asks for them.
    func obstacles(in area: CGRect) -> [LayoutProblem.Obstacle] { grid.obstacles(in: area) }

    /// The entries that meet `area`, by their place in `entries` (paint order).
    func entries(in area: CGRect) -> [Int] { grid.entries(in: area) }
}
