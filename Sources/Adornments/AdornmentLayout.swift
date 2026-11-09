import CoreGraphics
import Geometry

/// Where each of a shape's adornments goes, in view points, from the shape's top-left corner (y
/// down): pure geometry, the same for drawing and for hit testing. Three places, each a run of
/// adornments packed `spacing` apart, so on one shape none overlaps another by construction:
///
/// - the row above the top edge (`rowGap` above it, `rowHeight` tall; on a shape with a tab on its top
///   edge, `tabRowLift` higher, clear of the tab, its left end from where the tab starts): its right end leftward from
///   the right edge, whole, then its left end rightward from the left edge, in the room left (text
///   gives way, ending in "…", and needs `minTextRoom`, and its `lead` more (a symbol before it, a number after it), or
///   it and the rest are left out), unless it isn't shown whole and a right-end item's compact face
///   gives it more room (`Item.compact`: the right end's items take theirs, nearest the edge first,
///   as many as give the text the most room it can get, and no more, all of them when it gets none);
/// - the top-right corner (`cornerHeight` tall, centered on the top edge), leftward from
///   `cornerOverhang` past the right edge.
///
/// A tab on the top edge (`AdornmentPlacement.onTopEdge`) is placed apart, with the other shapes' tabs
/// (`tabs(_:)`), since tabs give way to each other across shapes; the layout of one shape leaves its slot
/// empty, and the caller fills it in.
///
/// On an open shape that is slanted (`Slant.slope`, the chord's dy / dx, y down), the shape's own body runs
/// through the middle of its anchor, and the row above it slides along the anchor, toward the side the body
/// leaves clear, only as far as it must to keep `margin` between the body's centre line and an edge (grown by
/// `margin` on every side, a slot is never crossed by it). The row moves whole, its
/// right end and the corner with its left end, so each keeps its own packing; the layout slides the slots against
/// an anchor that does not move, so it stays pure, and `editor.adornmentAnchor(of:)` is the anchor moved by the row's
/// slide (the layout returns it), so what hangs from the row hangs from where it is; a level shape (slope 0) is laid
/// out exactly as it was. The chord is the body's direction for a straight shape and the tangent's at its middle for a
/// bent one, whose arc may still cross a slot, more as it bends. The row's bottom is `h + rowGap` above the
/// anchor's middle, `h` half the anchor's height: where the body falls to the right (slope > 0) it is above the
/// middle on the left, so the row's leftmost point is no farther left than `-(h + rowGap - margin) / slope + margin`
/// from the middle; where it rises (slope < 0), mirrored, its rightmost no farther right than
/// `(h + rowGap - margin) / |slope| - margin`. The slide is at most `maxSlide` world units, or what a 120-point
/// anchor needs if that is more (`slideLimit(atScale:)`, `Slant.maxSlide` in view points), which bounds the reach
/// of an anchor as wide as an arrow's label.
///
/// An open shape with no label has no rect of its own to lay the row against, so its anchor is a point (the middle of
/// its outline) widened to `minAnchorWidth`, and the row is centred on that middle as one run (`Slant.centersRow`:
/// the middle of its extent, the left end and the right end together, is the anchor's middle; the corner rides along);
/// the slide of a slanted body then starts from there, moving the row only as far as it must. A shape with a label
/// keeps its row from the label's left edge, and a closed shape reads nothing of this.
///
/// The row ends a point above the corner's top (`rowGap` is half the corner's height, and one
/// more). The row's right end and the corner reach no more than `maxRun` from their starts:
/// whatever would is left out, with what comes after it. The row's left end stays within the
/// shape's width, less what the right end holds. So everything is within x `min(0, width − 200)` …
/// `width + 6`, y −31 … 8 (−27 … 8 on a shape with no tab), which culling and hit testing go by.
public enum AdornmentLayout {
    // View points.
    /// The row's height: a title's pill's, a lock's disc.
    public static let rowHeight: CGFloat = 18
    /// The corner's height: a tally's.
    public static let cornerHeight: CGFloat = 16
    /// Between the row and the top edge: clear of the corner, which reaches half its height above it.
    public static let rowGap: CGFloat = cornerHeight / 2 + 1
    /// How much higher the row sits on a shape with a tab on its top edge (a frame's title), which reaches half its
    /// height above the edge, as high as `rowGap`: the row clears the tab by `spacing`, as two adornments in a run are
    /// apart, and its left end starts where the tab does (`tabInset`), so a frame's type chips sit over its
    /// title's tab as a note's sit after its pill.
    public static let tabRowLift: CGFloat = spacing
    /// The farthest the row reaches above the top edge, a tab's lift included: what culling goes by.
    public static let rowReach: CGFloat = rowGap + rowHeight + tabRowLift
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
    /// The clear space kept between a slanted shape's body (its centre line) and the edge of a slot that
    /// slid clear of it, on every side.
    public static let margin: CGFloat = 4
    /// The farthest the row slides along its anchor to keep clear of the body, in world units (an arrow's
    /// label is at most some 250 wide, so its row slides at most half of that and the margin): it bounds the
    /// reach of the row on an anchor as wide as a label, which culling goes by (`area(showing:scale:)`).
    public static let maxSlide: CGFloat = 200

    /// The farthest the row slides, in view points, at `scale` world units per view point: `maxSlide` world
    /// units, but never less than a 120-point anchor with the longest run of the row's right end needs to
    /// clear any body (half the anchor, the margin and `maxRun`), so zoomed out the cap never keeps an ordinary
    /// anchor's row from clearing.
    public static func slideLimit(atScale scale: CGFloat) -> CGFloat {
        max(minAnchorWidth / 2 + margin + maxRun, maxSlide / scale)
    }

    /// One adornment to lay out: its place, how wide it is (text as long as it's drawn, measured; a
    /// symbol's disc as wide as its place is tall), whether it's text, which gives way at the row's
    /// left end, and for text, the room it needs besides `minTextRoom` (`lead`: a symbol before it and the
    /// gap after that, and a number after it and the gap before that, `AdornmentLabel.counted(_:)`).
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

    // MARK: The tab on the top edge

    /// A tab's height across its edge, half each side of it: a row's.
    public static let tabHeight: CGFloat = rowHeight
    /// How far along its edge from the shape's corner a tab starts.
    public static let tabInset: CGFloat = 10
    /// What a tab leaves free at the far end of its edge.
    public static let tabEndGap: CGFloat = 4
    /// A tab's corners: a tab, not a capsule.
    public static let tabRadius: CGFloat = 5
    /// How far a shape reaches past the edge a tab is on, at least, for the tab's inner half to lie on it.
    public static let tabLeastDepth: CGFloat = tabHeight / 2 + 3

    /// A shape's tab, in view points in the space its shape was given in: flat on the top edge, or turned
    /// down the left one.
    public struct Tab: Equatable, Sendable {
        public var frame: CGRect
        public var isTurned: Bool
        public init(frame: CGRect, isTurned: Bool) {
            self.frame = frame
            self.isTurned = isTurned
        }
        /// How long it is along its edge.
        public var length: CGFloat { isTurned ? frame.height : frame.width }
    }

    /// A shape that asks for a tab: its rect, in view points (any origin, the same for every request), and
    /// its tab's item.
    public struct TabRequest: Equatable, Sendable {
        public var shape: CGRect
        public var item: Item
        public init(shape: CGRect, item: Item) {
            self.shape = shape
            self.item = item
        }
    }

    /// Each shape's tab, placed in the order given (the caller ranks them: the outermost shape first, then
    /// the larger), nil for one left out: each clear of those placed before it by `spacing`, by sliding
    /// along its edge past what it meets. Flat on the top edge where that shows the whole text; on a shape
    /// at least twice as tall as it is wide, turned down the left edge where that shows more of it.
    public static func tabs(_ requests: [TabRequest]) -> [Tab?] {
        var placed: [CGRect] = []
        return requests.map { request in
            guard let tab = tab(of: request, clearOf: placed) else { return nil }
            placed.append(tab.frame)
            return tab
        }
    }

    /// One shape's tab, clear of `placed`.
    static func tab(of request: TabRequest, clearOf placed: [CGRect]) -> Tab? {
        let shape = request.shape, item = request.item
        let flat = slide(along: shape, turned: false, item: item, clearOf: placed)
        if let flat, flat.length >= item.width { return flat }
        guard shape.height >= 2 * shape.width, let turned = slide(along: shape, turned: true, item: item, clearOf: placed),
              turned.length > flat?.length ?? 0 else { return flat }
        return turned
    }

    /// A tab along one edge, from `tabInset` in, slid past each tab of `placed` it meets while its edge
    /// has room: text needs `minTextRoom` and its lead, a symbol its width.
    private static func slide(along shape: CGRect, turned: Bool, item: Item, clearOf placed: [CGRect]) -> Tab? {
        guard (turned ? shape.width : shape.height) >= tabLeastDepth else { return nil }
        let end = (turned ? shape.maxY : shape.maxX) - tabEndGap
        let least = item.isText ? minTextRoom + item.lead : item.width
        var start = (turned ? shape.minY : shape.minX) + tabInset
        while end - start >= least {
            let length = min(item.width, end - start)
            let frame = turned ? CGRect(x: shape.minX - tabHeight / 2, y: start, width: tabHeight, height: length)
                               : CGRect(x: start, y: shape.minY - tabHeight / 2, width: length, height: tabHeight)
            var past: CGFloat?
            for other in placed where other.insetBy(dx: -spacing, dy: -spacing).intersects(frame) {
                past = max(past ?? -.infinity, (turned ? other.maxY : other.maxX) + spacing)
            }
            guard let past else { return Tab(frame: frame, isTurned: turned) }
            // What it meets overlaps it, so its far end is past `start`: each step goes forward.
            start = max(past, start + 1)
        }
        return nil
    }

    /// What an open shape's row goes by, in view points: how tall its anchor is, and the slope of the chord from its
    /// outline's first point to its last (dy / dx, y down; infinite for an upright chord, 0 for a level one), which
    /// slides the row clear of a slanted shape's body. A closed shape has none.
    public struct Slant: Equatable, Sendable {
        public var anchorHeight: CGFloat
        public var slope: CGFloat
        /// The farthest the row slides, in view points (`AdornmentLayout.slideLimit(atScale:)`).
        public var maxSlide: CGFloat
        /// The anchor is a point (an open shape with no label): the row is centred on its middle before it slides.
        public var centersRow: Bool
        public init(anchorHeight: CGFloat, slope: CGFloat = 0, maxSlide: CGFloat = AdornmentLayout.slideLimit(atScale: 1), centersRow: Bool = false) {
            self.anchorHeight = anchorHeight
            self.slope = slope
            self.maxSlide = maxSlide
            self.centersRow = centersRow
        }
    }

    /// How far above its top edge a shape `width` points wide reaches with these adornments, in view
    /// points (so in world units at 100%, where adornments keep their size): what the row above holds
    /// reaches `rowGap + rowHeight` (and `tabRowLift` more over a tab), a chip on the corner `cornerHeight / 2`, nothing 0. Only what is
    /// shown counts: text left out for want of room reaches nowhere.
    /// `height` is the shape's, in view points: a shape too short for a tab, or so narrow and tall that its
    /// tab turns down its left edge, has none above it.
    public static func extent(of items: [Item], in width: CGFloat, height: CGFloat = .infinity) -> CGFloat {
        var reach: CGFloat = 0
        for slot in slots(of: items, width: width) {
            if let slot { reach = max(reach, -slot.frame.minY) }
        }
        // A tab, on a shape with nothing beside it, reaches half its height above the edge where it lies flat.
        if let tab = items.first(where: { $0.placement == .onTopEdge }),
           let alone = Self.tab(of: TabRequest(shape: CGRect(x: 0, y: 0, width: width, height: height.isFinite ? height : tabLeastDepth), item: tab),
                                clearOf: []), !alone.isTurned {
            reach = max(reach, tabHeight / 2)
        }
        return reach
    }

    /// The narrowest a shape can be, in view points, for every item to show whole: each in the row and the corner placed in
    /// full (none cut short, folded, given its compact face or left out) and a tab on the top edge flat and as long as its text.
    /// What a layout that sizes a shape by what it holds (a frame) also sizes it by, so its title is never cut. 0 for no items.
    public static func leastWidth(of items: [Item]) -> CGFloat {
        let row = items.filter { $0.placement != .onTopEdge && $0.placement != .inLabelLead }
        let tab = items.first { $0.placement == .onTopEdge }
        guard !row.isEmpty || tab != nil else { return 0 }
        func whole(_ width: CGFloat) -> Bool {
            let placed = slots(of: items, width: width)
            for (item, slot) in zip(items, placed) where item.placement != .onTopEdge && item.placement != .inLabelLead {
                guard let slot, !slot.isOverflow, !slot.isCompact, slot.frame.width >= item.width - 0.5 else { return false }
            }
            if let tab {
                let request = TabRequest(shape: CGRect(x: 0, y: 0, width: width, height: max(tabLeastDepth * 4, 64)), item: tab)
                guard let placed = Self.tab(of: request, clearOf: []), !placed.isTurned, placed.length >= tab.width - 0.5 else { return false }
            }
            return true
        }
        var high: CGFloat = 32
        while !whole(high) {
            high *= 2
            if high > 100_000 { return high }
        }
        var low: CGFloat = 0
        while high - low > 0.5 {
            let middle = (low + high) / 2
            if whole(middle) { high = middle } else { low = middle }
        }
        return high.rounded(.up)
    }

    /// Each item's frame, in the order given (the order they're claimed), for a shape `width`
    /// points wide; nil for one left out. `slant` is an open shape's: without it the row is laid out as a closed shape's.
    /// `leftStart`: where the row's left end may start at the earliest (clear of a container's tab).
    public static func frames(of items: [Item], width: CGFloat, slant: Slant? = nil, leftStart: CGFloat = 0) -> [CGRect?] {
        slots(of: items, width: width, slant: slant, leftStart: leftStart).map { slot in slot.map { $0.frame(width: width) } }
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
        /// The lead of a label (`AdornmentPlacement.inLabelLead`): where it is in world units, which the geometry
        /// gave it, and which of the label's faces is drawn there (0 the whole one). Its frame is that rect at the
        /// origin, one world unit to a point.
        var lead: (rect: CGRect, face: Int)?
        /// A tab on the top edge (`AdornmentPlacement.onTopEdge`): world units a point, the same size on screen
        /// at every zoom, where the rest shrink below `fullSizeZoom`. Its frame is from the top-left corner.
        var tabUnit: CGFloat?
        /// The tab is turned down the left edge: its frame is upright, and its face is drawn turned a quarter.
        var isTurned = false

        /// From the top-left corner.
        func frame(width: CGFloat) -> CGRect { isFromRight ? frame.offsetBy(dx: width, dy: 0) : frame }

        /// The corner, in world units, of a shape with these bounds.
        func corner(in bounds: CGRect) -> CGPoint {
            if let lead { return lead.rect.origin }
            return CGPoint(x: isFromRight ? bounds.maxX : bounds.minX, y: bounds.minY)
        }

        /// World units a point: `scale` for what is placed from the shape's edge, one for a label's lead, a
        /// tab's own.
        func unit(_ scale: CGFloat) -> CGFloat { tabUnit ?? (lead == nil ? scale : 1) }

        /// The frame in world units, for a shape with these bounds, at `scale` world units per point.
        func worldRect(in bounds: CGRect, scale: CGFloat) -> CGRect {
            if let lead { return lead.rect }
            let corner = corner(in: bounds), unit = unit(scale)
            return CGRect(x: corner.x + frame.minX * unit, y: corner.y + frame.minY * unit,
                          width: frame.width * unit, height: frame.height * unit)
        }
    }

    static func slots(of items: [Item], width: CGFloat, slant: Slant? = nil, leftStart: CGFloat = 0) -> [Slot?] {
        var slots: [Slot?] = []
        self.slots(of: items, width: width, slant: slant, leftStart: leftStart, into: &slots)
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
    ///
    /// Returns how far the row slid along the anchor, in view points (0 for a level shape, one not read, or a row
    /// already clear): where something that hangs from the row (a card, a menu) hangs.
    @discardableResult
    static func slots(of items: [Item], width: CGFloat, slant: Slant? = nil, leftStart: CGFloat = 0, into slots: inout [Slot?]) -> CGFloat {
        placeRow(items, width: width, leftStart: leftStart, into: &slots)
        return slideRow(items, width: width, slant: slant, into: &slots)
    }

    /// The row and the corner, with the compact faces where they give the left end's text the most room.
    /// `leftStart`: where the row's left end may start at the earliest, view points from the left edge (clear of a
    /// container's tab, `AdornmentState.giveWay`).
    private static func placeRow(_ items: [Item], width: CGFloat, leftStart: CGFloat = 0, into slots: inout [Slot?]) {
        var compactable = 0
        var overTab = false
        for item in items {
            if item.placement == .aboveTopRight && item.compact != nil { compactable += 1 }
            if item.placement == .onTopEdge { overTab = true }
        }
        place(items, width: width, compacting: 0, overTab: overTab, leftStart: leftStart, into: &slots)
        guard compactable > 0, !leftText(items, slots).isWhole else { return }
        // The most the text gets: every face compact. If it shows none even then, that's the layout.
        place(items, width: width, compacting: compactable, overTab: overTab, leftStart: leftStart, into: &slots)
        let most = leftText(items, slots)
        guard most.shown > 0 else { return }
        for count in 0..<compactable {
            place(items, width: width, compacting: count, overTab: overTab, leftStart: leftStart, into: &slots)
            if leftText(items, slots).shown == most.shown { return }
        }
        place(items, width: width, compacting: compactable, overTab: overTab, leftStart: leftStart, into: &slots)
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
    /// order they're claimed) in their compact faces; `overTab`, the shape has a tab on its top edge.
    private static func place(_ items: [Item], width: CGFloat, compacting: Int, overTab: Bool, leftStart: CGFloat = 0, into slots: inout [Slot?]) {
        slots.removeAll(keepingCapacity: true)
        slots.append(contentsOf: repeatElement(Slot?.none, count: items.count))
        // Over a tab on the top edge the row is lifted clear of it, and its left end starts where the tab does.
        let rowY = -(rowGap + rowHeight + (overTab ? tabRowLift : 0))
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
        // The row's left end, rightward from the left edge (from the tab's start over a tab), in the room the right end leaves.
        // Started past a container's tab, a row with no right end keeps the room it had, running on past the shape's right
        // edge rather than cutting a name the tab took the start of (a table's "orders" at its database's top-left was "or…").
        let tabStart = overTab ? tabInset : 0
        var left: CGFloat = max(tabStart, leftStart)
        let width = right == 0 ? width + max(0, leftStart - tabStart) : width
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

    /// Slides the row and the corner along the anchor, whole, clear of a slanted shape's body (see the header):
    /// the row's extent (its items' frames, not the corner's) is held to the side of the anchor's middle the
    /// body leaves clear, and moves no farther than `maxSlide`. Nothing moves for a level shape or one that
    /// isn't read (`slant` nil), nor for a row already clear. Returns the slide, in view points.
    private static func slideRow(_ items: [Item], width: CGFloat, slant: Slant?, into slots: inout [Slot?]) -> CGFloat {
        guard let slant else { return 0 }
        let slides = slant.slope != 0 && !slant.slope.isNaN
        guard slant.centersRow || slides else { return 0 }
        var lowest = CGFloat.infinity, highest = -CGFloat.infinity
        for i in items.indices where items[i].placement == .aboveTopLeft || items[i].placement == .aboveTopRight {
            guard let slot = slots[i] else { continue }
            let frame = slot.frame(width: width)
            lowest = min(lowest, frame.minX)
            highest = max(highest, frame.maxX)
        }
        guard lowest <= highest else { return 0 }
        // A point anchor: the row's extent is centred on the anchor's middle first, and the slide starts from there.
        var shift: CGFloat = slant.centersRow ? width / 2 - (lowest + highest) / 2 : 0
        lowest += shift
        highest += shift
        if slides {
            // From the anchor's left edge: the middle is `width / 2`; the row's bottom edge is `h + rowGap` above it.
            let drop = slant.anchorHeight / 2 + rowGap - margin
            if slant.slope > 0 {
                shift += min(max(0, width / 2 - drop / slant.slope + margin - lowest), slant.maxSlide)
            } else {
                shift += max(min(0, width / 2 + drop / -slant.slope - margin - highest), -slant.maxSlide)
            }
        }
        guard shift != 0 else { return 0 }
        for i in items.indices {
            guard let slot = slots[i] else { continue }
            guard slot.lead == nil, slot.tabUnit == nil else { continue }
            slots[i] = Slot(frame: slot.frame.offsetBy(dx: shift, dy: 0), isFromRight: slot.isFromRight, isCompact: slot.isCompact,
                            isOverflow: slot.isOverflow)
        }
        return shift
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

    /// How far a point is outside a rounded rect with corners of `radius` (negative inside it): a tab's.
    public static func distance(from point: CGPoint, to frame: CGRect, radius: CGFloat) -> CGFloat {
        let radius = max(0, min(radius, frame.width / 2, frame.height / 2))
        let inner = frame.insetBy(dx: radius, dy: radius)
        let dx = max(inner.minX - point.x, 0, point.x - inner.maxX), dy = max(inner.minY - point.y, 0, point.y - inner.maxY)
        if dx == 0, dy == 0 { return -min(point.x - frame.minX, frame.maxX - point.x, point.y - frame.minY, frame.maxY - point.y) }
        return (dx * dx + dy * dy).squareRoot() - radius
    }

    /// The world rect whose shapes may have adornments in `visible`: grown by as far as they reach
    /// from their shapes, at `scale` world units per point. Up by the corner's reach below the top
    /// edge, down by the row's above it, left by the corner's overhang past an anchor widened to 120, and right
    /// by the longest run.
    ///
    /// A slanted shape's row slides along the anchor (the header), which widens both sides: centred on a point anchor
    /// it is within about 100 points of the middle, and it slides at most `slideLimit` (264 view points, zoomed out),
    /// so 2 × `maxRun` either way holds it; zoomed in, the slide is `maxSlide` world units, and the row reaches past an
    /// anchor's edge no farther than that and its own run: the second term of each side, in world units, bounds an
    /// anchor as wide as a label, whose edge the shape's bounds hold.
    public static func area(showing visible: CGRect, scale: CGFloat) -> CGRect {
        let reachLeft = max(max(cornerOverhang + minAnchorWidth / 2, 2 * maxRun) * scale, maxSlide + cornerOverhang * scale)
        let reachRight = max(2 * maxRun * scale, maxSlide + maxRun * scale)
        let reachUp = cornerHeight / 2
        return CGRect(x: visible.minX - reachLeft, y: visible.minY - reachUp * scale,
               width: visible.width + reachLeft + reachRight,
               height: visible.height + (reachUp + rowReach) * scale)
    }

    /// How far past its frame a slot's drawing can reach, in view points: a dashed line's half, a descender, a wave. A slot whose frame grown by this misses the view draws nothing in it.
    public static let slotMargin: CGFloat = 4

    /// The world rect a closed shape's row and corner lie in, whatever they hold, `bounds` the shape's (a closed
    /// shape's anchor, **Anchors**): the row above the top edge, its left end within the shape's width and its right
    /// end leftward from the right edge by at most `maxRun`, and the corner from its overhang past the right edge
    /// leftward by at most `maxRun`. What `area(showing:scale:)` can only bound by its widest case, a row slid along
    /// an open shape, which a closed shape has none of: a shape in the area whose reach misses what is shown has
    /// nothing to make or draw.
    public static func reach(ofClosed bounds: CGRect, scale: CGFloat) -> CGRect {
        let left = min(bounds.minX, bounds.maxX - maxRun * scale), right = bounds.maxX + cornerOverhang * scale
        let top = bounds.minY - rowReach * scale, bottom = bounds.minY + cornerHeight / 2 * scale
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }

    /// The world rect whose shapes may have an adornment within `hitMargin` of `point`.
    public static func area(around point: CGPoint, scale: CGFloat) -> CGRect {
        area(showing: CGRect(origin: point, size: .zero), scale: scale).insetBy(dx: -hitMargin * scale, dy: -hitMargin * scale)
    }
}
