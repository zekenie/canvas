import Boards
@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Observation
import Selection
import TableOfContents
import TestKit

// The crumbs' menus, headlessly: which crumb's menu shows as the pointer goes (data-canvas's hover
// intent, 150 ms each way, one menu at a time), what each lists, and where a row picked goes.

/// The nest, with the table of contents (whose rows the menus show), inside P's board: the path is
/// root › D › P.
@MainActor func menuHarness(_ nest: Nest) throws -> EditorHarness {
    let h = try nestHarness(nest, [TableOfContentsPlugin()])
    expect(h.enter(nest.d))
    expect(h.enter(nest.p))
    return h
}

@MainActor let crumbMenuTests = Suite("The path's menus", [
    test("a crumb's menu is its own board, where the shape whose board is next on the path is highlighted: the way you came") {
        let nest = Nest()
        let h = try menuHarness(nest)
        let crumbs = try require(h.editor.boardCrumbs)
        expectEqual(crumbs.menu(of: .root), CrumbMenu(board: .root, highlighted: nest.d), "the root's too")
        expectEqual(crumbs.menu(of: nest.dBoard), CrumbMenu(board: nest.dBoard, highlighted: nest.p))
        expectEqual(crumbs.menu(of: nest.pBoard), CrumbMenu(board: nest.pBoard, highlighted: nil), "the board shown's: its own shapes")
        expectEqual(crumbs.menu(of: BoardID(owner: nest.b)), nil, "a board off the path")
        let contents = try require(h.editor.tableOfContents)
        expectEqual(contents.outline(of: .root).map(\.id), [nest.a, nest.d], "the root's menu: its rows, D among them")
        expectEqual(contents.outline(of: nest.pBoard).map(\.id), [nest.b, nest.c], "the board shown's")
        let without = try nestHarness(nest)
        expect(without.enter(nest.d))
        expectEqual(try require(without.editor.boardCrumbs).menu(of: .root), nil, "no menus without the table of contents, whose rows they show")
    },
    test("the board shown's crumb has a menu only while the board has shapes") {
        let nest = Nest()
        let h = try menuHarness(nest)
        let crumbs = try require(h.editor.boardCrumbs)
        h.editor.goToEnclosingBoard()
        h.editor.goToEnclosingBoard()
        let drawer = h.add(Drawer(CGRect(x: 400, y: 0, width: 100, height: 100)))
        expect(h.enter(drawer))
        let board = BoardID(owner: drawer)
        expectEqual(crumbs.menu(of: board), nil, "a board with nothing on it")
        expectEqual(crumbs.menu(of: .root), CrumbMenu(board: .root, highlighted: drawer))
        crumbs.pointerEntered(crumb: board)
        h.wait(1000)
        expectEqual(crumbs.openMenu, nil)
        let heard = Flag()
        withObservationTracking { _ = crumbs.menu(of: board) } onChange: { heard.set() }
        let box = h.add(Box(CGRect(x: 0, y: 0, width: 50, height: 50)))
        expect(heard.isSet, "the path, reading the menus, hears it")
        expectEqual(crumbs.menu(of: board), CrumbMenu(board: board, highlighted: nil))
        let quiet = Flag()
        withObservationTracking { _ = crumbs.menu(of: board) } onChange: { quiet.set() }
        h.editor.transact { $0.translate([box], by: CGPoint(x: 5, y: 0)) }
        expect(!quiet.isSet, "a commit that leaves it with shapes: nothing to hear")
        crumbs.pointerEntered(crumb: board)
        h.wait(200)
        expectEqual(crumbs.openMenu, board)
        h.editor.transact { $0.delete([box]) }
        expectEqual(crumbs.menu(of: board), nil, "empty again")
        expectEqual(crumbs.openMenu, nil, "and its menu closed")
    },
    test("the pointer on a crumb shows its menu once it's stayed 150 ms; off it, the menu closes 150 ms later") {
        let h = try menuHarness(Nest())
        let crumbs = try require(h.editor.boardCrumbs)
        let board = h.editor.board
        crumbs.pointerEntered(crumb: board)
        h.wait(140)
        expectEqual(crumbs.openMenu, nil, "not yet")
        h.wait(20)
        expectEqual(crumbs.openMenu, board)
        crumbs.pointerExited(crumb: board)
        h.wait(140)
        expectEqual(crumbs.openMenu, board, "not yet")
        h.wait(20)
        expectEqual(crumbs.openMenu, nil)
    },
    test("the menu stays while the pointer goes from its crumb onto it, and closes once the pointer has left both") {
        let h = try menuHarness(Nest())
        let crumbs = try require(h.editor.boardCrumbs)
        let board = h.editor.board
        crumbs.pointerEntered(crumb: board)
        h.wait(200)
        crumbs.pointerExited(crumb: board)
        h.wait(50)
        crumbs.pointerEnteredMenu()
        h.wait(1000)
        expectEqual(crumbs.openMenu, board)
        crumbs.pointerExitedMenu()
        h.wait(50)
        crumbs.pointerEntered(crumb: board)
        h.wait(1000)
        expectEqual(crumbs.openMenu, board, "back on its crumb in time")
        crumbs.pointerExited(crumb: board)
        crumbs.pointerEnteredMenu()
        crumbs.pointerExitedMenu()
        h.wait(160)
        expectEqual(crumbs.openMenu, nil)
    },
    test("passing over a crumb shows nothing; staying on the root's shows the root's") {
        let nest = Nest()
        let h = try menuHarness(nest)
        let crumbs = try require(h.editor.boardCrumbs)
        crumbs.pointerEntered(crumb: nest.dBoard)
        h.wait(100)
        crumbs.pointerExited(crumb: nest.dBoard)
        h.wait(1000)
        expectEqual(crumbs.openMenu, nil)
        crumbs.pointerEntered(crumb: .root)
        h.wait(1000)
        expectEqual(crumbs.openMenu, .root)
    },
    test("another crumb's menu takes the showing one's place once the pointer has stayed on it; back in time, the first stays") {
        let nest = Nest()
        let h = try menuHarness(nest)
        let crumbs = try require(h.editor.boardCrumbs)
        crumbs.pointerEntered(crumb: nest.dBoard)
        h.wait(200)
        crumbs.pointerExited(crumb: nest.dBoard)
        crumbs.pointerEntered(crumb: nest.pBoard)
        h.wait(140)
        expectEqual(crumbs.openMenu, nest.dBoard, "the first stays till then")
        h.wait(20)
        expectEqual(crumbs.openMenu, nest.pBoard)
        crumbs.pointerExited(crumb: nest.pBoard)
        crumbs.pointerEntered(crumb: nest.dBoard)
        h.wait(50)
        crumbs.pointerExited(crumb: nest.dBoard)
        crumbs.pointerEntered(crumb: nest.pBoard)
        h.wait(1000)
        expectEqual(crumbs.openMenu, nest.pBoard, "D's never showed, and P's didn't close")
    },
    test("a click on a crumb closes its menu, and so does another board shown; a menu about to show doesn't") {
        let nest = Nest()
        let h = try menuHarness(nest)
        let crumbs = try require(h.editor.boardCrumbs)
        crumbs.pointerEntered(crumb: nest.pBoard)
        h.wait(200)
        crumbs.closeMenu()
        expectEqual(crumbs.openMenu, nil)
        h.wait(1000)
        expectEqual(crumbs.openMenu, nil, "the pointer still on it shows it only once it comes back")
        crumbs.pointerEntered(crumb: nest.dBoard)
        h.wait(200)
        expectEqual(crumbs.openMenu, nest.dBoard)
        h.editor.goToEnclosingBoard()
        expectEqual(crumbs.openMenu, nil, "⌘↑")
        crumbs.pointerEntered(crumb: nest.dBoard)
        h.wait(100)
        expect(h.enter(nest.p))
        h.wait(1000)
        expectEqual(crumbs.openMenu, nil, "about to show on the board left")
    },
    test("a row picked goes to its shape on its board, selected there, one step back; the menu closes") {
        let nest = Nest()
        let h = try menuHarness(nest)
        let crumbs = try require(h.editor.boardCrumbs)
        crumbs.pointerEntered(crumb: .root)
        h.wait(200)
        crumbs.pick(nest.a)
        expectEqual(crumbs.openMenu, nil)
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [nest.a])
        h.editor.goBack()
        expectEqual(h.editor.board, nest.pBoard, "one step back to where the menu was")
        crumbs.pointerEntered(crumb: nest.pBoard)
        h.wait(200)
        crumbs.pick(nest.b)
        expectEqual(h.editor.board, nest.pBoard, "the board shown's own menu: the shape, on it")
        expectEqual(h.editor.selectedShapeIDs, [nest.b])
    },
    test("a row whose shape opens a board goes into it, one step back; the way you came, highlighted, goes there") {
        let nest = Nest()
        let h = try menuHarness(nest)
        let crumbs = try require(h.editor.boardCrumbs)
        crumbs.pointerEntered(crumb: .root)
        h.wait(200)
        crumbs.pick(nest.d)
        expectEqual(h.editor.board, nest.dBoard, "into the drawer's board, from the pocket's, two boards down")
        expectEqual(h.editor.selectedShapeIDs, [], "nothing selected on arrival")
        h.editor.goBack()
        expectEqual(h.editor.board, nest.pBoard, "one step back")
        crumbs.pointerEntered(crumb: nest.dBoard)
        h.wait(200)
        expectEqual(crumbs.menu(of: nest.dBoard)?.highlighted, nest.p)
        crumbs.pick(nest.p)
        expectEqual(crumbs.openMenu, nil)
        expectEqual(h.editor.board, nest.pBoard, "P's board: it's shown already")
        h.editor.goToEnclosingBoard()
        expectEqual(h.editor.selectedShapeIDs, [nest.p])
    },
])
