import CoreGraphics

/// Maps between world space, where shapes live, and view space, the canvas view's points.
public struct Camera: Equatable, Sendable {
    public static let zoomRange: ClosedRange<CGFloat> = 0.1...8

    /// The world point shown at the view's top-left corner.
    public var origin: CGPoint = .zero
    public var zoom: CGFloat = 1

    public init(origin: CGPoint = .zero, zoom: CGFloat = 1) {
        self.origin = origin
        self.zoom = zoom
    }

    /// Shows `bounds` (world units) centered in a view of `viewSize` points, zoomed to fit with
    /// `inset` view points of margin in all (half on each side), within `zoomRange` and never past
    /// `maxZoom` (tldraw's zoomToBounds, whose `targetZoom` is `maxZoom`). A side of zero size
    /// doesn't limit the zoom.
    public init(fitting bounds: CGRect, in viewSize: CGSize, inset: CGFloat, maxZoom: CGFloat = Camera.zoomRange.upperBound) {
        let width = max(viewSize.width - inset, 1), height = max(viewSize.height - inset, 1)
        let fit = min(bounds.width > 0 ? width / bounds.width : .infinity, bounds.height > 0 ? height / bounds.height : .infinity)
        zoom = min(maxZoom, min(max(fit, Self.zoomRange.lowerBound), Self.zoomRange.upperBound))
        origin = CGPoint(x: bounds.midX - viewSize.width / 2 / zoom, y: bounds.midY - viewSize.height / 2 / zoom)
    }

    public func toView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) * zoom, y: (point.y - origin.y) * zoom)
    }

    public func toWorld(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / zoom + origin.x, y: point.y / zoom + origin.y)
    }

    public func toView(_ rect: CGRect) -> CGRect {
        CGRect(origin: toView(rect.origin), size: CGSize(width: rect.width * zoom, height: rect.height * zoom))
    }

    public func toWorld(_ rect: CGRect) -> CGRect {
        CGRect(origin: toWorld(rect.origin), size: CGSize(width: rect.width / zoom, height: rect.height / zoom))
    }

    /// Moves the content by a distance measured in view points.
    public mutating func pan(by delta: CGSize) {
        origin.x -= delta.width / zoom
        origin.y -= delta.height / zoom
    }

    /// Changes the zoom while keeping the world point under `anchor` (in view space) fixed on screen.
    public mutating func setZoom(_ newZoom: CGFloat, around anchor: CGPoint) {
        let fixed = toWorld(anchor)
        zoom = min(max(newZoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        origin = CGPoint(x: fixed.x - anchor.x / zoom, y: fixed.y - anchor.y / zoom)
    }

    public mutating func zoom(by factor: CGFloat, around anchor: CGPoint) {
        setZoom(zoom * factor, around: anchor)
    }
}

