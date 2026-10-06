import CoreGraphics
import DrawScript
import Geometry
import TestKit

// The solver's obstacles, filed in a grid (`ObstacleGrid`): whatever the grid answers must be what
// going through every obstacle would say, in paint order, whichever cells they're filed in.

/// Obstacles at `rects`, in paint order, numbered as a board numbers its shapes: some places on it
/// are no obstacle's (an arrow's), so an id is never an obstacle's place in the grid.
private func obstacles(_ rects: CGRect...) -> [LayoutProblem.Obstacle] {
    rects.enumerated().map { LayoutProblem.Obstacle(id: 10 + $0.offset * 3, rect: $0.element) }
}

/// What going through every obstacle says meets `area` (finite), by place: the grid's answer, the slow way.
private func met(by all: [LayoutProblem.Obstacle], _ area: CGRect) -> [Int] {
    all.indices.filter { all[$0].rect.touches(area) }
}

/// A fixed run of numbers, so a failure is the same failure every time.
private struct Numbers {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// One of `0..<count`.
    mutating func below(_ count: Int) -> Int { Int(next() % UInt64(count)) }

    mutating func pick<T>(_ choices: [T]) -> T { choices[below(choices.count)] }
}

@MainActor let obstacleGridTests = Suite("The obstacle grid", [
    test("an area meets the obstacles it overlaps and those it only touches, and none it clears") {
        let all = obstacles(rect(0, 0, 100, 100), rect(100, 0, 100, 100), rect(600, 600, 100, 100))
        let grid = ObstacleGrid(all)
        expectEqual(grid.entries(in: rect(100, 0, 50, 50)), [0, 1], "on the first's right edge, in the second")
        expectEqual(grid.entries(in: rect(200, 100, 10, 10)), [1], "on the second's corner")
        expectEqual(grid.entries(in: rect(201, 0, 10, 10)), [], "a unit clear of the second, in the first's cell")
        expectEqual(grid.entries(in: rect(-10, -10, 5, 5)), [], "off the board")
        expectEqual(grid.obstacles(in: rect(650, 650, 1, 1)), [all[2]])
    },
    test("answers come in paint order, whatever cells the obstacles are filed in") {
        // The first sits far right, the third spans a row of cells, the fifth is too big to file, the second and the last share a cell.
        let all = obstacles(rect(3000, 0, 100, 100), rect(0, 0, 100, 100), rect(0, 0, 4000, 300), rect(2000, 0, 100, 100),
                            rect(-100, -100, 600_000, 600_000), rect(50, 50, 100, 100))
        let grid = ObstacleGrid(all)
        expectEqual(grid.entries(in: rect(-50, -50, 5000, 500)), [0, 1, 2, 3, 4, 5])
        expectEqual(grid.obstacles(in: rect(-50, -50, 5000, 500)).map(\.id), [10, 13, 16, 19, 22, 25], "each with the id it was given")
        expectEqual(grid.entries(in: rect(60, 60, 10, 10)), [1, 2, 4, 5])
        expectEqual(grid.entries(in: rect(2050, 50, 10, 10)), [2, 3, 4])
    },
    test("an obstacle on a cell's edge is met from either side of it, and one a hair away isn't") {
        let edge = ObstacleGrid.cellSize
        // The first starts on the line between two cells, the second ends on it.
        let grid = ObstacleGrid(obstacles(rect(edge, 0, 10, 10), rect(0, 0, edge, 10)))
        expectEqual(grid.entries(in: rect(0, 0, edge, 5)), [0, 1], "an area ending on the line meets what starts on it")
        expectEqual(grid.entries(in: rect(edge, 0, 5, 5)), [0, 1], "an area starting on it meets what ends on it")
        expectEqual(grid.entries(in: rect(0, 0, edge - 1, 5)), [1])
        expectEqual(grid.entries(in: rect(edge + 10, 0, 5, 5)), [0], "touching the first's far edge")
        expectEqual(grid.entries(in: rect(edge + 11, 0, 5, 5)), [], "a unit past it")
    },
    test("an obstacle too big to file cell by cell is answered wherever it is, and only there") {
        // One side of more cells than the grid files; and a block whose sides are fewer, but whose cells are too many.
        let long = rect(0, 0, ObstacleGrid.cellSize * CGFloat(ObstacleGrid.maxCells + 1), 100)
        let side = ObstacleGrid.cellSize * CGFloat(ObstacleGrid.maxCells / 10)
        let block = rect(0, 0, side, side)
        let all = obstacles(rect(long.maxX - 400, 40, 50, 50), long, rect(10, 10, 20, 20), block, rect(side - 600, side - 600, 50, 50))
        let grid = ObstacleGrid(all)
        expectEqual(grid.entries(in: rect(long.maxX - 390, 50, 5, 5)), [0, 1], "the far end of the long one, and what's there")
        expectEqual(grid.entries(in: rect(20, 20, 1, 1)), [1, 2, 3], "at the origin, where all three overlap")
        expectEqual(grid.entries(in: rect(side - 590, side - 590, 1, 1)), [3, 4], "the far corner of the block")
        expectEqual(grid.entries(in: rect(long.maxX, 100, 5, 5)), [1], "on the long one's corner")
        expectEqual(grid.entries(in: rect(long.maxX / 2, 200, 5, 5)), [], "below it, clear of the block too")
    },
    test("coordinates too far out to count cells for are answered too, beside obstacles near") {
        let all = obstacles(rect(2e15, 0, 100, 100), rect(0, 0, 100, 100), rect(-3e15, -3e15, 10, 10), rect(50, 50, 100, 100))
        let grid = ObstacleGrid(all)
        expectEqual(grid.entries(in: rect(2e15 + 50, 50, 10, 10)), [0])
        expectEqual(grid.entries(in: rect(-3e15, -3e15, 5, 5)), [2])
        expectEqual(grid.entries(in: rect(0, 0, 120, 120)), [1, 3], "near the origin, past the far ones")
        expectEqual(grid.entries(in: rect(-1e16, -1e16, 2e16, 2e16)), [0, 1, 2, 3], "all of them")
        expectEqual(grid.entries(in: .infinite), [0, 1, 2, 3], "the whole plane")
        expectEqual(grid.bounds, rect(-3e15, -3e15, 5e15 + 100, 3e15 + 150), "and they're in the bounds")
    },
    test("coordinates past what a cell's number can hold are answered too, not trapped on") {
        let grid = ObstacleGrid(obstacles(rect(1e300, 1e300, 10, 10), rect(0, 0, 100, 100)))
        expectEqual(grid.entries(in: rect(1e300, 1e300, 5, 5)), [0])
        expectEqual(grid.entries(in: rect(10, 10, 5, 5)), [1])
        expectEqual(grid.entries(in: rect(-1e301, -1e301, 2e301, 2e301)), [0, 1])
        expectEqual(grid.entries(in: .infinite), [0, 1])
    },
    test("an area that isn't finite meets nothing") {
        let grid = ObstacleGrid(obstacles(rect(0, 0, 100, 100)))
        expectEqual(grid.entries(in: .null), [])
        expectEqual(grid.entries(in: rect(.nan, 0, 10, 10)), [])
        expectEqual(grid.entries(in: rect(0, 0, .infinity, 10)), [])
        expectEqual(grid.obstacles(in: .null), [])
    },
    test("an area asked again is answered with what was found the first time") {
        let grid = ObstacleGrid(obstacles(rect(0, 0, 100, 100), rect(80, 80, 100, 100), rect(1000, 1000, 10, 10)))
        let first = grid.obstacles(in: rect(90, 90, 5, 5)), again = grid.obstacles(in: rect(90, 90, 5, 5))
        expectEqual(first.map(\.id), [10, 13])
        expectEqual(again, first)
        // The same array, not another found the same way: the second shares the first's storage.
        let kept = first.withUnsafeBufferPointer { $0.baseAddress }
        expect(kept != nil && kept == again.withUnsafeBufferPointer { $0.baseAddress }, "the answer is kept")
        let other = grid.obstacles(in: rect(90, 90, 6, 5))
        expect(kept != other.withUnsafeBufferPointer { $0.baseAddress }, "another area's answer is its own")
    },
    test("bounds are all the obstacles together, and obstacles is what the grid was made from") {
        let all = obstacles(rect(10, 20, 30, 40), rect(-50, 100, 10, 10), rect(500, -5, 1, 1))
        let grid = ObstacleGrid(all)
        expectEqual(grid.bounds, rect(-50, -5, 551, 115))
        expectEqual(grid.obstacles, all)
        expectEqual(ObstacleGrid(Array(all.prefix(1))).bounds, rect(10, 20, 30, 40), "one: its own")
    },
    test("with none, nothing is met, and there are no bounds") {
        let grid = ObstacleGrid([])
        expectEqual(grid.bounds, nil)
        expectEqual(grid.obstacles, [])
        expectEqual(grid.entries(in: rect(0, 0, 100, 100)), [])
        expectEqual(grid.obstacles(in: .infinite), [])
    },
    test("it answers as going through every obstacle does, for obstacles and areas of every size and place") {
        var numbers = Numbers(state: 2025)
        // On a lattice that lands on cell edges as often as not: specks, shapes, long thin ones, and some
        // too big to file (a long thin one past the cells a grid files, and blocks of too many).
        let places: [CGFloat] = (-80...160).map { CGFloat($0) * 64 }
        let sizes: [(w: CGFloat, h: CGFloat)] = [(64, 64), (160, 120), (200, 200), (256, 256), (320, 160), (1000, 60), (60, 1000), (4096, 64),
                                                 (64, 4096), (8192, 256), (256, 8192), (40_000, 64), (64, 40_000), (400_000, 64), (64, 400_000),
                                                 (0, 64), (64, 0), (0, 0)]
        var rects: [CGRect] = []
        for _ in 0..<350 {
            let size = numbers.pick(sizes)
            rects.append(rect(numbers.pick(places), numbers.pick(places), size.w, size.h))
        }
        rects += [rect(9216, 9216, 8191, 8191), rect(9216, 9216, 8192, 8192), rect(10_000, 10_000, 300_000, 300_000)]
        rects += [rect(2e15, 3e15, 64, 64), rect(-3e15, -1.5e15, 64, 64), rect(7e15, 0, 64, 64)]
        let all = rects.enumerated().map { LayoutProblem.Obstacle(id: $0.offset * 2, rect: $0.element) }
        let grid = ObstacleGrid(all)
        expectEqual(grid.obstacles, all)
        var wrong: [CGRect] = [], hits = 0, misses = 0
        for _ in 0..<600 {
            let near = numbers.below(20) != 0
            let area = near ? CGRect(x: numbers.pick(places) + CGFloat(numbers.below(3)) * 32, y: numbers.pick(places),
                                     width: numbers.pick([0, 1, 63, 64, 256, 1000, 5000]), height: numbers.pick([0, 1, 64, 255, 300, 5000, 20_000]))
                             : CGRect(x: numbers.pick([2e15, -3e15, 7e15, -1e16]), y: numbers.pick([0, 3e15, -1.5e15, 3.5e15]),
                                      width: numbers.pick([64, 1e15, 2e16]), height: numbers.pick([64, 1e15, 2e16]))
            let expected = met(by: all, area)
            if grid.entries(in: area) != expected || grid.obstacles(in: area) != expected.map({ all[$0] }) { wrong.append(area) }
            if expected.isEmpty { misses += 1 } else { hits += 1 }
        }
        expectEqual(Array(wrong.prefix(3)), [], "areas where the grid and going through every obstacle disagree, of \(wrong.count)")
        expect(hits > 50 && misses > 50, "areas that meet some obstacles and areas that meet none, to tell the two apart: \(hits), \(misses)")
    },
])
