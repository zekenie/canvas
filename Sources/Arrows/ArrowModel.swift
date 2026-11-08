import Canvas
import CanvasRPC
import CoreGraphics
import Mentions

/// An arrow: a shape kind with no box. The record's id is the arrow's id.
public struct Arrow: ShapeProps {
    public static let kind: ShapeKind = "arrow"
    /// Append only. The count is the version boards record.
    public static let migrations = [
        // It may say something, on its body (tldraw's arrow label).
        PropsMigration("text and labelPosition"),
        // Its text may mention shapes: text that would now read as a mention (or an escaped one)
        // is escaped, so it stays the text it was.
        PropsMigration("text may mention shapes") { props in MentionTextFormat.escapeLookalikesV1(in: &props, "text") },
        // An end may be bound to a part of its shape (a row: `ArrowBinding.part`), left out when it isn't, so nothing
        // written before reads otherwise.
        PropsMigration("an end may be bound to a part of its shape"),
    ]
    public static let properties = Properties<Arrow>(title: "Arrow") {
        Property("start", \.start).required()
        Property("end", \.end).required()
        Property("bend", \.bend).description("How far the midpoint is pushed off the straight line, in world units; 0 is straight.")
        Property("startArrowhead", \.startArrowhead)
        Property("endArrowhead", \.endArrowhead)
        Property("text", \.text).description("What the arrow says, set on its body.")
        Property("labelPosition", \.labelPosition).minimum(0).maximum(1).description("Where its text sits along it: 0 at its start, 1 at its end, 0.5 halfway.")
    }
    public var start: ArrowTerminal
    public var end: ArrowTerminal
    /// How far the arrow's midpoint is pushed off the straight line between its terminals, in
    /// world units along the line's perpendicular. Zero is a straight arrow.
    public var bend: CGFloat
    public var startArrowhead: Bool
    public var endArrowhead: Bool
    /// What it says, set on its body, which gives way to it (its label), with mentions of other
    /// shapes, as a note's text has (stored as a string all the same).
    public var text: MentionText
    /// Where its label's center sits along its visible body, as a fraction of its length: 0 at its
    /// start, 1 at its end (tldraw's `labelPosition`). The label stays clear of an end that has a
    /// head or is bound, however near that end this is.
    public var labelPosition: CGFloat

    public init(start: ArrowTerminal, end: ArrowTerminal, bend: CGFloat = 0, startArrowhead: Bool = false, endArrowhead: Bool = true,
                text: MentionText = "", labelPosition: CGFloat = 0.5) {
        self.start = start
        self.end = end
        self.bend = bend
        self.startArrowhead = startArrowhead
        self.endArrowhead = endArrowhead
        self.text = text
        self.labelPosition = labelPosition
    }

    /// Whether it says anything: a mention, or text that isn't all spaces and line breaks. Only then
    /// has it a label, but while it's being edited.
    public var hasText: Bool { !text.isBlank }

    public init() { self.init(start: .free(.zero), end: .free(.zero)) }

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

extension ArrowTerminal: SchemaDescribed {
    /// As it codes itself: an object with one member, `free` or `bound`.
    public static func schema(in definitions: inout SchemaDefinitions) -> JSONObject {
        let point = CGPoint.schema(in: &definitions), binding = ArrowBinding.schema(in: &definitions)
        return definitions.reference("terminal", of: Self.self) { _ in
            ["description": "Where an end is: a point, or a shape it's bound to.",
             "oneOf": [
                ["type": "object", "properties": ["free": .object(point)], "required": ["free"], "additionalProperties": false],
                ["type": "object", "properties": ["bound": .object(binding)], "required": ["bound"], "additionalProperties": false],
             ]]
        }
    }
}

public struct ArrowBinding: SchemaDefined, Equatable {
    public static let properties = Properties<ArrowBinding> {
        Property("shapeID", \.shapeID).required()
        Property("normalizedAnchor", \.normalizedAnchor).description("Where it aims within the shape's bounds: [0, 0] is the top-left corner, [1, 1] the bottom-right.")
        Property("isPrecise", \.isPrecise).description("Imprecise bindings aim at the center of the shape's bounds.")
        Property("isExact", \.isExact).description("Exact bindings run to the anchor, not the shape's outline.")
        Property("part", \.part).description("A part of the shape it's bound to (a row), drawn at that row's side facing the other end; absent for the shape as a whole.")
    }
    /// A shape arrows can bind to (see `Connectables`).
    public var shapeID: ShapeID
    /// Where the arrow aims within the shape's bounds: (0, 0) is the top-left corner, (1, 1) the
    /// bottom-right.
    public var normalizedAnchor: CGPoint
    /// Imprecise bindings ignore the anchor and aim at the center of the shape's bounds.
    public var isPrecise: Bool
    /// Exact bindings run all the way to the anchor instead of stopping at the shape's outline.
    public var isExact: Bool
    /// A part of the shape it's bound to (a row of a table: `PartedShape`), nil for the shape as a whole. Its end is then at
    /// the row's left or right side, at its middle, the side facing the other end, unclipped (a departure from tldraw); it is
    /// written precise and exact, its anchor where the side was when it was bound, which is where it's drawn while the
    /// shape's geometry doesn't list the part (a row taken out under a locked arrow).
    public var part: PartID?

    public init(shapeID: ShapeID, normalizedAnchor: CGPoint, isPrecise: Bool, isExact: Bool, part: PartID? = nil) {
        self.shapeID = shapeID
        self.normalizedAnchor = normalizedAnchor
        self.isPrecise = isPrecise
        self.isExact = isExact
        self.part = part
    }

    /// The address it's bound to: its shape, and its part.
    public var address: PartAddress { PartAddress(shapeID, part: part) }

    public init() { self.init(shapeID: ShapeID(), normalizedAnchor: CGPoint(x: 0.5, y: 0.5), isPrecise: false, isExact: false) }
}

public enum ArrowHandle: Hashable, Sendable {
    case terminal(ArrowEnd)
    /// Bends the arrow.
    case middle
}

extension PluginID {
    public static let arrows: PluginID = "arrows"
}
