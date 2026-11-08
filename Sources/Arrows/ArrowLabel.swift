import Adornments
import AppKit
import Canvas
import Geometry
import Mentions

// An arrow's label: its text, set on its body, which gives way to it. A port of tldraw's
// `arrowLabel.ts`: the label is measured (squeezed to the body's width on a body wider than it's
// tall, else to sixteen ems), centered on the body at its position, kept clear of an end that has a
// head or is bound, and the body is cut where it is.

/// An arrow's visible body as a curve its label sits on: a segment, or an arc, each from where the
/// arrow visibly starts (0) to where it ends (1), measured along it.
public struct ArrowBody: Sendable {
    public let start: CGPoint
    public let end: CGPoint
    /// Nil for a straight body.
    public let arc: Arc?
    /// A level arrow's curve, measured by its length (so a fraction along it is by length, as an arc's is); nil for any other.
    public let curve: CubicMeasure?

    public init(start: CGPoint, end: CGPoint, arc: Arc?) {
        self.start = start
        self.end = end
        self.arc = arc
        curve = nil
    }

    /// A level arrow's visible body.
    public init(curve: Cubic) {
        start = curve.start
        end = curve.end
        arc = nil
        self.curve = curve.measured()
    }

    public var length: CGFloat { curve?.length ?? arc?.length ?? start.distance(to: end) }

    /// The point `fraction` of the way along it (tldraw's `interpolateAlongEdge`).
    public func point(at fraction: CGFloat) -> CGPoint {
        if let curve { return curve.point(atFraction: fraction) }
        if let arc { return arc.point(at: fraction) }
        return start + (end - start) * fraction
    }

    /// How far along it the point of it nearest to `point` is, as a fraction (tldraw's
    /// `uninterpolateAlongEdge`): 0 at its start, 1 at its end.
    public func fraction(nearest point: CGPoint) -> CGFloat {
        if let curve { return curve.fraction(nearest: point) }
        if let arc {
            if let t = arc.parameter(of: point) { return t }
            return point.distance(to: arc.point(at: 0)) <= point.distance(to: arc.point(at: 1)) ? 0 : 1
        }
        let chord = end - start, squared = chord.dot(chord)
        guard squared > 0 else { return 0.5 }
        return min(max((point - start).dot(chord) / squared, 0), 1)
    }

    /// Where it crosses a closed polygon's edges, as fractions along it.
    func crossings(of polygon: [CGPoint]) -> [CGFloat] {
        if let curve {
            let length = curve.length
            return length > 0 ? curve.cubic.intersections(withPolygon: polygon).map { curve.length(at: $0) / length } : []
        }
        if let arc { return intersections(of: arc, withPolygon: polygon) }
        return intersections(ofSegmentFrom: start, to: end, withPolygon: polygon)
    }
}

extension ArrowGeometry {
    /// The visible body, between its clipped ends.
    public var body: ArrowBody {
        switch path {
        case .straight: ArrowBody(start: start, end: end, arc: nil)
        case .curved(let arc, let startT, let endT): ArrowBody(start: start, end: end, arc: arc.trimmed(from: startT, to: endT))
        case .level(let cubic, let startT, let endT): ArrowBody(curve: cubic.trimmed(from: startT, to: endT))
        }
    }
}

/// Where an arrow's label goes (tldraw's `getArrowLabelPosition`), pure.
public enum ArrowLabelLayout {
    /// Where a label starts out, and where it snaps to as it's dragged near: halfway.
    public static let defaultPosition: CGFloat = 0.5

    /// The label's frame, `size` (its text and its padding) centered on `body` at `position` (a
    /// fraction of its length), kept within the range a label of that size fits along it: its
    /// center no nearer an end than where the label, centered `clearance` along the body from it,
    /// would cross the body on the far side; only at the ends that `clearsStart` and `clearsEnd`
    /// say need it (one with a head or bound to a shape), else as far as the end itself. On a body
    /// too short for it, halfway.
    public static func frame(size: CGSize, at position: CGFloat, on body: ArrowBody, clearance: CGFloat,
                             clearsStart: Bool, clearsEnd: Bool) -> CGRect {
        let length = body.length
        guard length > 0, length.isFinite else { return CGRect(center: body.start, size: size) }
        let range = self.range(of: size, on: body, clearance: clearance)
        let wanted = position.isFinite ? position : defaultPosition
        let low = clearsStart ? range.lowerBound : 0, high = clearsEnd ? range.upperBound : 1
        let clamped = min(max(wanted, low), max(low, high))
        return CGRect(center: body.point(at: clamped), size: size)
    }

    /// tldraw's `getArrowLabelRange`: centered `clearance` in from each end, the label crosses the
    /// body; the crossing furthest from that end is as near it as the label's center may come.
    static func range(of size: CGSize, on body: ArrowBody, clearance: CGFloat) -> ClosedRange<CGFloat> {
        let relative = clearance / body.length
        let startBox = CGRect(center: body.point(at: relative), size: size).polygon
        let endBox = CGRect(center: body.point(at: 1 - relative), size: size).polygon
        let first = furthest(from: 0, among: body.crossings(of: startBox), on: body)
        let last = furthest(from: 1, among: body.crossings(of: endBox), on: body)
        let low = first ?? defaultPosition, high = last ?? defaultPosition
        return low > high ? defaultPosition...defaultPosition : low...high
    }

    private static func furthest(from end: CGFloat, among fractions: [CGFloat], on body: ArrowBody) -> CGFloat? {
        let from = body.point(at: end)
        return fractions.max { body.point(at: $0).distance(to: from) < body.point(at: $1).distance(to: from) }
    }
}

extension ArrowStyle {
    /// The label's text: smaller than a note's, as tldraw's arrow labels are than its notes' (20
    /// against 22), on lines string drawing would set it on.
    static let labelFont = NSFont.systemFont(ofSize: 15)
    static let labelLineHeight: CGFloat = 18
    /// Between the label's text and its edge: tldraw's `ARROW_LABEL_PADDING`, 4.25, to a whole
    /// point, so the text starts on one (`ArrowLabels.frame`).
    static let labelPadding: CGFloat = 4
    /// The label's corners, where the body is cut (tldraw's `labelBorderRadius`).
    static let labelCornerRadius: CGFloat = 3.5
    /// How far along the body from an end with a head, or bound, the label's edge stays (tldraw's
    /// `LABEL_TO_ARROW_PADDING`, 20, and twice what its stroke is wider than a small one's).
    static let labelClearance: CGFloat = 20 + (strokeWidth - 2) * 2
    /// A body wider than it's tall squeezes its label to its width less this, but no narrower than
    /// this (or the text, if that's narrower).
    static let labelSqueezeMargin: CGFloat = 64
    /// A label on any other body is no wider than this many of its ems.
    static let labelMaxEms: CGFloat = 16
    /// Dragged within this of halfway, in view points, a label snaps to it (tldraw's
    /// `labelCenterSnapDistance`).
    static let labelSnapDistance: CGFloat = 10

    /// The text's style, in the render, the editor and the measure alike: centered, on fixed lines,
    /// each mention a pill in the arrow's own color (`MentionSurface.shape`: over the canvas, whose
    /// color follows the appearance, as the line does).
    static let labelText = labelStyle(ink: color)

    /// The label's style in `color`: the arrow's own color's ink (text in the color, on the canvas).
    static func labelStyle(ink: NSColor) -> MentionTextStyle {
        MentionTextStyle(font: labelFont, color: ink, lineHeight: labelLineHeight, alignment: .center)
    }
}

/// An arrow's label measured and placed: its text's size kept by what it says and how wide it may
/// be, since an arrow's geometry is worked out again and again (each frame, each hit test). Each
/// mention is measured as a live pill by the name it shows now (`MentionTextStyle.measuredString`, given
/// `names` from the layout input Mentions sets when they differ from the text's): a pure function of
/// the arrow and that input, as its geometry has to be.
@MainActor
enum ArrowLabels {
    private struct Key: Hashable {
        /// As the arrow stores it.
        let text: String
        /// Whole points; nil for no limit.
        let width: CGFloat?
        /// The names its mentions show now, when they aren't the ones the text holds.
        let names: [String]?
    }
    private static var measured: [Key: CGSize] = [:]
    /// How many measures are kept: past it, they're all let go (a label's measure is quick).
    static let kept = 2_048

    /// The label's frame on `geometry`, or nil when it has none: no text (but while it's edited,
    /// `editing`, where an empty label is as wide as an "i", tldraw's). On whole points, as its size
    /// is: the editor's text view sets its text on whole view points, where string drawing doesn't,
    /// so the label's text is where the canvas draws it at 100%, as a note's is (its frame is on
    /// whole points too).
    /// An empty one is shown halfway, where typing puts it.
    static func frame(of arrow: Arrow, on geometry: ArrowGeometry, names: [String]? = nil, editing: Bool = false) -> CGRect? {
        laid(of: arrow, on: geometry, names: names, editing: editing, lead: nil)?.frame
    }

    /// A label laid out: its frame (what the body is cut around), the room kept in it for the pill that leads it, and
    /// where its text goes. Without a lead, the frame is the text's, whole.
    struct Laid: Equatable {
        let frame: CGRect
        /// Where the pill is, in `frame`: nil for no lead.
        let lead: CGRect?
        /// The part of `frame` the text is in (`placement(of:in:)` insets it by the padding).
        let text: CGRect
    }

    /// The label with a pill leading it (`faces`: the sizes the pill may take, widest first, what Adornments says of an
    /// arrow's: `AdornmentLead.faces`), or none. The pill's face is the widest of them whose label, the text after it
    /// squeezed as it is, is no wider than the body less `labelSqueezeMargin` (a label's own room), else the last, which
    /// is a dot's. The frame is the padding, the pill, then the text as it is measured, its own padding the gap; with
    /// no text it is the pill and a padding either side, a pill's height and a padding above and below it. A label with
    /// a lead is shown where the arrow has none but the lead: there is text, or `editing`, or a lead.
    static func laid(of arrow: Arrow, on geometry: ArrowGeometry, names: [String]? = nil, editing: Bool = false,
                     lead faces: [CGSize]?) -> Laid? {
        let faces = faces?.isEmpty == false ? faces : nil
        let hasWords = editing || arrow.hasText
        guard hasWords || faces != nil else { return nil }
        let body = geometry.body
        let bounds = geometry.bodyPath.boundingBoxOfPath
        let padding = ArrowStyle.labelPadding
        func words(reserving reserved: CGFloat) -> CGSize? {
            hasWords ? size(of: arrow.text.stored.isEmpty ? "i" : arrow.text, bodyBounds: bounds, names: names, reserving: reserved) : nil
        }
        let whole: CGSize, pill: CGSize?
        if let faces {
            let room = body.length - ArrowStyle.labelSqueezeMargin
            var chosen = faces.count - 1
            func total(_ face: CGSize) -> CGSize {
                let text = words(reserving: padding + face.width)
                return CGSize(width: padding + face.width + (text?.width ?? padding),
                              height: max(text?.height ?? 0, face.height + 2 * padding))
            }
            for (index, face) in faces.enumerated() where total(face).width <= room {
                chosen = index
                break
            }
            pill = faces[chosen]
            whole = total(faces[chosen])
        } else {
            pill = nil
            whole = words(reserving: 0) ?? .zero
        }
        let position = arrow.hasText || faces != nil ? arrow.labelPosition : ArrowLabelLayout.defaultPosition
        var frame = ArrowLabelLayout.frame(size: whole, at: position, on: body, clearance: ArrowStyle.labelClearance,
                                           clearsStart: arrow.startArrowhead || arrow.start.binding != nil,
                                           clearsEnd: arrow.endArrowhead || arrow.end.binding != nil)
        if frame.origin.x.isFinite, frame.origin.y.isFinite { frame.origin = CGPoint(x: frame.minX.rounded(), y: frame.minY.rounded()) }
        guard let pill else { return Laid(frame: frame, lead: nil, text: frame) }
        let lead = CGRect(x: frame.minX + padding, y: (frame.midY - pill.height / 2).rounded(), width: pill.width, height: pill.height)
        return Laid(frame: frame, lead: lead, text: CGRect(x: lead.maxX, y: frame.minY, width: frame.maxX - lead.maxX, height: frame.height))
    }

    /// The label of a shape as its context lays it out: the names its mentions show now, and the lead Adornments says
    /// the arrow has.
    static func laid(of shape: ShapeRecord<Arrow>, on geometry: ArrowGeometry, in context: ShapeContext, editing: Bool = false) -> Laid? {
        laid(of: shape.props, on: geometry, names: context.mentionNames(of: shape.id), editing: editing,
             lead: context.layoutInput(AdornmentLead.faces, of: shape)?.sizes)
    }

    /// The label as a shape's kept geometry has it: nil for none.
    static func laid(from geometry: ShapeGeometry) -> Laid? {
        guard let frame = geometry.label, let text = textFrame(of: geometry) else { return nil }
        return Laid(frame: frame, lead: geometry.labelLead, text: text)
    }

    /// Where a shape's label text goes in its geometry: the label's frame less its lead.
    static func textFrame(of geometry: ShapeGeometry) -> CGRect? {
        guard let label = geometry.label else { return nil }
        guard let lead = geometry.labelLead else { return label }
        return CGRect(x: lead.maxX, y: label.minY, width: label.maxX - lead.maxX, height: label.height)
    }

    /// The text's box, padding and all (tldraw's `getArrowLabelSize`): as wide as its widest line,
    /// but on a body wider than it's tall no wider than the body less a margin (and no narrower than
    /// the margin), else no wider than sixteen ems, where it wraps.
    static func size(of text: MentionText, bodyBounds: CGRect, names: [String]? = nil, reserving reserved: CGFloat = 0) -> CGSize {
        let free = measure(text, width: nil, names: names)
        let limit: CGFloat
        if bodyBounds.width > bodyBounds.height {
            let margin = ArrowStyle.labelSqueezeMargin
            limit = max(min(free.width, margin), min(bodyBounds.width - margin - reserved, free.width))
        } else {
            limit = ArrowStyle.labelMaxEms * ArrowStyle.labelFont.pointSize
        }
        let inner: CGSize
        if free.width <= limit {
            inner = free
        } else {
            let whole = max(limit.rounded(.down), 1)
            let squeezed = measure(text, width: whole, names: names)
            inner = CGSize(width: min(squeezed.width, whole), height: squeezed.height)
        }
        let padding = ArrowStyle.labelPadding * 2
        return CGSize(width: inner.width + padding, height: inner.height + padding)
    }

    /// The text set `width` wide (nil: on lines as long as it is), as string drawing sets it: its
    /// width a point wider than its widest line, rounded up, so the editor's text, laid out by
    /// TextKit, wraps where it does; its height its lines, a last empty one too (where the caret is
    /// after a Return).
    static func measure(_ text: MentionText, width: CGFloat?, names: [String]? = nil) -> CGSize {
        let key = Key(text: text.stored, width: width, names: names)
        if let size = measured[key] { return size }
        let string = ArrowStyle.labelText.measuredString(text, width: width, names: names)
        let bounds = string.boundingRect(with: CGSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude),
                                         options: [.usesLineFragmentOrigin])
        let size = CGSize(width: bounds.width.rounded(.up) + 1, height: bounds.height.rounded(.up))
        if measured.count >= kept { measured.removeAll(keepingCapacity: true) }
        measured[key] = size
        return size
    }

    /// The body's cut: the label's frame, its corners rounded.
    static func cut(_ frame: CGRect) -> CGPath {
        CGPath(roundedRect: frame, cornerWidth: ArrowStyle.labelCornerRadius, cornerHeight: ArrowStyle.labelCornerRadius, transform: nil)
    }

    /// Where the text is drawn in its frame (`drawMentionText`, the render's, and the faces' and
    /// Find's): centered within it, its padding in from its edges, over the canvas.
    static func placement(of text: MentionText, in frame: CGRect, ink: CGColor? = nil) -> MentionTextPlacement {
        let style = ink.flatMap { NSColor(cgColor: $0) }.map { ArrowStyle.labelStyle(ink: $0) } ?? ArrowStyle.labelText
        return MentionTextPlacement(text, in: frame.insetBy(dx: ArrowStyle.labelPadding, dy: ArrowStyle.labelPadding), style: style,
                             overCanvas: true)
    }
}
