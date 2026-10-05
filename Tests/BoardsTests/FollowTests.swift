import Boards
import Canvas
import CanvasTesting
import Selection
import TestKit

// `editor.follow`: the crumbs' menus' rule, once, for whatever else picks a shape from anywhere in
// the file (Jump To): into a shape whose kind opens its board, to any other, one step back.

@MainActor let followTests = Suite("Following a shape", [
    test("a shape whose kind opens its board is gone into: that board shown, nothing selected, one step back") {
        let nest = Nest()
        let h = try nestHarness(nest)
        h.editor.follow(nest.d)
        expectEqual(h.editor.board, nest.dBoard)
        expectEqual(h.editor.selectedShapeIDs, [])
        h.editor.follow(nest.p)
        expectEqual(h.editor.board, nest.pBoard, "a pocket's kind opens its board too: from another plugin's line")
        h.editor.goBack()
        expectEqual(h.editor.board, nest.dBoard, "one step back")
    },
    test("any other shape is gone to, wherever it is: its board shown, it selected, one step back to where it was followed from") {
        let nest = Nest()
        let h = try nestHarness(nest)
        h.editor.follow(nest.b)
        expectEqual(h.editor.board, nest.pBoard, "two boards down")
        expectEqual(h.editor.selectedShapeIDs, [nest.b])
        h.editor.follow(nest.a)
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [nest.a])
        h.editor.goBack()
        expectEqual(h.editor.board, nest.pBoard, "one step back, to the board the follow left")
        expectEqual(h.editor.selectedShapeIDs, [nest.b])
    },
    test("a shape that isn't in the file is followed nowhere") {
        let nest = Nest()
        let h = try nestHarness(nest)
        h.editor.follow(ShapeID())
        expectEqual(h.editor.board, .root)
        expect(!h.editor.canGoBack)
    },
    test("the crumbs' pick is a follow") {
        let nest = Nest()
        let h = try nestHarness(nest)
        let crumbs = try require(h.editor.boardCrumbs)
        crumbs.pick(nest.d)
        expectEqual(h.editor.board, nest.dBoard)
        crumbs.pick(nest.c)
        expectEqual(h.editor.board, nest.pBoard)
        expectEqual(h.editor.selectedShapeIDs, [nest.c])
    },
])
