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

    /// Pans the camera at once, by as little as it takes, so `rect` (world units from the shape's
    /// editing frame's origin: an editing view's coordinates) is in the part of the view the host leaves
    /// clear, `Style.keepInViewMargin` in from its edges; a rect too big to fit keeps its top-left
    /// corner in view. See `EditContext.keepInView`.
    func keepInView(_ rect: CGRect, of id: ShapeID) {
        guard session == nil, let box = editingFrame(of: id) else { return }
        let view = unobscuredViewport.insetBy(dx: Style.keepInViewMargin, dy: Style.keepInViewMargin)
        guard view.width > 0, view.height > 0 else { return }
        let shown = camera.toView(rect.offsetBy(dx: box.minX, dy: box.minY))
        /// How far to move what's shown along one axis to bring `low...high` inside `min...max`.
        func shift(_ low: CGFloat, _ high: CGFloat, into min: CGFloat, _ max: CGFloat) -> CGFloat {
            if low < min || high - low > max - min { return min - low }
            if high > max { return max - high }
            return 0
        }
        let delta = CGSize(width: shift(shown.minX, shown.maxX, into: view.minX, view.maxX),
                           height: shift(shown.minY, shown.maxY, into: view.minY, view.maxY))
        guard delta != .zero else { return }
        camera.pan(by: delta)
    }

    /// Any camera change (a scroll, a pinch, a zoom command, a hand drag, a test setting it) stops
    /// a slide or an animation, through `camera`'s didSet, as does the next press.
    func stopCameraMotion() {
        cameraMotion?.cancel()
        cameraMotion = nil
        cameraAnimationTarget = nil
        updateZoomPercentage()
    }

    /// `zoomPercentage` from where the camera is headed, set only if it changed. Not while an
    /// animation's frame moves the camera: it stays the animation's target's.
    private func updateZoomPercentage() {
        guard !isAnimationFrame else { return }
        let percentage = cameraTarget.zoomPercentage
        if percentage != zoomPercentage { zoomPercentage = percentage }
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
            isAnimationFrame = true
            camera = Camera(origin: CGPoint(x: start.origin.x + (target.origin.x - start.origin.x) * t,
                                            y: start.origin.y + (target.origin.y - start.origin.y) * t),
                            zoom: start.zoom + (target.zoom - start.zoom) * t)     // stops the animation…
            isAnimationFrame = false
            scheduleAnimationFrame(from: start, to: target, elapsed: now, total: total)     // …so it carries on
        }
        cameraAnimationTarget = target
        updateZoomPercentage()
    }

    /// tldraw's EASINGS.easeInOutCubic.
    static func easeInOutCubic(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : (t - 1) * (2 * t - 2) * (2 * t - 2) + 1
    }
}

// The core's zoom commands (View › Zoom In, Zoom Out, Actual Size and Zoom to Fit; Keyboard gives
// them their keys, CorePoints.swift claims them): each eases the camera there over
// `Style.zoomDuration` (tldraw's animationMediumMs), from where it's headed, so pressing one again
// before it lands goes on from there.
extension CanvasEditor {
    /// The stop Zoom In goes to: the first of `Camera.zoomStops` past `zoomPercentage`; nil at the
    /// last, where it's dimmed.
    var zoomInStop: Int? { Camera.zoomStops.first { $0 > zoomPercentage } }

    /// The stop Zoom Out goes to: the last of `Camera.zoomStops` short of `zoomPercentage`; nil at
    /// the first.
    var zoomOutStop: Int? { Camera.zoomStops.last { $0 < zoomPercentage } }

    /// Whether Zoom to Fit has something to fit: the board shown has shapes, and the view a size.
    var canZoomToFit: Bool { !unobscuredViewport.isEmpty && !shapeBounds.isNull }

    /// Zooms to `percent` around the view's center.
    func zoom(toPercent percent: Int) {
        var target = cameraTarget
        target.setZoom(CGFloat(percent) / 100, around: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2))
        animateCamera(to: target, duration: Style.zoomDuration)
    }

    /// Every shape of the board shown in view: fitted into what the host leaves clear of the view
    /// (`unobscuredViewport`) with a board's first visit's margin, as close as the zoom goes
    /// (tldraw's zoomToFit). Does nothing on an empty board, or before the view has a size.
    func zoomToFit() {
        guard canZoomToFit else { return }
        animateCamera(to: Camera(fitting: shapeBounds, in: unobscuredViewport, inset: Style.firstVisitInset), duration: Style.zoomDuration)
    }
}
