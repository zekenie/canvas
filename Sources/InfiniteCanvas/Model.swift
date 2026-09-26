import Foundation

typealias ShapeID = UUID

/// Anything on the canvas other than an arrow. What else a shape can do comes from further
/// protocols, like `Connectable`.
protocol CanvasShape {
    var id: ShapeID { get }
    /// Position and size in world coordinates.
    var frame: CGRect { get set }
    /// Whether a world point hits the shape, for selecting and dragging it.
    func contains(_ point: CGPoint) -> Bool
}

/// A shape arrows can bind to.
///
/// This is everything arrows know about the shapes they connect: an arrow end picks the
/// front-most connectable shape under it, stores its anchor relative to the shape's `bounds`, and
/// stops where it crosses the shape's `outline`.
protocol Connectable {
    var id: ShapeID { get }
    /// The shape's edge as a closed polygon in world coordinates. Curved edges can be approximated
    /// with enough points.
    var outline: [CGPoint] { get }
    /// The rectangle arrow anchors are measured within, so they follow the shape as it moves and
    /// resizes. Defaults to the outline's bounding box.
    var bounds: CGRect { get }
    /// Whether a world point is on the shape, for picking what an arrow end binds to. Defaults to
    /// being inside the outline.
    func contains(_ point: CGPoint) -> Bool
}

extension Connectable {
    var bounds: CGRect { CGRect(enclosing: outline) }

    func contains(_ point: CGPoint) -> Bool {
        polygonContains(outline, point)
    }
}

struct StickyNote: Identifiable {
    let id = ShapeID()
    /// Position and size in world coordinates.
    var frame: CGRect
    var text = ""
}

extension StickyNote: CanvasShape, Connectable {
    var outline: [CGPoint] { frame.polygon }
    var bounds: CGRect { frame }

    func contains(_ point: CGPoint) -> Bool {
        frame.contains(point)
    }
}

struct Ellipse: Identifiable {
    let id = ShapeID()
    /// Position and size in world coordinates.
    var frame: CGRect
}

extension Ellipse: CanvasShape, Connectable {
    /// Enough points that arrows stop visibly on the curve even zoomed all the way in.
    var outline: [CGPoint] {
        let count = 128
        return (0..<count).map { i in
            let angle = CGFloat(i) / CGFloat(count) * 2 * .pi
            return CGPoint(x: frame.midX + cos(angle) * frame.width / 2, y: frame.midY + sin(angle) * frame.height / 2)
        }
    }

    var bounds: CGRect { frame }

    func contains(_ point: CGPoint) -> Bool {
        guard frame.width > 0, frame.height > 0 else { return false }
        let x = (point.x - frame.midX) / (frame.width / 2)
        let y = (point.y - frame.midY) / (frame.height / 2)
        return x * x + y * y <= 1
    }
}

struct Arrow: Identifiable {
    let id = UUID()
    var start: ArrowTerminal
    var end: ArrowTerminal
    /// How far the arrow's midpoint is pushed off the straight line between its terminals, in
    /// world units along the line's perpendicular. Zero is a straight arrow.
    var bend: CGFloat = 0
    var startArrowhead = false
    var endArrowhead = true

    subscript(end: ArrowEnd) -> ArrowTerminal {
        get { end == .start ? start : self.end }
        set {
            if end == .start { start = newValue } else { self.end = newValue }
        }
    }

    func hasArrowhead(at end: ArrowEnd) -> Bool {
        end == .start ? startArrowhead : endArrowhead
    }

    mutating func toggleArrowhead(at end: ArrowEnd) {
        if end == .start { startArrowhead.toggle() } else { endArrowhead.toggle() }
    }
}

enum ArrowEnd {
    case start, end

    var opposite: ArrowEnd { self == .start ? .end : .start }
}

enum ArrowTerminal {
    case free(CGPoint)
    case bound(ArrowBinding)

    var binding: ArrowBinding? {
        if case .bound(let binding) = self { binding } else { nil }
    }
}

struct ArrowBinding {
    /// A `Connectable` shape.
    var shapeID: ShapeID
    /// Where the arrow aims within the shape's bounds: (0, 0) is the top-left corner, (1, 1) the
    /// bottom-right.
    var normalizedAnchor: CGPoint
    /// Imprecise bindings ignore the anchor and aim at the center of the shape's bounds.
    var isPrecise: Bool
    /// Exact bindings run all the way to the anchor instead of stopping at the shape's outline.
    var isExact: Bool
}

/// Maps between world space, where shapes live, and view space, the canvas view's points.
struct Camera {
    static let zoomRange: ClosedRange<CGFloat> = 0.1...8

    /// The world point shown at the view's top-left corner.
    var origin: CGPoint = .zero
    var zoom: CGFloat = 1

    func toView(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - origin.x) * zoom, y: (point.y - origin.y) * zoom)
    }

    func toWorld(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x / zoom + origin.x, y: point.y / zoom + origin.y)
    }

    func toView(_ rect: CGRect) -> CGRect {
        CGRect(origin: toView(rect.origin), size: CGSize(width: rect.width * zoom, height: rect.height * zoom))
    }

    func toWorld(_ rect: CGRect) -> CGRect {
        CGRect(origin: toWorld(rect.origin), size: CGSize(width: rect.width / zoom, height: rect.height / zoom))
    }

    /// Moves the content by a distance measured in view points.
    mutating func pan(by delta: CGSize) {
        origin.x -= delta.width / zoom
        origin.y -= delta.height / zoom
    }

    /// Changes the zoom while keeping the world point under `anchor` (in view space) fixed on screen.
    mutating func setZoom(_ newZoom: CGFloat, around anchor: CGPoint) {
        let fixed = toWorld(anchor)
        zoom = min(max(newZoom, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        origin = CGPoint(x: fixed.x - anchor.x / zoom, y: fixed.y - anchor.y / zoom)
    }

    mutating func zoom(by factor: CGFloat, around anchor: CGPoint) {
        setZoom(zoom * factor, around: anchor)
    }
}
