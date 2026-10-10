import CoreGraphics
import Geometry

/// Where each of a shape's adornments goes, in view points, from the shape's top-left corner (y
/// down): pure geometry, the same for drawing and for hit testing. Three places, each a run of
/// adornments packed `spacing` apart, so on one shape none overlaps another by construction:
///
/// - the row above the top edge (`rowGap` above it, `rowHeight` tall): its right end leftward from
///   the right edge, whole, then its left end rightward from the left edge, in the room left (text
///   gives way, ending in "…", and needs `minTextRoom`, and its `lead` more, a symbol before it, or
///   it and the rest are left out), unless it isn't shown whole and a right-end item's compact face
///   gives it more room (`Item.compact`: the right end's items take theirs, nearest the edge first,
///   as many as give the text the most room it can get, and no more, all of them when it gets none);
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
    /// The corner's height: a tally's.
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
    /// The least width of the place an open shape's adornments are laid out from (a wire's label, or
    /// its middle): a shorter one is widened about its center, so a row of chips has room.
    public static let minAnchorWidth: CGFloat = 120
    /// Below this zoom adornments shrink with the shapes.
    public static let fullSizeZoom: CGFloat = 0.25

    /// One adornment to lay out: its place, how wide it is (text as long as it's drawn, measured; a
    /// symbol's disc as wide as its place is tall), whether it's text, which gives way at the row's
    /// left end, and for text, how far it starts past its padding (`lead`: a symbol before it, and
    /// the gap after that), which it needs room for besides `minTextRoom`.
    public struct Item: Equatable, Sendable {
        public var placement: AdornmentPlacement
        public var width: CGFloat
        public var isText: Bool
        public var lead: CGFloat
        /// A narrower face an item at the row's right end may take (`AdornmentLabel.compact(_:)`),
        /// when its full one would leave the row's left end's text cut short or out, and it gives the
        /// text more room (or, while none shows anyway, the most it can).
        public var compact: Compact?
        /// The group of labels it is one of (one contribution's, at the row's left end, in order and
        /// next to each other in the items), nil for an adornment on its own. Every one but the
        /// group's last is shown whole or not at all; the first not shown, and those after it, fold
        /// into one "+N" chip, `overflowWidth` wide (the "+N" for it and those after it), shown only
        /// if it fits whole.
        public var group: Int?
        public var overflowWidth: CGFloat
        public init(_ placement: AdornmentPlacement, width: CGFloat, isText: Bool, lead: CGFloat = 0, compact: Compact? = nil,
                    group: Int? = nil, overflowWidth: CGFloat = 0) {
            self.placement = placement
            self.width = width
            self.isText = isText
            self.lead = lead
            self.compact = compact
            self.group = group
            self.overflowWidth = overflowWidth
        }

        /// What an item's compact face needs: only its width, since the right end places whole.
        public struct Compact: Equatable, Sendable {
            public var width: CGFloat
            public init(width: CGFloat) { self.width = width }
        }
    }

    /// World units per view point at `zoom`: an adornment keeps its size on screen, but below
    /// `fullSizeZoom` shrinks with the shapes.
    public static func scale(atZoom zoom: CGFloat) -> CGFloat { min(1, zoom / fullSizeZoom) / zoom }

    /// How tall adornments in a place are.
    public static func height(of placement: AdornmentPlacement) -> CGFloat {
        placement == .onTopRightCorner ? cornerHeight : rowHeight
    }

    /// How far above its top edge a shape `width` points wide reaches with these adornments, in view
    /// points (so in world units at 100%, where adornments keep their size): what the row above holds
    /// reaches `rowGap + rowHeight`, a chip on the corner `cornerHeight / 2`, nothing 0. Only what is
    /// shown counts: text left out for want of room reaches nowhere.
    public static func extent(of items: [Item], in width: CGFloat) -> CGFloat {
        var reach: CGFloat = 0
        for slot in slots(of: items, width: width) {
            if let slot { reach = max(reach, -slot.frame.minY) }
        }
        return reach
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
        /// The item's compact face is the one placed here.
        var isCompact = false
        /// The item and the rest of its group are folded into one "+N" chip, which is placed here.
        var isOverflow = false

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
        var slots: [Slot?] = []
        self.slots(of: items, width: width, into: &slots)
        return slots
    }

    /// Each item's slot, into `slots`, whatever it held: one array for every shape a frame lays
    /// out, so none is made a shape. Compact faces are the row's right end's to take, whenever the
    /// row's left end's text isn't shown whole with every face in full (cut short, or left out):
    /// the items at the right end that have a compact face take it, nearest the edge first, as few
    /// as give the texts as much width in all as every one of them does (so a title already whole
    /// goes no farther), and every one when even that shows none of them, since it's the most room.
    /// So as the shape widens the faces change once: compact, until the full faces and the whole
    /// text fit together, then full. A row with no text at its left end, or whose text is whole
    /// beside the full faces, keeps them. Items with no compact face cost no more than they did.
    static func slots(of items: [Item], width: CGFloat, into slots: inout [Slot?]) {
        var compactable = 0
        for item in items where item.placement == .aboveTopRight && item.compact != nil { compactable += 1 }
        place(items, width: width, compacting: 0, into: &slots)
        guard compactable > 0, !leftText(items, slots).isWhole else { return }
        // The most the text gets: every face compact. If it shows none even then, that's the layout.
        place(items, width: width, compacting: compactable, into: &slots)
        let most = leftText(items, slots)
        guard most.shown > 0 else { return }
        for count in 0..<compactable {
            place(items, width: width, compacting: count, into: &slots)
            if leftText(items, slots).shown == most.shown { return }
        }
        place(items, width: width, compacting: compactable, into: &slots)
    }

    /// How the row's left end's texts are shown: whether every one is at its full width, and how
    /// wide they are in all (one left out is none).
    private struct LeftText {
        var isWhole = true
        var shown: CGFloat = 0
    }

    private static func leftText(_ items: [Item], _ slots: [Slot?]) -> LeftText {
        var text = LeftText()
        for i in items.indices where items[i].placement == .aboveTopLeft && items[i].isText && items[i].group == nil {
            guard let slot = slots[i] else {
                text.isWhole = false
                continue
            }
            text.shown += slot.frame.width
            if slot.frame.width < items[i].width { text.isWhole = false }
        }
        return text
    }

    /// The layout itself, with the first `compacting` of the right end's compactable items (in the
    /// order they're claimed) in their compact faces.
    private static func place(_ items: [Item], width: CGFloat, compacting: Int, into slots: inout [Slot?]) {
        slots.removeAll(keepingCapacity: true)
        slots.append(contentsOf: repeatElement(Slot?.none, count: items.count))
        let rowY = -(rowGap + rowHeight)
        // The row's right end, leftward from the right edge: whole; one that would end past
        // `maxRun` is left out, with the rest.
        var right: CGFloat = 0
        var compacted = 0
        for i in items.indices where items[i].placement == .aboveTopRight {
            var itemWidth = items[i].width
            var isCompact = false
            if compacted < compacting, let compact = items[i].compact {
                itemWidth = compact.width
                isCompact = true
                compacted += 1
            }
            let x = right - itemWidth
            guard -x <= maxRun else { break }
            slots[i] = Slot(frame: CGRect(x: x, y: rowY, width: itemWidth, height: rowHeight), isFromRight: true, isCompact: isCompact)
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
        var folded: Int?
        for i in items.indices where items[i].placement == .aboveTopLeft {
            let item = items[i]
            if let group = item.group, group == folded { continue }
            let room = width + right - left
            var shown: CGFloat?
            if let group = item.group {
                // Whole, but for the group's last, which is cut short like any text; else folded.
                let isLast = !(i + 1 < items.count && items[i + 1].group == group)
                if item.width <= room {
                    shown = item.width
                } else if isLast, item.isText, room >= minTextRoom + item.lead {
                    shown = room
                } else {
                    // Fold from here; if the "+N" doesn't fit whole, fold the chips shown before it too,
                    // the later first, until it does, so what folds never goes unsaid. Not even the
                    // group's first chip's "+N" fitting, the run ends.
                    var at = i
                    var start = left
                    var available = room
                    while items[at].overflowWidth > available {
                        guard at > 0, items[at - 1].group == group, let before = slots[at - 1] else { break }
                        at -= 1
                        start = before.frame.minX
                        available = width + right - start
                    }
                    // With no room for even that, none of the group is shown: chips with no word of
                    // those left out would say less than none.
                    for j in at..<i { slots[j] = nil }
                    guard items[at].overflowWidth <= available else { break }
                    slots[at] = Slot(frame: CGRect(x: start, y: rowY, width: items[at].overflowWidth, height: rowHeight), isFromRight: false, isOverflow: true)
                    left = start + items[at].overflowWidth + spacing
                    folded = group
                    continue
                }
            } else {
                // Text before a group leaves the group's "+N" chip its width, so a long title can't
                // hide every chip: the title keeps what it needs to be shown at all (`minTextRoom`).
                var available = room
                if item.isText, let reserved = reservation(after: i, in: items) {
                    available = max(min(room, minTextRoom + item.lead), room - reserved)
                }
                shown = item.isText ? (available >= minTextRoom + item.lead ? min(item.width, available) : nil)
                                    : (item.width <= available ? item.width : nil)
            }
            guard let shown else { break }
            slots[i] = Slot(frame: CGRect(x: left, y: rowY, width: shown, height: rowHeight), isFromRight: false)
            left += shown + spacing
        }
    }

    /// What text at the row's left end leaves for the group after it: the "+N" chip that stands for
    /// all of it, and the gap before it. Nil with no group after.
    private static func reservation(after index: Int, in items: [Item]) -> CGFloat? {
        var i = index + 1
        while i < items.count {
            if items[i].placement == .aboveTopLeft, items[i].group != nil { return spacing + items[i].overflowWidth }
            i += 1
        }
        return nil
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
        let reachLeft = cornerOverhang + minAnchorWidth / 2
        return CGRect(x: visible.minX - reachLeft * scale, y: visible.minY - cornerHeight / 2 * scale,
               width: visible.width + (reachLeft + maxRun) * scale,
               height: visible.height + (cornerHeight / 2 + rowGap + rowHeight) * scale)
    }

    /// The world rect whose shapes may have an adornment within `hitMargin` of `point`.
    public static func area(around point: CGPoint, scale: CGFloat) -> CGRect {
        area(showing: CGRect(origin: point, size: .zero), scale: scale).insetBy(dx: -hitMargin * scale, dy: -hitMargin * scale)
    }
}
