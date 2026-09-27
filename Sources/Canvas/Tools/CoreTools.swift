import CoreGraphics
import Geometry

// The hand is in HandTool.swift, and moving shapes with the pointer in Translating.swift.

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
