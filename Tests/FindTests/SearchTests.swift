@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Find
import Geometry
import Selection
import TestKit

@MainActor let scopeTests = Suite("Find's scope and order", [
    test("from the root: the root's shapes in file order, then each board under it, depth first in file order") {
        let pockets = PocketFile(root: ["note one", "note two"], inA: ["note a"], inA1: ["note a1"], inB: ["note b"])
        let h = try findHarness(pockets.file)
        let find = try search("note", in: h)
        expectEqual(find.found, [pockets.root[0].id, pockets.root[1].id, pockets.inA[0].id, pockets.inA1[0].id, pockets.inB[0].id])
        expectEqual(find.results.map(\.board), [.root, .root, pockets.aBoard, pockets.a1Board, pockets.bBoard])
        expectEqual(find.total, 5)
    },
    test("from a pocket: that board and the boards under it; stepping and rows never scope again, typing does") {
        let pockets = PocketFile(root: ["note one"], inA: ["note a"], inA1: ["note a1"], inB: ["note b"])
        let h = try findHarness(pockets.file)
        expect(h.enter(pockets.a))
        let find = try search("note", in: h)
        expectEqual(find.found, [pockets.inA[0].id, pockets.inA1[0].id])
        expectEqual(find.scope, pockets.aBoard)
        find.step(forward: true)
        expectEqual(h.editor.board, pockets.a1Board, "stepped into A1")
        expectEqual(find.scope, pockets.aBoard, "stepping doesn't scope again")
        find.query = "note a"
        try settle(find, h)
        expectEqual(find.scope, pockets.a1Board, "typing scopes to the board shown")
        expectEqual(find.found, [pockets.inA1[0].id])
    },
    test("a scope that can't be shown any more, its pocket deleted or a file put in place without it, scopes again to the board shown and searches again") {
        let pockets = PocketFile(root: ["note one"], inA: ["note a"], inA1: ["note a1"], inB: ["note b"])
        let h = try findHarness(pockets.file)
        expect(h.enter(pockets.a))
        let find = try search("note", in: h)
        expectEqual(find.scope, pockets.aBoard)
        expectEqual(find.found, [pockets.inA[0].id, pockets.inA1[0].id])
        expect(h.editor.showBoard(.root))
        h.editor.transact { $0.delete([pockets.a]) }
        try settle(find, h)
        expectEqual(find.scope, .root, "the pocket's board is gone: the board shown")
        expectEqual(find.found, [pockets.root[0].id, pockets.inB[0].id], "the results follow, with nothing retyped")
        // A file put in place without the scope's board.
        let again = PocketFile(root: ["note one"], inA: ["note a"], inA1: [], inB: ["note b"])
        let g = try findHarness(again.file)
        expect(g.enter(again.a))
        let findAgain = try search("note", in: g)
        expectEqual(findAgain.scope, again.aBoard)
        let replacement = memos(["note new"])
        g.editor.replaceFile(with: CanvasFile(root: CanvasDocument(shapes: replacement)))
        try settle(findAgain, g)
        expectEqual(findAgain.scope, .root)
        expectEqual(findAgain.found, [replacement[0].id])
    },
    test("a container's shapes come after it, in file order") {
        let corral = ShapeID()
        var held = memos(["inside note"], y: 100)
        held[0] = held[0].copy(as: held[0].id, container: corral)
        let records = memos(["first note"], y: 300) + [AnyShapeRecord(ShapeRecord(id: corral, Corral(CGRect(x: 50, y: 50, width: 400, height: 200))))]
            + held + memos(["last note"], y: 500)
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: records)), more: [CorralsPlugin()])
        let find = try search("note", in: h)
        expectEqual(find.found, [records[0].id, held[0].id, records[3].id])
    },
    test("the count is hits, a text's up to the cap; exact and typos alike") {
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(["aa aa aa", String(repeating: "aa ", count: 150), "something somthing"]))))
        let find = try search("aa", in: h)
        expectEqual(find.results.map(\.hitCount), [3, 100])
        expectEqual(find.total, 103)
        find.query = "something"
        try settle(find, h)
        expectEqual(find.total, 2, "one exact, one typo")
        expectEqual(find.currentNumber, 1)
    },
])

@MainActor let typingTests = Suite("Find typing", [
    test("the current hit is the first on the board shown that's in view; the camera doesn't move") {
        let ids = (0..<3).map { _ in ShapeID() }
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(["far apple", "near apple", "apple"], ids: ids))))
        h.editor.camera = Camera(origin: CGPoint(x: 290, y: 0), zoom: 1)
        let camera = h.editor.camera
        let find = try search("apple", in: h)
        expectEqual(find.currentHit?.shape, ids[1], "the first in view: the far one's out to the left")
        expectEqual(h.editor.camera, camera)
    },
    test("none in view: the first on the board shown, brought into view; none there: the first anywhere, and no board changes") {
        let pockets = PocketFile(root: ["plain"], inA: ["apple pie"], inA1: [], inB: [])
        let h = try findHarness(pockets.file)
        h.editor.camera = Camera(origin: CGPoint(x: 5000, y: 5000), zoom: 1)
        let find = try search("plain", in: h)
        expectEqual(find.currentHit?.shape, pockets.root[0].id)
        expectEqual(h.editor.cameraTarget.toWorld(CGRect(origin: .zero, size: viewport)).contains(try require(memoRect(pockets.root[0].id, 0..<5, in: h.editor))),
                    true, "revealed")
        find.query = "apple"
        try settle(find, h)
        expectEqual(find.currentHit?.shape, pockets.inA[0].id, "the first anywhere")
        expectEqual(h.editor.board, .root, "typing never shows another board")
        expectEqual(find.currentNumber, 1)
    },
    test("past the first results asked, the first in view is found among the shapes in view") {
        let bodies = (0..<100).map { _ in "apple" }
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(bodies))))
        h.editor.camera = Camera(origin: CGPoint(x: 100 + 80 * 200 - 10, y: 0), zoom: 1)
        let camera = h.editor.camera
        let find = try search("apple", in: h)
        expectEqual(find.current, FindPosition(result: 80, ordinal: 0), "the 81st, past the 64 asked")
        expectEqual(h.editor.camera, camera)
    },
    test("typing never changes the selection, and leaves no undo step") {
        let ids = (0..<2).map { _ in ShapeID() }
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(["apple", "pear"], ids: ids))))
        h.editor.selection = ids[1]
        let find = try search("apple", in: h)
        find.step(forward: true)
        expectEqual(h.editor.selectedShapeIDs, [ids[1]])
        expect(!h.editor.undoHistory.canUndo, "no step")
        find.close()
        expect(!h.editor.undoHistory.canUndo)
    },
    test("⌘F mid-gesture does nothing; Find's commands are refused") {
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(["apple"]))))
        h.press(at: CGPoint(x: 150, y: 120))
        h.drag(to: CGPoint(x: 300, y: 300))
        expect(!h.editor.canPerform(.find))
        h.editor.find?.open()
        expect(h.editor.find?.isActive == false)
        h.release()
        expect(h.editor.canPerform(.find))
        h.hold(.command)
        expect(h.key("f"), "⌘F on the canvas")
        h.hold([])
        expect(h.editor.find?.isActive == true)
    },
    test("closing keeps what's typed for the next ⌘F, whose search runs again; each ⌘F asks the field to focus") {
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(["apple", "pear"]))))
        let find = try search("pear", in: h)
        let asked = find.focusRequest
        find.close()
        expect(!find.isActive)
        expectEqual(find.query, "pear")
        find.open()
        expectEqual(find.focusRequest, asked + 1)
        try settle(find, h)
        expectEqual(find.results.count, 1)
        find.open()
        expectEqual(find.focusRequest, asked + 2, "open: focuses again")
    },
])

@MainActor let steppingTests = Suite("Find stepping", [
    test("⌘G steps hit by hit, in order, across boards, wrapping; ⇧⌘G back") {
        let pockets = PocketFile(root: ["pear pear"], inA: ["pear"], inA1: [], inB: ["pear"])
        let h = try findHarness(pockets.file)
        let find = try search("pear", in: h)
        expectEqual(find.currentNumber, 1)
        expect(h.editor.canPerform(.findNext))
        h.editor.perform(.findNext)
        expectEqual(find.currentNumber, 2)
        expectEqual(h.editor.board, .root)
        h.editor.perform(.findNext)
        expectEqual(find.currentNumber, 3)
        expectEqual(h.editor.board, pockets.aBoard, "its board shown")
        h.editor.perform(.findNext)
        expectEqual(h.editor.board, pockets.bBoard)
        h.editor.perform(.findNext)
        expectEqual(find.currentNumber, 1, "wrapped")
        expectEqual(h.editor.board, .root)
        h.editor.perform(.findPrevious)
        expectEqual(find.currentNumber, 4)
        expectEqual(h.editor.board, pockets.bBoard)
    },
    test("the whole session is one step back: Back returns to where Find began") {
        let pockets = PocketFile(root: ["plain"], inA: ["pear"], inA1: ["pear"], inB: ["pear"])
        let h = try findHarness(pockets.file)
        let start = pockets.root[0].id
        h.editor.selection = start
        let camera = h.editor.camera
        let find = try search("pear", in: h)
        for _ in 0..<4 { find.step(forward: true) }
        expect(h.editor.board != .root)
        find.close()
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [start])
        expectEqual(h.editor.camera, camera)
        expect(!h.editor.canGoBack, "one step: selecting the memo, in view, was none of its own")
    },
    test("a pan or a click between steps adds no second step back") {
        let pockets = PocketFile(root: ["plain"], inA: ["pear", "pear"], inA1: [], inB: ["pear"])
        let h = try findHarness(pockets.file)
        let find = try search("pear", in: h)
        find.step(forward: true)
        expectEqual(h.editor.board, pockets.aBoard)
        h.editor.selection = pockets.inA[1].id
        h.editor.camera = Camera(origin: CGPoint(x: -400, y: -400), zoom: 1)
        find.step(forward: true)
        expectEqual(h.editor.board, pockets.bBoard)
        find.close()
        h.editor.goBack()
        expectEqual(h.editor.board, .root, "where Find began, once: the click, in view, was no step of its own")
        expect(!h.editor.canGoBack)
    },
    test("a step that moves nothing, after a pan, adds no step back: Back doesn't undo the pan") {
        let ids = (0..<2).map { _ in ShapeID() }
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(["pear", "pear"], ids: ids))))
        let find = try search("pear", in: h)
        let panned = Camera(origin: CGPoint(x: 20, y: 0), zoom: 1)
        h.editor.camera = panned
        find.step(forward: true)
        expectEqual(find.currentNumber, 2)
        expectEqual(h.editor.camera, panned, "in view: nothing moved")
        h.editor.selection = ids[1]
        expect(!h.editor.canGoBack, "nothing to undo the pan: Find's step moved nothing, and the click was in view")
        expectEqual(h.editor.camera, panned)
    },
    test("a row picked: its shape's first hit, brought into view on its board") {
        let pockets = PocketFile(root: ["pear"], inA: ["pear"], inA1: [], inB: [])
        let h = try findHarness(pockets.file)
        let find = try search("pear", in: h)
        find.select(pockets.inA[0].id)
        expectEqual(find.currentHit?.shape, pockets.inA[0].id)
        expectEqual(h.editor.board, pockets.aBoard)
    },
    test("⌘G with Find closed opens it on what was typed and lands on the first hit in view, which is its step; ⇧⌘G lands there, then steps back") {
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(["pear", "pear", "pear"]))))
        let find = try search("pear", in: h)
        find.step(forward: true)
        expectEqual(find.currentNumber, 2)
        find.close()
        expect(h.editor.canPerform(.findNext))
        h.editor.perform(.findNext)
        try settle(find, h)
        expect(find.isActive)
        expectEqual(find.currentNumber, 1, "the first hit in view: the landing is the step, none skipped")
        find.close()
        h.editor.perform(.findPrevious)
        try settle(find, h)
        expect(find.isActive)
        expectEqual(find.currentNumber, 3, "landed on the first, then one back: the last")
    },
    test("with no hits, ⌘G and ⇧⌘G can't run; with nothing typed and Find closed, neither") {
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(["pear"]))))
        expect(!h.editor.canPerform(.findNext))
        let find = try search("zzzz", in: h)
        expect(!h.editor.canPerform(.findNext))
        expect(!h.editor.canPerform(.findPrevious))
        expectEqual(find.currentNumber, nil)
    },
])

@MainActor let editTests = Suite("Find across edits", [
    test("an edit keeps the current hit: in its shape, clamped to what's left; gone, the next shape's; the camera stays") {
        let ids = (0..<3).map { _ in ShapeID() }
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(["pear", "pear pear pear", "pear"], ids: ids))))
        let find = try search("pear", in: h)
        find.step(forward: true)
        find.step(forward: true)
        find.step(forward: true)
        expectEqual(find.current, FindPosition(result: 1, ordinal: 2))
        let camera = h.editor.cameraTarget
        h.editor.transact { $0.update(ids[1], as: Memo.self) { $0.props.body = "pear pear" } }
        try settle(find, h)
        expectEqual(find.current, FindPosition(result: 1, ordinal: 1), "clamped")
        h.editor.transact { $0.update(ids[1], as: Memo.self) { $0.props.body = "plum" } }
        try settle(find, h)
        expectEqual(find.currentHit?.shape, ids[2], "the next")
        expectEqual(h.editor.cameraTarget, camera)
    },
    test("a shape that gains its first hit joins the results in order, the current hit kept") {
        let ids = (0..<3).map { _ in ShapeID() }
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(["pear", "plum", "pear"], ids: ids))))
        let find = try search("pear", in: h)
        find.step(forward: true)
        expectEqual(find.currentHit?.shape, ids[2])
        let searched = find.searchesAnswered
        h.editor.transact { $0.update(ids[1], as: Memo.self) { $0.props.body = "pear too" } }
        try settle(find, h)
        expectEqual(find.found, ids)
        expectEqual(find.currentHit?.shape, ids[2])
        expectEqual(find.searchesAnswered, searched + 1, "searched again for a shape that joins")
    },
    test("a shape added while nothing's typed is found when something is again") {
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(["pear", "plum"]))))
        let find = try search("pear", in: h)
        expectEqual(find.results.count, 1)
        find.query = ""
        try settle(find, h)
        let added = ShapeID()
        h.editor.transact { $0.insert(ShapeRecord(id: added, Memo(CGRect(x: 100, y: 300, width: 160, height: 40), "pear again"))) }
        find.query = "pear"
        try settle(find, h)
        expectEqual(find.results.count, 2)
        expect(find.hasHits(added))
    },
    test("a commit while a search is under way starts it again: its answer is the commit's") {
        let ids = (0..<3).map { _ in ShapeID() }
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(["pear", "plum", "pear"], ids: ids))))
        let find = try search("pear", in: h)
        find.query = "pea"
        expect(!find.isSettled, "under way")
        h.editor.transact { $0.update(ids[0], as: Memo.self) { $0.props.body = "plum" } }
        h.editor.transact { $0.update(ids[1], as: Memo.self) { $0.props.body = "peach" } }
        try settle(find, h)
        expectEqual(find.found, [ids[1], ids[2]])
        expectEqual(find.currentHit?.shape, ids[1], "landed as typing does")
    },
    test("a drag with Find open patches nothing and searches nothing") {
        let ids = (0..<2).map { _ in ShapeID() }
        let h = try findHarness(CanvasFile(root: CanvasDocument(shapes: memos(["pear", "plum"], ids: ids))))
        let find = try search("pear", in: h)
        let (searched, patched) = (find.searchesAnswered, find.shapesPatched)
        h.press(at: CGPoint(x: 150, y: 120))
        h.drag(to: CGPoint(x: 200, y: 300))
        h.drag(to: CGPoint(x: 250, y: 400))
        h.release()
        try settle(find, h)
        expectEqual(find.searchesAnswered, searched)
        expectEqual(find.shapesPatched, patched)
    },
])
