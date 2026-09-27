import Canvas
import CoreGraphics
import Keyboard

extension ToolID {
    public static let eraser: ToolID = "eraser"
}

/// A tool with no shape of its own: press, and drag across shapes to delete them. Deleting goes
/// through a transaction like any change, so other plugins react on their own: an arrow bound to
/// an erased shape lets go of it, though the eraser has never heard of arrows.
public struct EraserPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { "eraser" }

    public func register(into registrar: inout PluginRegistrar) {
        registrar.tool(ToolDescriptor(id: .eraser, label: "Eraser", systemImage: "eraser"), shortcut: "e") { _ in EraserTool() }
    }
}

/// The tool only starts things: what happens between press and release is the session's.
/// (Conforming in an extension lets the compiler catch a near miss on a defaulted requirement.)
final class EraserTool {}

extension EraserTool: Tool {
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {
        let session = ErasingSession()
        editor.session = session
        session.drag(pointer, in: editor)
    }
}

/// Until release, whatever the pointer passes over is erased: the whole path since the last
/// event, not just the points events land on, so a quick stroke doesn't skip a thin shape.
@MainActor
final class ErasingSession {
    private var last: CGPoint?
}

extension ErasingSession: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        let from = last ?? pointer.world, to = pointer.world
        last = to
        // Every 2 view points: finer than anything's hit area.
        let step = 2 / editor.shapeContext.zoom
        let count = max(1, Int((hypot(to.x - from.x, to.y - from.y) / step).rounded(.up)))
        var hits: Set<ShapeID> = []
        for i in 0...count {
            let t = CGFloat(i) / CGFloat(count)
            if let id = editor.shape(at: CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)) {
                hits.insert(id)
            }
        }
        guard !hits.isEmpty else { return }
        editor.transact { $0.delete(hits) }
    }
}
