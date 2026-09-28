import AppKit
import Canvas

/// Snapping's constants and its guides' look. Sizes are view points. The values follow tldraw.
@MainActor
enum SnappingStyle {
    /// How near an edge, a middle or a spacing snaps (tldraw's snapThreshold).
    static let threshold: CGFloat = 8
    /// Held mid-drag, what moves follows the pointer exactly: ⌘, as in Keynote, and ⌃, as an
    /// arrow's end binds to nothing with either.
    static let freeMoveModifiers: Modifiers = [.command, .control]
    /// tldraw's snap color, hsl(0, 76%, 60%), in light and dark alike.
    static let color = NSColor(srgbRed: 0.904, green: 0.296, blue: 0.296, alpha: 1)
    static let lineWidth: CGFloat = 1
    /// How far an alignment's ✕ reaches from its point, along each axis.
    static let cross: CGFloat = 2.5
    /// How far a spacing's middle tick reaches from its line; those at its edges reach twice as far.
    static let tick: CGFloat = 3.5

    /// Every guide in one stroke, in world units (tldraw's snap indicators): an alignment is a line
    /// through its points, a ✕ at each; a spacing, the spaces side by side at the middle of the
    /// stretch across its axis that all their edges share, each with a tick at its edges and one at
    /// its middle.
    static func draw(_ guides: [SnapGuide], in context: OverlayContext) {
        guard !guides.isEmpty else { return }
        let cg = context.cg, zoom = context.zoom
        let cross = self.cross / zoom, tick = self.tick / zoom
        func line(_ a: CGPoint, _ b: CGPoint) {
            cg.move(to: a)
            cg.addLine(to: b)
        }
        for guide in guides {
            switch guide {
            case .alignment(let axis, let position, let points):
                let across = points.map { $0[axis.across] }
                guard let low = across.min(), let high = across.max() else { continue }
                line(CGPoint(position, low, on: axis), CGPoint(position, high, on: axis))
                for point in points {
                    line(CGPoint(x: point.x - cross, y: point.y - cross), CGPoint(x: point.x + cross, y: point.y + cross))
                    line(CGPoint(x: point.x - cross, y: point.y + cross), CGPoint(x: point.x + cross, y: point.y - cross))
                }
            case .spacing(let axis, let gaps):
                guard let first = gaps.first else { continue }
                var shared = first.startSpan
                for gap in gaps {
                    guard let start = shared.intersection(gap.startSpan) else { continue }
                    shared = start
                    guard let end = shared.intersection(gap.endSpan) else { continue }
                    shared = end
                }
                let middle = (shared.lowerBound + shared.upperBound) / 2
                for gap in gaps {
                    line(CGPoint(gap.start, middle - tick * 2, on: axis), CGPoint(gap.start, middle + tick * 2, on: axis))
                    line(CGPoint(gap.end, middle - tick * 2, on: axis), CGPoint(gap.end, middle + tick * 2, on: axis))
                    line(CGPoint(gap.start, middle, on: axis), CGPoint(gap.end, middle, on: axis))
                    let center = (gap.start + gap.end) / 2
                    line(CGPoint(center, middle - tick, on: axis), CGPoint(center, middle + tick, on: axis))
                }
            }
        }
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(lineWidth / zoom)
        cg.strokePath()
    }
}
