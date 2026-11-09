import CoreGraphics

/// How far in from each edge of the canvas's view the host's own chrome covers it, in view points
/// (`CanvasEditor.coveredEdges`): the window's title bar along the top, its sidebar along the left
/// and its inspector along the right, while they show over a canvas that fills the window.
public struct CoveredEdges: Equatable, Sendable {
    public var top: CGFloat
    public var left: CGFloat
    public var bottom: CGFloat
    public var right: CGFloat

    public init(top: CGFloat = 0, left: CGFloat = 0, bottom: CGFloat = 0, right: CGFloat = 0) {
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }

    /// The part of a view of `size` they leave clear, in its points: never less than nothing, however
    /// much they cover (a window too narrow for both panes).
    public func clear(in size: CGSize) -> CGRect {
        let left = min(max(self.left, 0), size.width), top = min(max(self.top, 0), size.height)
        return CGRect(x: left, y: top, width: max(size.width - left - max(right, 0), 0), height: max(size.height - top - max(bottom, 0), 0))
    }

    /// Whether the panes along the sides are the same ones (each covering some, or none), however wide: a
    /// pane resized rather than shown or hidden.
    public func hasSameSides(as other: CoveredEdges) -> Bool { (left > 0) == (other.left > 0) && (right > 0) == (other.right > 0) }
}

/// How much of each corner of the part the chrome leaves clear (`CoveredEdges.clear(in:)`) the host's own views over the canvas
/// cover, in view points, from the corner (`CanvasEditor.coveredCorners`): the minimap in the bottom-left, its margin
/// included. A corner covered is no edge covered: the rest of that side is clear, so a fit still fills the view, while what
/// keeps one shape in the clear view (a put, a reveal, the caret kept in view) keeps it out of the corner too.
public struct CoveredCorners: Equatable, Sendable {
    public var topLeft: CGSize
    public var topRight: CGSize
    public var bottomLeft: CGSize
    public var bottomRight: CGSize

    public init(topLeft: CGSize = .zero, topRight: CGSize = .zero, bottomLeft: CGSize = .zero, bottomRight: CGSize = .zero) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomLeft = bottomLeft
        self.bottomRight = bottomRight
    }

    /// The corners covered of `clear` (view points), each a rect in its corner, no larger than `clear`; none for a corner
    /// nothing covers.
    public func rects(in clear: CGRect) -> [CGRect] {
        guard !clear.isEmpty else { return [] }
        func sized(_ size: CGSize) -> CGSize? {
            guard size.width > 0, size.height > 0 else { return nil }
            return CGSize(width: min(size.width, clear.width), height: min(size.height, clear.height))
        }
        var rects: [CGRect] = []
        if let s = sized(topLeft) { rects.append(CGRect(x: clear.minX, y: clear.minY, width: s.width, height: s.height)) }
        if let s = sized(topRight) { rects.append(CGRect(x: clear.maxX - s.width, y: clear.minY, width: s.width, height: s.height)) }
        if let s = sized(bottomLeft) { rects.append(CGRect(x: clear.minX, y: clear.maxY - s.height, width: s.width, height: s.height)) }
        if let s = sized(bottomRight) { rects.append(CGRect(x: clear.maxX - s.width, y: clear.maxY - s.height, width: s.width, height: s.height)) }
        return rects
    }
}

/// The part of a view a shape is kept in: a rect, less the corners of it the host's views cover (`CoveredCorners`), in any
/// one space (view points, or world units). What a put beside a shape judges a side seen by (Draw's `PutBeside`), and what
/// the camera keeps a rect in by the least pan (`CanvasEditor.keepInView`, `animateCamera(toShow:…)`).
public struct ClearView: Equatable, Sendable {
    public var rect: CGRect
    /// The corners of `rect` covered, each within it.
    public var covered: [CGRect]

    public init(rect: CGRect, covered: [CGRect] = []) {
        self.rect = rect
        self.covered = covered
    }

    /// The same, `inset` in from the rect's edges and kept as far from each covered corner (the corners grow by it, inward).
    public func insetBy(_ inset: CGFloat) -> ClearView {
        let inner = rect.insetBy(dx: inset, dy: inset)
        guard !inner.isEmpty else { return self }
        return ClearView(rect: inner, covered: covered.map { $0.insetBy(dx: -inset, dy: -inset) })
    }

    /// Whether `shown` is wholly in it: in the rect, and clear of every covered corner.
    public func contains(_ shown: CGRect) -> Bool {
        rect.contains(shown) && !covered.contains { $0.intersects(shown) }
    }

    /// How far `shown` moves (the camera's pan, in this space) to come wholly into it by as little as it takes: into the rect, as
    /// a rect too big for it keeps its top-left corner in; then, where that leaves it over a covered corner, out of the corner
    /// the shorter way that keeps it in the rect (up past a bottom corner's top or down past a top corner's bottom, across past
    /// its inner side), none where neither does.
    public func shift(bringing shown: CGRect) -> CGSize {
        func along(_ low: CGFloat, _ high: CGFloat, _ min: CGFloat, _ max: CGFloat) -> CGFloat {
            if low < min || high - low > max - min { return min - low }
            if high > max { return max - high }
            return 0
        }
        var delta = CGSize(width: along(shown.minX, shown.maxX, rect.minX, rect.maxX), height: along(shown.minY, shown.maxY, rect.minY, rect.maxY))
        for corner in covered {
            let moved = shown.offsetBy(dx: delta.width, dy: delta.height)
            guard corner.intersects(moved) else { continue }
            var ways: [CGSize] = []
            // Vertically: past the corner's inner edge, top or bottom as the corner is.
            let up = corner.maxY >= rect.maxY - 0.5 ? corner.minY - moved.maxY : corner.maxY - moved.minY
            if moved.minY + up >= rect.minY - 0.5, moved.maxY + up <= rect.maxY + 0.5 { ways.append(CGSize(width: 0, height: up)) }
            let across = corner.minX <= rect.minX + 0.5 ? corner.maxX - moved.minX : corner.minX - moved.maxX
            if moved.minX + across >= rect.minX - 0.5, moved.maxX + across <= rect.maxX + 0.5 { ways.append(CGSize(width: across, height: 0)) }
            guard let way = ways.min(by: { abs($0.width) + abs($0.height) < abs($1.width) + abs($1.height) }) else { continue }
            delta.width += way.width
            delta.height += way.height
        }
        return delta
    }
}
