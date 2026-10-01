import Canvas
import CanvasTesting
import CoreGraphics
import Frames
import Geometry
import Selection
import TestKit

// The Frame tool (F): a drag draws a frame from the press to the pointer, a click places one of
// 640 × 400 centered on it, and either way it's put down as a placed shape is: one step, "Add
// Frame", settled (in or out of the frames it lands in, taking in what's mostly inside it), selected,
// the default tool back. At 100% from the origin, view points are world units.

@MainActor let toolTests = Suite("The Frame tool", [
    test("F, then a drag, draws a frame from the press to the pointer, as one step, Add Frame; selected, with the default tool back") {
        let h = try frameHarness()
        h.frameTool()
        h.press(at: CGPoint(x: 100, y: 100))
        h.drag(to: CGPoint(x: 300, y: 250))
        h.drag(to: CGPoint(x: 500, y: 400))
        expect(h.frames.isEmpty, "nothing is put down until the release")
        h.release()
        let frame = try require(h.frames.first)
        expectEqual(h.frames.count, 1)
        expectEqual(frame.box, frameRect)
        expectEqual(h.editor.selection, frame.id)
        expectEqual(h.editor.currentToolID, .select)
        expectEqual(h.editor.undoHistory.undoName, "Add Frame")
        h.editor.undo()
        expect(h.frames.isEmpty)
        expect(!h.editor.canUndo, "drawing was one step")
    },
    test("drawn from the press up and to the left, it's the rect between the two") {
        let h = try frameHarness()
        h.frameTool()
        h.press(at: CGPoint(x: 500, y: 400))
        h.drag(to: CGPoint(x: 300, y: 300))
        h.drag(to: CGPoint(x: 100, y: 100))
        h.release()
        expectEqual(h.frames.map(\.box), [frameRect])
    },
    test("a click places a frame of 640 × 400 centered on it; so does a press that moves less than 12 view points either way") {
        let h = try frameHarness()
        h.frameTool()
        h.click(at: CGPoint(x: 500, y: 400))
        expectEqual(h.frames.map(\.box), [CGRect(x: 180, y: 200, width: 640, height: 400)])
        expectEqual(h.editor.undoHistory.undoName, "Add Frame")
        expectEqual(h.editor.currentToolID, .select)
        h.editor.undo()
        h.frameTool()
        h.press(at: CGPoint(x: 500, y: 400))
        h.drag(to: CGPoint(x: 508, y: 395))
        h.drag(to: CGPoint(x: 511, y: 389))
        h.release()
        expectEqual(h.frames.map(\.box), [CGRect(x: 180, y: 200, width: 640, height: 400)], "a jitter is a click, centered on the press")
    },
    test("12 view points along either axis is a drag, at any zoom; and once it's drawing, coming back to the press draws the smallest frame") {
        let h = try frameHarness()
        h.editor.camera = Camera(origin: .zero, zoom: 0.5)
        h.frameTool()
        h.press(at: CGPoint(x: 100, y: 100))
        h.drag(to: CGPoint(x: 112, y: 100))
        h.release()
        expectEqual(h.frames.map(\.box), [CGRect(x: 200, y: 200, width: 96, height: 64)], "12 view points: 24 world units, the smallest a frame is")
        h.editor.undo()
        h.frameTool()
        h.press(at: CGPoint(x: 100, y: 100))
        h.drag(to: CGPoint(x: 300, y: 300))
        h.drag(to: CGPoint(x: 101, y: 101))
        h.release()
        expectEqual(h.frames.map(\.box), [CGRect(x: 200, y: 200, width: 96, height: 64)], "drawing still")
    },
    test("never smaller than 96 × 64, grown from the press toward the pointer") {
        let h = try frameHarness()
        h.frameTool()
        h.press(at: CGPoint(x: 300, y: 300))
        h.drag(to: CGPoint(x: 340, y: 280))
        h.release()
        expectEqual(h.frames.map(\.box), [CGRect(x: 300, y: 236, width: 96, height: 64)])
    },
    test("⇧ draws a square, by its longer side; ⌥ draws it about the press; each as it's pressed or let go, the pointer still") {
        let h = try frameHarness()
        h.frameTool()
        h.press(at: CGPoint(x: 200, y: 200))
        h.drag(to: CGPoint(x: 300, y: 260))
        h.drag(to: CGPoint(x: 400, y: 300))
        h.hold(.shift)
        h.release()
        expectEqual(h.frames.map(\.box), [CGRect(x: 200, y: 200, width: 200, height: 200)], "⇧: a square")
        h.hold([])
        h.wait(200)
        h.editor.undo()
        h.frameTool()
        h.hold(.option)
        h.press(at: CGPoint(x: 200, y: 200))
        h.drag(to: CGPoint(x: 250, y: 230))
        h.drag(to: CGPoint(x: 300, y: 260))
        h.release()
        expectEqual(h.frames.map(\.box), [CGRect(x: 100, y: 140, width: 200, height: 120)], "⌥: about the press")
    },
    test("Escape puts nothing down, leaves no step, and the Frame tool stays") {
        let h = try frameHarness()
        h.frameTool()
        h.press(at: CGPoint(x: 100, y: 100))
        h.drag(to: CGPoint(x: 300, y: 250))
        h.escape()
        h.release()
        expect(h.frames.isEmpty)
        expect(!h.editor.canUndo)
        expectEqual(h.editor.currentToolID, ToolID(placing: Frame.kind))
    },
    test("drawn over boxes, it takes in what's mostly inside it, nudging in what hangs over its edge, and out what's mostly outside; gliding there, as one step") {
        let h = try frameHarness()
        let inside = h.addBox(CGRect(x: 150, y: 150, width: 100, height: 100))
        let over = h.addBox(CGRect(x: 430, y: 200, width: 100, height: 100))          // 70% inside
        let out = h.addBox(CGRect(x: 480, y: 300, width: 100, height: 60))            // 20% inside
        h.frameTool()
        h.press(at: CGPoint(x: 100, y: 100))
        h.drag(to: CGPoint(x: 300, y: 250))
        h.drag(to: CGPoint(x: 500, y: 400))
        h.release()
        let frame = try require(h.frames.first?.id)
        expectEqual(h.editor.holder(of: inside), frame)
        expectEqual(h.editor.holder(of: over), frame)
        expectEqual(h.editor.holder(of: out), nil)
        expectEqual(h.editor.box(inside), CGRect(x: 150, y: 150, width: 100, height: 100), "inside it already: not nudged")
        expectEqual(h.editor.box(over), CGRect(x: 384, y: 200, width: 100, height: 100), "nudged in, 16 inside its edge")
        expectEqual(h.editor.box(out), CGRect(x: 516, y: 300, width: 100, height: 60), "nudged out, 16 outside it")
        expect(h.editor.isGliding(over) && h.editor.isGliding(out), "gliding there")
        h.wait(300)
        expect(!h.editor.isGliding(over) && !h.editor.isGliding(out))
        let order = h.editor.document.shapes.map(\.id)
        expect(order.firstIndex(of: frame)! < order.firstIndex(of: inside)! && order.firstIndex(of: frame)! < order.firstIndex(of: over)!,
               "what it holds paints above it")
        expectEqual(h.editor.undoHistory.undoName, "Add Frame")
        h.editor.undo()
        expect(h.frames.isEmpty)
        expectEqual(h.editor.box(over), CGRect(x: 430, y: 200, width: 100, height: 100), "undone as one step")
        expectEqual(h.editor.box(out), CGRect(x: 480, y: 300, width: 100, height: 60))
        expectEqual(h.editor.holder(of: inside), nil)
    },
    test("drawn inside a frame, it's in that frame, and takes in what it's drawn over there") {
        let h = try frameHarness()
        let outer = h.addFrame(CGRect(x: 50, y: 50, width: 800, height: 600))
        let box = h.addBox(CGRect(x: 150, y: 150, width: 100, height: 100), in: outer)
        h.frameTool()
        h.press(at: CGPoint(x: 100, y: 100))
        h.drag(to: CGPoint(x: 300, y: 250))
        h.drag(to: CGPoint(x: 500, y: 400))
        h.release()
        let inner = try require(h.frames.first { $0.id != outer }?.id)
        expectEqual(h.editor.holder(of: inner), outer)
        expectEqual(h.editor.holder(of: box), inner)
    },
    test("drawn, or clicked, into a read-only frame, nothing is put down, and the frame hears it was refused") {
        let refusals = RefusalLog()
        let h = try frameHarness(refusals)
        let outer = h.addFrame(CGRect(x: 50, y: 50, width: 800, height: 600))
        h.editor.freeze([outer])
        let steps = h.editor.undoHistory.undoName
        h.frameTool()
        h.press(at: CGPoint(x: 100, y: 100))
        h.drag(to: CGPoint(x: 300, y: 250))
        h.drag(to: CGPoint(x: 500, y: 400))
        h.release()
        expectEqual(h.frames.map(\.id), [outer])
        expectEqual(refusals.refusals, [[outer]])
        expectEqual(h.editor.undoHistory.undoName, steps, "no step")
        h.frameTool()
        h.click(at: CGPoint(x: 450, y: 350))
        expectEqual(h.frames.map(\.id), [outer])
        expectEqual(refusals.refusals, [[outer], [outer]])
    },
])
