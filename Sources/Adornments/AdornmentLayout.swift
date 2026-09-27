import CoreGraphics
import Geometry

/// Where each of a shape's adornments goes, in view points, from the shape's top-left corner (y
/// down): pure geometry, the same for drawing and for hit testing. Three places, each a run of
/// adornments packed `spacing` apart, so on one shape none overlaps another by construction:
///
/// - the row above the top edge (`rowGap` above it, `rowHeight` tall): its right end leftward from
///   the right edge, whole, then its left end rightward from the left edge, in the room left (text
///   gives way, ending in "…", and needs `minTextRoom`, or it and the rest are left out);
/// - the top-right corner (`cornerHeight` tall, centered on the top edge), leftward from
///   `cornerOverhang` past the right edge.
///
/// The row ends a point above the corner's top (`rowGap` is half the corner's height, and one
/// more). The row's right end and the corner reach no more than `maxRun` from their starts:
/// whatever would is left out, with what comes after it. The row's left end stays within the
/// shape's width, less what the right end holds. So everything is within x `min(0, width − 200)` …
/// `width + 6`, y −27 … 8, which culling and hit testing go by.
public enum AdornmentLayout {
    // View points.
    /// The row's height: a title's pill's, a lock's disc.
    public static let rowHeight: CGFloat = 18
    /// The corner's height: a checklist's tally.
    public static let cornerHeight: CGFloat = 16
    /// Between the row and the top edge: clear of the corner, which reaches half its height above it.
    public static let rowGap: CGFloat = cornerHeight / 2 + 1
    /// How far the corner reaches past the right edge.
    public static let cornerOverhang: CGFloat = 6
    /// Between adornments in a run.
    public static let spacing: CGFloat = 4
    /// The least room text at the row's left end is shown in.
    public static let minTextRoom: CGFloat = 30
    /// The farthest a run reaches from its start: the row's right end from the right edge, the
    /// corner from its overhang.
    public static let maxRun: CGFloat = 200
    /// How far past its edge a point is still on an adornment.
    public static let hitMargin: CGFloat = 3
    /// Below this zoom adornments shrink with the shapes.
    public static let fullSizeZoom: CGFloat = 0.25

    /// One adornment to lay out: its place, how wide it is (text as long as it is, a symbol's disc
    /// as wide as its place is tall), and whether it's text, which gives way at the row's left end.
    public struct Item: Equatable, Sendable {
        public var placement: AdornmentPlacement
        public var width: CGFloat
        public var isText: Bool
        public init(_ placement: AdornmentPlacement, width: CGFloat, isText: Bool) {
            self.placement = placement
            self.width = width
            self.isText = isText
        }
    }

    /// World units per view point at `zoom`: an adornment keeps its size on screen, but below
    /// `fullSizeZoom` shrinks with the shapes.
    public static func scale(atZoom zoom: CGFloat) -> CGFloat { min(1, zoom / fullSizeZoom) / zoom }

    /// How tall adornments in a place are.
    public static func height(of placement: AdornmentPlacement) -> CGFloat {
        placement == .onTopRightCorner ? cornerHeight : rowHeight
    }

    /// Each item's frame, in the order given (the order they're claimed), for a shape `width`
    /// points wide; nil for one left out.
    public static func frames(of items: [Item], width: CGFloat) -> [CGRect?] {
        slots(of: items, width: width).map { slot in slot.map { $0.frame(width: width) } }
    }

    /// Where an item goes: its frame from the top corner its place runs from, the right one for the
    /// row's right end and the corner. So what's at the right is placed from the right edge, as
    /// exactly as what's at the left is from the left edge, however wide the shape.
    struct Slot {
        /// View points, from the corner.
        let frame: CGRect
        let isFromRight: Bool

        /// From the top-left corner.
        func frame(width: CGFloat) -> CGRect { isFromRight ? frame.offsetBy(dx: width, dy: 0) : frame }

        /// The corner, in world units, of a shape with these bounds.
        func corner(in bounds: CGRect) -> CGPoint { CGPoint(x: isFromRight ? bounds.maxX : bounds.minX, y: bounds.minY) }

        /// The frame in world units, for a shape with these bounds, at `scale` world units per point.
        func worldRect(in bounds: CGRect, scale: CGFloat) -> CGRect {
            let corner = corner(in: bounds)
            return CGRect(x: corner.x + frame.minX * scale, y: corner.y + frame.minY * scale,
                          width: frame.width * scale, height: frame.height * scale)
        }
    }

    static func slots(of items: [Item], width: CGFloat) -> [Slot?] {
        var slots = [Slot?](repeating: nil, count: items.count)
        let rowY = -(rowGap + rowHeight)
        // The row's right end, leftward from the right edge: whole; one that would end past
        // `maxRun` is left out, with the rest.
        var right: CGFloat = 0
        for i in items.indices where items[i].placement == .aboveTopRight {
            let x = right - items[i].width
            guard -x <= maxRun else { break }
            slots[i] = Slot(frame: CGRect(x: x, y: rowY, width: items[i].width, height: rowHeight), isFromRight: true)
            right = x - spacing
        }
        // The corner, centered on the top edge, leftward from its overhang.
        var corner = cornerOverhang
        for i in items.indices where items[i].placement == .onTopRightCorner {
            let x = corner - items[i].width
            guard cornerOverhang - x <= maxRun else { break }
            slots[i] = Slot(frame: CGRect(x: x, y: -cornerHeight / 2, width: items[i].width, height: cornerHeight), isFromRight: true)
            corner = x - spacing
        }
        // The row's left end, rightward from the left edge, in the room the right end leaves.
        var left: CGFloat = 0
        for i in items.indices where items[i].placement == .aboveTopLeft {
            let room = width + right - left
            let shown: CGFloat? = items[i].isText ? (room >= minTextRoom ? min(items[i].width, room) : nil)
                                                  : (items[i].width <= room ? items[i].width : nil)
            guard let shown else { break }
            slots[i] = Slot(frame: CGRect(x: left, y: rowY, width: shown, height: rowHeight), isFromRight: false)
            left += shown + spacing
        }
        return slots
    }

    /// How far a point is outside an adornment laid out in `frame` (negative inside it), in view
    /// points: from the capsule its frame holds, a disc when it's as wide as it's tall.
    public static func distance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let radius = min(frame.width, frame.height) / 2
        let a = CGPoint(x: frame.minX + radius, y: frame.minY + radius)
        let b = CGPoint(x: frame.maxX - radius, y: frame.maxY - radius)
        return distanceToSegment(from: point, a, b) - radius
    }

    /// The world rect whose shapes may have adornments in `visible`: grown by as far as they reach
    /// from their shapes, at `scale` world units per point. Up by the corner's reach below the top
    /// edge, down by the row's above it, left by the corner's overhang, and right by the longest run.
    public static func area(showing visible: CGRect, scale: CGFloat) -> CGRect {
        CGRect(x: visible.minX - cornerOverhang * scale, y: visible.minY - cornerHeight / 2 * scale,
               width: visible.width + (cornerOverhang + maxRun) * scale,
               height: visible.height + (cornerHeight / 2 + rowGap + rowHeight) * scale)
    }

    /// The world rect whose shapes may have an adornment within `hitMargin` of `point`.
    public static func area(around point: CGPoint, scale: CGFloat) -> CGRect {
        area(showing: CGRect(origin: point, size: .zero), scale: scale).insetBy(dx: -hitMargin * scale, dy: -hitMargin * scale)
    }
}
