import CoreGraphics
import Geometry

// The camera's motions, on `scheduler`: the slide after a flung hand drag (tldraw's slideCamera),
// and animated moves (tldraw's animateToViewport). One runs at a time.
extension CanvasEditor {
    /// Slides the camera on, replacing any motion running. `direction` is the pointer velocity at
    /// the release, not normalized (as in tldraw). Each frame, every
    /// `Style.cameraSlideFrameMilliseconds` (16 ms), moves `direction` × speed × that many view
    /// points (so the same distance on screen at any zoom), then the speed drops by the friction. The frame whose speed would drop
    /// under `Style.cameraSlideStopSpeed` doesn't move, and the slide ends. The speed starts at
    /// min(speed, 1).
    func slideCamera(direction: CGPoint, speed: CGFloat) {
        stopCameraMotion()
        scheduleSlideFrame(direction: direction, speed: min(speed, 1))
    }

    /// Moves the camera to `target` over `duration`, easing in and out (tldraw's default, a cubic),
    /// a frame every 16 ms, replacing any motion running. Its origin and zoom each follow the
    /// easing, and the last frame, at `duration`, lands exactly on `target`. Any other camera
    /// change (a scroll, a pinch, a hand drag, a press) stops it where it is, as it stops a slide.
    public func animateCamera(to target: Camera, duration: Duration) {
        stopCameraMotion()
        let total = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        guard total > 0, camera != target else {
            camera = target
            return
        }
        scheduleAnimationFrame(from: camera, to: target, elapsed: 0, total: total)
    }

    /// Where the camera comes to rest: while an animation runs (`animateCamera`), its target;
    /// otherwise the camera itself (a slide after a fling has no fixed end). What to remember a view
    /// as, if it's remembered mid-motion.
    public var cameraTarget: Camera { cameraAnimationTarget ?? camera }

    /// Any camera change (a scroll, a pinch, a zoom command, a hand drag, a test setting it) stops
    /// a slide or an animation, through `camera`'s didSet, as does the next press.
    func stopCameraMotion() {
        cameraMotion?.cancel()
        cameraMotion = nil
        cameraAnimationTarget = nil
    }

    private func scheduleSlideFrame(direction: CGPoint, speed: CGFloat) {
        cameraMotion = scheduler.schedule(after: Style.cameraSlideFrame) { [weak self] in
            guard let self else { return }
            let move = direction * (speed * Style.cameraSlideFrameMilliseconds)
            let next = speed * (1 - Style.cameraSlideFriction)
            guard next >= Style.cameraSlideStopSpeed else {
                cameraMotion = nil
                return
            }
            camera.pan(by: CGSize(width: move.x, height: move.y))     // stops the slide, as any camera change does…
            scheduleSlideFrame(direction: direction, speed: next)     // …so it carries on from here
        }
    }

    /// Milliseconds.
    private func scheduleAnimationFrame(from start: Camera, to target: Camera, elapsed: Double, total: Double) {
        let step = min(Double(Style.cameraSlideFrameMilliseconds), total - elapsed)
        cameraMotion = scheduler.schedule(after: .milliseconds(step)) { [weak self] in
            guard let self else { return }
            let now = elapsed + step
            guard now < total else {
                camera = target
                return
            }
            let t = Self.easeInOutCubic(CGFloat(now / total))
            camera = Camera(origin: CGPoint(x: start.origin.x + (target.origin.x - start.origin.x) * t,
                                            y: start.origin.y + (target.origin.y - start.origin.y) * t),
                            zoom: start.zoom + (target.zoom - start.zoom) * t)     // stops the animation…
            scheduleAnimationFrame(from: start, to: target, elapsed: now, total: total)     // …so it carries on
        }
        cameraAnimationTarget = target
    }

    /// tldraw's EASINGS.easeInOutCubic.
    static func easeInOutCubic(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : (t - 1) * (2 * t - 2) * (2 * t - 2) + 1
    }
}
