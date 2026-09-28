import Canvas
import CoreGraphics
import DrawScript
import Geometry

// What's in a script's way, found fast: the board's obstacles (closed shapes the script doesn't
// move or delete, each at its size as the script leaves it) are filed once a run, in paint order,
// in a grid of square cells, so the solver's question (what's near this box?) costs what's near the
// box, however big the board is. The solver asks again after every push, mostly about boxes that
// haven't moved, so each answer is kept for the run.

/// The board's obstacles, for one run.
@MainActor
final class ObstacleIndex {
    struct Entry {
        let record: AnyShapeRecord
        /// Its place in the document: what the layout calls it.
        let id: Int
        let rect: CGRect
    }

    /// In paint order.
    private(set) var entries: [Entry] = []
    /// All of them together; nil with none.
    private(set) var bounds: CGRect?
    /// Each cell's entries, in paint order.
    private var cells: [Cell: [Int]] = [:]
    /// Entries too big to file cell by cell (or too far out to count cells for): every question
    /// asks them.
    private var unfiled: [Int] = []
    private var answers: [Area: [LayoutProblem.Obstacle]] = [:]

    /// A cell's side, in world units: about a shape's.
    static let cellSize: CGFloat = 256
    /// The most cells an entry is filed in, or a question asks: past that, it's cheaper to go
    /// through them all.
    static let maxCells = 1024

    private struct Cell: Hashable {
        let x: Int
        let y: Int
    }

    private struct Area: Hashable {
        let x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat
        init(_ rect: CGRect) {
            x = rect.minX
            y = rect.minY
            width = rect.width
            height = rect.height
        }
    }

    /// `shapes` in paint order; those `excluded` aren't obstacles, and those `resized` are at the
    /// size given.
    init(_ shapes: [AnyShapeRecord], document: CanvasDocument, context: ShapeContext, excluding excluded: Set<ShapeID>,
         resized: [ShapeID: CGRect]) {
        for record in shapes where !excluded.contains(record.id) {
            guard let rect = resized[record.id] ?? Drawing.obstacle(record, in: context), let id = document.index(of: record.id) else { continue }
            let entry = entries.count
            entries.append(Entry(record: record, id: id, rect: rect))
            bounds = bounds.map { $0.union(rect) } ?? rect
            guard let span = Self.cells(of: rect) else {
                unfiled.append(entry)
                continue
            }
            for x in span.x { for y in span.y { cells[Cell(x: x, y: y), default: []].append(entry) } }
        }
    }

    /// The obstacles that meet `area` (touching counts), in paint order, as the layout asks for them.
    func obstacles(in area: CGRect) -> [LayoutProblem.Obstacle] {
        let key = Area(area)
        if let known = answers[key] { return known }
        let found = self.entries(in: area).map { LayoutProblem.Obstacle(id: entries[$0].id, rect: entries[$0].rect) }
        answers[key] = found
        return found
    }

    /// The entries that meet `area`, by their place in `entries` (paint order).
    func entries(in area: CGRect) -> [Int] {
        guard let bounds, area.isFinite, area.touches(bounds) else { return [] }
        let asked = area.intersection(bounds)
        guard let span = Self.cells(of: asked.isNull ? area : asked) else {
            return entries.indices.filter { entries[$0].rect.touches(area) }
        }
        var found = Set(unfiled.filter { entries[$0].rect.touches(area) })
        for x in span.x {
            for y in span.y {
                for entry in cells[Cell(x: x, y: y)] ?? [] where entries[entry].rect.touches(area) { found.insert(entry) }
            }
        }
        return found.sorted()
    }

    /// The cells a rect covers, if they're few enough to go through one by one.
    private static func cells(of rect: CGRect) -> (x: ClosedRange<Int>, y: ClosedRange<Int>)? {
        // Beyond this, a cell's number isn't a whole number a machine word holds.
        let far = 1e15
        guard rect.isFinite, abs(rect.minX) < far, abs(rect.maxX) < far, abs(rect.minY) < far, abs(rect.maxY) < far else { return nil }
        let x = Int((rect.minX / cellSize).rounded(.down))...Int((rect.maxX / cellSize).rounded(.down))
        let y = Int((rect.minY / cellSize).rounded(.down))...Int((rect.maxY / cellSize).rounded(.down))
        guard x.count <= maxCells, y.count <= maxCells, x.count * y.count <= maxCells else { return nil }
        return (x, y)
    }
}
