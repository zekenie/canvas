import Foundation

struct StickyNote: Identifiable {
    let id = UUID()
    /// Position and size in world coordinates.
    var frame: CGRect
    var text = ""
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
    var noteID: StickyNote.ID
    /// Where the arrow aims within the note's frame: (0, 0) is the top-left corner, (1, 1) the
    /// bottom-right.
    var normalizedAnchor: CGPoint
    /// Imprecise bindings ignore the anchor and aim at the note's center.
    var isPrecise: Bool
    /// Exact bindings run all the way to the anchor instead of stopping at the note's edge.
    var isExact: Bool
}

/// Maps between world space, where notes live, and view space, the canvas view's points.
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
