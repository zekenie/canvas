import CoreGraphics
import DrawScript
import Geometry
import TestKit

// A stand-in for Draw, so solver tests can be written in the language: a board of titled rects,
// kind words with sizes (fixture words only), and a resolver that turns a script into a layout
// problem the way the caller does. Titles on the board that a statement restates with placements
// are free (and not obstacles); restated without placements, they stay put; every other board
// shape is an obstacle, its id its place on the board.

/// Kind words and their sizes: fixture words, never a shipped kind's.
let fixtureSizes: [String: CGSize] = [
    "card": CGSize(width: 200, height: 100),
    "box": CGSize(width: 100, height: 100),
    "disc": CGSize(width: 120, height: 120),
    "pill": CGSize(width: 60, height: 30),
]

/// The word of a kind the caller makes up beside what a script says: its boxes are `implied`.
let impliedWord = "pill"

struct Board {
    var shapes: [(title: String, rect: CGRect)] = []
    var view: CGRect?

    init(_ shapes: [(String, CGRect)] = [], view: CGRect? = nil) {
        self.shapes = shapes.map { (title: $0.0, rect: $0.1) }
        self.view = view
    }

    func index(of title: String) -> Int? { shapes.firstIndex { $0.title == title } }
}

func rect(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> CGRect {
    CGRect(x: x, y: y, width: width, height: height)
}

/// What a draw came to: the boxes placed (by title, or by line), or the error.
struct Drawn {
    var problem: LayoutProblem?
    var solution: LayoutSolution?
    var error: ScriptError?
    var titles: [String?] = []
    var lines: [Int] = []
    var obstacleTitles: [Int: String] = [:]
    /// How many times the solver asked for a name.
    var namesAsked: Box<Int>

    subscript(title: String) -> CGRect? {
        guard let solution, let index = titles.firstIndex(of: title) else { return nil }
        return solution.rects[index]
    }

    func rect(onLine line: Int) -> CGRect? {
        guard let solution, let index = lines.firstIndex(of: line) else { return nil }
        return solution.rects[index]
    }

    /// What a box was pushed past, by title.
    func pushedPast(_ title: String) -> [String] {
        guard let solution, let index = titles.firstIndex(of: title) else { return [] }
        return solution.pushedPast[index].map(named)
    }

    /// The board shapes a box sits in as zones, by title.
    func zones(_ title: String) -> [String] {
        guard let solution, let index = titles.firstIndex(of: title) else { return [] }
        return solution.zones[index].map { named(.obstacle($0.id)) }
    }

    func named(_ ref: LayoutProblem.Ref) -> String {
        switch ref {
        case .free(let box): titles[box] ?? "line \(lines[box])"
        case .obstacle(let id): obstacleTitles[id] ?? "obstacle \(id)"
        case .fixed(let index): "fixed \(index)"
        }
    }
}

final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Reads a script, resolves it against a board as Draw does, and solves it.
func draw(_ source: String, on board: Board = Board(), obstacleOrder: @escaping ([LayoutProblem.Obstacle]) -> [LayoutProblem.Obstacle] = { $0 }) -> Drawn {
    let asked = Box(0)
    let script: Script
    do throws(ScriptErrors) {
        script = try Script(parsing: source)
    } catch {
        return Drawn(error: error.first, namesAsked: asked)
    }
    var free: [LayoutProblem.Free] = []
    var titles: [String?] = []
    var lines: [Int] = []
    var freeIndex: [String: Int] = [:]
    var stays: [String: Gap?] = [:]
    var shapes: [(Statement, ShapeStatement)] = []
    for statement in script.statements {
        guard case .shape(let shape) = statement.body else { continue }
        if let title = shape.title, let at = board.index(of: title) {
            if shape.clauses.isEmpty {
                stays[title] = shape.gap
                continue
            }
            freeIndex[title] = free.count
            let had = board.shapes[at].rect.size
            free.append(LayoutProblem.Free(line: statement.line, name: "\"\(title)\"", size: shape.size?.size(height: had.height) ?? had,
                                           gap: shape.gap, overlapAllowed: shape.overlapAllowed, current: board.shapes[at].rect))
        } else {
            if let title = shape.title { freeIndex[title] = free.count }
            let name = shape.title.map { "\"\($0)\"" } ?? "the \(shape.word) on line \(statement.line)"
            let placed = fixtureSizes[shape.word] ?? CGSize(width: 50, height: 50)
            free.append(LayoutProblem.Free(line: statement.line, name: name, size: shape.size?.size(height: placed.height) ?? placed,
                                           gap: shape.gap, overlapAllowed: shape.overlapAllowed, implied: shape.word == impliedWord))
        }
        titles.append(shape.title)
        lines.append(statement.line)
        shapes.append((statement, shape))
    }

    var obstacles: [LayoutProblem.Obstacle] = []
    var obstacleTitles: [Int: String] = [:]
    for (index, shape) in board.shapes.enumerated() where freeIndex[shape.title] == nil {
        obstacles.append(LayoutProblem.Obstacle(id: index, rect: shape.rect))
        obstacleTitles[index] = shape.title
    }
    var fixed: [LayoutProblem.Fixed] = []
    var fixedNames: [String] = []
    var fixedIndex: [String: Int] = [:]
    func fixedRef(_ key: String, _ make: () -> LayoutProblem.Fixed) -> LayoutProblem.Ref {
        if let at = fixedIndex[key] { return .fixed(at) }
        fixedIndex[key] = fixed.count
        fixed.append(make())
        fixedNames.append(key)
        return .fixed(fixed.count - 1)
    }
    let boardBounds = obstacles.isEmpty ? nil : obstacles.map(\.rect).reduce(CGRect.null) { $0.union($1) }
    for (index, (_, shape)) in shapes.enumerated() {
        free[index].clauses = shape.clauses.map { clause in
            let refs: [LayoutProblem.Ref] = clause.targets.map { target in
                switch target.box {
                case .title(let title):
                    if let at = freeIndex[title] { return .free(at) }
                    guard let at = board.index(of: title) else { return .fixed(-1) }
                    return fixedRef("\"\(title)\"") {
                        LayoutProblem.Fixed(rect: board.shapes[at].rect, gap: stays[title] ?? nil, obstacle: at)
                    }
                case .id: return .fixed(-1)
                case .board: return fixedRef("board") { LayoutProblem.Fixed(rect: boardBounds ?? .zero, word: .board) }
                case .view: return fixedRef("view") { LayoutProblem.Fixed(rect: board.view ?? .zero, word: .view) }
                }
            }
            return LayoutProblem.ResolvedClause(clause, refs: refs)
        }
    }
    let all = obstacles
    let problem = LayoutProblem(
        free: free, fixed: fixed,
        obstacles: { area in obstacleOrder(all.filter { $0.rect.intersects(area) }) },
        boardBounds: boardBounds,
        viewMiddle: board.view?.center ?? .zero, view: board.view,
        name: { ref in
            asked.value += 1
            switch ref {
            case .fixed(let index): return fixedNames[index]
            case .obstacle(let id): return "\"\(obstacleTitles[id] ?? "?")\""
            case .free(let box): return free[box].name
            }
        })
    var drawn = Drawn(problem: problem, titles: titles, lines: lines, obstacleTitles: obstacleTitles, namesAsked: asked)
    do throws(ScriptError) {
        drawn.solution = try problem.solve()
    } catch {
        drawn.error = error
    }
    return drawn
}

/// The first error reading a script gives, if any.
func parseError(_ source: String) -> ScriptError? {
    do throws(ScriptErrors) {
        _ = try Script(parsing: source)
        return nil
    } catch {
        return error.first
    }
}

/// Every error reading a script gives.
func parseErrors(_ source: String) -> [ScriptError] {
    do throws(ScriptErrors) {
        _ = try Script(parsing: source)
        return []
    } catch {
        return error.errors
    }
}

/// The one statement a line says, read.
func parse(_ source: String) throws -> Statement.Body {
    do throws(ScriptErrors) {
        let script = try Script(parsing: source)
        return script.statements[0].body
    } catch {
        throw error
    }
}

/// The shape a line says.
@MainActor
func shape(_ source: String, file: StaticString = #fileID, line: UInt = #line) throws -> ShapeStatement {
    guard case .shape(let shape) = try parse(source) else {
        expect(false, "\(source) isn't a shape", file: file, line: line)
        throw RequireFailed()
    }
    return shape
}

/// The clauses a shape line says, quoted back.
@MainActor
func written(_ source: String) throws -> [String] {
    try shape(source).clauses.map(\.written)
}

@MainActor
func expectRect(_ actual: CGRect?, _ expected: CGRect, file: StaticString = #fileID, line: UInt = #line) {
    guard let actual else {
        expect(false, "no rect, expected \(expected)", file: file, line: line)
        return
    }
    expectClose(actual.origin, expected.origin, within: 1e-6, file: file, line: line)
    expectClose(CGPoint(x: actual.width, y: actual.height), CGPoint(x: expected.width, y: expected.height), within: 1e-6, file: file, line: line)
}

@MainActor
func expectError(_ drawn: Drawn, _ reason: ScriptError.Reason, _ message: String? = nil, line: Int? = nil, file: StaticString = #fileID, sourceLine: UInt = #line) {
    guard let error = drawn.error else {
        expect(false, "expected \(reason), got \(drawn.solution.map { "\($0.rects)" } ?? "nothing")", file: file, line: sourceLine)
        return
    }
    expectEqual(error.reason, reason, error.message, file: file, line: sourceLine)
    if let message { expectEqual(error.message, message, file: file, line: sourceLine) }
    if let line { expectEqual(error.line, line, file: file, line: sourceLine) }
}

/// Why solving a problem fails, or nil if it doesn't.
func reason(solving problem: LayoutProblem) -> ScriptError.Reason? {
    do throws(ScriptError) {
        let solution = try problem.solve()
        _ = solution
        return nil
    } catch {
        return error.reason
    }
}
