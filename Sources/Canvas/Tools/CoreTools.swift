import CoreGraphics
import Geometry

/// The core's select tool. Handles win over shapes; a pressed shape comes to the front (unless
/// it's painted by anchor) and moves with the pointer, or runs its own translation session.
final class SelectTool {}

extension SelectTool: Tool {
    func cursor(in editor: CanvasEditor) -> CanvasCursor { editor.hoveredHandle != nil ? .openHand : .standard }

    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {
        if let handle = editor.handle(atViewPoint: pointer.view) {
            editor.pressHandle(handle, with: pointer)
            return
        }
        defer { editor.hovered = nil }
        guard let id = editor.shape(at: pointer.world), let record = editor.document[id],
              let definition = editor.registry.definition(for: record.kind) else {
            editor.selection = nil
            if pointer.clickCount == 2, let placement = editor.registry.doubleClickPlacement {
                editor.place(placement, at: pointer.world)
            } else {
                editor.session = PanSession(last: pointer.view)
            }
            return
        }
        if !(definition is any PaintOrderAnchored) {
            editor.transact { $0.bringToFront(id) }
        }
        editor.selection = id
        if pointer.clickCount == 2, definition is any Editable {
            editor.beginEditing(id)
        } else if let custom = definition as? any CustomTranslation {
            editor.session = custom.erasedTranslationSession(for: record, at: pointer, in: editor)
        } else if let box = record.box {
            editor.session = MoveShapeSession(id: id, grabOffset: pointer.world - box.origin)
        }
    }

    func pointerMoved(_ pointer: Pointer, in editor: CanvasEditor) {
        if let handle = editor.handle(atViewPoint: pointer.view) {
            editor.hoveredHandle = handle
            editor.hovered = nil
        } else {
            editor.hoveredHandle = nil
            editor.hovered = editor.shape(at: pointer.world)
        }
    }
}

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

@MainActor
final class PanSession {
    private var last: CGPoint
    init(last: CGPoint) { self.last = last }
}

extension PanSession: Session {    func cursor(in editor: CanvasEditor) -> CanvasCursor? { .closedHand }
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        let delta = CGSize(width: pointer.view.x - last.x, height: pointer.view.y - last.y)
        last = pointer.view
        editor.camera.pan(by: delta)
    }
}

/// Follows the pointer by the shape's box, with no drag threshold.
@MainActor
final class MoveShapeSession {
    let id: ShapeID
    let grabOffset: CGPoint
    init(id: ShapeID, grabOffset: CGPoint) {
        self.id = id
        self.grabOffset = grabOffset
    }
}

extension MoveShapeSession: Session {    var hidesSelectionIndicator: Bool { true }
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        editor.transact { tx in tx.update(id) { $0.box?.origin = pointer.world - grabOffset } }
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
