@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// Going to shapes on other boards of the file: a mention names a shape wherever it is, so going to
// it shows its board first.

private let view = CGSize(width: 1000, height: 700)
private let far = CGRect(x: 3000, y: 2000, width: 100, height: 100)
private let near = CGRect(x: 0, y: 0, width: 100, height: 100)

private func revealed(_ frame: CGRect) -> Camera { Camera(fitting: frame, in: view, inset: 100, maxZoom: 1.2) }

/// A root holding box A and pocket P; P's board holds box N near its origin and box F far from it.
private struct Pocketed {
    let a = ShapeID(), p = ShapeID(), n = ShapeID(), f = ShapeID()
    var file: CanvasFile {
        let box = { (id: ShapeID, frame: CGRect) in AnyShapeRecord(ShapeRecord(id: id, Box(frame))) }
        return CanvasFile(root: CanvasDocument(shapes: [box(a, near), AnyShapeRecord(ShapeRecord(id: p, Pocket(CGRect(x: 200, y: 0, width: 100, height: 100))))]),
                          children: [p: CanvasDocument(shapes: [box(n, near), box(f, far)])])
    }
    var pBoard: BoardID { BoardID(owner: p) }
}

@MainActor private func harness(_ file: CanvasFile, _ more: [any CanvasPlugin] = []) throws -> EditorHarness {
    let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), PocketsPlugin()] + more, file: file)
    h.editor.viewportDidResize(to: view)
    return h
}

@MainActor let goToBoardsTests = Suite("Going to shapes on other boards", [
    test("going to a shape on another board shows its board, selects it there and brings it into view; Back returns to the board left, with its selection") {
        let tree = Pocketed()
        let h = try harness(tree.file)
        h.editor.selection = tree.a
        h.editor.goTo([tree.f])
        expectEqual(h.editor.board, tree.pBoard)
        expectEqual(h.editor.selectedShapeIDs, [tree.f])
        h.wait(200)
        expectEqual(h.editor.camera, revealed(far), "from the board's first visit, which shows it too small to read")
        h.editor.goBack()
        expectEqual(h.editor.board, .root, "one step back")
        expectEqual(h.editor.selectedShapeIDs, [tree.a])
    },
    test("from inside a board, going to a shape on the root goes up to it; a shape already readable there leaves the camera the root was left with") {
        let tree = Pocketed()
        let h = try harness(tree.file)
        let camera = h.editor.camera
        expect(h.enter(tree.p))
        h.editor.goTo([tree.a])
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [tree.a])
        h.wait(200)
        expectEqual(h.editor.camera, camera, "in view at 100% already")
    },
    test("shapes spread over boards go to the first one's board, and to those of them there") {
        let tree = Pocketed()
        let h = try harness(tree.file)
        h.editor.goTo([ShapeID(), tree.n, tree.a, tree.f])
        expectEqual(h.editor.board, tree.pBoard, "the first that's in the file is on P's board")
        expectEqual(h.editor.selectedShapeIDs, [tree.n, tree.f])
        h.editor.goTo([tree.a, tree.f])
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [tree.a])
    },
    test("a shape on a board that can't be shown, or in no board, isn't gone to; nor is any while a press runs") {
        let tree = Pocketed(), lost = ShapeID(), orphan = ShapeID()
        var file = tree.file
        file = CanvasFile(root: file.root, children: file.children.merging([orphan: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: lost, Box(near)))])]) { a, _ in a })
        let h = try harness(file)
        h.editor.goTo([lost])
        expectEqual(h.editor.board, .root, "its owner isn't in the file")
        h.editor.goTo([lost, tree.f])
        expectEqual(h.editor.board, tree.pBoard, "the first on a board it can show")
        expect(h.editor.showBoard(.root))
        h.editor.session = TranslatingSession(ids: [tree.a], from: .zero, in: h.editor)
        h.editor.goTo([tree.f])
        expectEqual(h.editor.board, .root)
        h.editor.session = nil
    },
    test("a face's click can go to a shape on another board: its board is shown and the rest of the double-click is the click's") {
        let log = FaceLog()
        let links = Contributor(id: "links") { r in
            r.shapeFaces(at: { _, shape, point in shape.box.map(face(of:))?.contains(point) == true ? shape.id : nil },
                         click: { _, editor in
                             if let target = log.names { editor.goTo([target]) }
                         })
        }
        let tree = Pocketed()
        let h = try harness(tree.file, [links])
        log.names = tree.f
        h.click(at: CGPoint(x: 20, y: 20))                                  // on A's face
        expectEqual(h.editor.board, tree.pBoard)
        expectEqual(h.editor.selectedShapeIDs, [tree.f])
        h.press(at: CGPoint(x: 20, y: 20), clickCount: 2)
        h.release()
        expectEqual(h.editor.selectedShapeIDs, [tree.f], "the second press is the click's: N, under it now, isn't pressed")
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [tree.a], "back to the face's shape")
    },
    test("going into a pocket shows its board, one step back to where it was gone into from: from its board, from another, or with it selected already") {
        let boards = PocketBoards()
        let h = try pocketsHarness(boards)
        h.editor.viewportDidResize(to: view)
        h.editor.selection = boards.a
        h.editor.goInto(boards.p)
        expectEqual(h.editor.board, boards.pBoard)
        h.editor.goBack()
        expectEqual(h.editor.board, .root, "one step back")
        expectEqual(h.editor.selectedShapeIDs, [boards.a], "not to P selected, which going to it passed through")

        // Q, on P's board, from the root: through P's board into Q's, still one step.
        h.editor.goInto(boards.q)
        expectEqual(h.editor.boardPath, [.root, boards.pBoard, BoardID(owner: boards.q)])
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [boards.a])

        // P selected and in view already: going to it takes no step, so showing its board is the
        // step, as opening it is.
        h.editor.selection = boards.p
        h.editor.goInto(boards.p)
        expectEqual(h.editor.board, boards.pBoard)
        h.editor.goBack()
        expectEqual(h.editor.board, .root)
        expectEqual(h.editor.selectedShapeIDs, [boards.p])

        // Inside P, going into P is gone into already: nothing, not up to the root and back.
        expect(h.enter(boards.p))
        h.editor.selection = boards.b
        let steps = h.editor.canGoBack
        h.editor.goInto(boards.p)
        expectEqual(h.editor.board, boards.pBoard)
        expectEqual(h.editor.selectedShapeIDs, [boards.b], "the selection as it was")
        expectEqual(h.editor.canGoBack, steps)
    },
    test("going into a shape that opens by editing edits it, selected; one that doesn't open is only gone to; none while a press runs") {
        let boards = PocketBoards()
        let h = try pocketsHarness(boards)
        h.editor.goInto(boards.c)
        expectEqual(h.editor.editingShapeID, boards.c)
        expectEqual(h.editor.selectedShapeIDs, [boards.c])
        h.editor.goInto(boards.a)
        expectEqual(h.editor.editingShapeID, nil, "going ends editing")
        expectEqual(h.editor.selectedShapeIDs, [boards.a])
        expectEqual(h.editor.board, .root)
        h.editor.session = TranslatingSession(ids: [boards.a], from: .zero, in: h.editor)
        h.editor.goInto(boards.p)
        expectEqual(h.editor.board, .root)
        h.editor.session = nil
    },
])
