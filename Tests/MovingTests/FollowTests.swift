@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Selection
import TableOfContents
import TestKit

// After a move the editor goes where the shapes went, so the person is never left where they were: onto another
// board, that board is shown with them selected there; on the board shown, they're selected and, landed out of
// view, brought into it at the zoom the camera has; either way as one step back, to the board, the selection and
// the camera before the move. The commands, Move To ▸ and the table of contents' drops share the commit that does
// it (`Block.commit`), so each goes alike.

/// The view the editor is given, in view points: a board starts showing the world from 0, 0 to 1000, 700.
private let viewSize = CGSize(width: 1000, height: 700)

/// The moving harness with the selection, in a view of `viewSize`.
@MainActor private func followingHarness(_ file: CanvasFile) throws -> EditorHarness {
    let h = try droppingHarness(file)
    h.editor.viewportDidResize(to: viewSize)
    return h
}

/// Whether the shape's box is all in the view, where the camera is headed.
@MainActor private func inView(_ h: EditorHarness, _ id: ShapeID) -> Bool {
    guard let frame = h.frame(of: id) else { return false }
    return h.editor.cameraTarget.toWorld(h.editor.unobscuredViewport).contains(frame)
}

@MainActor let followingTests = Suite("Going where the shapes went", [
    test("into a corral out of view, the shape selected: the camera follows it there at the zoom it had, and one Back returns the camera, the shape still selected; Forward goes there again") {
        let f = ShapeID(), s = ShapeID()
        let h = try followingHarness(CanvasFile(root: board(corral(f, at(3000, 0, 600, 400)), box(s, 100, 100))))
        let start = Camera(zoom: 0.5)
        h.editor.camera = start
        h.editor.selection = s
        expect(h.run("move-to", onSelection: [s], with: f))
        expectEqual(h.frame(of: s), at(3040, 40))
        expect(inView(h, s), "brought into view")
        expectEqual(h.editor.cameraTarget.zoom, 0.5, "at the zoom it had, not a link's readable one")
        expectEqual(h.editor.selectedShapeIDs, [s])
        h.wait(300)
        let there = h.editor.camera
        expect(h.editor.canGoBack)
        h.editor.goBack()
        h.wait(300)
        expectEqual(h.editor.camera, start, "the view it was moved from")
        expectEqual(h.editor.selectedShapeIDs, [s], "still selected, where it went")
        expect(!h.editor.canGoBack)
        h.editor.goForward()
        h.wait(300)
        expectEqual(h.editor.camera, there)
    },

    test("into a corral in view: the shape glides there and the camera stays; no step back") {
        let f = ShapeID(), s = ShapeID()
        let h = try followingHarness(CanvasFile(root: board(corral(f, at(500, 0, 400, 400)), box(s, 100, 100))))
        h.editor.selection = s
        expect(h.run("move-to", onSelection: [s], with: f))
        expectEqual(h.frame(of: s), at(540, 40))
        expect(h.editor.isGliding(s))
        expectEqual(h.editor.cameraTarget, Camera())
        expect(!h.editor.canGoBack)
    },

    test("typed in a shape's text with something else selected: the shape is selected where it lands, and Back returns to what was selected, the camera where it was") {
        let f = ShapeID(), s = ShapeID(), t = ShapeID()
        let h = try followingHarness(CanvasFile(root: board(corral(f, at(3000, 0, 600, 400)), box(s, 100, 100), box(t, 300, 100))))
        h.editor.selection = t
        expect(h.run("move-to", on: s, with: f))
        expectEqual(h.editor.selectedShapeIDs, [s])
        expect(inView(h, s))
        h.wait(300)
        h.editor.goBack()
        h.wait(300)
        expectEqual(h.editor.selectedShapeIDs, [t])
        expectEqual(h.editor.camera, Camera())
    },

    test("beside a shape out of view: followed there, as into a corral") {
        let x = ShapeID(), s = ShapeID()
        let h = try followingHarness(CanvasFile(root: board(box(x, 4000, 2000), box(s, 100, 100))))
        h.editor.selection = s
        expect(h.run("move-near", onSelection: [s], with: x))
        expectEqual(h.frame(of: s), at(4180, 2000), "right of it, 80 away")
        expect(inView(h, s))
        expect(h.editor.canGoBack)
    },

    test("several onto a pocket's board: that board shown with all of them selected there, a link that rode along with them too; Back returns to the root and the camera it had; Forward to them again") {
        let p = ShapeID(), a = ShapeID(), b = ShapeID(), link = ShapeID()
        let h = try followingHarness(CanvasFile(root: board(pocket(p, 0, 0), box(a, 400, 0), box(b, 600, 0),
                                                           AnyShapeRecord(ShapeRecord(id: link, Link(from: a, to: b))))))
        let start = Camera(origin: CGPoint(x: 100, y: 0))
        h.editor.camera = start
        h.editor.selectedShapeIDs = [a, b, link]
        expect(h.run("move-to", onSelection: [a, b, link], with: p))
        expectEqual(h.editor.board, BoardID(owner: p))
        expectEqual(h.file.board(containing: link), BoardID(owner: p), "bound only to what moved, it went along")
        expectEqual(h.editor.selectedShapeIDs, [a, b, link], "the selection, where it went")
        expect(inView(h, a) && inView(h, b))
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.camera, start)
        expectEqual(h.editor.selectedShapeIDs, [], "what was selected there is gone from it")
        h.editor.goForward()
        expectEqual(h.editor.board, BoardID(owner: p))
        expectEqual(Set(h.editor.selectedShapeIDs), [a, b, link])
    },

    test("into a corral on a pocket's board, out of the view that board was left with: shown, and the camera brought to the shape there at that view's zoom") {
        let p = ShapeID(), q = ShapeID(), x = ShapeID(), s = ShapeID()
        let h = try followingHarness(CanvasFile(root: board(pocket(p, 0, 0), box(s, 400, 0)),
                                                children: [p: board(box(x, 0, 0), corral(q, at(5000, 5000, 600, 400)))]))
        expect(h.enter(p))
        h.editor.camera = Camera(zoom: 2)                      // left showing X, not the corral
        expect(h.editor.showBoard(.root))
        expect(h.run("move-to", on: s, with: q))
        expectEqual(h.editor.board, BoardID(owner: p))
        expectEqual(h.container(of: s), q)
        expect(inView(h, s), "brought into view")
        expectEqual(h.editor.cameraTarget.zoom, 2, "at the zoom that board was left with")
        expectEqual(h.editor.selectedShapeIDs, [s])
    },

    test("a row dropped on the row of a corral out of view: the shape selected in it, and the camera follows it there, as the commands' moves") {
        let f = ShapeID(), s = ShapeID()
        let h = try followingHarness(CanvasFile(root: board(corral(f, at(3000, 0, 600, 400)), box(s, 100, 100))))
        expect(h.drop([s], on: f, .on))
        expectEqual(h.container(of: s), f)
        expectEqual(h.editor.selectedShapeIDs, [s])
        expect(inView(h, s))
        expect(h.editor.canGoBack)
    },

    test("what's brought into view is what moved: a selected shape the move left where it was isn't fitted in with it") {
        let f = ShapeID(), s = ShapeID(), x = ShapeID()
        let h = try followingHarness(CanvasFile(root: board(corral(f, at(3000, 0, 600, 400)), box(s, 100, 100), box(x, -6000, 100))))
        h.editor.selectedShapeIDs = [s, x]
        expect(h.run("move-to", on: s, with: f))
        expectEqual(h.editor.selectedShapeIDs, [s, x], "the selection, which holds what moved, kept")
        expect(inView(h, s))
        expectEqual(h.editor.cameraTarget.zoom, 1, "not zoomed out to fit X, 9,000 away, which didn't move")
    },
    test("a move that lands where the shapes are goes nowhere: no step, and the camera stays where the person panned it, off the shape") {
        let x = ShapeID(), s = ShapeID()
        let h = try followingHarness(CanvasFile(root: board(box(x, 400, 0), box(s, 580, 0))))
        h.editor.selection = s
        let panned = Camera(origin: CGPoint(x: 3000, y: 3000))
        h.editor.camera = panned
        expect(h.run("move-near", onSelection: [s], with: x))
        expectEqual(h.frame(of: s), at(580, 0), "already right of it")
        expectEqual(h.editor.cameraTarget, panned)
        expect(!h.editor.canGoBack)
    },
])
