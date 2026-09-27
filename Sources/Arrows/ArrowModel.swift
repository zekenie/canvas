import Canvas
import CoreGraphics

/// An arrow: a shape kind with no box. The record's id is the arrow's id.
public struct Arrow: ShapeProps {
    public static let kind: ShapeKind = "arrow"
    public var start: ArrowTerminal
    public var end: ArrowTerminal
    /// How far the arrow's midpoint is pushed off the straight line between its terminals, in
    /// world units along the line's perpendicular. Zero is a straight arrow.
    public var bend: CGFloat
    public var startArrowhead: Bool
    public var endArrowhead: Bool

    public init(start: ArrowTerminal, end: ArrowTerminal, bend: CGFloat = 0, startArrowhead: Bool = false, endArrowhead: Bool = true) {
        self.start = start
        self.end = end
        self.bend = bend
        self.startArrowhead = startArrowhead
        self.endArrowhead = endArrowhead
    }

    public subscript(end: ArrowEnd) -> ArrowTerminal {
        get { end == .start ? start : self.end }
        set {
            if end == .start { start = newValue } else { self.end = newValue }
        }
    }

    public func hasArrowhead(at end: ArrowEnd) -> Bool {
        end == .start ? startArrowhead : endArrowhead
    }

    public mutating func toggleArrowhead(at end: ArrowEnd) {
        if end == .start { startArrowhead.toggle() } else { endArrowhead.toggle() }
    }
}

public enum ArrowEnd: Hashable, Codable, Sendable {
    case start, end
    public var opposite: ArrowEnd { self == .start ? .end : .start }
}

public enum ArrowTerminal: Equatable, Codable, Sendable {
    case free(CGPoint)
    case bound(ArrowBinding)

    public var binding: ArrowBinding? {
        if case .bound(let binding) = self { binding } else { nil }
    }

    private enum CodingKeys: String, CodingKey { case free, bound }

    /// In a board: `{"free": [x, y]}` or `{"bound": {…}}`. (Synthesized, each would nest its
    /// value under an extra `_0`.)
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let point = try container.decodeIfPresent(CGPoint.self, forKey: .free) {
            self = .free(point)
        } else {
            self = .bound(try container.decode(ArrowBinding.self, forKey: .bound))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .free(let point): try container.encode(point, forKey: .free)
        case .bound(let binding): try container.encode(binding, forKey: .bound)
        }
    }
}

public struct ArrowBinding: Equatable, Codable, Sendable {
    /// A shape arrows can bind to (see `Connectables`).
    public var shapeID: ShapeID
    /// Where the arrow aims within the shape's bounds: (0, 0) is the top-left corner, (1, 1) the
    /// bottom-right.
    public var normalizedAnchor: CGPoint
    /// Imprecise bindings ignore the anchor and aim at the center of the shape's bounds.
    public var isPrecise: Bool
    /// Exact bindings run all the way to the anchor instead of stopping at the shape's outline.
    public var isExact: Bool

    public init(shapeID: ShapeID, normalizedAnchor: CGPoint, isPrecise: Bool, isExact: Bool) {
        self.shapeID = shapeID
        self.normalizedAnchor = normalizedAnchor
        self.isPrecise = isPrecise
        self.isExact = isExact
    }
}

public enum ArrowHandle: Hashable, Sendable {
    case terminal(ArrowEnd)
    /// Bends the arrow.
    case middle
}

extension ToolID {
    public static let arrow: ToolID = "arrow"
}

extension PluginID {
    public static let arrows: PluginID = "arrows"
}
