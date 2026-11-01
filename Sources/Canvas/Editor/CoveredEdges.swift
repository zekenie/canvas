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
