import CoreGraphics
import Geometry

/// The core's hand tool (tldraw's): dragging pans, and a flung release lets the camera slide on.
/// It never selects or moves shapes, and a click does nothing. Escape returns to Select.
final class HandTool {}

extension HandTool: Tool {
    func cursor(in editor: CanvasEditor) -> CanvasCursor { .openHand }

    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {
        editor.session = HandSession(press: pointer.view)      // the press has already stopped any slide
    }
}

/// tldraw's hand Pointing, then Dragging. Past the drag threshold the camera follows the pointer
/// absolutely from the press, so the threshold's 4 points aren't lost. A scroll or pinch during
/// the drag is kept: the drag carries on from there.
@MainActor
final class HandSession {
    private var press: CGPoint          // view points
    private var start: Camera?          // when the drag passed the threshold, or was rebased
    private var applied: Camera?        // what this session last set
    init(press: CGPoint) { self.press = press }
}

extension HandSession: Session {
    func cursor(in editor: CanvasEditor) -> CanvasCursor? { .closedHand }

    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        if start == nil {
            guard pointer.view.distance(to: press) > Style.dragThreshold else { return }
            start = editor.camera
        } else if editor.camera != applied {
            // Something else moved the camera: follow the pointer from here instead.
            start = editor.camera
            press = pointer.view
        }
        guard var camera = start else { return }
        camera.pan(by: CGSize(width: pointer.view.x - press.x, height: pointer.view.y - press.y))
        editor.camera = camera
        applied = camera
    }

    /// tldraw's Dragging.complete: a flung release slides on. A click (no drag) does nothing.
    func end(_ pointer: Pointer, in editor: CanvasEditor) {
        guard start != nil else { return }
        let velocity = editor.pointerVelocity
        let speed = min(velocity.length, Style.cameraSlideMaxSpeed)
        if speed > Style.cameraSlideMinSpeed { editor.slideCamera(direction: velocity, speed: speed) }
    }

    /// Escape: stop where it is, with no slide (tldraw: back to the hand's idle). Escape again
    /// returns to Select.
    func cancel(in editor: CanvasEditor) -> Bool { true }
}
