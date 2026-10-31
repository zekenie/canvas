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
        animateCamera(to: target, duration: duration, easing: Self.easeInOutCubic)
    }

    /// `animateCamera(to:duration:)` along `easing` (0 to 1 over the time, 0 to 1 of the way).
    func animateCamera(to target: Camera, duration: Duration, easing: @escaping @MainActor (CGFloat) -> CGFloat) {
        stopCameraMotion()
        let total = Double(duration.components.seconds) * 1000 + Double(duration.components.attoseconds) / 1e15
        guard total > 0, camera != target else {
            camera = target
            return
        }
        scheduleAnimationFrame(from: camera, to: target, elapsed: 0, total: total, easing: easing)
    }

    /// Moves the camera as `animateCamera(to:duration:)` does, to fit `rect` (world units) into the part
    /// of the view the host leaves clear (`unobscuredViewport`) with `inset` view points of margin in
    /// all, no closer than `maxZoom`; and keeps that fit while the view around it settles: a change of
    /// the view's size in the next `Style.viewSettle` that leaves part of `rect` out (the inspector the
    /// selection shows sliding in beside the canvas, narrowing it) fits it again into what is clear then,
    /// unless something else has moved the camera since. What bringing shapes into view goes by (Selection's `reveal`). Replaces
    /// what was kept (`keepInViewWhileSettling`). Nothing before the view has a size, or for a null rect.
    public func animateCamera(toFit rect: CGRect, inset: CGFloat, maxZoom: CGFloat, duration: Duration) {
        let view = unobscuredViewport
        guard !view.isEmpty, !rect.isNull else { return }
        let target = Camera(fitting: rect, in: view, inset: inset, maxZoom: maxZoom)
        animateCamera(to: target, duration: duration)
        keptView = KeptView(rect: rect, keeping: .fit(inset: inset, maxZoom: maxZoom), camera: target,
                            until: scheduler.now + Style.viewSettle)
    }

    /// Keeps what of `rect` (world units) is in view now in view while the view around it settles: all of
    /// it, or the part the clear view shows (`unobscuredViewport`, where the camera is headed) of one cut
    /// by its edge. A change of the view's size in the next `Style.viewSettle` that leaves part of that out
    /// (the inspector the selection shows sliding in beside the canvas) pans the camera by as little as
    /// brings it back, `Style.keepInViewMargin` in from the edges (a part too big for that keeps its
    /// top-left corner in view), unless something else has moved the camera since or a press is under way.
    /// What a selection does as it changes (Selection's), so a shape selected by the canvas's edge isn't
    /// left under the inspector. Replaces what was kept (a fit, `animateCamera(toFit:…)`); a rect with
    /// nothing in view keeps nothing new.
    public func keepInViewWhileSettling(_ rect: CGRect) {
        let view = unobscuredViewport, camera = cameraTarget
        guard !view.isEmpty, !rect.isNull else { return }
        let shown = rect.intersection(camera.toWorld(view))
        guard !shown.isNull, shown.width > 0 || shown.height > 0 else { return }
        keptView = KeptView(rect: shown, keeping: .inView, camera: camera, until: scheduler.now + Style.viewSettle)
    }

    /// The view's size changed: a view kept (`animateCamera(toFit:…)`, `keepInViewWhileSettling`) whose
    /// time isn't up and whose camera nothing else has moved since (where the camera is headed is where
    /// it was left), and which the view now leaves part of out, is kept in what is clear of it: a fit
    /// fitted again, a rect brought back into view, easing there while the camera's move is under way,
    /// at once otherwise; services hear it (`viewWasKept`), the move being no one's.
    func keepViewAfterResize() {
        guard let kept = keptView else { return }
        guard scheduler.now < kept.until, cameraTarget == kept.camera else { return keptView = nil }
        // Only a view that leaves part of it out: one wider again (the inspector sliding back out) moves nothing.
        let view = unobscuredViewport
        guard !view.isEmpty, !kept.camera.toWorld(view).contains(kept.rect) else { return }
        let target: Camera
        switch kept.keeping {
        case .fit(let inset, let maxZoom):
            target = Camera(fitting: kept.rect, in: view, inset: inset, maxZoom: maxZoom)
        case .inView:
            guard session == nil else { return }
            let margin = view.insetBy(dx: Style.keepInViewMargin, dy: Style.keepInViewMargin)
            var moved = kept.camera
            moved.pan(by: Self.shift(bringing: kept.camera.toView(kept.rect), into: margin.isEmpty ? view : margin))
            target = moved
        }
        guard target != kept.camera else { return }
        keptView?.camera = target
        if cameraAnimationTarget != nil {
            animateCamera(to: target, duration: Style.keptViewDuration)
        } else {
            camera = target
        }
        tellViewKept(from: kept.camera, to: target)
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
        let delta = Self.shift(bringing: camera.toView(rect.offsetBy(dx: box.minX, dy: box.minY)), into: view)
        guard delta != .zero else { return }
        camera.pan(by: delta)
    }

    /// How far to move what's shown (view points) to bring `shown` inside `view`, by as little as it
    /// takes; one too big for it along a way keeps its top or left edge in view.
    static func shift(bringing shown: CGRect, into view: CGRect) -> CGSize {
        /// Along one axis: `low...high` inside `min...max`.
        func shift(_ low: CGFloat, _ high: CGFloat, into min: CGFloat, _ max: CGFloat) -> CGFloat {
            if low < min || high - low > max - min { return min - low }
            if high > max { return max - high }
            return 0
        }
        return CGSize(width: shift(shown.minX, shown.maxX, into: view.minX, view.maxX),
                      height: shift(shown.minY, shown.maxY, into: view.minY, view.maxY))
    }

    /// Any camera change (a scroll, a pinch, a zoom command, a hand drag, a test setting it) stops
    /// a slide or an animation, through `camera`'s didSet, as does the next press. An animation's own
    /// frame keeps its target: what `camera`'s didSet tells after this (a card following the camera)
    /// reads where the camera is headed, and the frame schedules the next at once.
    func stopCameraMotion() {
        cameraMotion?.cancel()
        cameraMotion = nil
        if !isAnimationFrame { cameraAnimationTarget = nil }
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
    private func scheduleAnimationFrame(from start: Camera, to target: Camera, elapsed: Double, total: Double,
                                        easing: @escaping @MainActor (CGFloat) -> CGFloat) {
        let step = min(Double(Style.cameraSlideFrameMilliseconds), total - elapsed)
        cameraMotion = scheduler.schedule(after: .milliseconds(step)) { [weak self] in
            guard let self else { return }
            let now = elapsed + step
            guard now < total else {
                camera = target
                return
            }
            let t = easing(CGFloat(now / total))
            isAnimationFrame = true
            camera = Camera(origin: CGPoint(x: start.origin.x + (target.origin.x - start.origin.x) * t,
                                            y: start.origin.y + (target.origin.y - start.origin.y) * t),
                            zoom: start.zoom + (target.zoom - start.zoom) * t)     // stops the animation…
            isAnimationFrame = false
            scheduleAnimationFrame(from: start, to: target, elapsed: now, total: total, easing: easing)     // …so it carries on
        }
        cameraAnimationTarget = target
        updateZoomPercentage()
    }

    /// tldraw's EASINGS.easeInOutCubic.
    static func easeInOutCubic(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : (t - 1) * (2 * t - 2) * (2 * t - 2) + 1
    }

    /// tldraw's EASINGS.easeOutCubic: fast from the start, so a motion begun again mid-way keeps going.
    static func easeOutCubic(_ t: CGFloat) -> CGFloat {
        let u = t - 1
        return u * u * u + 1
    }
}

/// What the camera keeps in view while the view around it settles (`CanvasEditor.animateCamera(toFit:…)`,
/// `keepInViewWhileSettling`): the world rect and how, where the camera was headed as it was last left
/// (anything else that moves the camera leaves `cameraTarget` elsewhere, and it goes), and when its time
/// is up, on the scheduler's clock.
struct KeptView {
    enum Keeping {
        /// Fitted again into what is clear of the view.
        case fit(inset: CGFloat, maxZoom: CGFloat)
        /// Brought back into view by as little as it takes, if the view leaves part of it out.
        case inView
    }

    let rect: CGRect
    let keeping: Keeping
    var camera: Camera
    let until: Duration
}

/// Which way a pan by the keys moves the view over the board (`CanvasEditor.pan`): `.right` shows
/// what is to the right.
public enum PanDirection: Hashable, Sendable, CaseIterable {
    case left, right, up, down
}

// Moving the view with the keys, as the Hand moves it with the pointer: the arrow keys with nothing
// selected (Selection's), Page Up and Page Down, Home and End (Keyboard's keys for the core's
// commands). Each eases the camera from where it's headed, so a held key's repeats glide on.
extension CanvasEditor {
    /// Whether the keys can move the view: it has a size.
    public var canPan: Bool { !unobscuredViewport.isEmpty }

    /// Moves the view a step that way (`Style.panStep` view points, the same on screen at any zoom),
    /// or with `far` a page (`Style.panPage` of the view's clear part along that way), eased out over
    /// `Style.panDuration` from where the camera is headed: pressed again, or held, before it lands,
    /// it goes on from there. Does nothing while the view has no size.
    public func pan(_ direction: PanDirection, far: Bool = false) {
        guard canPan else { return }
        let view = unobscuredViewport
        let distance: CGFloat
        switch direction {
        case .left, .right: distance = far ? view.width * Style.panPage : Style.panStep
        case .up, .down: distance = far ? view.height * Style.panPage : Style.panStep
        }
        // The board moves the other way: to see what's to the right, it goes left.
        let delta: CGSize = switch direction {
        case .left: CGSize(width: distance, height: 0)
        case .right: CGSize(width: -distance, height: 0)
        case .up: CGSize(width: 0, height: distance)
        case .down: CGSize(width: 0, height: -distance)
        }
        var target = cameraTarget
        target.pan(by: delta)
        animateCamera(to: target, duration: Style.panDuration, easing: Self.easeOutCubic)
    }

    /// Whether Home and End have somewhere to go: the board has shapes, and the view a size.
    var canScrollToEnds: Bool { canPan && !shapeBounds.isNull }

    /// Home: the start of the board's shapes in view at the zoom it has, their top left
    /// `Style.firstVisitInset` / 2 in from the view's clear part's, as a document's Home shows its
    /// beginning; along a way they fit, they are centered instead. Eased as the zooms are.
    func scrollToStart() { scroll(toEnd: false) }

    /// End: the end of the board's shapes in view, their bottom right in from the view's, as `scrollToStart`.
    func scrollToEnd() { scroll(toEnd: true) }

    private func scroll(toEnd: Bool) {
        guard canScrollToEnds else { return }
        let bounds = shapeBounds, view = unobscuredViewport, margin = Style.firstVisitInset / 2
        var target = cameraTarget
        let zoom = target.zoom
        /// The world coordinate at the view's origin along one way: the shapes' `low`...`high` centered in
        /// the view's `start`...`end` if they fit, else their start (or end) a margin in.
        func origin(_ low: CGFloat, _ high: CGFloat, in start: CGFloat, _ end: CGFloat) -> CGFloat {
            if (high - low) * zoom + 2 * margin <= end - start { return (low + high) / 2 - (start + end) / 2 / zoom }
            return toEnd ? high - (end - margin) / zoom : low - (start + margin) / zoom
        }
        target.origin = CGPoint(x: origin(bounds.minX, bounds.maxX, in: view.minX, view.maxX),
                                y: origin(bounds.minY, bounds.maxY, in: view.minY, view.maxY))
        animateCamera(to: target, duration: Style.zoomDuration)
    }
}

// The core's zoom commands (View › Zoom In, Zoom Out, Actual Size and Zoom to Fit; Keyboard gives
// them their keys, CorePoints.swift claims them): each eases the camera there over
// `Style.zoomDuration` (tldraw's animationMediumMs), from where it's headed, so pressing one again
// before it lands goes on from there. Zoom to Fit pressed again goes back to where it left.
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

    /// The margin a board's first visit fits its shapes with, view points in all (half on each side),
    /// as Zoom to Fit does: for a picture of a board that shows it as a first visit would
    /// (the core's `BoardPicture`).
    @_spi(Host) public static var firstVisitInset: CGFloat { Style.firstVisitInset }

    /// Every shape of the board shown in view: fitted into what the host leaves clear of the view
    /// (`unobscuredViewport`) with a board's first visit's margin, as close as the zoom goes
    /// (tldraw's zoomToFit). Does nothing on an empty board, or before the view has a size.
    ///
    /// Again, while the camera is still where the fit left it (at it, or headed for it, so pressing
    /// twice in a row goes back at once) and a fit now would be the same (the view and the board's
    /// shapes as they were), it goes back to the camera from before the fit (Terminal Graph's). Any other camera change forgets it: a pan, a zoom, a drag of the hand or a slide
    /// leaves the camera elsewhere, and showing another board clears it (`show`), so the next fit
    /// remembers the camera it leaves.
    func zoomToFit() {
        guard canZoomToFit else { return }
        let fit = Camera(fitting: shapeBounds, in: unobscuredViewport, inset: Style.firstVisitInset)
        // Back only while a fit now would be that fit: a resized view (the inspector shown) or shapes
        // added or taken away since make it a fit again.
        if let memory = cameraBeforeFit, cameraTarget == memory.fit, fit == memory.fit {
            cameraBeforeFit = nil
            animateCamera(to: memory.before, duration: Style.zoomDuration)
            return
        }
        // Nothing to go back to when the camera is already there.
        cameraBeforeFit = cameraTarget == fit ? nil : (cameraTarget, fit)
        animateCamera(to: fit, duration: Style.zoomDuration)
    }
}
