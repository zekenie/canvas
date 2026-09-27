import CoreGraphics
import Geometry

// The select tool is in SelectTool.swift, the hand in HandTool.swift, and moving the selection in
// Translating.swift.

/// Places a shape where the canvas is pressed. Registered by `ShapeRegistrar.tool(...)`.
@MainActor
final class PlaceShapeTool {
    let placement: Placement
    init(_ placement: Placement) { self.placement = placement }
}

extension PlaceShapeTool: Tool {
    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {
        editor.place(placement, at: pointer.world)
    }
}

/// A handle was pressed; past the drag threshold, the definition's drag session takes over.
@MainActor
final class PointingHandleSession {
    let shapeID: ShapeID
    let handle: AnyHashable
    let origin: CGPoint
    init(shapeID: ShapeID, handle: AnyHashable, origin: CGPoint) {
        self.shapeID = shapeID
        self.handle = handle
        self.origin = origin
    }
}

extension PointingHandleSession: Session {    func cursor(in editor: CanvasEditor) -> CanvasCursor? { .closedHand }
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        guard pointer.view.distance(to: origin) > Style.dragThreshold,
              let record = editor.document[shapeID],
              let definition = editor.registry.definition(for: record.kind) as? any HandleProviding,
              let next = definition.erasedDragSession(for: handle, of: record, from: editor.camera.toWorld(origin), in: editor)
        else { return }
        editor.hoveredHandle = nil
        editor.session = next
        next.drag(pointer, in: editor)
    }
    /// Released without a drag: drop any hint the press showed.
    func end(_ pointer: Pointer, in editor: CanvasEditor) {
        editor.hintedShapeID = nil
    }
}
