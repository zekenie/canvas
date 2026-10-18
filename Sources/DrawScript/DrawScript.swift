import CoreGraphics

// DrawScript: the language `canvas draw` reads, and the solver that places what it says.
//
// A script is one statement a line: a shape (`card "API" right of "Web" priority: high`), an edge
// (`edge "Web" -> "API"`), a delete, a group or an ungroup (`group "API" and "Web"`: shapes that are
// selected as one), or a style (a named bundle of attributes). Shapes are placed
// by where they sit against others, never by coordinates, and a gap is a minimum. This module reads
// the text into statements (`Script(parsing:)`, which merges styles into the statements that use
// them) and places boxes (`LayoutProblem.solve()`): it knows no canvas, registry, kind or plugin.
// Every first word but `edge`, `delete`, `group`, `ungroup` and `style` is a kind word, left for the caller to resolve;
// titles are left as written; an attribute that isn't the language's own is a key and a value the
// caller checks against the kind. The caller (Draw) resolves the words, builds the layout problem
// from its board (the shapes that stay put, the parts of their outlines, the view) and applies
// what comes back.
//
// The language and its solver are modified from reladraw's (https://github.com/reladraw/reladraw,
// Apache-2.0; THIRD_PARTY_NOTICES.md): its placements, parts, lists, one unplaced shape, refusing
// rather than guessing, and the longest-path solve. What differs is a live board's: shapes already
// on it are fixed and are obstacles, restated shapes move alone, and one drawing with nothing to
// hang on goes where the view is. The name is reladraw's; this language isn't called that.
//
// Its own words are written as enums with implicit raw values, never as string literals, so no
// word here can be mistaken for another module's id.

/// The words a statement may start with other than a kind's.
public enum Keyword: String, Sendable, CaseIterable {
    case edge, delete, style
    /// `group "A" and "B"`: shapes that are one group, and `ungroup "A"`: shapes that are in none.
    case group, ungroup
}

/// The attribute keys the language keeps for itself. Every other key on a shape is one of its
/// kind's properties, which the caller checks.
public enum LanguageKey: String, Sendable, CaseIterable {
    /// `size: 200x120`, in world units, or a width alone, `size: 200x`.
    case size
    /// `gap: wide`: this shape's default gap in every placement it's in.
    case gap
    /// `overlap: allow`: this shape may overlap others.
    case overlap
    /// `style: urgent, quiet`: the styles it takes, in order.
    case style
    /// `title: "New"`: a restated shape's new title (a rename).
    case title
}

/// An edge's own keys: the side each end aims at, and what it goes through. Every other key on an
/// edge is one the caller declares.
public enum EdgeKey: String, Sendable, CaseIterable {
    case from, to
    /// `via: reference`: the kind of shape the edge goes through, which stands for its end.
    case via
    /// `share: true` or `share: "A"`: an edge through a reference reuses one already beside its start's
    /// container, or the one beside A, rather than make another.
    case share
}

/// The side of a shape an edge's end aims at.
public enum EdgeSide: String, Sendable, CaseIterable {
    case top, right, bottom, left
}

/// The arrow an edge is written with. `<-` is the same edge written the other way round; `<->`
/// has heads at both ends.
public enum EdgeArrow: String, Sendable, CaseIterable {
    case forward = "->"
    case backward = "<-"
    case both = "<->"
}

/// Which way one box sits from another: the four sides, and the four corners, which are two sides
/// at once (`above-left` is above and left, with the gap off both).
public enum Direction: String, Sendable, CaseIterable {
    case above, below, left, right
    case aboveLeft = "above-left", aboveRight = "above-right", belowLeft = "below-left", belowRight = "below-right"

    /// −1 left, 1 right, 0 neither.
    public var horizontal: Int {
        switch self {
        case .left, .aboveLeft, .belowLeft: -1
        case .right, .aboveRight, .belowRight: 1
        case .above, .below: 0
        }
    }

    /// −1 above, 1 below, 0 neither.
    public var vertical: Int {
        switch self {
        case .above, .aboveLeft, .aboveRight: -1
        case .below, .belowLeft, .belowRight: 1
        case .left, .right: 0
        }
    }

    /// The other way round.
    public var opposite: Direction { Direction(horizontal: -horizontal, vertical: -vertical)! }

    /// The direction with these components, if any (both 0 is none).
    public init?(horizontal: Int, vertical: Int) {
        guard let direction = Direction.allCases.first(where: { $0.horizontal == horizontal && $0.vertical == vertical }) else { return nil }
        self = direction
    }

    /// Whether it's written `right of "A"` rather than `above "A"`: "above of" isn't English.
    var takesOf: Bool { horizontal != 0 }
}

/// What a `level with` shares: the vertical middle (`level with`), or a side (`top level with`).
public enum AlignSide: String, Sendable, CaseIterable {
    case center, top, bottom, left, right

    /// Whether it settles where a box sits horizontally (left, right) rather than vertically.
    public var isHorizontal: Bool { self == .left || self == .right }
}

/// A part of a box a placement may name: one of its four sides (a segment as long as the side and
/// no thicker) or one of its nine points.
public enum Part: String, Sendable, CaseIterable {
    case top, bottom, left, right
    case topLeft = "top-left", topCenter = "top-center", topRight = "top-right"
    case leftCenter = "left-center", center, rightCenter = "right-center"
    case bottomLeft = "bottom-left", bottomCenter = "bottom-center", bottomRight = "bottom-right"

    /// A side rather than a point.
    public var isSide: Bool { self == .top || self == .bottom || self == .left || self == .right }

    /// One of the four corners, which the caller may put on a shape's outline rather than its
    /// bounds (a round shape's).
    public var isCorner: Bool { self == .topLeft || self == .topRight || self == .bottomLeft || self == .bottomRight }

    /// The direction from this part toward the box's middle: what `inside` means (`outside` is
    /// its opposite). Nil for the center, which isn't on the boundary.
    public var inward: Direction? {
        let across = rawValue.contains(Part.left.rawValue) ? 1 : rawValue.contains(Part.right.rawValue) ? -1 : 0
        let down = rawValue.contains(Part.top.rawValue) ? 1 : rawValue.contains(Part.bottom.rawValue) ? -1 : 0
        return Direction(horizontal: across, vertical: down)
    }

    /// Where the part is in a box of this size, from its top-left: a side is a segment with no
    /// thickness, a point a rect with no size, each read off the bounds.
    public func rect(in size: CGSize) -> CGRect {
        func place(_ length: CGFloat, near: Part, far: Part) -> (start: CGFloat, length: CGFloat)? {
            if rawValue.contains(near.rawValue) { return (0, 0) }
            if rawValue.contains(far.rawValue) { return (length, 0) }
            return isSide ? nil : (length / 2, 0)
        }
        let x = place(size.width, near: .left, far: .right) ?? (0, size.width)
        let y = place(size.height, near: .top, far: .bottom) ?? (0, size.height)
        return CGRect(x: x.start, y: y.start, width: x.length, height: y.length)
    }
}

/// A named gap, or a number of world units: how far apart a placement holds two boxes at least.
public enum GapName: String, Sendable, CaseIterable {
    case none, tight, normal, wide

    /// In world units.
    public var value: CGFloat {
        switch self {
        case .none: 0
        case .tight: 40
        case .normal: 80
        case .wide: 160
        }
    }
}

/// A gap as written: a name or a number (world units, at least 0).
public enum Gap: Sendable, Hashable {
    case named(GapName)
    case units(CGFloat)

    /// In world units.
    public var value: CGFloat {
        switch self {
        case .named(let name): name.value
        case .units(let units): units
        }
    }

    /// As a script writes it.
    public var written: String {
        switch self {
        case .named(let name): name.rawValue
        case .units(let units): units == units.rounded() && abs(units) < 1e15 ? String(Int(units)) : "\(units)"
        }
    }
}

/// `size:` as written: a width and a height (`300x200`), or a width alone (`300x`), the height then
/// what the caller's kind gives it (a note as tall as its text at that width). World units.
public struct Size: Sendable, Hashable {
    public var width: CGFloat
    /// Nil for a width alone.
    public var height: CGFloat?

    public init(width: CGFloat, height: CGFloat?) {
        self.width = width
        self.height = height
    }

    /// Both sides: its own, its height else `height`.
    public func size(height fallback: CGFloat) -> CGSize {
        CGSize(width: width, height: height ?? fallback)
    }

    /// As a script writes it: `300x200`, `300x`.
    public var written: String {
        Gap.units(width).written + "x" + (height.map { Gap.units($0).written } ?? "")
    }
}

/// The two words that name a box no shape is.
public enum PlaceWord: String, Sendable, CaseIterable {
    /// The bounds of every shape on the board the script doesn't move.
    case board
    /// The part of the board in the window.
    case view
}

/// The language's other words: those that open a placement, join targets, or are a value.
enum Word: String {
    case of, level, with, and, allow, inside, outside, on
    /// `in "X"`: the shape that holds this one.
    case `in`
    /// Not a part here: a shape's text isn't a box.
    case text
    /// A value that puts a property back to its default, which the caller reads; never a title.
    case null
}

/// One axis of the board: x across (right is +), y down (below is +).
enum Axis: CaseIterable {
    case x, y

    /// "horizontally", "vertically": how a message names it.
    var adverb: String { self == .x ? "horizontally" : "vertically" }
}
