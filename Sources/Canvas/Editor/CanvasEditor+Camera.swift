import CoreGraphics
import Geometry

// The camera's slide after a flung hand drag (tldraw's slideCamera), on `scheduler`.
extension CanvasEditor {
    /// Slides the camera on, replacing any slide running. `direction` is the pointer velocity at
    /// the release, not normalized (as in tldraw). Each frame, every
    /// `Style.cameraSlideFrameMilliseconds` (16 ms), moves `direction` × speed × that many view
    /// points (so the same distance on screen at any zoom), then the speed drops by the friction. The frame whose speed would drop
    /// under `Style.cameraSlideStopSpeed` doesn't move, and the slide ends. The speed starts at
    /// min(speed, 1).
    func slideCamera(direction: CGPoint, speed: CGFloat) {
        stopCameraSlide()
        scheduleSlideFrame(direction: direction, speed: min(speed, 1))
    }

    /// Any camera change (a scroll, a pinch, a zoom command, a hand drag, a test setting it) stops
    /// a slide, through `camera`'s didSet, as does the next press.
    func stopCameraSlide() {
        cameraSlide?.cancel()
        cameraSlide = nil
    }

    private func scheduleSlideFrame(direction: CGPoint, speed: CGFloat) {
        cameraSlide = scheduler.schedule(after: Style.cameraSlideFrame) { [weak self] in
            guard let self else { return }
            let move = direction * (speed * Style.cameraSlideFrameMilliseconds)
            let next = speed * (1 - Style.cameraSlideFriction)
            guard next >= Style.cameraSlideStopSpeed else {
                cameraSlide = nil
                return
            }
            camera.pan(by: CGSize(width: move.x, height: move.y))     // stops the slide, as any camera change does…
            scheduleSlideFrame(direction: direction, speed: next)     // …so it carries on from here
        }
    }
}
