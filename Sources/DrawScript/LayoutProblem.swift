import CoreGraphics

// Modified from reladraw's src/resolve.ts and src/constrain.ts (Apache-2.0; THIRD_PARTY_NOTICES.md).

/// What to place, and against what: the boxes a script moves (`free`: new shapes, and shapes it
/// restates with placements), in script order, each with its placements resolved to boxes; the
/// boxes that stay put that a placement names (`fixed`: board shapes, `board`, `view`, `origin`); and the
/// shapes the free boxes must keep clear of (obstacles: every closed board shape the script doesn't
/// move, met where the box that takes it along puts it, if one does), which may be thousands, so
/// they're asked for by region and named only when a message needs one. Positions are world units,
/// y down; a box's position is its top-left.
///
/// Not `Sendable`: it carries the caller's lookups, which run on the caller's thread, while
/// `solve()` does.
public struct LayoutProblem {
    /// A box the script moves.
    public struct Free {
        /// The statement's line, for errors.
        public var line: Int
        /// How a message names it, ready to go in a sentence: `"API"` (quotes and all), or
        /// `the card on line 3`.
        public var name: String
        public var size: CGSize
        /// Where it goes, in the order written; none for the one shape a script may leave unplaced.
        public var clauses: [ResolvedClause]
        /// Its `gap:`, the default for every placement it's in (as either end).
        public var gap: Gap?
        /// `overlap: allow`: no separation, and no list.
        public var overlapAllowed: Bool
        /// A restated shape's bounds now: on an axis no placement settles, it stays where it is, and
        /// a zone that holds them is one it already sits in. Nil for a new shape.
        public var current: CGRect?
        /// What holds it (`in "F"`, F a shape that holds others on its board): it's kept within that
        /// box, the tight gap in from each side, as `inside` keeps a box, or it's `no_room`; and it
        /// may overlap it. Its placements say where in it. Nil for none.
        public var holder: Holder?
        /// The obstacles (by id) that go wherever it goes: what it holds, as a container does. It's
        /// never kept clear of them, and none of them is a zone of it. A restated box (`current`)
        /// takes them as far as it moves, so every other box meets them there, never where they
        /// are now: kept clear of them there as of a part of this box, which it follows if this box
        /// moves on, or sitting on one there that's its zone. Where restated boxes nest, each takes
        /// along what the inner one doesn't. A fixed box or a holder is where it is now, so none may
        /// be one a box takes along: the caller refuses a placement against one.
        public var carries: Set<Int>
        /// A box the caller made up beside what a statement says (a stand-in for an edge's end), which
        /// no script wrote a placement for: where it clashes with another free box that nothing
        /// orders against it, it's the one that moves, past that box, the way its own placements leave
        /// it free to go, where for a box the script wrote that is `unordered`. The later of two such
        /// boxes yields to the earlier. Such boxes placed alike list only with each other, never with a
        /// box the script wrote, `impliedListStep` apart.
        public var implied: Bool

        public init(line: Int, name: String, size: CGSize, clauses: [ResolvedClause] = [], gap: Gap? = nil,
                    overlapAllowed: Bool = false, current: CGRect? = nil, holder: Holder? = nil, carries: Set<Int> = [],
                    implied: Bool = false) {
            self.line = line
            self.name = name
            self.size = size
            self.clauses = clauses
            self.gap = gap
            self.overlapAllowed = overlapAllowed
            self.current = current
            self.holder = holder
            self.carries = carries
            self.implied = implied
        }
    }

    /// A box a free box is kept within (`in "F"`): a fixed box, or a free one.
    public struct Holder {
        public var ref: Ref
        /// How a message names what keeps the box there: `in "Sprint 3"`.
        public var written: String
        /// Whether the box goes in the holder itself, not in what it holds: no obstacle wholly within
        /// the holder is a zone of it, so it's kept clear of a frame in the holder, as of any shape
        /// there, rather than landing on one that holds others (a zone's rule c). False, as `in "F"`
        /// has it, a box that lands among a shape in the holder and what that holds sits on it.
        public var direct: Bool

        public init(_ ref: Ref, written: String, direct: Bool = false) {
            self.ref = ref
            self.written = written
            self.direct = direct
        }
    }

    /// A box that stays put, which a placement names.
    public struct Fixed {
        public var rect: CGRect
        /// Its `gap:`, when the script restates it (without placements, so it stays put).
        public var gap: Gap?
        /// The obstacle it is, if it is one, so `inside` and `on` exempt the pair.
        public var obstacle: Int?
        /// `board`, `view` or `origin`; nil for a shape. A zone holds a shape a free box is placed
        /// against at twice that shape's area, and the `view` whatever its size; the board, framed by
        /// what's on it, and the origin, a point, make nothing a zone.
        public var word: PlaceWord?

        public init(rect: CGRect, gap: Gap? = nil, obstacle: Int? = nil, word: PlaceWord? = nil) {
            self.rect = rect
            self.gap = gap
            self.obstacle = obstacle
            self.word = word
        }
    }

    /// A shape the free boxes keep clear of.
    public struct Obstacle: Sendable, Equatable {
        /// Its place in the board's stacking order (lower paints below), each obstacle's its own:
        /// the order the solver scans them in.
        public var id: Int
        public var rect: CGRect

        public init(id: Int, rect: CGRect) {
            self.id = id
            self.rect = rect
        }
    }

    /// A box, by its place in `free` or `fixed`, or by its obstacle id.
    public enum Ref: Sendable, Hashable {
        case free(Int)
        case fixed(Int)
        case obstacle(Int)
    }

    /// One box a placement names, and the part of it.
    public struct ResolvedTarget {
        /// A free or a fixed box (never an obstacle).
        public var ref: Ref
        public var part: Part?
        /// The part, from the box's top-left, when it isn't where `Part.rect(in:)` puts it in the
        /// box's bounds (a corner on a round shape's outline). Nil: `part` in the bounds, or the whole
        /// box.
        public var partRect: CGRect?
        /// As written, for messages: `"Hub" top`.
        public var written: String

        public init(_ ref: Ref, part: Part? = nil, partRect: CGRect? = nil, written: String) {
            self.ref = ref
            self.part = part
            self.partRect = partRect
            self.written = written
        }
    }

    /// A placement with its targets found.
    public struct ResolvedClause {
        public var relation: Relation
        /// What it's placed against, in the order written.
        public var targets: [ResolvedTarget]
        public var gap: Gap?
        /// As written, for messages. Placements alike for a list are alike in what they say (relation,
        /// targets, parts and gap), which, for a script's, is being written alike.
        public var written: String

        public init(relation: Relation, targets: [ResolvedTarget], gap: Gap? = nil, written: String) {
            self.relation = relation
            self.targets = targets
            self.gap = gap
            self.written = written
        }

        /// The direction it holds its box in: a direction's own, or `inside`'s and `outside`'s from
        /// their part. Nil for alignments and `on`.
        public var direction: Direction? {
            switch relation {
            case .direction(let direction): direction
            case .inside: targets.first?.part?.inward
            case .outside: targets.first?.part?.inward?.opposite
            case .level, .on: nil
            }
        }

        /// A clause as parsed, its targets found: each of `refs` is the box of the target at its
        /// place, and `partRects` (by place) any part not where `Part.rect(in:)` puts it.
        public init(_ clause: Clause, refs: [Ref], partRects: [Int: CGRect] = [:]) {
            precondition(refs.count == clause.targets.count, "one ref for each of the clause's targets")
            self.init(relation: clause.relation,
                      targets: clause.targets.enumerated().map { index, target in
                          ResolvedTarget(refs[index], part: target.part, partRect: partRects[index], written: target.written)
                      },
                      gap: clause.gap, written: clause.written)
        }
    }

    public var free: [Free]
    public var fixed: [Fixed]
    /// The obstacles whose rects meet `rect`, in stacking order (more is fine: the solver checks).
    /// Asked for each free box as it's placed, again after every solve, once for the region a
    /// drawing with nothing to hang on may land in, once more for each box where it lands (the
    /// zones it sits in), and once for each obstacle a box lands wholly on (whether it holds
    /// others); each of those again for each restated box that takes obstacles along (`Free.carries`),
    /// about the region as far back as that box moves. So a caller keeps its answers:
    /// `ObstacleGrid.obstacles(in:)` files the obstacles so a question costs what's near it, and
    /// keeps each answer.
    public var obstacles: (CGRect) -> [Obstacle]
    /// The bounds of every obstacle (the `board` target), nil when there are none: a drawing with
    /// nothing to hang on goes right of it when the view is full.
    public var boardBounds: CGRect?
    /// The middle of the view, where a drawing with nothing to hang on is centered if it can be.
    public var viewMiddle: CGPoint
    /// The view, while the board is in a window: a region that holds all of it isn't in the way of
    /// a drawing with nothing to hang on, which is drawn on it.
    public var view: CGRect?
    /// How a message names a fixed box or an obstacle, as `Free.name` names a free one; asked only
    /// when one is needed.
    public var name: (Ref) -> String
    /// Where a drawing with nothing to hang on lands for a person (a shape Insert puts down): at the nearest spot where
    /// it is inside `clear` with `above` over its top too (the row of things shown just above it), when one is clear,
    /// before the spots out of it. Nil, as `canvas draw` places one, for the nearest spot wherever it is.
    public var landsInView: InView?

    /// `landsInView`'s region: world units.
    public struct InView: Sendable, Equatable {
        public var clear: CGRect
        public var above: CGFloat

        public init(clear: CGRect, above: CGFloat) {
            self.clear = clear
            self.above = above
        }

        /// Whether `rect`, with the room above it, is inside.
        func holds(_ rect: CGRect) -> Bool {
            clear.contains(CGRect(x: rect.minX, y: rect.minY - above, width: rect.width, height: rect.height + above))
        }
    }

    public init(free: [Free], fixed: [Fixed] = [], obstacles: @escaping (CGRect) -> [Obstacle] = { _ in [] }, boardBounds: CGRect? = nil,
                viewMiddle: CGPoint = .zero, view: CGRect? = nil, name: @escaping (Ref) -> String = { _ in "a shape" }) {
        self.free = free
        self.fixed = fixed
        self.obstacles = obstacles
        self.boardBounds = boardBounds
        self.viewMiddle = viewMiddle
        self.view = view
        self.name = name
    }

    // MARK: Spacing (world units)

    /// Between the members of a list, unless they all say the same `gap:`: a tight gap, and room
    /// for the row of things shown just above the next (a title's pill, a lock's chip): 27 view
    /// points, so 27 units at 100% and 54 at 50%, clear down to about 42%.
    public static let listStep: CGFloat = 64
    /// Between the members of a list of boxes the caller made up (`Free.implied`: an edge's
    /// stand-ins, beside the shape it's from), unless they all say the same `gap:`: a pill that
    /// stands in has no title, so nothing is shown above it to leave room for.
    public static let impliedListStep: CGFloat = 16
    /// Kept between two boxes pushed apart side by side: more than what's shown beside a shape
    /// reaches past its side (6 view points, 24 units at the 25% it stops growing at).
    public static let horizontalClearance: CGFloat = 40
    /// Kept between two boxes pushed apart one above the other: room for the row above the lower one.
    public static let verticalClearance: CGFloat = 64
    /// How far apart the spots tried for a drawing with nothing to hang on are, ring after ring.
    public static let ringStep: CGFloat = 40
    /// How far a shape placed `inside` a box, or in a container (`in "F"`), sits from its edge: a `tight` gap.
    public static let insideGap: CGFloat = GapName.tight.value
    /// How far apart a placement holds two boxes when nothing says (`normal`): the gap of an edge's
    /// reference from the shape it is beside.
    public static let defaultGap: CGFloat = GapName.normal.value
    /// How many rings are tried before it goes right of the board.
    public static let rings = 100
    /// How clear of everything else a drawing with nothing to hang on lands (`normal`).
    public static let anchorClearance: CGFloat = GapName.normal.value
    /// How far right of the board it goes when no spot near the view is clear (`wide`).
    public static let fallbackGap: CGFloat = GapName.wide.value
}

/// Where each free box goes.
public struct LayoutSolution: Sendable, Equatable {
    /// Each free box's bounds, in `free`'s order.
    public var rects: [CGRect]
    /// Each time keeping clear of something moved a box, in the order it happened: the boxes kept
    /// apart, then any others that moved with them.
    public var pushes: [Push]
    /// For each free box, the obstacles it overlaps that are zones for it, in stacking order: each
    /// wholly holds the box where it is now (a restated one's), a shape it's placed against, the
    /// box where it lands and other shapes too, or the `view` it's placed against (or its drawing
    /// with nothing to hang on is drawn in), and isn't one it's `inside` or `on`. A free box held
    /// counts only if it's on the zone for a reason of its own (`Solver.counted(by:in:)`). It sits
    /// on them, so it paints above them, and it isn't kept within them. Each is where the boxes
    /// leave it: one a restated box takes along (`Free.carries`), moved as far as that box moves.
    public var zones: [[LayoutProblem.Obstacle]]
    /// Each box slid along an axis its placement leaves free, to stay inside what holds it (`in "F"`,
    /// or `inside`), in the order it happened.
    public var slides: [Slide]

    /// `zones` nil: none for any box.
    public init(rects: [CGRect], pushes: [Push], zones: [[LayoutProblem.Obstacle]]? = nil, slides: [Slide] = []) {
        self.rects = rects
        self.pushes = pushes
        self.zones = zones ?? rects.map { _ in [] }
        self.slides = slides
    }

    /// A free box that would have crossed its holder's edge on the axis its placement leaves free (a
    /// lone direction centers it there), and was slid along it until it was inside.
    public struct Slide: Sendable, Equatable {
        /// Its place in `free`.
        public var box: Int
        /// Which way it went: right, left, below or above.
        public var way: Direction
        /// What it stays inside.
        public var inside: LayoutProblem.Ref

        public init(box: Int, way: Direction, inside: LayoutProblem.Ref) {
            self.box = box
            self.way = way
            self.inside = inside
        }
    }

    /// For each free box, what it was pushed past, in order, each once: what it was kept clear of
    /// itself, not what a box it moved along with was.
    public var pushedPast: [[LayoutProblem.Ref]] {
        var past = Array(repeating: [LayoutProblem.Ref](), count: rects.count)
        for push in pushes where push.along == nil && !past[push.box].contains(push.past) { past[push.box].append(push.past) }
        return past
    }

    /// A free box pushed past another box to keep clear of it, or moved along with one that was.
    public struct Push: Sendable, Equatable {
        /// Its place in `free`.
        public var box: Int
        /// What it keeps clear of: another free box, or an obstacle.
        public var past: LayoutProblem.Ref
        /// Which way it went: right, left, below or above.
        public var way: Direction
        /// The free box pushed past `past` that it went along with, when it wasn't that box itself:
        /// it's placed against that one (centered on it, say), or that one against it. Nil when it
        /// was pushed itself.
        public var along: Int?
        /// Whether each of its own placements on the axis it went along still holds as written once
        /// everything is placed: it's as close to what it's placed against as they say, and still
        /// centered on or level with what it was (it moved with them). False when one of them now
        /// leaves more room than it says (a direction's gap grew). Alignments and centering always
        /// hold, since a box is never pushed along an axis they hold it on (held on both is
        /// `unordered`; an alignment to several shapes a push moved apart is `no_room`): only a
        /// direction's gap can grow.
        public var placementsHold: Bool

        public init(box: Int, past: LayoutProblem.Ref, way: Direction, along: Int? = nil, placementsHold: Bool = false) {
            self.box = box
            self.past = past
            self.way = way
            self.along = along
            self.placementsHold = placementsHold
        }
    }
}
