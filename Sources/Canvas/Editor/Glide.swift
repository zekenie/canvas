import CoreGraphics
import Geometry

// The glide: shapes that just moved (a drop nudged in or out of a container, a refused drop sent
// back) ease to where they are from where they were drawn, with a slight overshoot, through their
// drawing offsets (`setDrawingOffset`), on `scheduler`: the board already holds where they are, so
// hit testing, handles and pictures of the board go by that, as with a shake. A new press, a session
// starting, a commit that touches a gliding shape, or another board shown ends its glide where it is
// (offset zero).
extension CanvasEditor {
    /// Glides shapes that just moved by these deltas (world units, what `Transaction.settle` hands
    /// back), each from where it was drawn before it moved to where it is, together: over
    /// `Style.glideDuration`, eased out with a slight overshoot. A shape gliding already goes on
    /// from where it's drawn. Shapes that aren't on the board shown, or didn't move, don't glide.
    public func glide(_ moves: [ShapeID: CGPoint]) {
        let zoom = camera.zoom
        var started = false
        for (id, delta) in moves where delta != .zero && document[id] != nil {
            // From where it's drawn now, in world units, less how far it moved.
            let drawn = drawingOffsets[id].map { CGPoint(x: $0.x / zoom, y: $0.y / zoom) } ?? .zero
            let from = CGPoint(x: drawn.x - delta.x, y: drawn.y - delta.y)
            guard from != .zero else { continue }
            glides[id] = Glide(from: from, frames: 0)
            drawingOffsets[id] = CGPoint(x: from.x * zoom, y: from.y * zoom)
            started = true
        }
        guard started else { return }
        setNeedsDisplay()
        if glideFrame == nil { scheduleGlideFrame() }
    }

    /// Whether a shape is gliding now.
    public func isGliding(_ id: ShapeID) -> Bool { glides[id] != nil }

    /// Ends these shapes' glides where they are: drawn where they are.
    func endGlides(_ ids: some Sequence<ShapeID>) {
        guard !glides.isEmpty else { return }
        var ended = false
        for id in ids where glides.removeValue(forKey: id) != nil {
            drawingOffsets[id] = nil
            ended = true
        }
        if glides.isEmpty {
            glideFrame?.cancel()
            glideFrame = nil
        }
        if ended { setNeedsDisplay() }
    }

    /// Ends every glide where it is.
    func endGlides() {
        guard !glides.isEmpty else { return }
        endGlides(Array(glides.keys))
    }

    private func scheduleGlideFrame() {
        glideFrame = scheduler.schedule(after: Style.glideFrame) { [weak self] in self?.playGlideFrame() }
    }

    /// One frame of every glide: each a frame further along, drawn where its ease puts it (at the
    /// zoom now), and once it's played out, where it is.
    private func playGlideFrame() {
        glideFrame = nil
        let zoom = camera.zoom, total = Style.glideDuration
        for (id, glide) in glides {
            let frames = glide.frames + 1
            let t = CGFloat((Style.glideFrame * frames) / total)
            guard t < 1 else {
                glides[id] = nil
                drawingOffsets[id] = nil
                continue
            }
            glides[id]?.frames = frames
            let left = 1 - Self.easeOutBack(t)
            drawingOffsets[id] = CGPoint(x: glide.from.x * left * zoom, y: glide.from.y * left * zoom)
        }
        setNeedsDisplay()
        if !glides.isEmpty { scheduleGlideFrame() }
    }

    /// An ease out that goes a little past 1 and comes back (`Style.glideOvershoot`).
    static func easeOutBack(_ t: CGFloat) -> CGFloat {
        let c = Style.glideOvershoot, u = t - 1
        return 1 + (c + 1) * u * u * u + c * u * u
    }
}

/// A shape's glide: where it set out from, in world units from where it is, and how many frames of it
/// have played.
struct Glide {
    let from: CGPoint
    var frames: Int
}
