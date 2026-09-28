@_spi(Host) import Canvas
import CanvasTesting
import CoreGraphics
import Geometry
import Snapping

/// What the move tool drags: the shapes a test names, or else the shape pressed.
@MainActor
final class Moves {
    var ids: [ShapeID] = []
}

/// The select tool's lone box, without Selection (which SnappingTests can't use): a press on a shape
/// starts a `TranslatingSession` of what `moves` names, or of that shape, from the press, with no
/// drag threshold.
final class MoveTool {
    let moves: Moves
    init(moves: Moves) { self.moves = moves }
}

extension MoveTool: Tool {
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {
        guard let id = editor.shape(at: pointer.world) else { return }
        editor.session = TranslatingSession(ids: moves.ids.isEmpty ? [id] : moves.ids, from: pointer.world, in: editor)
    }
}

/// The move tool, as the default tool.
@MainActor func movePlugin(_ moves: Moves) -> Contributor {
    Contributor(id: "moving") { r in
        r.tool(ToolDescriptor(id: "move", label: "Move", systemImage: "arrow.up.and.down.and.arrow.left.and.right")) { _ in MoveTool(moves: moves) }
        r.defaultTool("move")
    }
}

/// An editor of the fixtures' boxes with Snapping and the move tool, its view 1000 × 800 points at
/// 100%, so the world from (0, 0) to (1000, 800) is in view.
@MainActor func snapHarness(moves: Moves = Moves(), _ more: [any CanvasPlugin] = [], shapes: [any CanvasPlugin] = [FixturesPlugin()]) throws -> EditorHarness {
    let h = try EditorHarness(plugins: shapes + [SnappingPlugin(), movePlugin(moves)] + more)
    h.editor.viewportDidResize(to: CGSize(width: 1000, height: 800))
    return h
}

extension EditorHarness {
    func origin(of id: ShapeID) -> CGPoint? { editor.document[id]?.box?.origin }
}

/// How many times the editor asked to be redrawn (`editorNeedsDisplay`), as a host would hear it.
@MainActor
final class Redraws {
    var count = 0
}

extension Redraws: CanvasEditorDelegate {
    func editorNeedsDisplay(_ editor: CanvasEditor) { count += 1 }
    func editorCursorDidChange(_ editor: CanvasEditor) {}
    func editorEditingDidChange(_ editor: CanvasEditor) {}
}
