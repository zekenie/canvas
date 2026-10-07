@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Keyboard
import Observation
import Selection
import TestKit

// The shape the pointer is on where a plugin shows one the canvas doesn't (`editor.hoveredElsewhere`:
// a row of another board's shapes in the table of contents): a shape of the file that isn't on the
// board shown, observed, outlined faintly as the shape on the board shown that holds it, and let go of
// by a tool change, another board shown, and the shape leaving the file or coming onto the board.
// Fixtures only: pockets own boards, cards are what the placing tool puts down.

/// A root holding A and pocket P; P's board holds B and pocket Q; Q's board holds Z. The pocket
/// boards aren't shown.
private struct Nested {
    let a = ShapeID(), p = ShapeID(), b = ShapeID(), q = ShapeID(), z = ShapeID()
    var pBoard: BoardID { BoardID(owner: p) }
    var qBoard: BoardID { BoardID(owner: q) }

    var file: CanvasFile {
        func record<P: ShapeProps>(_ id: ShapeID, _ props: P) -> AnyShapeRecord { AnyShapeRecord(ShapeRecord(id: id, props)) }
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        return CanvasFile(root: CanvasDocument(shapes: [record(a, Box(frame)), record(p, Pocket(frame.offsetBy(dx: 200, dy: 0)))]),
                          children: [p: CanvasDocument(shapes: [record(b, Box(frame)), record(q, Pocket(frame.offsetBy(dx: 200, dy: 0)))]),
                                     q: CanvasDocument(shapes: [record(z, Box(frame))])])
    }
}

@MainActor private func nestedHarness(_ nested: Nested = Nested()) throws -> EditorHarness {
    try EditorHarness(plugins: [KeyboardPlugin(), SelectionPlugin(), FixturesPlugin(), CardsPlugin(), PocketsPlugin()], file: nested.file)
}

@MainActor let hoverElsewhereTests = Suite("Hovering where the canvas doesn't show the shape", [
    test("a shape on another board can be hovered elsewhere, one on the board shown or none can't, and setting either lets go of what was") {
        let n = Nested()
        let h = try nestedHarness(n)
        expectEqual(h.editor.hoveredElsewhere, nil)
        h.editor.hoveredElsewhere = n.b                     // on P's board
        expectEqual(h.editor.hoveredElsewhere, n.b)
        expectEqual(h.editor.hovered, nil, "the canvas's hover is the canvas's")
        h.editor.hoveredElsewhere = n.z                     // two boards down
        expectEqual(h.editor.hoveredElsewhere, n.z)
        h.editor.hoveredElsewhere = n.a                     // on the board shown: that's the hover's
        expectEqual(h.editor.hoveredElsewhere, nil)
        h.editor.hoveredElsewhere = n.b
        h.editor.hoveredElsewhere = ShapeID()               // in no board of the file
        expectEqual(h.editor.hoveredElsewhere, nil)
        h.editor.hoveredElsewhere = n.b
        h.editor.hoveredElsewhere = nil
        expectEqual(h.editor.hoveredElsewhere, nil)
    },
    test("it's observed, and the same shape again changes nothing: no notification, no redraw") {
        let n = Nested()
        let h = try nestedHarness(n)
        let host = DisplayCounter()
        h.editor.delegate = host
        /// Whether `change` reaches whoever observes `hoveredElsewhere`.
        @MainActor func reaches(_ change: () -> Void) -> Bool {
            let changed = Flag()
            withObservationTracking { _ = h.editor.hoveredElsewhere } onChange: { changed.set() }
            change()
            return changed.isSet
        }
        expect(reaches { h.editor.hoveredElsewhere = n.b }, "set")
        expectEqual(host.redraws, 1)
        expect(!reaches { h.editor.hoveredElsewhere = n.b }, "the same shape again")
        expectEqual(host.redraws, 1)
        expect(reaches { h.editor.hoveredElsewhere = n.z }, "another")
        expect(reaches { h.editor.hoveredElsewhere = nil }, "off it")
        expect(!reaches { h.editor.hoveredElsewhere = nil }, "and again")
        expect(!reaches { h.editor.hoveredElsewhere = n.a }, "a shape on the board shown, with none hovered elsewhere: nothing")
        expectEqual(host.redraws, 3)
    },
    test("the canvas outlines faintly the shape on the board shown that holds it: its pocket, at any depth, and itself where the hover is alone") {
        let n = Nested()
        let h = try nestedHarness(n)
        expectEqual(h.editor.outlines.faintShapes, [])
        h.editor.hoveredElsewhere = n.b                     // on P's board: P holds it
        expectEqual(h.editor.outlines.faintShapes, [n.p])
        h.editor.hoveredElsewhere = n.z                     // on Q's board, which is on P's: P holds it
        expectEqual(h.editor.outlines.faintShapes, [n.p])
        h.editor.hoveredElsewhere = nil
        expectEqual(h.editor.outlines.faintShapes, [], "at once, as the hover's is")
        h.editor.hoveredElsewhere = n.b
        h.editor.hovered = n.a                              // the pointer on the canvas wins: that one alone
        expectEqual(h.editor.outlines.faintShapes, [n.a])
        h.editor.hovered = nil
        expectEqual(h.editor.outlines.faintShapes, [n.p], "and the holder again when it's let go of")
        // On P's board: Z's holder is Q, B is on it, and A is above it (no shape on the board shown holds it).
        expect(h.enter(n.p))
        h.editor.hoveredElsewhere = n.z
        expectEqual(h.editor.outlines.faintShapes, [n.q])
        h.editor.hoveredElsewhere = n.a
        expectEqual(h.editor.hoveredElsewhere, n.a, "a shape of the file, on a board above")
        expectEqual(h.editor.outlines.faintShapes, [], "no shape on this board holds it")
    },
    test("it's drawn as the hover is: lighter than the selection's, not on a selected shape, and not while a session runs") {
        let n = Nested()
        let h = try nestedHarness(n)
        h.editor.hoveredElsewhere = n.b
        let plain = renderBitmap(h.editor, size: CGSize(width: 600, height: 200))
        h.editor.hoveredElsewhere = nil
        let none = renderBitmap(h.editor, size: CGSize(width: 600, height: 200))
        expect(changedPixels(plain, none, in: CGRect(x: 180, y: 0, width: 140, height: 120)) > 0, "P is outlined faintly")
        h.editor.hoveredElsewhere = n.b
        h.editor.selection = n.p
        expectEqual(h.editor.outlines.faintShapes, [], "a selected shape shows its selection instead")
        expectEqual(h.editor.outlines.shapes, [n.p])
        h.editor.selection = nil
        expectEqual(h.editor.outlines.faintShapes, [n.p])
        h.editor.session = IdleSession()
        expectEqual(h.editor.outlines.faintShapes, [], "none while a session runs")
        h.editor.session = nil
        expectEqual(h.editor.outlines.faintShapes, [n.p], "and back when it ends")
    },
    test("changing tools, showing another board, the shape leaving the file and the shape coming onto the board shown let go of it") {
        let n = Nested()
        let h = try nestedHarness(n)
        h.editor.hoveredElsewhere = n.b
        h.editor.setTool(ToolID(placing: Card.kind))
        expectEqual(h.editor.hoveredElsewhere, nil, "a tool change")
        h.editor.hoveredElsewhere = n.b
        expect(h.enter(n.p))
        expectEqual(h.editor.hoveredElsewhere, nil, "another board shown, whichever it is")
        expect(h.editor.showBoard(.root))
        h.editor.hoveredElsewhere = n.b
        h.editor.transact(on: n.pBoard, "Delete") { $0.delete([n.b]) }
        expectEqual(h.editor.hoveredElsewhere, nil, "the shape deleted, on a board that isn't shown")
        h.editor.hoveredElsewhere = n.z
        h.editor.transact("Delete") { $0.delete([n.p]) }       // takes P's board and Q's with it
        expectEqual(h.editor.hoveredElsewhere, nil, "the board it's on taken with its owner")
        h.editor.undo()
        h.editor.hoveredElsewhere = n.z
        expectEqual(h.editor.hoveredElsewhere, n.z, "undone, it's a shape of the file again")
        // Brought onto the board shown, it's the hover's, and not a shape the canvas doesn't show.
        h.editor.transact("Move") { _ = $0.move([n.z], from: n.qBoard, to: .root) }
        expectEqual(h.editor.hoveredElsewhere, nil)
    },
    test("without the Selection plugin it's nil, and setting it does nothing") {
        let h = try EditorHarness(plugins: [FixturesPlugin()])
        let a = h.add(Box(CGRect(x: 0, y: 0, width: 10, height: 10)))
        h.editor.hoveredElsewhere = a
        expectEqual(h.editor.hoveredElsewhere, nil)
    },
])
