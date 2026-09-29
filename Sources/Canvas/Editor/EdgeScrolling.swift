import CoreGraphics
import Geometry

// Scrolling the canvas at its edges while a drag runs that asks for it (`Session.scrollsAtEdges`: a
// drag that moves shapes, a marquee, a connection being drawn), tldraw's EdgeScrollManager: once the
// pointer has gone past the drag threshold from the press, while it's within
// `Style.edgeScrollDistance` of an edge, or past it, for longer than `Style.edgeScrollDelay`, the
// camera pans that way a frame at a time on `scheduler`, faster the nearer the edge (full speed at it
// and past it), easing in over `Style.edgeScrollEaseDuration`, and slower on a side of the view
// under `Style.edgeScrollSmallView`, as tldraw's. The session hears a drag where the pointer is on
// each frame, as on any move of the camera (a scroll or pinch mid-drag too), without the pointer's
// velocity being sampled.
//
// Where it isn't tldraw's: every edge scrolls within 8 points of it and past it (tldraw scrolls at an
// edge that meets other UI, its insets, only past it; a Mac's pointer goes past any edge of a window,
// and the canvas's top and right edges meet the toolbar and the inspector); frames are a nominal 16
// ms, as the camera's slide's are, not the display's; and a connection being drawn from a port scrolls,
// where tldraw's handle drags don't, so a note off screen can be linked to without zooming out.
extension CanvasEditor {
    /// A drag event of the press under way reached the session: once past the drag threshold, and
    /// with the pointer at an edge, the canvas starts scrolling there.
    func dragDidReachSession(_ pointer: Pointer) {
        lastPointer = pointer
        if !pressDragged, let press = pressLocation, pointer.view.distance(to: press) > Style.dragThreshold { pressDragged = true }
        guard edgeScrollTick == nil, pressDragged, session?.scrollsAtEdges == true, edgeProximity != .zero else { return }
        scheduleEdgeScroll()
    }

    /// The press under way ended, or its session stopped scrolling at edges.
    func stopEdgeScrolling() {
        edgeScrollTick?.cancel()
        edgeScrollTick = nil
        edgeScrollTime = 0
    }

    /// How near an edge the pointer is, per axis, from 0 (further in than `edgeScrollDistance`) to 1
    /// at the edge and past it: positive at the left and top edges, negative at the right and bottom
    /// (tldraw's proximity factors, with no insets). Zero with no view.
    var edgeProximity: CGPoint {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return .zero }
        let location = tracker.location
        func factor(_ position: CGFloat, _ length: CGFloat) -> CGFloat {
            let distance = Style.edgeScrollDistance
            if position < distance { return min(1, (distance - position) / distance) }
            if position > length - distance { return -min(1, (position - (length - distance)) / distance) }
            return 0
        }
        return CGPoint(x: factor(location.x, viewportSize.width), y: factor(location.y, viewportSize.height))
    }

    private func scheduleEdgeScroll() {
        edgeScrollTick = scheduler.schedule(after: Style.cameraSlideFrame) { [weak self] in self?.scrollAtEdge() }
    }

    /// A frame at an edge (tldraw's updateEdgeScrolling): off every edge, it stops, and the delay
    /// starts over next time; else, past the delay, the camera pans toward the edge, eased in.
    private func scrollAtEdge() {
        edgeScrollTick = nil
        let proximity = edgeProximity
        guard session?.scrollsAtEdges == true, pressDragged, proximity != .zero else {
            edgeScrollTime = 0
            return
        }
        let frame = Style.cameraSlideFrameMilliseconds
        edgeScrollTime += frame
        if edgeScrollTime > Style.edgeScrollDelay {
            let eased = Self.easeInCubic(min(1, edgeScrollTime / (Style.edgeScrollDelay + Style.edgeScrollEaseDuration)))
            // tldraw's speed is view points per 60 Hz frame; a frame here is 16 ms.
            let speed = Style.edgeScrollSpeed * frame / (1000 / 60) * eased
            func scale(_ length: CGFloat) -> CGFloat { length < Style.edgeScrollSmallView ? Style.edgeScrollSmallViewFactor : 1 }
            camera.pan(by: CGSize(width: speed * proximity.x * scale(viewportSize.width),
                                  height: speed * proximity.y * scale(viewportSize.height)))     // the session follows it
        }
        scheduleEdgeScroll()
    }

    /// The camera moved: a session that scrolls at edges hears a drag where the pointer is, so what
    /// it drags stays under it (tldraw dispatches a pointer move on every camera change). The
    /// pointer's velocity isn't sampled: it hasn't moved.
    func sessionFollowsCamera() {
        guard !isFollowingCamera, let session, session.scrollsAtEdges, var pointer = lastPointer else { return }
        pointer.view = tracker.location
        pointer.world = camera.toWorld(tracker.location)
        pointer.modifiers = effectiveModifiers
        isFollowingCamera = true
        defer { isFollowingCamera = false }
        session.drag(pointer, in: self)
    }

    /// tldraw's EASINGS.easeInCubic.
    static func easeInCubic(_ t: CGFloat) -> CGFloat { t * t * t }
}
