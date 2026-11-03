@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// Walking shapes (`ShapeWalk`): a client's rows, each with stops, gone through stop by stop, wrapping, the
// whole walk one step back. The rows here are a list a test sets (`Rows`); Find is the shipped client, and
// FindTests hold its stepping unchanged.

private let view = CGSize(width: 1000, height: 700)
private let near = CGRect(x: 0, y: 0, width: 100, height: 100)
private let far = CGRect(x: 3000, y: 2000, width: 100, height: 100)

private func revealed(_ frame: CGRect) -> Camera { Camera(fitting: frame, in: view, inset: 100, maxZoom: 1.2) }

/// A root holding box A, pocket P and a ghost G (which can't be selected); P's board holding box N near its
/// origin and box F far from it; and a shape on a board whose owner is nowhere (it can't be shown).
private struct Tree {
    let a = ShapeID(), p = ShapeID(), g = ShapeID(), n = ShapeID(), f = ShapeID(), lost = ShapeID(), orphan = ShapeID()
    var pBoard: BoardID { BoardID(owner: p) }
    var orphanBoard: BoardID { BoardID(owner: orphan) }

    var file: CanvasFile {
        let box = { (id: ShapeID, frame: CGRect) in AnyShapeRecord(ShapeRecord(id: id, Box(frame))) }
        return CanvasFile(root: CanvasDocument(shapes: [box(a, near), AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 200, y: 0, width: 100, height: 100)))),
                                                        AnyShapeRecord(ShapeRecord(id: g, Ghost(CGRect(x: 400, y: 0, width: 100, height: 100))))]),
                          children: [p: CanvasDocument(shapes: [box(n, near), box(f, far)]),
                                     orphan: CanvasDocument(shapes: [box(lost, near)])])
    }
}

/// Rows a test sets: one shape on one board each, with the stops it says, ranked by place.
@MainActor private final class Rows: ShapeWalkSource {
    var rows: [WalkRow] = []
    /// How often the walk said it moved.
    var moves = 0
    /// Where a stop's part of its shape is, by row.
    var focus: [Int: CGRect] = [:]
    var placed: Int?

    init(_ list: [(ShapeID, BoardID, Int)]) { set(list) }

    func set(_ list: [(ShapeID, BoardID, Int)]) {
        rows = list.enumerated().map { WalkRow(key: $1.0, shape: $1.0, board: $1.1, stops: $1.2, rank: $0 * 10) }
    }

    var walkRowCount: Int { rows.count }
    func walkRow(at index: Int) -> WalkRow { rows[index] }
    func walkPlace(ofKey key: AnyHashable) -> Int? { rows.firstIndex { $0.key == key } }
    var walkTotal: Int { rows.reduce(0) { $0 + $1.stops } }
    func walkStops(before index: Int) -> Int { rows[..<index].reduce(0) { $0 + $1.stops } }
    func walkFocus(of position: WalkPosition) -> CGRect? { focus[position.row] }
    func walkDidMove() { moves += 1 }
}

/// What a test's walks hold weakly or unowned (a walk's source, the editor), kept for the test: the
/// next test's first harness lets the last one's go.
@MainActor private var held: [AnyObject] = []

@MainActor private func attach(_ walk: ShapeWalk, _ source: some ShapeWalkSource) {
    held.append(source)
    walk.source = source
}

@MainActor private func harness(_ tree: Tree) throws -> EditorHarness {
    held.removeAll()
    let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), PocketsPlugin(), GhostsPlugin()], file: tree.file)
    h.editor.viewportDidResize(to: view)
    held.append(h)
    return h
}

/// A walk over the rows, each on the root (the shapes a test adds there), as rows of these stops.
@MainActor private func flat(_ stops: [Int], arrival: WalkArrival = .shows) throws -> (EditorHarness, ShapeWalk, Rows) {
    held.removeAll()
    let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
    h.editor.viewportDidResize(to: view)
    held.append(h)
    let ids = stops.indices.map { i in h.add(Box(CGRect(x: CGFloat(i) * 150, y: 0, width: 100, height: 100))) }
    let rows = Rows(zip(ids, stops).map { ($0, BoardID.root, $1) })
    let walk = ShapeWalk(editor: h.editor, arrival: arrival)
    attach(walk, rows)
    return (h, walk, rows)
}

/// The walk's place as (row, ordinal).
@MainActor private func place(_ walk: ShapeWalk) -> [Int]? { walk.current.map { [$0.row, $0.ordinal] } }

@MainActor let walkTests = Suite("Walking shapes", [
    test("a step goes stop by stop through the rows' stops, wrapping, numbering from 1 in all; the first going on or back from nothing") {
        let (_, walk, rows) = try flat([2, 1, 3])
        expectEqual(rows.walkTotal, 6)
        expectEqual(walk.number, nil)
        var seen: [[Int]] = [], numbers: [Int] = []
        for _ in 0..<7 {
            walk.step(forward: true)
            seen.append(place(walk)!); numbers.append(walk.number!)
        }
        expectEqual(seen, [[0, 0], [0, 1], [1, 0], [2, 0], [2, 1], [2, 2], [0, 0]], "the last row's last stop, then round to the first")
        expectEqual(numbers, [1, 2, 3, 4, 5, 6, 1])
        walk.step(forward: false)
        expectEqual(place(walk), [2, 2], "back from the first wraps to the last row's last stop")
        expectEqual(walk.number, 6)
        walk.step(forward: false)
        expectEqual(place(walk), [2, 1])
        walk.land(at: nil)
        walk.step(forward: false)
        expectEqual(place(walk), [2, 2], "back from nothing is the last")
        expectEqual(walk.stepCount, 7 + 1 + 1 + 1, "every step counts; landing does not")
        expectEqual(rows.moves, walk.stepCount)
    },
    test("a row with no stops stays in the walk: a step passes it, a move and a pick reach it, and a step goes on from it") {
        let (_, walk, _) = try flat([1, 0, 2, 0])
        walk.step(forward: true); walk.step(forward: true)
        expectEqual(place(walk), [2, 0], "the empty row passed")
        walk.step(forward: true); walk.step(forward: true)
        expectEqual(place(walk), [0, 0], "wrapped past the last, empty row")
        walk.step(forward: false)
        expectEqual(place(walk), [2, 1], "back past the empty last row, to the last stop")
        walk.move(by: 1)
        expectEqual(place(walk), [3, 0], "a move reaches it")
        expectEqual(walk.number, 4, "its number follows the stops before it")
        walk.step(forward: false)
        expectEqual(place(walk), [2, 1])
        walk.pick(row: 1)
        expectEqual(place(walk), [1, 0])
        walk.step(forward: true)
        expectEqual(place(walk), [2, 0], "from an empty row, on to the next stop")
        walk.pick(row: 1)
        walk.step(forward: false)
        expectEqual(place(walk), [0, 0], "and back to the one before")
        let (_, none, rows2) = try flat([0, 0])
        none.step(forward: true); none.step(forward: false)
        expectEqual(none.current, nil, "no row has a stop")
        expectEqual(none.stepCount, 0)
        expectEqual(rows2.moves, 0)
    },
    test("a move goes by rows, wrapping; with nothing current down goes to the first and up to the last; a pick goes to a row; both count") {
        let (_, walk, _) = try flat([2, 1, 3, 1])
        walk.move(by: -1)
        expectEqual(place(walk), [3, 0])
        walk.move(by: 2)
        expectEqual(place(walk), [1, 0], "round the end")
        walk.step(forward: true)
        walk.step(forward: true)
        walk.move(by: -3)
        expectEqual(place(walk), [3, 0], "its first stop, from wherever in its row")
        walk.land(at: nil)
        walk.move(by: 8)
        expectEqual(place(walk), [0, 0])
        walk.pick(row: 2)
        expectEqual(place(walk), [2, 0])
        walk.pick(row: 4)
        walk.pick(row: -1)
        expectEqual(place(walk), [2, 0], "no such row")
        expectEqual(walk.stepCount, 2 + 2 + 1 + 1 + 1)
    },
    test("boards: the rows of a board are a run, a move by board goes to a run's first row, wrapping") {
        let tree = Tree()
        let h = try harness(tree)
        let rows = Rows([(tree.a, .root, 1), (tree.p, .root, 1), (tree.n, tree.pBoard, 1), (tree.f, tree.pBoard, 2), (tree.lost, tree.orphanBoard, 1)])
        let walk = ShapeWalk(editor: h.editor, arrival: .shows)
        attach(walk, rows)
        expectEqual(walk.boardRuns(), [WalkBoardRun(board: .root, rows: 0..<2), WalkBoardRun(board: tree.pBoard, rows: 2..<4),
                                       WalkBoardRun(board: tree.orphanBoard, rows: 4..<5)])
        walk.moveBoard(by: -1)
        expectEqual(place(walk), [4, 0], "up from nothing: the last board")
        walk.moveBoard(by: 1)
        expectEqual(place(walk), [0, 0], "wrapped")
        walk.pick(row: 1)
        walk.moveBoard(by: 1)
        expectEqual(place(walk), [2, 0])
        walk.pick(row: 3)
        walk.moveBoard(by: 0)
        expectEqual(place(walk), [2, 0], "the current board's first")
        walk.moveBoard(by: -1)
        expectEqual(place(walk), [0, 0])
        rows.set([])
        expectEqual(walk.boardRuns(), [])
        walk.rowsDidChange()
        walk.moveBoard(by: 1)
        expectEqual(walk.current, nil)
    },
    test("shows: a stop on another board shows the board and leaves nothing selected; the camera moves only for what is out of view") {
        let tree = Tree()
        let h = try harness(tree)
        let rows = Rows([(tree.a, .root, 1), (tree.n, tree.pBoard, 1), (tree.f, tree.pBoard, 1)])
        let walk = ShapeWalk(editor: h.editor, arrival: .shows)
        attach(walk, rows)
        h.editor.selection = tree.a
        let camera = h.editor.camera
        walk.step(forward: true)
        expectEqual(h.editor.board, .root)
        h.wait(300)
        expectEqual(h.editor.camera, camera, "in view already")
        walk.step(forward: true)
        expectEqual(h.editor.board, tree.pBoard)
        expectEqual(h.editor.selectedShapeIDs, [], "showing a board empties the selection, and nothing selects")
        h.wait(300)
        let shown = h.editor.camera
        walk.step(forward: true)
        h.wait(300)
        expectEqual(h.editor.camera, shown, "a board's first visit shows all it holds: nothing to bring in")
        h.editor.camera = Camera()
        walk.step(forward: false)
        h.wait(300)
        expectEqual(h.editor.camera, Camera(), "N is in view")
        walk.step(forward: true)
        h.wait(300)
        expectEqual(h.editor.camera, revealed(far), "F is out of view: brought in")
        expectEqual(h.editor.selectedShapeIDs, [])
    },
    test("shows on the board shown, a stop out of view, the walk ended there: Back returns the camera to where it began, with the selection it never changed") {
        let tree = Tree()
        let h = try harness(tree)
        let distant = h.add(Box(far))
        let rows = Rows([(distant, .root, 1)])
        let walk = ShapeWalk(editor: h.editor, arrival: .shows)
        attach(walk, rows)
        h.editor.selection = tree.a
        walk.begin()
        walk.step(forward: true)
        h.wait(300)
        expectEqual(h.editor.camera, revealed(far))
        walk.end()
        expectEqual(h.editor.selectedShapeIDs, [tree.a])
        expect(h.editor.canGoBack, "a place of its own, though only the camera moved")
        h.editor.goBack()
        h.wait(300)
        expectEqual(h.editor.camera, Camera())
        expectEqual(h.editor.selectedShapeIDs, [tree.a])
        expect(!h.editor.canGoBack)
    },
    test("shows: a stop's focus rect, not its shape, is what has to be in view") {
        let tree = Tree()
        let h = try harness(tree)
        let rows = Rows([(tree.n, tree.pBoard, 1)])
        let walk = ShapeWalk(editor: h.editor, arrival: .shows)
        attach(walk, rows)
        rows.focus[0] = CGRect(x: 5000, y: 5000, width: 10, height: 10)
        walk.step(forward: true)
        h.wait(300)
        expect(h.editor.camera != Camera(), "the shape is in view, its part is not: the camera moved")
        expect(h.editor.camera.toWorld(CGRect(origin: .zero, size: view)).contains(near), "to the shape")
    },
    test("selects: a stop's shape is selected where it is, its board shown, and brought into view unless readably in view") {
        let tree = Tree()
        let h = try harness(tree)
        let rows = Rows([(tree.a, .root, 1), (tree.n, tree.pBoard, 1), (tree.f, tree.pBoard, 1)])
        let walk = ShapeWalk(editor: h.editor, arrival: .selects)
        attach(walk, rows)
        let camera = h.editor.camera
        walk.step(forward: true)
        expectEqual(h.editor.selectedShapeIDs, [tree.a])
        h.wait(300)
        expectEqual(h.editor.camera, camera)
        walk.step(forward: true)
        expectEqual(h.editor.board, tree.pBoard)
        expectEqual(h.editor.selectedShapeIDs, [tree.n])
        walk.step(forward: true)
        h.wait(300)
        expectEqual(h.editor.selectedShapeIDs, [tree.f])
        expectEqual(h.editor.camera, revealed(far))
    },
    test("selects: the focus rect is brought into view if it is not, and the camera stays when it is") {
        let tree = Tree()
        let h = try harness(tree)
        let rows = Rows([(tree.a, .root, 1)])
        let walk = ShapeWalk(editor: h.editor, arrival: .selects)
        attach(walk, rows)
        rows.focus[0] = CGRect(x: 10, y: 10, width: 20, height: 20)
        let camera = h.editor.camera
        walk.step(forward: true)
        h.wait(300)
        expectEqual(h.editor.camera, camera, "in view")
        rows.focus[0] = CGRect(x: 4000, y: 3000, width: 20, height: 20)
        walk.step(forward: true)
        h.wait(300)
        expect(h.editor.camera != camera, "its part was out of view")
        expect(h.editor.camera.toWorld(CGRect(origin: .zero, size: view)).contains(rows.focus[0]!))
    },
    test("selects never assumes the shape was selected: a shape that can't be, or on a board that can't be shown, is still the stop, and the walk goes past it") {
        let tree = Tree()
        let h = try harness(tree)
        let rows = Rows([(tree.a, .root, 1), (tree.g, .root, 1), (tree.lost, tree.orphanBoard, 1), (tree.n, tree.pBoard, 1)])
        let walk = ShapeWalk(editor: h.editor, arrival: .selects)
        attach(walk, rows)
        walk.step(forward: true)
        expectEqual(h.editor.selectedShapeIDs, [tree.a])
        walk.step(forward: true)
        expectEqual(place(walk), [1, 0], "the ghost is the stop")
        expectEqual(h.editor.selectedShapeIDs, [tree.a], "which can't be selected: the selection stays")
        walk.step(forward: true)
        expectEqual(place(walk), [2, 0], "so is the shape on a board that can't be shown")
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [tree.a])
        walk.step(forward: true)
        expectEqual(place(walk), [3, 0])
        expectEqual(h.editor.selectedShapeIDs, [tree.n])
        expectEqual(walk.number, 4)
        let showing = ShapeWalk(editor: h.editor, arrival: .shows)
        attach(showing, rows)
        showing.pick(row: 2)
        expectEqual(place(showing), [2, 0])
        expectEqual(h.editor.board, tree.pBoard, "shows: a board that can't be shown leaves the one shown")
    },
    test("the whole walk is one step back, to where it began, however the person moved between; Forward returns to the last stop") {
        let tree = Tree()
        let h = try harness(tree)
        let rows = Rows([(tree.a, .root, 1), (tree.n, tree.pBoard, 1), (tree.f, tree.pBoard, 1), (tree.p, .root, 1)])
        let walk = ShapeWalk(editor: h.editor, arrival: .selects)
        attach(walk, rows)
        h.editor.selection = tree.p
        let camera = h.editor.camera
        walk.begin()
        expect(walk.isRunning)
        walk.step(forward: true)
        walk.step(forward: true)
        h.editor.camera = Camera(origin: CGPoint(x: -400, y: -400), zoom: 1)
        walk.step(forward: true)
        h.wait(300)
        walk.step(forward: true)
        walk.move(by: 1)
        walk.pick(row: 2)
        h.wait(300)
        expectEqual(h.editor.board, tree.pBoard)
        expectEqual(h.editor.selectedShapeIDs, [tree.f])
        expect(h.editor.canGoBack)
        h.editor.goBack()
        expectEqual(h.editor.board, .root, "where it began")
        expectEqual(h.editor.selectedShapeIDs, [tree.p])
        expectEqual(h.editor.camera, camera)
        expect(!h.editor.canGoBack, "one step: selecting P, in view, was none of its own")
        expect(h.editor.canGoForward)
        h.editor.goForward()
        expectEqual(h.editor.board, tree.pBoard, "the last stop")
        expectEqual(h.editor.selectedShapeIDs, [tree.f])
    },
    test("shows is one step back too, even when the stepping moved only the camera and the board, and a step that moves nothing adds none") {
        let tree = Tree()
        let h = try harness(tree)
        let rows = Rows([(tree.a, .root, 1), (tree.f, tree.pBoard, 1)])
        let walk = ShapeWalk(editor: h.editor, arrival: .shows)
        attach(walk, rows)
        h.editor.selection = tree.a
        h.editor.goBack()
        h.editor.selection = tree.a
        walk.begin()
        walk.step(forward: true)
        expect(!h.editor.canGoBack, "in view on the board shown: the walk's step moved nothing, and selecting A, in view, was no step of its own")
        h.editor.selection = tree.a
        walk.begin()
        walk.step(forward: true)
        h.wait(300)
        expectEqual(h.editor.board, tree.pBoard)
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [tree.a])
    },
    test("without a begun walk the moves record what they do; a walk begun again starts anew; end leaves the place and the editor") {
        let tree = Tree()
        let h = try harness(tree)
        let rows = Rows([(tree.a, .root, 1), (tree.n, tree.pBoard, 1)])
        let walk = ShapeWalk(editor: h.editor, arrival: .selects)
        attach(walk, rows)
        walk.step(forward: true)
        walk.step(forward: true)
        expectEqual(h.editor.selectedShapeIDs, [tree.n])
        walk.begin()
        walk.step(forward: true)
        expectEqual(h.editor.selectedShapeIDs, [tree.a])
        walk.end()
        expect(!walk.isRunning)
        expectEqual(place(walk), [0, 0])
        expectEqual(h.editor.board, .root)
    },
    test("selects: a focus rect is not asked for, nor the camera moved, when the stop's board can't be shown") {
        let tree = Tree()
        let h = try harness(tree)
        let rows = Rows([(tree.lost, tree.orphanBoard, 1)])
        let walk = ShapeWalk(editor: h.editor, arrival: .selects)
        attach(walk, rows)
        rows.focus[0] = CGRect(x: 4000, y: 3000, width: 20, height: 20)
        let camera = h.editor.camera
        walk.step(forward: true)
        h.wait(300)
        expectEqual(place(walk), [0, 0])
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.camera, camera, "a rect of another board means nothing on this one")
    },
    test("a click in view between moves adds no step, nor does the walk after its first move: Back reaches the walk's start, then no more") {
        let (h, walk, rows) = try flat([1, 1, 1, 1], arrival: .selects)
        let ids = rows.rows.map(\.shape)
        h.editor.selection = ids[2]
        walk.begin()
        walk.step(forward: true)
        expectEqual(h.editor.selectedShapeIDs, [ids[0]])
        h.editor.selection = ids[3]
        walk.step(forward: true)
        expectEqual(h.editor.selectedShapeIDs, [ids[1]])
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [ids[2]], "the walk's start, put on the history once: the click, in view, was no step of its own")
        expect(!h.editor.canGoBack, "selecting the start, in view, was none either")
    },
    test("after end the next moves record their own step from where they find the editor; a walk begun again starts anew") {
        let (h, walk, rows) = try flat([1, 1, 1], arrival: .selects)
        let ids = rows.rows.map(\.shape)
        h.editor.selection = ids[2]
        walk.begin()
        walk.step(forward: true)
        walk.end()
        h.editor.selection = ids[2]
        walk.step(forward: true)
        expectEqual(h.editor.selectedShapeIDs, [ids[1]])
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [ids[2]], "the move after end is a step of its own, from where it found the editor")
        h.editor.selection = ids[1]
        walk.begin()
        walk.step(forward: true)
        expectEqual(h.editor.selectedShapeIDs, [ids[2]])
        h.editor.goBack()
        expectEqual(h.editor.selectedShapeIDs, [ids[1]], "Back returns to the second begin's start")
    },
    test("a kept row that now has no stops stays current, is numbered, and a step passes it; a search over many rows finds a gone row's rank") {
        let (h, walk, rows) = try flat([2, 1, 1])
        walk.pick(row: 0); walk.step(forward: true)
        let kept = walk.kept
        let ids = rows.rows.map(\.shape)
        rows.set([(ids[0], .root, 0), (ids[1], .root, 1), (ids[2], .root, 1)])
        walk.rowsDidChange(keeping: kept)
        expectEqual(place(walk), [0, 0], "the row stays, its stop clamped to none")
        expectEqual(walk.number, 1)
        walk.step(forward: true)
        expectEqual(place(walk), [1, 0], "a step passes it")
        // seven rows ranked 0, 10, ... 60; the current row's key is gone
        let more = (0..<7).map { _ in h.add(Box(CGRect(x: 0, y: 300, width: 10, height: 10))) }
        let board = BoardID.root
        let make = { (ranks: [Int]) in
            rows.rows = ranks.enumerated().map { WalkRow(key: more[$0.offset], shape: more[$0.offset], board: board, stops: 1, rank: $0.element) }
        }
        for gone in [0, 5, 25, 35, 45, 55, 65, 70] {
            make([0, 10, 20, 30, 40, 50, 60])
            walk.land(at: WalkPosition(row: 3, ordinal: 0))
            let k = WalkKept(key: ShapeID(), ordinal: 0, rank: gone)
            walk.rowsDidChange(keeping: k)
            let want = [0, 10, 20, 30, 40, 50, 60].firstIndex { $0 >= gone } ?? 0
            expectEqual(place(walk), [want, 0], "rank \(gone)")
        }
    },
    test("finish closes the walk, then selects the current stop's shape as part of the one step back to where it began") {
        let tree = Tree()
        let h = try harness(tree)
        let rows = Rows([(tree.a, .root, 1), (tree.n, tree.pBoard, 1), (tree.f, tree.pBoard, 2)])
        let walk = ShapeWalk(editor: h.editor, arrival: .shows)
        attach(walk, rows)
        h.editor.selection = tree.p
        walk.begin()
        expect(!walk.finish(), "no current stop")
        expect(walk.isRunning)
        walk.pick(row: 2)
        h.wait(300)
        expectEqual(h.editor.selectedShapeIDs, [], "showing selects nothing")
        var order: [String] = []
        expect(walk.finish {
            order.append(walk.isRunning ? "running" : "ended")
            order.append(h.editor.board == tree.pBoard ? "on P" : "root")
            order.append(h.editor.selectedShapeIDs.isEmpty ? "unselected" : "selected")
        })
        expectEqual(order, ["ended", "on P", "unselected"], "the walk ended, and nothing moved, when the client's closing ran")
        expectEqual(h.editor.board, tree.pBoard)
        expectEqual(h.editor.selectedShapeIDs, [tree.f])
        h.editor.goBack()
        expectEqual(h.editor.board, .root, "back to where the walk began")
        expectEqual(h.editor.selectedShapeIDs, [tree.p])
        expect(!h.editor.canGoBack, "one step: selecting P, in view, was none of its own")
    },
    test("rows that change: the place is found again by key, its stop clamped; else the first row at or after its rank; none with no rows") {
        let tree = Tree()
        let h = try harness(tree)
        let (a, n, f, g) = (tree.a, tree.n, tree.f, tree.g)
        let rows = Rows([(a, .root, 1), (n, .root, 3), (f, .root, 1)])
        let walk = ShapeWalk(editor: h.editor, arrival: .shows)
        attach(walk, rows)
        walk.pick(row: 1); walk.step(forward: true); walk.step(forward: true)
        expectEqual(place(walk), [1, 2])
        var kept = walk.kept
        expectEqual(kept, WalkKept(key: n, ordinal: 2, rank: 10))
        rows.set([(g, .root, 1), (a, .root, 1), (n, .root, 2), (f, .root, 1)])
        walk.rowsDidChange(keeping: kept)
        expectEqual(place(walk), [2, 1], "the same row, in its new place, its stop clamped to the two it has")
        expectEqual(walk.number, 4, "g and a before it, two stops in, then its second")
        kept = walk.kept
        rows.rows = [WalkRow(key: g, shape: g, board: .root, stops: 1, rank: 0), WalkRow(key: f, shape: f, board: .root, stops: 1, rank: 30)]
        walk.rowsDidChange(keeping: kept)
        expectEqual(place(walk), [1, 0], "the row is gone: the first at or after its rank")
        walk.pick(row: 0)
        kept = walk.kept
        rows.set([(f, .root, 1)])
        rows.rows = [WalkRow(key: f, shape: f, board: .root, stops: 1, rank: 5)]
        walk.rowsDidChange(keeping: kept)
        expectEqual(place(walk), [0, 0], "a gone row's rank is before it")
        kept = walk.kept
        rows.rows = [WalkRow(key: g, shape: g, board: .root, stops: 1, rank: 1)]
        walk.rowsDidChange(keeping: kept)
        expectEqual(place(walk), [0, 0], "after every rank: round to the first")
        walk.pick(row: 0)
        rows.set([])
        walk.rowsDidChange(keeping: walk.kept)
        expectEqual(walk.current, nil, "no rows")
        expectEqual(walk.number, nil)
        walk.land(at: WalkPosition(row: 3, ordinal: 0))
        rows.set([(a, .root, 1)])
        walk.rowsDidChange()
        expectEqual(walk.current, nil, "without keeping, a place past the rows goes")
        walk.land(at: WalkPosition(row: 0, ordinal: 0))
        walk.rowsDidChange()
        expectEqual(place(walk), [0, 0], "and one still among them stays")
        expectEqual(walk.kept?.key, a)
    },
    test("inserted rows join in order and the stop stays current: the numbers after it move, the stepping goes on from it") {
        let tree = Tree()
        let h = try harness(tree)
        let rows = Rows([(tree.a, .root, 1), (tree.n, .root, 1)])
        let walk = ShapeWalk(editor: h.editor, arrival: .shows)
        attach(walk, rows)
        walk.pick(row: 1)
        expectEqual(walk.number, 2)
        let kept = walk.kept
        rows.set([(tree.g, .root, 2), (tree.a, .root, 1), (tree.n, .root, 1), (tree.f, .root, 1)])
        walk.rowsDidChange(keeping: kept)
        expectEqual(place(walk), [2, 0])
        expectEqual(walk.number, 4)
        walk.step(forward: true)
        expectEqual(place(walk), [3, 0])
        walk.step(forward: true)
        expectEqual(place(walk), [0, 0])
    },
    test("land puts the walk at a stop without a step; arriving goes there too, still without one") {
        let tree = Tree()
        let h = try harness(tree)
        let rows = Rows([(tree.a, .root, 1), (tree.n, tree.pBoard, 1)])
        let walk = ShapeWalk(editor: h.editor, arrival: .shows)
        attach(walk, rows)
        walk.land(at: WalkPosition(row: 0, ordinal: 0))
        expectEqual(place(walk), [0, 0])
        expectEqual(rows.moves, 0)
        walk.land(at: WalkPosition(row: 1, ordinal: 0), arriving: true)
        expectEqual(h.editor.board, tree.pBoard)
        expectEqual(walk.stepCount, 0)
        expectEqual(rows.moves, 1)
    },
    test("begin at an entry: the first or last stop, the first after (before) the selection, or a shape's") {
        let (h, walk, rows) = try flat([1, 0, 2, 1])
        let ids = rows.rows.map(\.shape)
        expect(walk.begin(at: .first))
        expectEqual(place(walk), [0, 0])
        expect(walk.begin(at: .last))
        expectEqual(place(walk), [3, 0])
        walk.land(at: nil)
        h.editor.selection = ids[0]
        expect(walk.begin(at: .afterSelection(forward: true)))
        expectEqual(place(walk), [2, 0], "after the selected row, passing the empty one")
        h.editor.selection = ids[2]
        walk.begin(at: .afterSelection(forward: false))
        expectEqual(place(walk), [0, 0], "before it, passing the empty one")
        h.editor.selection = ids[3]
        walk.begin(at: .afterSelection(forward: false))
        expectEqual(place(walk), [2, 1], "before it: the last stop of the row before")
        h.editor.selectedShapeIDs = [ids[0], ids[3]]
        walk.begin(at: .afterSelection(forward: true))
        expectEqual(place(walk), [0, 0], "after the last of several selected: round the end")
        walk.begin(at: .afterSelection(forward: false))
        expectEqual(place(walk), [3, 0], "before the first of them: round the start")
        h.editor.selectedShapeIDs = [ids[1], ids[2]]
        walk.begin(at: .afterSelection(forward: true))
        expectEqual(place(walk), [3, 0])
        h.editor.selection = nil
        walk.begin(at: .afterSelection(forward: true))
        expectEqual(place(walk), [0, 0], "nothing selected: the first")
        walk.begin(at: .afterSelection(forward: false))
        expectEqual(place(walk), [3, 0], "and the last going back")
        expect(walk.begin(at: .shape(ids[2])))
        expectEqual(place(walk), [2, 0])
        expect(!walk.begin(at: .shape(ids[1])), "a row with no stops is no entry")
        expect(!walk.begin(at: .shape(ShapeID())))
        expectEqual(place(walk), [2, 0], "and the place stays")
        let (_, empty, _) = try flat([0])
        expect(!empty.begin(at: .first))
        expect(empty.isRunning)
        expectEqual(empty.stepCount, 0)
    },
    test("a source that orders shapes the rows don't hold begins a walk after a selection that is no row") {
        let (h, walk, rows) = try flat([1, 1, 1])
        final class Ordered: ShapeWalkSource {
            let base: Rows
            init(_ base: Rows) { self.base = base }
            var walkRowCount: Int { base.walkRowCount }
            func walkRow(at index: Int) -> WalkRow { base.walkRow(at: index) }
            func walkPlace(ofKey key: AnyHashable) -> Int? { base.walkPlace(ofKey: key) }
            func walkStops(before index: Int) -> Int { base.walkStops(before: index) }
            func walkPlace(of selection: [ShapeID], forward: Bool) -> Int? { 1 }
        }
        let ordered = Ordered(rows)
        attach(walk, ordered)
        h.editor.selection = h.add(Box(CGRect(x: 0, y: 500, width: 10, height: 10)))
        walk.begin(at: .afterSelection(forward: true))
        expectEqual(place(walk), [2, 0], "on from the row the source named")
        walk.begin(at: .afterSelection(forward: false))
        expectEqual(place(walk), [0, 0])
    },
    test("nothing moves mid-gesture, or while shapes wait to be placed, and nothing is lost to the refusal") {
        let tree = Tree()
        let h = try harness(tree)
        let rows = Rows([(tree.a, .root, 2), (tree.n, tree.pBoard, 1)])
        let walk = ShapeWalk(editor: h.editor, arrival: .selects)
        attach(walk, rows)
        h.editor.selection = tree.p
        walk.begin()
        walk.step(forward: true)
        expectEqual(place(walk), [0, 0])
        h.editor.session = TranslatingSession(ids: [tree.a], from: .zero, in: h.editor)
        walk.step(forward: true); walk.move(by: 1); walk.moveBoard(by: 1); walk.pick(row: 1)
        expect(!walk.begin(at: .first))
        expect(!walk.finish())
        expectEqual(place(walk), [0, 0])
        expectEqual(walk.stepCount, 1)
        expectEqual(rows.moves, 1)
        walk.land(at: WalkPosition(row: 1, ordinal: 0), arriving: true)
        expectEqual(h.editor.board, .root, "a landing that arrives is refused as a step is")
        h.editor.session = nil
        let slab = AnyShapeRecord(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 40, height: 30))))
        expect(h.editor.placeLater(PendingPlacement([slab], stepName: "Add") { _ in [.zero] }))
        walk.step(forward: true); walk.pick(row: 1); walk.move(by: 1)
        expect(h.editor.isPlacingLater, "the shapes wait still")
        expect(!walk.begin(at: .first), "an entry is refused while shapes wait")
        expectEqual(place(walk), [1, 0], "the landing's place, not a step's")
        expectEqual(walk.stepCount, 1)
        h.editor.setTool(h.editor.registry.defaultTool)
        walk.step(forward: true)
        expectEqual(place(walk), [0, 0], "on from the landing's place, round to the first")
        expectEqual(h.editor.selectedShapeIDs, [tree.a])
        expectEqual(walk.stepCount, 2)
    },
    test("a landing that steps goes to the stop after or before, wrapping, while shapes wait to be placed, counts no step, and shows no other board") {
        let tree = Tree()
        let h = try harness(tree)
        let rows = Rows([(tree.a, .root, 2), (tree.n, tree.pBoard, 1)])
        let walk = ShapeWalk(editor: h.editor, arrival: .selects)
        attach(walk, rows)
        walk.begin()
        let slab = AnyShapeRecord(ShapeRecord(Box(CGRect(x: 0, y: 0, width: 40, height: 30))))
        expect(h.editor.placeLater(PendingPlacement([slab], stepName: "Add") { _ in [.zero] }))
        walk.land(stepping: false)
        expectEqual(place(walk), [1, 0], "from nothing, back is the last stop")
        expectEqual(h.editor.board, .root, "it is on Texas's board, which showing would let the shapes go")
        walk.land(stepping: false)
        expectEqual(place(walk), [0, 1], "on a row of the board shown, the stop before")
        expectEqual(h.editor.selectedShapeIDs, [tree.a], "and it arrives there")
        walk.land(stepping: true)
        expectEqual(place(walk), [1, 0])
        walk.land(stepping: true)
        expectEqual(place(walk), [0, 0], "wrapping")
        expect(h.editor.isPlacingLater, "the shapes wait still")
        expectEqual(walk.stepCount, 0)
        expectEqual(rows.moves, 2, "only the two landings on the board shown arrived and told the source")
        h.editor.session = TranslatingSession(ids: [tree.a], from: .zero, in: h.editor)
        walk.land(stepping: true)
        expectEqual(place(walk), [0, 0], "nothing mid-gesture")
    },
])
