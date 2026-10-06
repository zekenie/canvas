import CoreGraphics
import Geometry

// What's in a placed box's way, found fast: the obstacles (the shapes the solver keeps clear of,
// each at its size as the placement leaves it) are filed once, in paint order, in a grid of square
// cells, so the solver's question (what's near this box?) costs what's near the box, however many
// obstacles there are. The solver asks again after every push, mostly about boxes that haven't
// moved, so each answer is kept for the grid's life.

/// Obstacles filed for the solver (`LayoutProblem.obstacles` asks it, a region at a time), for one
/// placement. Boxes only: it knows no shape, so what an obstacle is, and which shape it stands for,
/// is the caller's. Not `Sendable`: it keeps its answers.
public final class ObstacleGrid {
    /// In paint order, as the solver numbers them: an obstacle's `id` is its own (its place on the
    /// board), whatever its place here.
    public let obstacles: [LayoutProblem.Obstacle]
    /// All of them together; nil with none.
    public private(set) var bounds: CGRect?
    /// Each cell's obstacles, by their place in `obstacles`, in paint order.
    private var cells: [Cell: [Int]] = [:]
    /// Obstacles too big to file cell by cell (or too far out to count cells for), by their place in
    /// `obstacles`: every question asks them.
    private var unfiled: [Int] = []
    private var answers: [Area: [LayoutProblem.Obstacle]] = [:]

    /// A cell's side, in world units: about a shape's.
    public static let cellSize: CGFloat = 256
    /// The most cells an obstacle is filed in, or a question asks: past that, it's cheaper to go
    /// through them all.
    public static let maxCells = 1024

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

    /// Files `obstacles`, which are in paint order, each with the id the solver calls it.
    public init(_ obstacles: [LayoutProblem.Obstacle]) {
        self.obstacles = obstacles
        for (entry, obstacle) in obstacles.enumerated() {
            bounds = bounds.map { $0.union(obstacle.rect) } ?? obstacle.rect
            guard let span = Self.cells(of: obstacle.rect) else {
                unfiled.append(entry)
                continue
            }
            for x in span.x { for y in span.y { cells[Cell(x: x, y: y), default: []].append(entry) } }
        }
    }

    /// The obstacles that meet `area` (touching counts), in paint order, as the solver asks for
    /// them. The answer to an area asked before is the one kept.
    public func obstacles(in area: CGRect) -> [LayoutProblem.Obstacle] {
        let key = Area(area)
        if let known = answers[key] { return known }
        let found = entries(in: area).map { obstacles[$0] }
        answers[key] = found
        return found
    }

    /// The obstacles that meet `area` (touching counts), by their place in `obstacles` (paint order).
    public func entries(in area: CGRect) -> [Int] {
        guard let bounds, area.isFinite, area.touches(bounds) else { return [] }
        let asked = area.intersection(bounds)
        guard let span = Self.cells(of: asked.isNull ? area : asked) else {
            return obstacles.indices.filter { obstacles[$0].rect.touches(area) }
        }
        var found = Set(unfiled.filter { obstacles[$0].rect.touches(area) })
        for x in span.x {
            for y in span.y {
                for entry in cells[Cell(x: x, y: y)] ?? [] where obstacles[entry].rect.touches(area) { found.insert(entry) }
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
