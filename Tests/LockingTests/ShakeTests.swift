import Canvas
import CanvasTesting
import CoreGraphics
import Locking
import Selection
import TestKit

// A shake lasts 360 ms, played a frame every 16 ms: side to side, 5 points at most, dying away.

@MainActor let shakeTests = Suite("Shaking a locked shape", [
    test("dragging a locked shape leaves it where it is, and shakes it, side to side, then puts it back where it's drawn") {
        let h = try lockingHarness()
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        h.editor.lock([box])
        h.press(at: CGPoint(x: 150, y: 150))
        h.drag(to: CGPoint(x: 200, y: 180))
        expectEqual(h.editor.document[box]?.box, CGRect(x: 100, y: 100, width: 100, height: 100))
        expectEqual(h.editor.selection, box, "pressing it selected it")
        var offsets: [CGPoint] = []
        for _ in 0..<24 {
            h.wait(16)
            offsets.append(h.editor.drawingOffset(of: box))
        }
        expect(offsets.allSatisfy { $0.y == 0 }, "only side to side")
        expect(offsets.allSatisfy { abs($0.x) <= 5 }, "\(offsets)")
        expect(offsets.contains { $0.x > 2 } && offsets.contains { $0.x < -2 }, "both ways: \(offsets)")
        expect(abs(offsets[1].x) > abs(offsets[20].x) || offsets[20].x == 0, "dying away")
        expectEqual(offsets.last, .zero, "done by 384 ms")
        h.release()
    },
    test("a click on a locked shape selects it, and doesn't shake it: it isn't a try to move it") {
        let h = try lockingHarness()
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        h.editor.lock([box])
        h.press(at: CGPoint(x: 150, y: 150))
        h.drag(to: CGPoint(x: 152, y: 151))          // a hand's jitter
        h.release()
        h.wait(16)
        expectEqual(h.editor.selection, box)
        expectEqual(h.editor.drawingOffset(of: box), .zero)
    },
    test("dragging a selection moves its unlocked shapes and shakes its locked ones") {
        let h = try lockingHarness()
        let locked = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        let free = h.add(Box(CGRect(x: 300, y: 100, width: 100, height: 100)))
        h.editor.lock([locked])
        h.editor.selectedShapeIDs = [locked, free]
        h.press(at: CGPoint(x: 350, y: 150))
        h.drag(to: CGPoint(x: 380, y: 150))
        h.wait(16)
        expectEqual(h.editor.document[free]?.box?.origin, CGPoint(x: 330, y: 100))
        expectEqual(h.editor.document[locked]?.box?.origin, CGPoint(x: 100, y: 100))
        expect(h.editor.drawingOffset(of: locked) != .zero)
        expectEqual(h.editor.drawingOffset(of: free), .zero)
        h.release()
    },
    test("Delete takes the rest of the selection and keeps a locked shape, which shakes") {
        let h = try lockingHarness()
        let locked = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        let free = h.add(Box(CGRect(x: 300, y: 100, width: 100, height: 100)))
        h.editor.lock([locked])
        h.editor.selectedShapeIDs = [locked, free]
        expect(h.key("\u{7f}"))
        expectEqual(h.editor.document.shapes.map(\.id), [locked])
        expectEqual(h.editor.selectedShapeIDs, [locked])
        h.wait(16)
        expect(h.editor.drawingOffset(of: locked) != .zero)
    },
    test("a locked editable shape isn't edited: a double-click, or Return, shakes it instead") {
        let h = try lockingHarness()
        let card = h.add(Card(CGRect(x: 100, y: 100, width: 100, height: 60)))
        h.editor.lock([card])
        h.click(at: CGPoint(x: 150, y: 130))
        h.click(at: CGPoint(x: 150, y: 130), clickCount: 2)
        expectEqual(h.editor.editingShapeID, nil)
        h.wait(16)
        expect(h.editor.drawingOffset(of: card) != .zero)
        h.wait(400)
        expect(h.key("\r"))
        expectEqual(h.editor.editingShapeID, nil)
        h.wait(16)
        expect(h.editor.drawingOffset(of: card) != .zero)
        h.editor.unlock([card])
        h.wait(400)
        expect(h.key("\r"))
        expectEqual(h.editor.editingShapeID, card, "unlocked, it's edited")
    },
    test("a shake under way isn't started over by another try; one after it is a new shake") {
        let h = try lockingHarness()
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        h.editor.lock([box])
        h.editor.selection = box
        h.editor.perform(.delete)
        h.wait(160)
        h.editor.perform(.delete)                    // 160 ms in
        h.wait(224)                                  // 384 ms in: over, had it started over it'd be 224 ms into another
        expectEqual(h.editor.drawingOffset(of: box), .zero)
        h.editor.perform(.delete)
        h.wait(16)
        expect(h.editor.drawingOffset(of: box) != .zero)
    },
    test("unlocked, the shape moves and deletes as any other, and nothing shakes") {
        let h = try lockingHarness()
        let box = h.add(Box(CGRect(x: 100, y: 100, width: 100, height: 100)))
        h.editor.lock([box])
        h.editor.unlock([box])
        h.press(at: CGPoint(x: 150, y: 150))
        h.drag(to: CGPoint(x: 200, y: 150))
        h.release()
        expectEqual(h.editor.document[box]?.box?.origin, CGPoint(x: 150, y: 100))
        expectEqual(h.editor.drawingOffset(of: box), .zero)
        h.editor.perform(.delete)
        expectEqual(h.editor.document.shapes, [])
    },
])
