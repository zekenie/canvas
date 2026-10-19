import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Clipboard
import CoreGraphics
import Geometry
import Keyboard
import Selection
import TestKit

// ⌘D and Edit › Duplicate put copies of the selection beside it without the pasteboard, and a drag with ⌥
// held carries copies in place of the shapes: the paste's own machinery (new ids naming their originals,
// containers copied whole, settled where they land), a step named Duplicate.

@MainActor let duplicateTests = Suite("Duplicating", [
    test("⌘D puts a copy beside the selection, 16 points down and right, selected, in one step, Duplicate; the pasteboard is not touched, and the original stays") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let box = h.add(Box(slot(0)))
        h.add(Disc(slot(1)))
        h.editor.selection = box
        let count = pasteboard.changeCount
        let before = h.editor.document
        expect(h.command("d"))
        expectEqual(pasteboard.changeCount, count)
        let copy = try require(h.editor.shapes(since: before).first)
        expectEqual(h.editor.shapes(since: before).count, 1)
        expectEqual(copy.box, slot(0).offsetBy(dx: 16, dy: 16))
        expectEqual(copy.copiedFrom, box)
        expectEqual(h.editor.selectedShapeIDs, [copy.id])
        expectEqual(h.editor.document[box]?.box, slot(0))
        expectEqual(h.editor.undoHistory.undoName, "Duplicate")
        h.editor.undo()
        expectEqual(h.editor.document.shapes.count, 2)
        expect(h.editor.canRedo)
    },
    test("a duplicate is 16 view points away at any zoom; a container is copied with what it holds, each copy in its copy") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [CorralsPlugin()])
        h.editor.viewportDidResize(to: CGSize(width: 800, height: 600))
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 400, height: 300)))
        let box = h.add(Box(CGRect(x: 50, y: 50, width: 100, height: 100)))
        h.editor.put([box], in: pen)
        h.editor.camera = Camera(origin: .zero, zoom: 2)
        h.editor.selection = pen
        let before = h.editor.document
        h.editor.duplicateSelection()
        let made = h.editor.shapes(since: before)
        expectEqual(made.map(\.copiedFrom), [pen, box])
        expectEqual(made.first?.box, CGRect(x: 8, y: 8, width: 400, height: 300), "16 view points at twice the zoom")
        expectEqual(h.editor.holder(of: made[1].id), made[0].id)
        expectEqual(h.editor.holder(of: box), pen)
        expectEqual(h.editor.undoHistory.undoName, "Duplicate")
    },
    test("nothing is duplicated mid-gesture, on a board that takes no shapes, or of shapes that can't be copied; Edit › Duplicate is off then") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let ticket = h.add(Ticket(frame: slot(0)))
        h.editor.selection = ticket
        expect(!h.editor.canPerform(.duplicate))
        expect(!h.command("d"))
        let box = h.add(Box(slot(1)))
        h.editor.selection = box
        expect(h.editor.canPerform(.duplicate))
        h.press(at: middle(1))
        expect(!h.editor.canPerform(.duplicate), "a press is under way")
        h.release()
        expectEqual(h.editor.document.shapes.count, 2)
        h.editor.selectedShapeIDs = [ticket, box]
        h.editor.duplicateSelection()
        expectEqual(h.editor.document.shapes.count, 3, "the box only")
    },
    test("a drag with ⌥ held carries a copy: the original stays, the copy follows the pointer, and the copy and its move are one step, Duplicate; Escape takes the copy away") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard)
        let box = h.add(Box(slot(0)))
        h.add(Disc(slot(2)))
        h.editor.selection = box
        let count = pasteboard.changeCount
        h.hold(.option)
        h.press(at: middle(0))
        h.drag(to: middle(0) + CGPoint(x: 0, y: 300), speed: 4)
        h.release()
        h.hold([])
        expectEqual(pasteboard.changeCount, count)
        let copy = try require(h.editor.selectedShapeIDs.first)
        expect(copy != box)
        expectEqual(h.editor.document[box]?.box, slot(0))
        expectEqual(h.editor.document[copy]?.box, slot(0).offsetBy(dx: 0, dy: 300))
        expectEqual(h.editor.document[copy]?.copiedFrom, box)
        expectEqual(h.editor.undoHistory.undoName, "Duplicate")
        h.editor.undo()
        expect(h.editor.document[copy] == nil)
        expectEqual(h.editor.document[box]?.box, slot(0))
        // Without ⌥ (let go more than 150 ms ago) the same drag moves the shape.
        h.wait(200)
        h.press(at: middle(0))
        h.drag(to: middle(0) + CGPoint(x: 0, y: 300), speed: 4)
        h.release()
        expectEqual(h.editor.document[box]?.box, slot(0).offsetBy(dx: 0, dy: 300))
        expectEqual(h.editor.document.shapes.count, 2)
        // Escape in the middle of a ⌥ drag takes the copy away and leaves the selection and the step as they were.
        let step = h.editor.undoHistory.undoName
        h.editor.selection = box
        h.hold(.option)
        h.press(at: middle(0) + CGPoint(x: 0, y: 300))
        h.drag(to: middle(0) + CGPoint(x: 150, y: 500), speed: 4)
        expectEqual(h.editor.document.shapes.count, 3, "the copy is being dragged")
        h.escape()
        h.release()
        h.hold([])
        expectEqual(h.editor.document.shapes.count, 2)
        expectEqual(h.editor.document[box]?.box, slot(0).offsetBy(dx: 0, dy: 300))
        expectEqual(h.editor.selectedShapeIDs, [box])
        expectEqual(h.editor.undoHistory.undoName, step, "no step for it")
    },
    test("a gauge and its stretch duplicated together: the copy of the stretch is laid out by the copy of the gauge, in one step") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [StretchesPlugin()])
        let gauge = h.add(CanvasTesting.Gauge(CGRect(x: 1000, y: 0, width: 60, height: 40), width: 300, height: 100))
        let stretch = h.add(Stretch(CGRect(x: 1000, y: 100, width: 100, height: 60), gauge: gauge))
        h.editor.selectedShapeIDs = [gauge, stretch]
        let before = h.editor.document
        h.editor.duplicateSelection()
        let made = h.editor.shapes(since: before)
        let newGauge = try require(made.first { $0.kind == CanvasTesting.Gauge.kind })
        let newStretch = try require(made.first { $0.kind == Stretch.kind })
        expectEqual(newStretch.typed(as: Stretch.self)?.props.gauge?.shape, newGauge.id, "it names the gauge that came with it")
        expectEqual(h.editor.shapeContext.frame(of: newStretch.id), CGRect(origin: try require(newStretch.box).origin, size: CGSize(width: 300, height: 100)))
        expectEqual(newStretch.box?.size, CGSize(width: 100, height: 60), "and stores what it did")
        expectEqual(h.editor.undoHistory.undoName, "Duplicate")
        h.editor.undo()
        expectEqual(h.editor.document, before)
    },
    test("a drag with ⌥ held over a corral's edge settles the copy of a stretch by its laid-out frame: stored inside, laid out mostly outside, it is nudged out") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [CorralsPlugin(), StretchesPlugin()])
        let pen = h.add(Corral(CGRect(x: 100, y: 100, width: 400, height: 300)))
        let gauge = h.add(CanvasTesting.Gauge(CGRect(x: 1000, y: 0, width: 60, height: 40), width: 300, height: 60))
        let stretch = h.add(Stretch(CGRect(x: 700, y: 150, width: 100, height: 60), gauge: gauge))
        h.editor.selection = stretch
        h.hold(.option)
        h.press(at: CGPoint(x: 750, y: 180))
        h.drag(to: CGPoint(x: 600, y: 180), speed: 4)
        h.drag(to: CGPoint(x: 430, y: 180), speed: 4)         // its box at 380…480, inside the corral; its frame to 680
        h.release()
        h.hold([])
        let copy = try require(h.editor.selectedShapeIDs.first)
        expect(copy != stretch)
        expectEqual(h.editor.holder(of: copy), nil, "40% of its frame is in: out")
        expectEqual(h.editor.document[copy]?.box?.origin, CGPoint(x: 380, y: 24), "nudged clear the shortest way for its frame: up, 16 above the corral")
        expectEqual(h.editor.document[stretch]?.box?.origin, CGPoint(x: 700, y: 150))
        expectEqual(h.editor.undoHistory.undoName, "Duplicate")
        expect(!(h.editor.shapeContext.frame(of: copy) ?? .null).intersects(try require(h.editor.document[pen]?.box)), "its frame is clear of the corral")
    },
    test("Escape in a drag with ⌥ held takes away a copied container and everything it holds") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let h = try harness(pasteboard, [CorralsPlugin()])
        let pen = h.add(Corral(CGRect(x: 0, y: 0, width: 400, height: 300)))
        let box = h.add(Box(CGRect(x: 50, y: 50, width: 100, height: 100)))
        h.editor.put([box], in: pen)
        h.editor.selection = pen
        let step = h.editor.undoHistory.undoName
        h.hold(.option)
        h.press(at: CGPoint(x: 300, y: 250))
        h.drag(to: CGPoint(x: 500, y: 450), speed: 4)
        expectEqual(h.editor.document.shapes.count, 4, "the copy of the container and of what it holds are being dragged")
        h.escape()
        h.release()
        h.hold([])
        expectEqual(h.editor.document.shapes.count, 2, "nothing of the copy is left")
        expectEqual(h.editor.selectedShapeIDs, [pen])
        expectEqual(h.editor.holder(of: box), pen)
        expectEqual(h.editor.undoHistory.undoName, step, "no step for it")
    },
    test("a drag with ⌥ held does not copy shapes that are read-only: it refuses, as a drag of them does, and nothing is made") {
        let pasteboard = privatePasteboard()
        defer { pasteboard.releaseGlobally() }
        let log = RefusalLog()
        let h = try harness(pasteboard, [FreezingPlugin(log: log)])
        let box = h.add(Box(slot(0)))
        h.editor.freeze([box])
        h.editor.selection = box
        h.hold(.option)
        h.press(at: middle(0))
        h.drag(to: middle(0) + CGPoint(x: 0, y: 300), speed: 4)
        h.release()
        h.hold([])
        expectEqual(h.editor.document.shapes.count, 1)
        expectEqual(h.editor.document[box]?.box, slot(0))
        expect(log.refusals.contains([box]), "\(log.refusals)")
    },
])
