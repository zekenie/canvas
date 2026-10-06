@_spi(Host) import Canvas
import CanvasTesting
import Connections
import CoreGraphics
import Geometry
import Selection
import TestKit

// The drag drawing a connection, around its ends: Escape, the target's outline, the binding hints,
// and what it leaves alone (the selection, its history, the tool).
@MainActor let connectionDragTests = Suite("Connection drag", [
    test("drawn past the canvas's edge, a connection scrolls it, its end under the pointer, and binds to a shape it brought into view") {
        let board = try PortBoard()
        board.h.editor.viewportDidResize(to: CGSize(width: 700, height: 600))
        let far = board.h.add(Box(CGRect(x: 1100, y: 80, width: 200, height: 200)))
        board.connect(to: CGPoint(x: 720, y: 180), release: false)
        board.h.wait(1000)
        let camera = board.h.editor.camera
        expect(camera.origin.x > 500, "scrolled right: \(camera)")
        guard case .free(let end)? = board.arrows.first?.props.end else { throw RequireFailed() }
        expectClose(end, camera.toWorld(CGPoint(x: 720, y: 180)), within: 1e-9)
        board.h.drag(to: board.h.view(CGPoint(x: 1200, y: 180)), speed: fast)
        board.h.release()
        expectEqual(board.arrows.first?.props.end.binding?.shapeID, far)
    },
    test("an arrow's handle dragged past the canvas's edge doesn't scroll it, as tldraw's doesn't") {
        let board = try PortBoard()
        board.h.editor.viewportDidResize(to: CGSize(width: 700, height: 600))
        board.h.editor.selection = board.h.add(Arrow(start: .free(CGPoint(x: 300, y: 450)), end: .free(CGPoint(x: 500, y: 450))))
        board.h.move(to: CGPoint(x: 500, y: 450))
        board.h.press()
        expect(board.h.editor.session != nil, "the end's handle")
        board.h.drag(to: CGPoint(x: 720, y: 180), speed: fast)
        board.h.wait(1000)
        expectEqual(board.h.editor.camera, Camera())
        board.h.release()
    },
    test("Escape mid-drag, its key or the command, deletes the arrow; the rest of the drag does nothing") {
        for byKey in [false, true] {
            let board = try PortBoard()
            let before = board.h.editor.document
            board.connect(to: boxB.center, release: false)
            expectEqual(board.arrows.count, 1)
            if byKey { board.h.key("\u{1b}") } else { board.h.escape() }
            expect(board.arrows.isEmpty, "by key: \(byKey)")
            expect(board.h.editor.session == nil, "by key: \(byKey)")
            expectEqual(board.h.editor.hintedShapeID, nil, "by key: \(byKey)")
            board.h.drag(to: CGPoint(x: 600, y: 200), speed: fast)
            board.h.release()
            expect(board.arrows.isEmpty, "by key: \(byKey)")
            expectEqual(board.h.editor.document, before, "by key: \(byKey)")
            expectEqual(board.h.editor.currentToolID, .select, "by key: \(byKey)")
        }
    },
    test("a press on a dot released without a drag, or Escaped before one, draws nothing") {
        for escapes in [false, true] {
            let board = try PortBoard()
            let before = board.h.editor.document
            board.pressDot()
            board.h.drag(to: aRightDot + CGPoint(x: 4, y: 0))                // not past the threshold
            if escapes {
                board.h.escape()
                board.h.drag(to: boxB.center, speed: fast)
            }
            board.h.release()
            expectEqual(board.h.editor.document, before, "escaped: \(escapes)")
            expectEqual(board.h.editor.hintedShapeID, nil, "escaped: \(escapes)")
        }
    },
    test("a lock above the board landing between the press on a dot and the drag starts no connection: no arrow is made, and the release leaves the board as it is") {
        let pocket = ShapeID()
        let frame = CGRect(x: 400, y: 600, width: 50, height: 50)
        let inside = CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(Box(boxA))), AnyShapeRecord(ShapeRecord(Box(boxB)))])
        let file = CanvasFile(root: CanvasDocument(shapes: [AnyShapeRecord(ShapeRecord(id: pocket, Pocket(frame)))]), children: [pocket: inside])
        let h = try EditorHarness(plugins: PortBoard.plugins(more: [PocketsPlugin(), FreezingPlugin()]), file: file)
        expect(h.enter(pocket))
        h.move(to: CGPoint(x: 180, y: 180))
        h.move(to: aRightDot)
        h.press()
        h.editor.transact(on: .root, "Freeze") { $0.update(pocket) { $0[Frozen.self] = true } }
        expect(h.editor.isBoardReadOnly)
        let before = h.file
        h.drag(to: boxB.center, speed: fast)
        expect(h.editor.session == nil, "nothing begun")
        h.release()
        expectEqual(h.file, before)
        expectEqual(h.editor.document.shapes.compactMap { $0.typed(as: Arrow.self) }.count, 0)
    },
    test("the arrow comes in once the drag passes 4 points; releasing finishes it, or deletes it, in one commit") {
        for (target, drawn) in [(boxB.center, true), (CGPoint(x: 380, y: 500), false)] {
            let board = try PortBoard()
            let revision = board.h.editor.revision
            board.pressDot()
            board.h.drag(to: aRightDot + CGPoint(x: 4, y: 0))
            expectEqual(board.h.editor.revision, revision)
            board.h.drag(to: aRightDot + CGPoint(x: 5, y: 0))
            expectEqual(board.arrows.count, 1)
            board.h.drag(to: target, speed: fast)
            let beforeRelease = board.h.editor.revision
            board.h.release()
            expectEqual(board.h.editor.revision, beforeRelease + 1, "drawn: \(drawn)")
            expectEqual(board.arrows.count, drawn ? 1 : 0)
        }
    },
    test("the hand closes from the press on the dot through the drag; released, the cursor is the select tool's again") {
        let board = try PortBoard()
        board.h.move(to: CGPoint(x: 180, y: 180))
        board.h.move(to: aRightDot)
        expectEqual(board.h.editor.cursor, .openHand)
        board.h.press()
        expectEqual(board.h.editor.cursor, .closedHand)
        board.h.drag(to: boxB.center, speed: fast)
        expectEqual(board.h.editor.cursor, .closedHand)
        board.h.release()
        expectEqual(board.h.editor.cursor, .standard)
    },
    test("the target is outlined (the hint) while the end is over it, and not once released") {
        let board = try PortBoard()
        board.pressDot()
        board.h.drag(to: CGPoint(x: 380, y: 180), speed: fast)
        expectEqual(board.h.editor.hintedShapeID, nil)
        board.h.drag(to: boxB.center, speed: fast)
        expectEqual(board.h.editor.hintedShapeID, board.b)
        expectEqual(board.h.editor.outlines.shapes, [board.b])
        board.h.drag(to: discC.center, speed: fast)
        expectEqual(board.h.editor.hintedShapeID, nil)
        board.h.drag(to: boxB.center, speed: fast)
        expectEqual(board.h.editor.hintedShapeID, board.b)
        board.h.release()
        expectEqual(board.h.editor.hintedShapeID, nil)
        expectEqual(board.h.editor.outlines.shapes, [])
    },
    test("the binding hints show for the connection being drawn, though it isn't selected, as they would selected") {
        let board = try PortBoard()
        let size = CGSize(width: 700, height: 300)
        let insideA = CGRect(x: 100, y: 160, width: 170, height: 40)     // the start's dot and stub; the body starts at x 280
        board.connect(to: boxB.center, release: false)
        let arrow = try require(board.arrows.first?.id)
        let dragging = renderBitmap(board.h.editor, size: size)
        // The same arrow, selected, its handles hidden as a session hides them.
        let reference = try EditorHarness(plugins: PortBoard.plugins(), document: board.h.editor.document)
        reference.editor.selection = arrow
        reference.editor.session = IdleSession()
        expectEqual(changedPixels(dragging, renderBitmap(reference.editor, size: size), in: insideA), 0)
        board.h.release()
        expectEqual(board.h.editor.selectedShapeIDs, [])
        expect(changedPixels(dragging, renderBitmap(board.h.editor, size: size), in: insideA) > 0, "released, unselected, it shows none")
    },
    test("while a connection is drawn, its binding hints show in place of the selected arrow's") {
        let board = try PortBoard()
        let d = board.h.add(Box(boxD))
        let selected = board.h.add(Arrow(start: binding(d), end: binding(board.c)))
        board.h.editor.selection = selected
        let size = CGSize(width: 700, height: 620)
        let insideA = CGRect(x: 100, y: 160, width: 170, height: 40)
        let insideD = CGRect(x: 100, y: 480, width: 170, height: 40)     // the selected arrow's start
        board.connect(to: boxB.center, release: false)
        let drawn = try require(board.arrows.last?.id)
        let dragging = renderBitmap(board.h.editor, size: size)
        // The new arrow selected instead, its handles hidden as a session hides them.
        let reference = try EditorHarness(plugins: PortBoard.plugins(), document: board.h.editor.document)
        reference.editor.selection = drawn
        reference.editor.session = IdleSession()
        let expected = renderBitmap(reference.editor, size: size)
        expectEqual(changedPixels(dragging, expected, in: insideA), 0)
        expectEqual(changedPixels(dragging, expected, in: insideD), 0)
        board.h.release()
        expectEqual(board.h.editor.selection, selected)
        expect(changedPixels(dragging, renderBitmap(board.h.editor, size: size), in: insideD) > 0, "released, the selected arrow's show again")
    },
    test("the selection, and the way back through it, stay as they were: drawn, not drawn, or Escaped") {
        for outcome in ["drawn", "not drawn", "Escaped"] {
            let board = try PortBoard()
            board.h.editor.selection = board.c
            let revision = board.h.editor.selectionRevision
            switch outcome {
            case "drawn": board.connect(to: boxB.center)
            case "not drawn": board.connect(to: CGPoint(x: 380, y: 500))
            default:
                board.connect(to: boxB.center, release: false)
                board.h.escape()
                board.h.release()
            }
            expectEqual(board.arrows.count, outcome == "drawn" ? 1 : 0, outcome)
            expectEqual(board.h.editor.selectedShapeIDs, [board.c], outcome)
            expectEqual(board.h.editor.selectionRevision, revision, outcome)
            expectEqual(board.h.editor.currentToolID, .select, outcome)
            board.h.editor.goBack()
            expectEqual(board.h.editor.selectedShapeIDs, [], outcome)
            expect(!board.h.editor.canGoBack, "only the step before C was selected: \(outcome)")
        }
    },
    test("a connection drawn with nothing selected leaves nothing to go back to") {
        let board = try PortBoard()
        board.connect(to: boxB.center)
        expectEqual(board.arrows.count, 1)
        expectEqual(board.h.editor.selectedShapeIDs, [])
        expect(!board.h.editor.canGoBack)
    },
])
