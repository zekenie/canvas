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
