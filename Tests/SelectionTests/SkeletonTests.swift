@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// Zoomed out, shapes are drawn as skeletons (below the editor's `skeletonZoom`, 35%), which show
// none of their content: a skeleton has no faces, and what the pointer hovers is looked for again
// where it rests as the level changes. And the selection's bounds, which every frame outlining
// several selected shapes reads, are kept from one read to the next while nothing they come from
// changes.

/// A card at (100, 100), 200 × 100, its face (`facesPlugin`) the square from 110 to 130, naming a
/// box far off for hover, and the box.
@MainActor private final class SkeletonFaces {
    let log = FaceLog()
    let h: EditorHarness
    let card: ShapeID
    let target: ShapeID
    var editor: CanvasEditor { h.editor }

    init(_ more: [any CanvasPlugin] = []) throws {
        h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin(), facesPlugin(log)] + more)
        card = h.add(Card(CGRect(x: 100, y: 100, width: 200, height: 100)))
        target = h.add(Box(CGRect(x: 1000, y: 1000, width: 100, height: 100)))
        log.names = target
    }

    /// The face's middle, where the pointer reaches it, in view points.
    var onFace: CGPoint { h.view(CGPoint(x: 120, y: 120)) }

    /// The camera at `zoom`, its origin where it was.
    func zoom(_ zoom: CGFloat) { editor.camera = Camera(origin: editor.camera.origin, zoom: zoom) }
}

/// A plugin with one canvas button, a 20-point square at (40, 40) in view points, there only while
/// shapes are drawn in full, as a label that goes blank zoomed out might be.
@MainActor private func fullDetailButton(_ bell: Bell) -> Contributor {
    Contributor(id: "full-detail-button") { r in
        let rect = CGRect(x: 40, y: 40, width: 20, height: 20)
        r.canvasButtons(at: { editor, point in !editor.drawsSkeletons && rect.contains(point) ? "chip" : nil },
                        click: { button, _ in bell.rings.append(button) })
    }
}

/// A square 20 view points across at its origin: its geometry reads the camera.
private struct ViewSquare: ShapeProps {
    static let kind: ShapeKind = "view-square"
    static let properties = Properties<ViewSquare> {
        Property("origin", \.origin)
    }
    var origin: CGPoint = .zero
    init() {}
    init(at origin: CGPoint) { self.origin = origin }
}

private struct ViewSquareDefinition {}

extension ViewSquareDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<ViewSquare>, in context: RenderContext) {}

    func geometry(of shape: ShapeRecord<ViewSquare>, in context: ShapeContext) -> ShapeGeometry {
        let side = 20 / context.zoom
        return ShapeGeometry(outline: CGRect(origin: shape.props.origin, size: CGSize(width: side, height: side)).polygon)
    }
}

@MainActor private func viewSquaresPlugin() -> Contributor {
    Contributor(id: "view-squares") { r in r.shape(ViewSquareDefinition()) }
}

@MainActor let skeletonTests = Suite("Skeletons", [
    test("a shape drawn as a skeleton has no faces: a click there is the shape's, a double-click edits it, the pointer hovers it; from 35% up, faces again") {
        let board = try SkeletonFaces()
        board.zoom(0.3)
        expect(board.editor.drawsSkeleton(of: board.card))
        board.log.asked = []
        board.h.move(to: board.onFace)
        expectEqual(board.editor.hovered, board.card, "the card, not what the face names")
        board.h.click(at: board.onFace)
        expectEqual(board.log.asked, [], "never asked")
        expectEqual(board.log.clicks, [])
        expectEqual(board.editor.selection, board.card)
        expectEqual(board.editor.editingShapeID, nil, "a click only selects it")
        board.h.press(at: board.onFace, clickCount: 2)
        board.h.release()
        expectEqual(board.log.doubleClicks, [])
        expectEqual(board.editor.editingShapeID, board.card, "a double-click edits it, as elsewhere on it")
        expect(!board.editor.drawsSkeleton(of: board.card), "drawn in full while it's edited")
        board.editor.endEditing()
        board.zoom(0.35)
        board.h.move(to: board.onFace)
        expectEqual(board.editor.hovered, board.target)
        board.h.click(at: board.onFace)
        expectEqual(board.log.clicks, [board.card])
        expectEqual(board.editor.editingShapeID, nil)
    },
    test("a press on a skeleton's lone box where a face would be follows the pointer at once, as a press beside a face does") {
        let log = FaceLog()
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), facesPlugin(log)])
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 200, height: 100)))     // its face: 110 to 130
        h.editor.camera = Camera(zoom: 0.25)
        h.editor.selection = box
        let face = h.view(CGPoint(x: 120, y: 120))
        h.press(at: face)
        h.drag(to: CGPoint(x: face.x + 3, y: face.y))
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 112, y: 100), "3 view points at 25%, within the threshold")
        h.release()
        expectEqual(log.clicks, [])
    },
    test("zoomed out past 35% under a still pointer, a face's hover gives way to its shape; zoomed back in, the face takes it again") {
        let board = try SkeletonFaces()
        board.zoom(0.4)
        board.h.move(to: board.onFace)
        expectEqual(board.editor.hovered, board.target)
        board.editor.camera.setZoom(0.36, around: board.onFace)
        expectEqual(board.editor.hovered, board.target, "still drawn in full")
        board.editor.camera.setZoom(0.3, around: board.onFace)
        expectEqual(board.editor.hovered, board.card, "no pill there now: its card")
        board.editor.camera.setZoom(0.2, around: board.onFace)
        expectEqual(board.editor.hovered, board.card)
        board.editor.camera.setZoom(0.4, around: board.onFace)
        expectEqual(board.editor.hovered, board.target)
        board.editor.skeletonZoom = 0.5
        expectEqual(board.editor.hovered, board.card, "the host's level moved past the zoom, likewise")
        board.editor.skeletonZoom = 0
        expectEqual(board.editor.hovered, board.target)
    },
    test("the level changing looks for nothing once the pointer's off the canvas, in another tool, or mid-press") {
        let board = try SkeletonFaces()
        board.zoom(0.4)
        board.h.move(to: board.onFace)
        board.editor.pointerExited()
        expectEqual(board.editor.hovered, nil)
        board.editor.camera.setZoom(0.3, around: board.onFace)
        expectEqual(board.editor.hovered, nil, "off the canvas")
        board.editor.camera.setZoom(0.4, around: board.onFace)
        expectEqual(board.editor.hovered, nil)
        board.h.move(to: board.onFace)
        board.h.press(at: board.onFace)
        board.editor.camera.setZoom(0.3, around: board.onFace)
        expectEqual(board.editor.hovered, nil, "a press hovers nothing, and the level changing mid-press looks for nothing")
        board.h.release()
        expectEqual(board.log.clicks, [], "the face went with its card's content mid-press: the release is the card's")
        expectEqual(board.editor.selection, board.card)
        board.editor.camera.setZoom(0.4, around: board.onFace)
        board.h.move(to: board.onFace)
        board.editor.setTool(.hand)
        board.editor.camera.setZoom(0.3, around: board.onFace)
        expectEqual(board.editor.hovered, nil, "in the hand tool")
    },
    test("a face pressed in full is clicked on its release only while its shape is still drawn in full: a pinch past 35% mid-press makes the release the shape's") {
        let board = try SkeletonFaces()
        board.zoom(0.5)
        board.h.move(to: board.onFace)
        board.h.press(at: board.onFace)
        board.editor.camera.setZoom(0.4, around: board.onFace)
        board.h.release()
        expectEqual(board.log.clicks, [board.card], "zoomed, but still in full: the face's click")
        board.editor.selection = nil
        board.h.move(to: board.onFace)
        board.h.press(at: board.onFace)
        board.editor.camera.setZoom(0.3, around: board.onFace)
        board.h.release()
        expectEqual(board.log.clicks, [board.card], "a skeleton by the release: no click")
        expectEqual(board.editor.selection, board.card, "the card selected, as a click on it there does")
        expectEqual(board.editor.editingShapeID, nil)
    },
    test("a canvas button that goes with the level under a still pointer gives the hover up to the shape under it, and takes it back") {
        let bell = Bell()
        let board = try SkeletonFaces([fullDetailButton(bell)])
        board.editor.camera = Camera(origin: CGPoint(x: 25, y: 25), zoom: 0.4)       // the button over the card, at (150, 150)
        board.h.move(to: CGPoint(x: 50, y: 50))
        expectEqual(board.editor.hoveredButton, AnyHashable("chip"))
        expectEqual(board.editor.hovered, nil)
        board.editor.camera.setZoom(0.3, around: CGPoint(x: 50, y: 50))
        expectEqual(board.editor.hoveredButton, nil)
        expectEqual(board.editor.hovered, board.card)
        board.editor.camera.setZoom(0.4, around: CGPoint(x: 50, y: 50))
        expectEqual(board.editor.hoveredButton, AnyHashable("chip"))
        expectEqual(board.editor.hovered, nil)
    },

    // MARK: The selection's bounds

    test("the selection's bounds are worked out once, and kept through frames, reads and hovers, until the selection changes") {
        #if DEBUG
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 10, y: 20, width: 100, height: 50)))
        let b = h.add(Box(CGRect(x: 300, y: 200, width: 50, height: 50)))
        let c = h.add(Box(CGRect(x: 500, y: 0, width: 50, height: 50)))
        let before = h.editor.selectionBoundsWorkedOut
        h.editor.selectedShapeIDs = [a, b]
        expectEqual(h.editor.selectionBounds, CGRect(x: 10, y: 20, width: 340, height: 230))
        _ = renderBitmap(h.editor, size: CGSize(width: 600, height: 400))
        _ = renderBitmap(h.editor, size: CGSize(width: 600, height: 400))
        h.move(to: CGPoint(x: 520, y: 20))
        h.move(to: CGPoint(x: 700, y: 700))
        expectEqual(h.editor.selectionBounds, CGRect(x: 10, y: 20, width: 340, height: 230))
        expectEqual(h.editor.selectionBoundsWorkedOut - before, 1, "once")
        h.editor.selectedShapeIDs = [a, c]
        expectEqual(h.editor.selectionBounds, CGRect(x: 10, y: 0, width: 540, height: 70))
        h.editor.selectedShapeIDs = [a, b]
        expectEqual(h.editor.selectionBounds, CGRect(x: 10, y: 20, width: 340, height: 230), "the same shapes again")
        #endif
    },
    test("a pan or a zoom works the selection's bounds out again only while some geometry on the board reads the camera") {
        #if DEBUG
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), viewSquaresPlugin()])
        let a = h.add(Box(CGRect(x: 10, y: 20, width: 100, height: 50)))
        let b = h.add(Box(CGRect(x: 300, y: 200, width: 50, height: 50)))
        h.editor.selectedShapeIDs = [a, b]
        let box = CGRect(x: 10, y: 20, width: 340, height: 230)
        expectEqual(h.editor.selectionBounds, box)
        expect(!h.editor.geometriesReadCamera, "no geometry reads the camera")
        let worked = h.editor.selectionBoundsWorkedOut
        h.editor.camera = Camera(origin: CGPoint(x: 40, y: 10), zoom: 2)
        expectEqual(h.editor.selectionBounds, box)
        h.editor.camera = Camera(zoom: 0.1)
        _ = renderBitmap(h.editor, size: CGSize(width: 600, height: 400))
        expectEqual(h.editor.selectionBounds, box)
        expectEqual(h.editor.selectionBoundsWorkedOut, worked, "a pan and a zoom: kept")
        // A shape elsewhere on the board whose geometry reads the camera: the bounds are kept by the camera again.
        h.add(ViewSquare(at: CGPoint(x: 900, y: 900)))
        _ = h.editor.paintOrder()
        expect(h.editor.geometriesReadCamera, "a geometry reads the camera")
        expectEqual(h.editor.selectionBounds, box)
        let worked2 = h.editor.selectionBoundsWorkedOut
        h.editor.camera = Camera(zoom: 1)
        expectEqual(h.editor.selectionBounds, box)
        expectEqual(h.editor.selectionBoundsWorkedOut, worked2 + 1, "a zoom works them out again")
        #endif
    },
    test("the selection's bounds follow a drag of the selection, its undo and redo, and a deletion of one of it and its undo") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 200, y: 0, width: 100, height: 100)))
        h.editor.selectedShapeIDs = [a, b]
        expectEqual(h.editor.selectionBounds, CGRect(x: 0, y: 0, width: 300, height: 100))
        h.press(at: CGPoint(x: 50, y: 50))
        h.drag(to: CGPoint(x: 60, y: 50))
        expectEqual(h.editor.selectionBounds, CGRect(x: 10, y: 0, width: 300, height: 100), "mid-drag")
        h.drag(to: CGPoint(x: 80, y: 70))
        h.release()
        expectEqual(h.editor.selectionBounds, CGRect(x: 30, y: 20, width: 300, height: 100))
        h.editor.undo()
        expectEqual(h.editor.selectedShapeIDs, [a, b])
        expectEqual(h.editor.selectionBounds, CGRect(x: 0, y: 0, width: 300, height: 100), "undone")
        h.editor.redo()
        expectEqual(h.editor.selectionBounds, CGRect(x: 30, y: 20, width: 300, height: 100), "redone")
        h.editor.transact { $0.delete([b]) }
        expectEqual(h.editor.selectedShapeIDs, [a])
        expectEqual(h.editor.selectionBounds, CGRect(x: 30, y: 20, width: 100, height: 100), "b deleted")
        h.editor.undo()
        h.editor.selectedShapeIDs = [a, b]
        expectEqual(h.editor.selectionBounds, CGRect(x: 30, y: 20, width: 300, height: 100), "b back")
    },
    test("the selection's bounds follow a shape whose geometry follows another, unselected, and geometry that reads the camera") {
        let h = try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), LinksPlugin(), viewSquaresPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 100, height: 100)))
        let b = h.add(Box(CGRect(x: 300, y: 0, width: 100, height: 100)))
        let c = h.add(Box(CGRect(x: 100, y: 400, width: 20, height: 20)))
        let link = h.add(Link(from: a, to: b))                                     // (50, 50) to (350, 50)
        h.editor.selectedShapeIDs = [link, c]
        expectEqual(h.editor.selectionBounds, CGRect(x: 50, y: 50, width: 300, height: 370))
        h.editor.transact { $0.update(b, as: Box.self) { $0.props.frame.origin = CGPoint(x: 500, y: -100) } }
        expectEqual(h.editor.selectionBounds, CGRect(x: 50, y: -50, width: 500, height: 470), "b moved, and the link with it")
        let square = h.add(ViewSquare(at: CGPoint(x: 0, y: 0)))
        h.editor.selectedShapeIDs = [square, c]
        expectEqual(h.editor.selectionBounds, CGRect(x: 0, y: 0, width: 120, height: 420))
        h.editor.camera = Camera(zoom: 0.1)
        expectEqual(h.editor.selectionBounds, CGRect(x: 0, y: 0, width: 200, height: 420), "200 units across at 10%")
    },
    test("the selection's bounds follow the board shown: none on arrival, the new board's shapes', and the first board's back there") {
        let boards = PocketBoards()
        let h = try pocketsHarness(boards)
        h.editor.selectedShapeIDs = [boards.a, boards.c]
        expectEqual(h.editor.selectionBounds, CGRect(x: 0, y: 0, width: 500, height: 100))
        expect(h.enter(boards.p))
        expectEqual(h.editor.selectionBounds, nil, "nothing selected on arrival")
        h.editor.selectedShapeIDs = [boards.b, boards.q]
        expectEqual(h.editor.selectionBounds, CGRect(x: 0, y: 0, width: 300, height: 400))
        h.editor.goBack()
        expectEqual(h.editor.board, .root, "Back: the board left")
        expectEqual(h.editor.selectedShapeIDs, [boards.a, boards.c])
        expectEqual(h.editor.selectionBounds, CGRect(x: 0, y: 0, width: 500, height: 100))
    },
])
