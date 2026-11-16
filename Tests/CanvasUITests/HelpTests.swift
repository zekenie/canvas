import AppKit
@_spi(Host) import Canvas
import CanvasTesting
@_spi(Host) import CanvasUI
import Geometry
import TestKit

// The canvas shows its tool's help (`Tool.help`) as the system tooltip, set as the pointer's state changes
// and gone with it: over a view the canvas hosts it's gone too, and while a press runs.

/// A tool whose help is `words` over the card, where the pointer last was, and nothing elsewhere.
@MainActor final class HelpingTool {
    var words: String? = "A card"
    var pointer: CGPoint?
}

/// A press that does nothing but run.
@MainActor final class HoldingSession {}

extension HoldingSession: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {}
}

extension HelpingTool: Tool {
    func help(in editor: CanvasEditor) -> String? {
        guard let pointer, editor.shape(at: pointer) != nil else { return nil }
        return words
    }
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) { editor.session = HoldingSession() }
    func pointerMoved(_ pointer: Pointer, in editor: CanvasEditor) {
        self.pointer = pointer.world
        editor.refreshCursor()
    }
    func pointerExited(in editor: CanvasEditor) {
        pointer = nil
        editor.refreshCursor()
    }
}

@MainActor func helpingCanvas() throws -> (h: EditorHarness, canvas: CanvasView, tool: HelpingTool) {
    let tool = HelpingTool()
    let h = try EditorHarness(plugins: [FixturesPlugin(), CardsPlugin(), Contributor(id: "helping") {
        $0.tool(ToolDescriptor(id: .probe, label: "Probe", systemImage: "circle")) { _ in tool }
        $0.defaultTool(.probe)
    }])
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
    let canvas = CanvasView(editor: h.editor)
    window.contentView = canvas
    h.add(Card(CGRect(x: 100, y: 100, width: 200, height: 100)))
    return (h, canvas, tool)
}

@MainActor let helpTests = Suite("The canvas's tooltip", [
    test("the tool's help is the view's tooltip while the pointer's where it applies, and gone when it moves off, leaves or the help goes") {
        let (_, canvas, tool) = try helpingCanvas()
        expectEqual(canvas.toolTip, nil)
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 150, y: 150), in: canvas))
        expectEqual(canvas.toolTip, "A card")
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 600, y: 400), in: canvas, time: 1.1))
        expectEqual(canvas.toolTip, nil)
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 150, y: 150), in: canvas, time: 1.2))
        expectEqual(canvas.toolTip, "A card")
        canvas.mouseExited(with: try require(NSEvent.enterExitEvent(with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 1.3,
                                                                    windowNumber: canvas.window?.windowNumber ?? 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil)))
        expectEqual(canvas.toolTip, nil, "the pointer left the canvas")
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 150, y: 150), in: canvas, time: 1.4))
        tool.words = nil
        canvas.editorCursorDidChange(canvas.editor)
        expectEqual(canvas.toolTip, nil, "the tool has none now")
    },
    test("a press takes the tooltip away until it ends") {
        let (_, canvas, _) = try helpingCanvas()
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 150, y: 150), in: canvas))
        expectEqual(canvas.toolTip, "A card")
        canvas.mouseDown(with: mouse(.leftMouseDown, at: CGPoint(x: 150, y: 150), in: canvas, time: 1.1))
        expectEqual(canvas.toolTip, nil)
        canvas.mouseUp(with: mouse(.leftMouseUp, at: CGPoint(x: 150, y: 150), in: canvas, time: 1.2))
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 151, y: 150), in: canvas, time: 1.3))
        expectEqual(canvas.toolTip, "A card")
    },
    test("under a view over the canvas there's no tooltip of the canvas's, and back on the canvas it's the tool's") {
        let (_, canvas, _) = try helpingCanvas()
        try cover(canvas)
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 150, y: 150), in: canvas))
        expectEqual(canvas.toolTip, "A card")
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 400, y: 30), in: canvas, time: 1.1))
        expectEqual(canvas.toolTip, nil)
        canvas.mouseMoved(with: mouse(.mouseMoved, at: CGPoint(x: 150, y: 150), in: canvas, time: 1.2))
        expectEqual(canvas.toolTip, "A card")
    },
])
