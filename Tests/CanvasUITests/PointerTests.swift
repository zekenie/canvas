import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import CanvasUI
import Geometry
import TestKit

/// The probe tool's log, and on a double-click it begins editing the shape under the press, as the
/// select tool does.
final class EditingProbeTool {
    let log: PointerLog
    init(log: PointerLog) { self.log = log }
}

extension EditingProbeTool: Tool {
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {
        log.events.append("down")
        if pointer.clickCount == 2, let id = editor.shape(at: pointer.world) { _ = editor.beginEditing(id) }
    }
    func pointerMoved(_ pointer: Pointer, in editor: CanvasEditor) { log.events.append("moved") }
    func pointerExited(in editor: CanvasEditor) { log.events.append("exited") }
}

/// Puts a view over the canvas's top middle, as the host puts the path there: 200 points wide, 60
/// tall, from x 300. The canvas fills the window.
@MainActor func cover(_ canvas: CanvasView) throws {
    let window = try require(canvas.window)
    let container = NSView(frame: window.contentLayoutRect)
    canvas.frame = container.bounds
    let cover = NSView(frame: CGRect(x: 300, y: container.bounds.height - 60, width: 200, height: 60))
    container.addSubview(canvas)
    container.addSubview(cover)
    window.contentView = container
}

/// A canvas 800 × 600 in an unshown window, a 200 × 100 card at (100, 100) on it, and the probe
/// tool, which logs what it hears.
@MainActor func cardCanvas() throws -> (h: EditorHarness, canvas: CanvasView, card: ShapeID, log: PointerLog) {
    let log = PointerLog()
    let h = try EditorHarness(plugins: [FixturesPlugin(), CardsPlugin(), Contributor(id: "probe") {
        $0.tool(ToolDescriptor(id: .probe, label: "Probe", systemImage: "circle")) { _ in EditingProbeTool(log: log) }
        $0.defaultTool(.probe)
    }])
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let canvas = CanvasView(editor: h.editor)
    window.contentView = canvas
    let card = h.add(Card(CGRect(x: 100, y: 100, width: 200, height: 100)))
    return (h, canvas, card, log)
}

// Where the pointer is over a view the canvas hosts, it isn't over the canvas.
@MainActor let pointerTests = Suite("Pointer", [
    test("over the editing view the pointer is off the canvas: the tool hears it leave, once, and move again back on the canvas") {
        let (h, canvas, card, log) = try cardCanvas()
        expect(h.editor.beginEditing(card))
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 50, y: 50), in: canvas))
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 200, y: 150), in: canvas, time: 1.1))
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 210, y: 150), in: canvas, time: 1.2))
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 50, y: 50), in: canvas, time: 1.3))
        expectEqual(log.events, ["moved", "exited", "moved"])
    },
    test("once editing ends, where the editing view was is the canvas again") {
        let (h, canvas, card, log) = try cardCanvas()
        expect(h.editor.beginEditing(card))
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 200, y: 150), in: canvas))
        h.editor.endEditing()
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 210, y: 150), in: canvas, time: 1.1))
        expectEqual(log.events, ["exited", "moved"])
    },
    test("a press that began editing, released over the editing view, leaves the pointer there, off the canvas") {
        let (h, canvas, card, log) = try cardCanvas()
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 200, y: 150), in: canvas, clicks: 2))
        expectEqual(h.editor.editingShapeID, card)
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 200, y: 150), in: canvas, clicks: 2, time: 1.05))
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 210, y: 150), in: canvas, time: 1.1))
        expectEqual(log.events, ["down", "moved", "exited"], "the release hovers what's there, then leaves; the move stays off")
    },
    test("under a view the host puts over the canvas (the path) the pointer is off the canvas: the tool hears it leave, once, and move again back on the canvas") {
        let (_, canvas, _, log) = try cardCanvas()
        try cover(canvas)
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 50, y: 30), in: canvas))
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 400, y: 30), in: canvas, time: 1.1))
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 410, y: 30), in: canvas, time: 1.2))
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 400, y: 90), in: canvas, time: 1.3))
        expectEqual(log.events, ["moved", "exited", "moved"])
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 400, y: 90), in: canvas, time: 1.4))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 400, y: 30), in: canvas, time: 1.5))
        expectEqual(log.events.suffix(3), ["down", "moved", "exited"], "a press released under it hovers what's there, then leaves: the pointer's off the canvas")
    },
    test("under a view over the canvas the cursor is the arrow, moved there or released there after a press; back on the canvas, the tool's") {
        let (_, canvas, _, _) = try cardCanvas()        // the probe's cursor is a tool's default, the crosshair
        try cover(canvas)
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 400, y: 90), in: canvas))
        NSCursor.crosshair.set()
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 400, y: 30), in: canvas, time: 1.1))
        expect(NSCursor.current === NSCursor.arrow, "moved under it")
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 400, y: 90), in: canvas, time: 1.2))
        expect(NSCursor.current === NSCursor.crosshair, "back on the canvas")
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 400, y: 90), in: canvas, time: 1.3))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 400, y: 30), in: canvas, time: 1.4))
        expect(NSCursor.current === NSCursor.arrow, "released under it")
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 410, y: 30), in: canvas, time: 1.5))
        expect(NSCursor.current === NSCursor.arrow, "and moved on there")
    },
    test("a release on the canvas stays on it, and the editing view is where its shape is at any zoom") {
        let (h, canvas, card, log) = try cardCanvas()
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 50, y: 50), in: canvas))
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 50, y: 50), in: canvas, time: 1.05))
        h.editor.camera.setZoom(2, around: .zero)
        expect(h.editor.beginEditing(card))
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 350, y: 150), in: canvas, time: 1.1))    // (175, 75): above the card
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 350, y: 250), in: canvas, time: 1.2))    // (175, 125): on it
        expectEqual(log.events, ["down", "moved", "moved", "exited"])
    },
])
