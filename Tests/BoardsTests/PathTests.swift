import AppKit
import Boards
@_spi(Host) import Canvas
import CanvasTesting
import Observation
import Selection
import TestKit
import Titles

/// Whether `body` changes what the crumbs are, as the path's view would hear it.
@MainActor func changesCrumbs(_ crumbs: BoardCrumbs, _ body: () -> Void) -> Bool {
    let heard = Flag()
    withObservationTracking { _ = crumbs.crumbs } onChange: { heard.set() }
    body()
    return heard.isSet
}

@MainActor let pathTests = Suite("The path", [
    test("the crumbs are the boards below the root down to the board shown, each by its name and symbol") {
        let nest = Nest()
        let h = try nestHarness(nest)
        let crumbs = try require(h.editor.boardCrumbs)
        expectEqual(crumbs.crumbs, [], "none on the root")
        expect(h.enter(nest.d))
        expect(h.enter(nest.p))
        expectEqual(crumbs.crumbs, [BoardCrumb(board: nest.dBoard, title: "Untitled Drawer", systemImage: "archivebox"),
                                    BoardCrumb(board: nest.pBoard, title: "Untitled Pocket", systemImage: "tray")])
        let layout = crumbs.layout(rootName: "Plans")
        expectEqual(layout.leading.map(\.title), ["Plans", "Untitled Drawer", "Untitled Pocket"])
        expectEqual(layout.folded, [])
        expectEqual(layout.trailing, [])
        h.editor.goToEnclosingBoard()
        expectEqual(crumbs.crumbs.map(\.board), [nest.dBoard])
    },
    test("past four crumbs, the middle folds: root, …, parent, the board shown") {
        let (h, ids) = try chainHarness(depth: 3)
        let crumbs = try require(h.editor.boardCrumbs)
        for id in ids { expect(h.enter(id)) }
        expectEqual(crumbs.layout(rootName: "R").leading.count, 4, "four fit")
        let (five, fiveIDs) = try chainHarness(depth: 4)
        for id in fiveIDs { expect(five.enter(id)) }
        let folded = try require(five.editor.boardCrumbs).layout(rootName: "R")
        expectEqual(folded.leading.map(\.board), [.root], "five don't")
        expectEqual(folded.folded.map(\.board), [BoardID(owner: fiveIDs[0]), BoardID(owner: fiveIDs[1])])
        expectEqual(folded.trailing.map(\.board), fiveIDs.suffix(2).map { BoardID(owner: $0) })
        let (deep, deepIDs) = try chainHarness(depth: 5)
        for id in deepIDs { expect(deep.enter(id)) }
        let layout = try require(deep.editor.boardCrumbs).layout(rootName: "R")
        expectEqual(layout.leading.map(\.board), [.root])
        expectEqual(layout.folded.map(\.board), deepIDs.prefix(3).map { BoardID(owner: $0) })
        expectEqual(layout.trailing.map(\.board), deepIDs.suffix(2).map { BoardID(owner: $0) })
    },
    test("\"…\" is a menu of the boards it folds, root side first, each going up to its board, one step back") {
        let (h, ids) = try chainHarness(depth: 5)
        for (id, name) in zip(ids, ["A", "B", "C", "D", "E"]) {
            expect(h.editor.showBoard(try require(h.editor.file.board(containing: id))))
            h.name(id, name)
        }
        expect(h.enter(ids[4]))
        let folded = try require(h.editor.boardCrumbs).layout(rootName: "R").folded
        let menu = BoardPath.foldedMenu(folded, editor: h.editor)
        expectEqual(menu.items.map(\.title), ["A", "B", "C"])
        expect(menu.items.allSatisfy(\.isEnabled))
        try menu.choose("B")                     // through NSApp, which this suite alone never makes
        expectEqual(h.editor.board, BoardID(owner: ids[1]))
        expectEqual(h.editor.selectedShapeIDs, [ids[2]], "the shape the path came through")
        h.editor.goBack()
        expectEqual(h.editor.board, BoardID(owner: ids[4]))
    },
    test("a commit on the board shown leaves the crumbs as they are; showing another board remakes them") {
        let nest = Nest()
        let h = try nestHarness(nest)
        h.name(nest.d, "Kitchen")
        let crumbs = try require(h.editor.boardCrumbs)
        expect(h.enter(nest.d))
        expect(h.enter(nest.p))
        let made = crumbs.remade
        expect(!changesCrumbs(crumbs) {
            for step in 1...5 { h.editor.transact("Move") { $0.translate([nest.b], by: CGPoint(x: CGFloat(step), y: 0)) } }
            h.name(nest.c, "Card")
        }, "a drag and a rename on the board shown")
        expectEqual(crumbs.remade, made, "not even made again: each commit looks only at the boards above's revisions")
        expect(changesCrumbs(crumbs) { h.editor.goToEnclosingBoard() })
        expectEqual(crumbs.remade, made + 1, "made once for the switch")
        expectEqual(crumbs.crumbs.map(\.title), ["Kitchen"])
    },
    test("a board above that changes while this one is shown (a file put in place) names its crumbs again") {
        let nest = Nest()
        let h = try nestHarness(nest)
        let crumbs = try require(h.editor.boardCrumbs)
        expect(h.enter(nest.d))
        expect(h.enter(nest.p))
        var file = h.editor.file
        var renamed = try require(file.root[nest.d])
        renamed[TitleProperty.self] = "Pantry"
        file = CanvasFile(root: CanvasDocument(shapes: [try require(file.root[nest.a]), renamed]), children: file.children)
        let made = crumbs.remade
        expect(changesCrumbs(crumbs) { h.editor.replaceFile(with: file) })
        expectEqual(crumbs.remade, made + 1, "made once")
        expectEqual(h.editor.board, nest.pBoard, "still shown")
        expectEqual(crumbs.crumbs.map(\.title), ["Pantry", "Untitled Pocket"])
        expect(!changesCrumbs(crumbs) { h.editor.replaceFile(with: file) }, "the same names: no change heard")
    },
    test("a crumb says whether its board is read-only: under a frozen owner every board is, the root never; the path's read-only part starts at the first") {
        let nest = Nest()
        let h = try nestHarness(nest, [FreezingPlugin()])
        let crumbs = try require(h.editor.boardCrumbs)
        expectEqual(crumbs.readOnlyStart, nil)
        h.editor.freeze([nest.d])
        expect(h.enter(nest.d))
        expect(h.enter(nest.p))
        expectEqual(crumbs.crumbs.map(\.isReadOnly), [true, true], "D's board, and P's under it, though P isn't frozen")
        expectEqual(crumbs.readOnlyStart, nest.dBoard)
        expectEqual(crumbs.layout(rootName: "Plans").leading.map(\.isReadOnly), [false, true, true], "the root's crumb never is")
        expectEqual(BoardCrumb(board: nest.dBoard, title: "D").isReadOnly, false, "unless it's said")
        h.editor.goToEnclosingBoard()
        expectEqual(crumbs.crumbs.map(\.isReadOnly), [true], "the board shown, as the editor says")
        expectEqual(crumbs.readOnlyStart, nest.dBoard)
        h.editor.showBoard(.root)
        expectEqual(crumbs.crumbs, [])
        expectEqual(crumbs.readOnlyStart, nil)
    },
    test("only the first read-only crumb starts the read-only part: freezing a shape on a board that isn't, in the middle of the path, moves it down") {
        let nest = Nest()
        let h = try nestHarness(nest, [FreezingPlugin()])
        let crumbs = try require(h.editor.boardCrumbs)
        expect(h.enter(nest.d))
        expect(h.enter(nest.p))
        expectEqual(crumbs.crumbs.map(\.isReadOnly), [false, false])
        expectEqual(crumbs.readOnlyStart, nil)
        expect(changesCrumbs(crumbs) { h.editor.transact(on: nest.dBoard, "Freeze") { $0.update(nest.p) { $0[Frozen.self] = true } } })
        expectEqual(crumbs.crumbs.map(\.isReadOnly), [false, true], "P's board, the board shown, now: its owner is frozen on D's board")
        expectEqual(crumbs.readOnlyStart, nest.pBoard)
        expect(h.editor.isBoardReadOnly)
    },
    test("a lock above lands while this board is shown, or goes (a commit on a board above, a file put in place): the crumbs are made again, flags and all") {
        let nest = Nest()
        let h = try nestHarness(nest, [FreezingPlugin()])
        let crumbs = try require(h.editor.boardCrumbs)
        expect(h.enter(nest.d))
        expect(h.enter(nest.p))
        var made = crumbs.remade
        expect(changesCrumbs(crumbs) { h.editor.transact(on: .root, "Freeze") { $0.update(nest.d) { $0[Frozen.self] = true } } })
        expectEqual(h.editor.board, nest.pBoard, "still shown")
        expectEqual(crumbs.crumbs.map(\.isReadOnly), [true, true])
        expectEqual(crumbs.remade, made + 1, "made once")
        made = crumbs.remade
        expect(changesCrumbs(crumbs) { h.editor.transact(on: .root, "Thaw") { $0.update(nest.d) { $0[Frozen.self] = nil } } })
        expectEqual(crumbs.crumbs.map(\.isReadOnly), [false, false])
        expectEqual(crumbs.readOnlyStart, nil)
        expectEqual(crumbs.remade, made + 1)
        var file = h.editor.file
        var frozen = try require(file.root[nest.d])
        frozen[Frozen.self] = true
        file = CanvasFile(root: CanvasDocument(shapes: [try require(file.root[nest.a]), frozen]), children: file.children)
        expect(changesCrumbs(crumbs) { h.editor.replaceFile(with: file) })
        expectEqual(crumbs.crumbs.map(\.isReadOnly), [true, true], "a file put in place")
        expect(!changesCrumbs(crumbs) { h.editor.replaceFile(with: file) }, "the same: no change heard")
    },
    test("\"…\" shows the lock on the item of the crumb where the read-only part starts when that's folded, and on no other; below the fold, its menu has none") {
        let (h, ids) = try chainHarness(depth: 5, more: [FreezingPlugin()])
        for (id, name) in zip(ids, ["A", "B", "C", "D", "E"]) {
            expect(h.editor.showBoard(try require(h.editor.file.board(containing: id))))
            h.name(id, name)
        }
        expect(h.enter(ids[4]))
        let crumbs = try require(h.editor.boardCrumbs)
        h.editor.transact(on: BoardID(owner: ids[0]), "Freeze") { $0.update(ids[1]) { $0[Frozen.self] = true } }
        expectEqual(crumbs.crumbs.map(\.isReadOnly), [false, true, true, true, true], "B's board, and every one under it")
        let folded = crumbs.layout(rootName: "R").folded
        let menu = BoardPath.foldedMenu(folded, editor: h.editor)
        expectEqual(menu.items.map(\.title), ["A", "B", "C"], "named as ever")
        expectEqual(menu.items.map { $0.image != nil }, [false, true, false], "B's, not C's, though C's board is read-only too")
        expectEqual(menu.items[1].image?.accessibilityDescription, "Read-only")
        try menu.choose("B")
        expectEqual(h.editor.board, BoardID(owner: ids[1]), "chosen as the rest are")
        h.editor.goBack()
        h.editor.transact(on: BoardID(owner: ids[0]), "Thaw") { $0.update(ids[1]) { $0[Frozen.self] = nil } }
        h.editor.transact(on: BoardID(owner: ids[2]), "Freeze") { $0.update(ids[3]) { $0[Frozen.self] = true } }
        expectEqual(crumbs.crumbs.map(\.isReadOnly), [false, false, false, true, true])
        expectEqual(BoardPath.foldedMenu(crumbs.layout(rootName: "R").folded, editor: h.editor).items.map { $0.image != nil }, [false, false, false],
                    "the part starts at D's, which isn't folded")
    },
    test("an owner above renamed by a write to its board while this one is shown (transact(on:), an answer landing) names its crumb again") {
        let nest = Nest()
        let h = try nestHarness(nest)
        let crumbs = try require(h.editor.boardCrumbs)
        expect(h.enter(nest.d))
        expect(h.enter(nest.p))
        expect(changesCrumbs(crumbs) { h.editor.transact(on: .root, "Rename") { $0.update(nest.d) { $0[TitleProperty.self] = "Pantry" } } })
        expectEqual(h.editor.board, nest.pBoard, "still shown")
        expectEqual(crumbs.crumbs.map(\.title), ["Pantry", "Untitled Pocket"])
        h.editor.undo()
        expectEqual(h.editor.board, .root, "undoing it shows the root")
        expectEqual(crumbs.crumbs, [])
    },
])
