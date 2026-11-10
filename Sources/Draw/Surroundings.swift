import Canvas
import CoreGraphics
import Adornments
import DrawScript
import Geometry
import Topology

// Draw's placement for plugins: where shapes land beside, in or anywhere on a board; Moving's solver, for every plugin that puts shapes down.
// Where moved shapes land, worked out as `canvas draw` places a shape (DrawLayout, beside this file): a
// layout problem for DrawScript's solver, with the box around them as its one free box and the shapes of
// the board they land on as its obstacles. It's put down anew, as a new shape is (no `current`): where
// they are now holds them nowhere, and they're in their own way nowhere.

/// Where moved shapes go: the board, the box around them there, and the shapes there they're raised
/// above, as draw raises a shape over the zones it sits on and what it's drawn inside.
public struct Landing: Equatable {
    public let board: BoardID
    public let rect: CGRect
    public var above: [ShapeID] = []

    public init(board: BoardID, rect: CGRect, above: [ShapeID] = []) {
        self.board = board
        self.rect = rect
        self.above = above
    }
}

/// How a shape put down for a person, beside another or anywhere (Insert, ⇧↩, a new type), goes: where the person sees it,
/// in the clear part of the view (`reading.view`, as the chrome is headed, less the corner the minimap covers, `reading.covered`)
/// with the row of adornments above its top (a title's pill: `above`, world units) inside that part too, `margin` in from its
/// edges and that corner.
public struct PutBeside: Sendable, Equatable {
    /// World units over the box's top that must be in view too.
    public var above: CGFloat
    /// World units kept in from the view's edges.
    public var margin: CGFloat
    /// Whether the view will be panned to what's put down (Insert's: the selection is brought into view, the shape it's beside
    /// kept with it), so a side counts as seen when the two fit in the clear part together; else (a note put down settled, the
    /// keyboard staying where it is) only one in the clear part as it is.
    public var panned: Bool
    /// Whether it's put beside the selection as the next of a run of them (Insert, ⇧↩), so a chain reads in order: a side
    /// that reads backward (left, above) never wins over one that reads on (right, below) that is seen, with a pan or without.
    public var inOrder: Bool

    public init(above: CGFloat, margin: CGFloat, panned: Bool = false, inOrder: Bool = false) {
        self.above = above
        self.margin = margin
        self.panned = panned
        self.inOrder = inOrder
    }

    /// The row above a shape (Adornments' `rowGap + rowHeight`, 27 view points) and `PlacingStyle.viewMargin`, at `zoom`.
    @MainActor
    public static func inView(at zoom: CGFloat, panned: Bool = false, inOrder: Bool = false) -> PutBeside {
        let zoom = zoom > 0 && zoom.isFinite ? zoom : 1
        return PutBeside(above: (AdornmentLayout.rowGap + AdornmentLayout.rowHeight) / zoom, margin: PlacingStyle.viewMargin / zoom,
                         panned: panned, inOrder: inOrder)
    }

    /// The same at the zoom `editor`'s camera is headed for.
    @MainActor
    public static func inView(of editor: CanvasEditor, panned: Bool = false, inOrder: Bool = false) -> PutBeside {
        inView(at: editor.cameraTarget.zoom, panned: panned, inOrder: inOrder)
    }

    /// The part of `view` (world units) a box goes in, with its row above: in from the edges and the covered corners (`covered`,
    /// the minimap's) by the margin.
    func clear(of view: CGRect, covered: [CGRect] = []) -> ClearView {
        ClearView(rect: view, covered: covered).insetBy(margin)
    }

    /// Whether `rect`, with its row above, is seen in `clear`: in it, or, `panned`, able to be panned into it with `beside`
    /// (the shape it's put down beside, with its row above too), by the least pan, as the camera pans (`ClearView.shift`).
    func shows(_ rect: CGRect, in clear: ClearView, beside: CGRect? = nil) -> Bool {
        let shown = withRow(rect)
        guard panned, let beside else { return clear.contains(shown) }
        let both = shown.union(withRow(beside))
        let pan = clear.shift(bringing: both)
        return clear.contains(both.offsetBy(dx: pan.width, dy: pan.height))
    }

    /// Whether the least pan that brings `rect` and `beside` (each with its row above) into `clear` takes any of `shown` (rects
    /// wholly in `clear` now) out of it.
    func pansAway(from shown: [CGRect], toShow rect: CGRect, beside: CGRect, in clear: ClearView) -> Bool {
        let both = withRow(rect).union(withRow(beside))
        let pan = clear.shift(bringing: both)
        guard pan != .zero else { return false }
        return shown.contains { clear.contains($0) && !clear.contains($0.offsetBy(dx: pan.width, dy: pan.height)) }
    }

    private func withRow(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: rect.minY - above, width: rect.width, height: rect.height + above) }
}

/// The constants of placing for plugins.
@MainActor
public enum PlacingStyle {
    /// The sides `near` tries, in order: of the sides that land as near the shape, the first wins.
    public static let sides: [Direction] = [.right, .below, .left, .above]
    /// The corners `inside` tries in a frame, in reading order: the first with room wins.
    public static let corners: [Part] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
    /// The room an arrow to or from a shape placed between two others needs, between the two edges it
    /// joins: a body long enough to show a head and read as an arrow, as draw's `normal` gap leaves one.
    public static let arrowRoom: CGFloat = GapName.normal.value
    /// How far in from the clear part of the view's edges a shape put down for a person lands (`PutBeside`), in view points.
    public static let viewMargin: CGFloat = 16
    /// How far from the shape it's joined to a pill an arrow reaches from a row lands (`landing(of:joinedFrom:of:)`): room for the
    /// arrow's own pill (`calls`) on the line between them, and its head.
    public static let pillReach: CGFloat = 120
    /// How many reaches out a pill is tried at, on each side, before it's landed as draw lands one.
    public static let pillSteps = 3
    /// How far out from a row's end the mark at a line's end there reaches, with the room the line needs to turn after it (the
    /// longest, a bar and a circle, 30, and 6): a pill a line between rows (a key) joins below the shape is slid out past it, so the
    /// line leaves the row's side level and bends after its mark (`landing(of:joinedFrom:of:)`'s `level`).
    public static let markRoom: CGFloat = 36
    /// The line a pill stands at the end of shows this much either side of the label it carries (a channel's pill: `reads`), its
    /// head's run and its own: a pill put down for such an arrow is at least the label's width and twice this from its start.
    public static let labelEndRoom: CGFloat = 40
    /// Between two such labels on lines from one start to pills one above the other: the pills are spaced so the labels, halfway
    /// along, are this far apart.
    public static let labelSpacing: CGFloat = 16
    /// How far another arrow's line keeps from the label a pill's arrow will carry, as a move places the pill (connect new-4: a
    /// calls line never runs under the reads pill).
    public static let labelClearance: CGFloat = 6

    /// The sides of `bounds` a shape whose arrows reach `reached` may go on so they run clean: the one facing it (along the axis
    /// it lies further out on; overlapping, the way its middle lies, by each axis's share of `bounds`), then below; facing above,
    /// above, then left and right. Never the far side of `bounds` from what the arrows reach (New Version's copy, UX walk 3 evolve-1).
    public static func sides(of bounds: CGRect, facing reached: CGRect) -> [Direction] {
        let dx = reached.minX >= bounds.maxX ? reached.minX - bounds.maxX : reached.maxX <= bounds.minX ? reached.maxX - bounds.minX : 0
        let dy = reached.minY >= bounds.maxY ? reached.minY - bounds.maxY : reached.maxY <= bounds.minY ? reached.maxY - bounds.minY : 0
        let facing: Direction
        if dx == 0 && dy == 0 {
            let cx = reached.midX - bounds.midX, cy = reached.midY - bounds.midY
            facing = abs(cx) / max(bounds.width, 1) >= abs(cy) / max(bounds.height, 1) ? (cx >= 0 ? .right : .left) : (cy >= 0 ? .below : .above)
        } else if abs(dx) >= abs(dy) {
            facing = dx > 0 ? .right : .left
        } else {
            facing = dy > 0 ? .below : .above
        }
        switch facing {
        case .above: return [.above, .left, .right]
        case .below: return [.below]
        default: return [facing, .below]
        }
    }
}

/// A board shapes land on, as `canvas draw` reads the board it places shapes on: read in place
/// (`editor.reading(of:)`, shown or not), every shape there with a solid (`ShapeContext.solidBounds(of:)`)
/// an obstacle, in paint order, numbered by its place in the document, filed once in an `ObstacleGrid`,
/// which keeps each answer for the problems asked of it. On the moving shapes' own board they're no
/// obstacles, and what they hold goes with them (`LayoutProblem.Free.carries`), so it's never in their
/// way. They land as one box, the box around them all.
@MainActor
public struct Surroundings {
    public let reading: BoardReading
    private let grid: ObstacleGrid
    /// The moving shapes' size, all together: the free box's.
    private let size: CGSize
    /// What the shapes hold, by place in the document, on their own board; none on another.
    private let carries: Set<Int>
    /// The middle of the view the board would be shown with (draw's), where a shape with nothing to hang
    /// on goes.
    private let viewMiddle: CGPoint
    /// What joins shapes, for a put beside one for a person: a pan only takes away what's joined to it (`PutBeside`).
    private weak var topology: TopologyIndex?
    /// The room a kind that grows as rows are typed keeps clear below it (`Registry.roomKeptBelow`), of a shape on this board, and
    /// of the shapes that move together as one box (the most any keeps): a box put below one is spaced past it, as draw's solver spaces it.
    private let keeps: (ShapeID) -> CGFloat
    private let movingKeeps: CGFloat

    /// `board` as it is now, for a box of `size` to land on; nil for a board the editor can't show or a
    /// size that isn't one. `carrying` are the shapes that make the box and go with it (the shapes moved,
    /// each a moving shape of their own board, so no obstacle there); `held` is what they hold, at any
    /// depth, which goes along and is never in their way. Both are of one board, and matter only when
    /// that is `board`: a new shape, or shapes landing on another board, pass none.
    public init?(on board: BoardID, moving size: CGSize, carrying: [ShapeID] = [], held: [ShapeID] = [], in editor: CanvasEditor) {
        guard let reading = editor.reading(of: board), size.width.isFinite, size.height.isFinite else { return nil }
        self.reading = reading
        self.size = size
        let own = carrying.first.map { editor.file.board(containing: $0) == board } ?? false
        let document = reading.document, shapes = reading.shapes, moving = Set(carrying)
        var obstacles: [LayoutProblem.Obstacle] = []
        for record in reading.paintOrder() where !(own && moving.contains(record.id)) {
            guard let rect = shapes.solidBounds(of: record.id), let index = document.index(of: record.id) else { continue }
            obstacles.append(LayoutProblem.Obstacle(id: index, rect: rect))
        }
        grid = ObstacleGrid(obstacles)
        carries = own ? Set(held.compactMap { document.index(of: $0) }) : []
        viewMiddle = reading.view.map { CGPoint(x: $0.midX, y: $0.midY) } ?? shapes.camera.toWorld(.zero)
        topology = editor.topology
        let registry = editor.registry
        keeps = { id in document[id].map { registry.roomKeptBelow($0.kind) } ?? 0 }
        movingKeeps = carrying.compactMap { document[$0] }.map { registry.roomKeptBelow($0.kind) }.max() ?? 0
    }

    /// Beside `target`: on each of its four sides in turn (`PlacingStyle.sides`), placed as draw places
    /// `right of "X"`, draw's normal gap from it and centered on it the other way, and pushed out along
    /// that side's axis past whatever's in its way there (the solver's separation). The side that lands
    /// nearest it wins, the earlier on a tie: so the first side that's free, and with none free, the one
    /// that frees up nearest. A side the solver can't place is passed over; with none placed, it's right
    /// of the target, centered, over what's there. Nil for a target with nothing drawn to be beside.
    ///
    /// `within` a container (a frame the target is in, at any depth), each side is kept within it too,
    /// as draw keeps a shape `in "F"` (its holder, held directly: a frame in it is in its way); with no
    /// side placed there, it's put in the container as `inside(_:)` puts it, and raised above it.
    ///
    /// `put` is how a shape put down beside another for a person goes (Insert, ⇧↩, a new type beside the shapes that name
    /// it): top-aligned with it on its right or left (`top level with`, as two tables side by side are drawn), and on a side
    /// in the clear part of the view where one is (`PutBeside.inView`), the nearest of those, so it is never put down out of
    /// sight, under the inspector or under the minimap while a side in view is free. A side seen only by a pan that takes out of
    /// view a shape it shows whole that is joined to the target (an edge of any type, either way: a key, an arrow, a type's is-a,
    /// a mention) or holds it ranks under a side seen as the view is: what the person is working with stays in view, while a
    /// chain of shapes joined to nothing goes on right, panning (T1 panel 3). Put `inOrder` (Insert), a side that reads
    /// backward (left, above) never wins over one that reads on (right, below) that is seen at all.
    ///
    /// `sides` are the sides tried, in order (all four by default): a caller that knows which way the shape's arrows run (New
    /// Version's copy, toward what its copied arrows reach) names only those that keep them clean.
    public func near(_ target: ShapeID, within holder: ShapeID? = nil, put: PutBeside? = nil, sides: [Direction] = PlacingStyle.sides) -> Landing? {
        guard let bounds = reading.shapes.geometry(of: target)?.bounds else { return nil }
        return near(bounds, obstacle: obstacle(target), within: holder, avoiding: [], sides: sides, put: put, besides: [target], roomBelow: keeps(target))
    }

    /// Beside a box that is not a shape of the board yet (or not there any more): as `near(_:within:)`
    /// lands beside a shape with these bounds. `avoiding` are boxes a caller has planned and not put
    /// down, which the landing keeps clear of as of any shape there. `besides` are the shapes the box is around (the selection),
    /// whose joined shapes a `put`'s pan keeps in view.
    public func near(_ rect: CGRect, avoiding: [CGRect] = [], within holder: ShapeID? = nil, put: PutBeside? = nil,
                     sides: [Direction] = PlacingStyle.sides, besides: [ShapeID] = []) -> Landing? {
        near(rect, obstacle: nil, within: holder, avoiding: avoiding, sides: sides, put: put, besides: besides)
    }

    private func near(_ bounds: CGRect, obstacle targetObstacle: Int?, within holder: ShapeID?, avoiding: [CGRect],
                      sides: [Direction] = PlacingStyle.sides, put: PutBeside? = nil, besides: [ShapeID] = [], roomBelow: CGFloat? = nil) -> Landing? {
        guard !bounds.isNull, bounds.isFinite else { return nil }
        // A point to land beside (the middle of two shapes) is no shape: it has no area, so a shape under it would be held by it at
        // any size (the solver's zone (a)) and landed on. Marked as the board, nothing is a zone of it and what is under it is in the way.
        var fixed = [LayoutProblem.Fixed(rect: bounds, obstacle: targetObstacle, word: bounds.width * bounds.height == 0 ? .board : nil)]
        // Below a shape that keeps room as it grows, at least that room; a box that keeps room, the same above what it's put above.
        fixed[0].roomBelow = roomBelow ?? besides.map(keeps).max() ?? 0
        var held: LayoutProblem.Holder?
        if let holder, let holding = reading.shapes.geometry(of: holder)?.bounds, !holding.isNull, holding.isFinite {
            fixed.append(LayoutProblem.Fixed(rect: holding, obstacle: obstacle(holder)))
            held = LayoutProblem.Holder(.fixed(1), written: "in \(Self.holder)", direct: true)
        }
        var best: (rect: CGRect, gap: CGFloat, zones: [ShapeID], seen: Int, onward: Bool)?
        let view = put.flatMap { put in reading.view.map { put.clear(of: $0, covered: reading.covered) } }
        // The shapes wholly in view joined to what it's put beside, or holding it: what a pan may not take away. Worked out once,
        // when a side needs a pan.
        var kept: [CGRect]?
        for side in sides {
            var clauses = [LayoutProblem.ResolvedClause(relation: .direction(side), targets: [LayoutProblem.ResolvedTarget(.fixed(0), written: Self.target)],
                                                        written: "\(side.rawValue) \(Self.target)")]
            if put != nil, side == .right || side == .left {
                clauses.append(LayoutProblem.ResolvedClause(relation: .level(.top), targets: [LayoutProblem.ResolvedTarget(.fixed(0), written: Self.target)],
                                                            written: "top level with \(Self.target)"))
            }
            var free = LayoutProblem.Free(line: 1, name: Self.moving, size: size, clauses: clauses, holder: held, carries: carries)
            free.roomBelow = movingKeeps
            guard let placed = place(free, fixed: fixed, avoiding: avoiding)
            else { continue }
            let gap = Self.gap(from: bounds, to: placed.rect, side)
            // How it's seen: in the clear view (3: as it is, or once the view pans to it with the shape it's beside, a put that
            // pans); by a pan that takes out of view a shape it shows whole that is joined to the target or holds it (1: UX walk 3
            // tables-1, Insert ▸ Enum beside orders panned customers, keyed to orders, off screen), or not at all (0).
            var seen = 3
            if let view, let put {
                if !put.shows(placed.rect, in: view, beside: bounds) {
                    seen = 0
                } else if put.panned {
                    if kept == nil { kept = joined(to: besides, in: view.rect) }
                    if put.pansAway(from: kept ?? [], toShow: placed.rect, beside: bounds, in: view) { seen = 1 }
                }
            }
            // Read on: right or below, for a put in order; every side alike otherwise.
            let onward = put?.inOrder == true && (side == .right || side == .below)
            // A side seen at all beats one out of view; then, put in order, one that reads on beats one that reads backward; then a
            // side seen beats one seen by a pan that loses what the person works with; among sides alike, the nearer, the earlier
            // on a tie.
            let better = best.map { best in
                if (seen > 0) != (best.seen > 0) { return seen > 0 }
                if onward != best.onward { return onward }
                return seen != best.seen ? seen > best.seen : gap < best.gap - Self.slack
            } ?? true
            if better { best = (placed.rect, gap, placed.zones, seen, onward) }
        }
        guard let best else {
            if let holder, held != nil { return inside(holder) }
            // None placed: on the first side asked (right, by default), the normal gap off it, centered, over what's there.
            let gap = GapName.normal.value
            let rect: CGRect = switch sides.first ?? .right {
            case .left: CGRect(x: bounds.minX - gap - size.width, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            case .below: CGRect(x: bounds.midX - size.width / 2, y: bounds.maxY + gap, width: size.width, height: size.height)
            case .above: CGRect(x: bounds.midX - size.width / 2, y: bounds.minY - gap - size.height, width: size.width, height: size.height)
            default: CGRect(x: bounds.maxX + gap, y: bounds.midY - size.height / 2, width: size.width, height: size.height)
            }
            return Landing(board: reading.board, rect: rect)
        }
        return Landing(board: reading.board, rect: best.rect, above: best.zones + (held == nil ? [] : [holder].compactMap { $0 }))
    }

    /// The rects of the shapes in the view the board is read with (`reading.view`, world units) joined to `ids` by an edge
    /// Topology knows, either way, or holding one of them: what a pan for a shape put down for a person working with `ids` may
    /// not take away (UX walk 3 tables-1, walk 5 apis-5-1). None with no view, or without Topology.
    public func joinedInView(to ids: [ShapeID]) -> [CGRect] {
        guard let view = reading.view else { return [] }
        return joined(to: ids, in: view)
    }

    /// The rects of the shapes in `view` (world units) joined to `ids` by an edge Topology knows, either way, or holding one of
    /// them: what a person working with `ids` keeps in view as a shape is put down beside them. None without Topology.
    private func joined(to ids: [ShapeID], in view: CGRect) -> [CGRect] {
        guard !ids.isEmpty else { return [] }
        var joined: Set<ShapeID> = []
        for id in ids {
            if let topology { for (_, ends) in topology.neighbors(of: id) { joined.formUnion(ends) } }
            // Every holder up the chain, whether or not an edge named it already.
            var seen: Set<ShapeID> = []
            var up = reading.shapes.container(of: id)
            while let holder = up, seen.insert(holder).inserted {
                joined.insert(holder)
                up = reading.shapes.container(of: holder)
            }
        }
        joined.subtract(ids)
        guard !joined.isEmpty else { return [] }
        let shapes = reading.document.shapes
        return grid.obstacles(in: view).compactMap { obstacle in
            shapes.indices.contains(obstacle.id) && joined.contains(shapes[obstacle.id].id) ? obstacle.rect : nil
        }
    }

    /// Between two shapes, which an arrow from the first to it and another from it to the second join:
    /// across the gap the two leave between them, along the axis they are further apart on (the other if
    /// the gap there can't hold it), centered in it and on the middle of the two across, with the room
    /// each arrow needs (`room`, by default `PlacingStyle.arrowRoom`; a caller whose arrows carry names asks for more) left clear on each side, so each shows a body. The two
    /// are read `growing` taller, as the caller is about to give each a row. Where that spot is taken
    /// (something on the board in it, but the frames the two are in, which it is raised above) or neither gap holds it, beside the middle of the two as `near`
    /// lands beside a box, clear of both: the nearer of the two sides across the line between them, never
    /// along it. With one shape drawn, beside it (`near`); none, nil.
    public func between(_ first: ShapeID, _ second: ShapeID, growing: CGFloat = 0, room: CGFloat? = nil) -> Landing? {
        func grown(_ id: ShapeID) -> CGRect? {
            guard var bounds = reading.shapes.geometry(of: id)?.bounds, !bounds.isNull, bounds.isFinite else { return nil }
            bounds.size.height += max(0, growing)
            return bounds
        }
        guard let a = grown(first), let b = grown(second) else { return grown(first) == nil ? near(second) : near(first) }
        let middle = CGPoint(x: (a.midX + b.midX) / 2, y: (a.midY + b.midY) / 2)
        let room = room ?? PlacingStyle.arrowRoom
        // The gaps the two leave along each axis, the wider first; those that hold the box and its arrows' rooms.
        let apart = [(horizontal: true, gap: max(b.minX - a.maxX, a.minX - b.maxX), start: min(a.maxX, b.maxX), size: size.width),
                     (horizontal: false, gap: max(b.minY - a.maxY, a.minY - b.maxY), start: min(a.maxY, b.maxY), size: size.height)]
            .sorted { $0.gap > $1.gap }
        let gaps = apart.filter { $0.gap >= $0.size + 2 * room }
        // The frames the two are in, at any depth, are regions the box sits on, not in its way (the solver's zones).
        var frames: [ShapeID] = []
        for id in [first, second] {
            var up = reading.shapes.container(of: id)
            while let frame = up, !frames.contains(frame) { frames.append(frame); up = reading.shapes.container(of: frame) }
        }
        let theirs = ([first, second] + frames).compactMap { obstacle($0) }
        if let axis = gaps.first {
            let along = axis.start + (axis.gap - axis.size) / 2
            let rect = axis.horizontal
                ? CGRect(x: along, y: middle.y - size.height / 2, width: size.width, height: size.height)
                : CGRect(x: middle.x - size.width / 2, y: along, width: size.width, height: size.height)
            let wanted = rect.insetBy(dx: -LayoutProblem.horizontalClearance, dy: -LayoutProblem.verticalClearance)
            if !grid.obstacles(in: wanted).contains(where: { !theirs.contains($0.id) && $0.rect.intersects(wanted) }) {
                return Landing(board: reading.board, rect: rect, above: frames)
            }
        }
        // Beside the middle, across the line between the two.
        return near(CGRect(origin: middle, size: .zero), obstacle: nil, within: nil, avoiding: [a, b],
                    sides: apart[0].horizontal ? [.below, .above] : [.right, .left])
    }

    /// In `container`, a shape on this board that holds shapes (a frame), as draw places a shape
    /// `in "F"`: against its top-left, draw's tight gap in (`inside "F" top-left`), pushed clear of what's
    /// in it and kept within it (the frame its holder); with no room that way, against each of its other
    /// corners in turn (`PlacingStyle.corners`), pushed the other ways. It goes in the frame itself
    /// (`Holder.direct`): a frame in it is in its way like any shape there, never a zone it lands in, so
    /// `/move-to` a frame doesn't leave it in one nested in that frame where there's room beside. With
    /// no room from any corner, at its top-left all the same, as far in (less, where it's barely bigger
    /// than the shape: half the room it has), over what's there. It's raised above the zones it sits on
    /// and the frame, as draw raises a shape over what it's drawn inside. Nil for a frame with nothing
    /// drawn.
    public func inside(_ container: ShapeID) -> Landing? {
        guard let bounds = reading.shapes.geometry(of: container)?.bounds, !bounds.isNull, bounds.isFinite else { return nil }
        let fixed = LayoutProblem.Fixed(rect: bounds, obstacle: obstacle(container))
        let written = "in \(Self.target)"
        for corner in PlacingStyle.corners {
            let clause = LayoutProblem.ResolvedClause(relation: .inside, targets: [LayoutProblem.ResolvedTarget(.fixed(0), part: corner, written: Self.target)],
                                                       written: written)
            let free = LayoutProblem.Free(line: 1, name: Self.moving, size: size, clauses: [clause],
                                          holder: LayoutProblem.Holder(.fixed(0), written: written, direct: true), carries: carries)
            if let placed = place(free, fixed: [fixed]) { return Landing(board: reading.board, rect: placed.rect, above: placed.zones + [container]) }
        }
        let gap = GapName.tight.value
        let inset = CGSize(width: min(gap, max(0, (bounds.width - size.width) / 2)), height: min(gap, max(0, (bounds.height - size.height) / 2)))
        return Landing(board: reading.board, rect: CGRect(origin: CGPoint(x: bounds.minX + inset.width, y: bounds.minY + inset.height), size: size),
                       above: [container])
    }

    /// Whether a box landed at `rect` shows in the clear part of the view as `put` asks (with its row above, in from the edges):
    /// what a caller that puts a shape down settled, never panned to, checks a landing beside a shape by before it falls back
    /// to `anywhere(put:)`. True with no view.
    public func shows(_ rect: CGRect, put: PutBeside) -> Bool {
        guard let view = reading.view else { return true }
        var settled = put
        settled.panned = false
        return settled.shows(rect, in: put.clear(of: view, covered: reading.covered))
    }

    /// Anywhere on the board, as draw puts the one shape a script says nothing about the place of (no
    /// placements, and not on the board yet): at the middle of the view the board would be shown with,
    /// or the nearest spot around it clear of what's there, ring by ring; failing that, at the middle
    /// all the same.
    ///
    /// `put` (Insert's, for a person): at the nearest spot that is in the clear part of the view with the row above it
    /// (`PutBeside`), where one is clear, before any out of it.
    public func anywhere(put: PutBeside? = nil) -> Landing {
        let room = put.flatMap { put in reading.view.map { (put.clear(of: $0, covered: reading.covered), put.above) } }
        let rect = place(LayoutProblem.Free(line: 1, name: Self.moving, size: size, carries: carries), inView: room)?.rect
            ?? CGRect(x: viewMiddle.x - size.width / 2, y: viewMiddle.y - size.height / 2, width: size.width, height: size.height)
        return Landing(board: reading.board, rect: rect)
    }

    /// Where Insert puts a shape of `size` down on the board shown (the core's insertion spot, which
    /// Draw's plugin claims): beside one shape as `near` lands beside it, within the container it's in;
    /// beside several as beside the box around them, within the container they share; with none
    /// `anywhere`, in the middle of the view or the nearest spot round it clear of what's there. Nil with
    /// none and no view, or a board the editor can't read.
    ///
    /// For a person (`PutBeside.inView`): beside a shape it is top-aligned with it, and it goes on a side, or to a spot, in
    /// the clear part of the view (as it will be once the inspector the new shape's selection shows is in) with the row
    /// above it (its title's pill), where one is free.
    static func insertionSpot(of size: CGSize, beside shapes: [ShapeID], in editor: CanvasEditor) -> CGRect? {
        guard let surroundings = Surroundings(on: editor.board, moving: size, in: editor) else { return nil }
        let containers = Set(shapes.map { editor.shapeContext.container(of: $0) })
        let holder = containers.count == 1 ? containers.first ?? nil : nil
        // Selected and brought into view once put down, with what it's beside kept in view (Selection's); the next of a run, in order.
        let put = PutBeside.inView(of: editor, panned: true, inOrder: true)
        switch shapes.count {
        case 0: return surroundings.reading.view == nil ? nil : surroundings.anywhere(put: put).rect
        case 1: return surroundings.near(shapes[0], within: holder, put: put)?.rect
        default:
            let bounds = shapes.compactMap { surroundings.reading.shapes.geometry(of: $0)?.bounds }.reduce(CGRect.null) { $0.union($1) }
            return surroundings.near(bounds, within: holder, put: put, besides: shapes)?.rect
        }
    }

    /// A stand-in (a pill) of `size` at `spot`, as `canvas draw` places the one it makes for an edge:
    /// against the shape it is beside, or, in a column of pills there, past the last (`StandInRoute`
    /// says where; its placements are the ones a script's statement gets). The box is a made-up one
    /// (`Free.implied`), like draw's. Nil for a spot with nothing drawn to be placed against.
    ///
    /// `planned`, for a pill beside a shape or a pill that is not on the board yet (one a move is bringing here), is the box
    /// the pill is placed against, as the spot's `after` or `near` would be if it were drawn: no obstacle of the board's, so it
    /// is held clear by the caller's `avoiding` if at all.
    func landing(of size: CGSize, at spot: StandInSpot, planned: CGRect? = nil, avoiding: [CGRect] = []) -> Landing? {
        guard size.width.isFinite, size.height.isFinite else { return nil }
        let against = spot.after ?? spot.near
        let bounds: CGRect, solid: Int?
        if let planned {
            (bounds, solid) = (planned, nil)
        } else {
            guard let found = reading.shapes.geometry(of: against)?.bounds else { return nil }
            (bounds, solid) = (found, obstacle(against))
        }
        guard !bounds.isNull, bounds.isFinite else { return nil }
        let clauses = spot.clauses(near: Self.target, after: spot.after == nil ? nil : Self.column).map {
            LayoutProblem.ResolvedClause($0, refs: [.fixed(0)])
        }
        let free = LayoutProblem.Free(line: 1, name: Self.moving, size: size, clauses: clauses, implied: true)
        guard let placed = place(free, fixed: [LayoutProblem.Fixed(rect: bounds, obstacle: solid)], avoiding: avoiding) else { return nil }
        return Landing(board: reading.board, rect: placed.rect, above: placed.zones)
    }

    /// A pill of `size` an arrow joins to row `row` (its rect, world units) of `near`, a shape of this board, landed where the
    /// arrow reads clean: where the straight line from the row to the pill crosses no shape. Tried in order (E4 panel 4): below
    /// `near`, under one of the row's ends (the left first), the line meeting the pill's top; then right of it, then left, level
    /// with the row (the pill's middle at the row's middle), so the line meets the pill's near side and never its bottom from
    /// below; each a reach out (`PlacingStyle.pillReach`), then farther. A spot counts where the pill is within the clear view,
    /// clear of what is on the board (but `near` and what holds it) and of `avoiding` by draw's clearances, and its line crosses
    /// none of them. `bounds`: `near`'s where the caller's step changes them (rows added), else the board's. Nil where none does: the
    /// caller lands it as draw does (`landing(of:at:)`).
    ///
    /// `level`, for a line between two rows (a key, the far row on the binding of a pill for its shape: its ends carry marks):
    /// level with the row first, left of `near` then right (T3 panel 4, T6 panel 3), so the line leaves the row's side straight;
    /// then below, the pill slid out past the row's end by the mark's room (`PlacingStyle.markRoom`), never under the end, so the
    /// line leaves the side and turns after its mark.
    ///
    /// `labels`: the labels the arrows already at `near` carry (a channel's pill, `reads`): the line crosses none of them, so a
    /// line never runs under another arrow's label and reads as labeled by it. `inView` false for a caller that puts shapes where
    /// the board is not shown, or where its move leaves them (a move's pills): a spot need not be in the view. A box of
    /// `avoiding` that holds `near` (a frame that moves with it) is a region the pill may sit on, as a shape of the board is.
    public func landing(of size: CGSize, joinedFrom row: CGRect, of near: ShapeID, bounds nearBounds: CGRect? = nil,
                        avoiding: [CGRect] = [], level: Bool = false, labels: [CGRect] = [], inView: Bool = true) -> Landing? {
        guard size.width.isFinite, size.height.isFinite, row.isFinite, !row.isNull,
              let bounds = nearBounds ?? reading.shapes.geometry(of: near)?.bounds, bounds.isFinite, !bounds.isNull else { return nil }
        let own = obstacle(near)
        // What holds `near` (a frame or a database it is in) is a region the pill may sit wholly on, or wholly off, never across its
        // edge; a line may run over it. Every other shape is in the way of the pill, and of the line.
        func holds(_ obstacle: LayoutProblem.Obstacle) -> Bool { obstacle.id != own && obstacle.rect.contains(bounds) }
        func inWay(_ obstacle: LayoutProblem.Obstacle) -> Bool { obstacle.id != own && !holds(obstacle) }
        func straddles(_ obstacle: LayoutProblem.Obstacle, _ rect: CGRect) -> Bool { holds(obstacle) && obstacle.rect.intersects(rect) && !obstacle.rect.contains(rect) }
        let reach = PlacingStyle.pillReach, width = size.width, height = size.height
        // The rows of `near` under the one the arrow leaves: a line slid in under the shape must not cut across them.
        let below = CGRect(x: bounds.minX, y: row.maxY, width: bounds.width, height: max(0, bounds.maxY - row.maxY))
        var spots: [(rect: CGRect, from: CGPoint, to: CGPoint)] = []
        func belowSpots() {
            // A line between rows leaves the row's side level for its mark's room before it turns: never under the end, nor in.
            let room = PlacingStyle.markRoom
            let slides: [(CGFloat, Bool)] = level ? [(room + width / 2, false), (room + width, false)]
                : [(0, false), (width / 2, false), (-width / 2, true), (width, false)]
            for step in 1...PlacingStyle.pillSteps {
                let out = reach * CGFloat(step)
                for end in [row.minX, row.maxX] {
                    let outward: CGFloat = end == row.minX ? -1 : 1
                    // Under the row's end, else slid out from under the shape, else in: the line still meets the top, steep as it is,
                    // but only where it leaves the shape's body alone (the row is its last): straight down from the end of a row
                    // with rows under it runs along the shape's own side, so there the pill goes beside the row instead.
                    for (amount, inward) in slides {
                        let slide = outward * amount, middle = end + slide
                        // The row leaves by the end facing the pill's middle: this one.
                        guard (middle < row.midX) == (end == row.minX) else { continue }
                        let rect = CGRect(x: middle - width / 2, y: bounds.maxY + out, width: width, height: height)
                        let from = CGPoint(x: end, y: row.midY), to = CGPoint(x: middle, y: rect.minY)
                        if inward, Self.crosses(from, to, below) { continue }
                        if slide == 0, below.height > row.height / 2 { continue }
                        spots.append((rect, from, to))
                    }
                }
            }
        }
        func levelSpots() {
            for side: CGFloat in level ? [-1, 1] : [1, -1] {
                for step in 1...PlacingStyle.pillSteps {
                    let out = reach * CGFloat(step)
                    let x = side > 0 ? bounds.maxX + out : bounds.minX - out - width
                    let rect = CGRect(x: x, y: row.midY - height / 2, width: width, height: height)
                    spots.append((rect, CGPoint(x: side > 0 ? row.maxX : row.minX, y: row.midY), CGPoint(x: side > 0 ? rect.minX : rect.maxX, y: row.midY)))
                }
            }
        }
        if level {
            levelSpots()
            belowSpots()
        } else {
            belowSpots()
            levelSpots()
        }
        let finite = avoiding.filter(\.isFinite)
        // A box planned that holds `near` (the frame it moves with) is a region, as a shape of the board that holds it is.
        let regions = finite.filter { $0.contains(bounds) && $0 != bounds }
        let planned = finite.filter { !($0.contains(bounds) && $0 != bounds) }
        for spot in spots {
            if inView, let view = reading.view, !view.contains(spot.rect) { continue }
            let wanted = spot.rect.insetBy(dx: -LayoutProblem.horizontalClearance, dy: -LayoutProblem.verticalClearance)
            guard !grid.obstacles(in: wanted).contains(where: { ($0.rect.intersects(wanted) && inWay($0)) || straddles($0, spot.rect) }),
                  !planned.contains(where: { $0.intersects(wanted) }),
                  !regions.contains(where: { $0.intersects(spot.rect) && !$0.contains(spot.rect) }) else { continue }
            let line = CGRect(x: min(spot.from.x, spot.to.x), y: min(spot.from.y, spot.to.y),
                              width: abs(spot.to.x - spot.from.x), height: abs(spot.to.y - spot.from.y)).insetBy(dx: -1, dy: -1)
            guard !grid.obstacles(in: line).contains(where: { inWay($0) && Self.crosses(spot.from, spot.to, $0.rect) }),
                  !planned.contains(where: { Self.crosses(spot.from, spot.to, $0) }),
                  !labels.contains(where: { Self.crosses(spot.from, spot.to, $0) }) else { continue }
            // Raised above what holds `near` that it sits on, as draw raises a shape over the zones it lands on.
            let shapes = reading.document.shapes
            let holders = grid.obstacles(in: spot.rect).filter { holds($0) && shapes.indices.contains($0.id) }
                .sorted { $0.id < $1.id }.map { shapes[$0.id].id }
            return Landing(board: reading.board, rect: spot.rect, above: holders)
        }
        return nil
    }

    /// Whether a line from row `row` of `near` (its rect, world units) to a pill already at `pill` reads clean, as a pill landed by
    /// `landing(of:joinedFrom:of:)` does: the straight line from the row's end facing the pill's middle to the pill's nearest point
    /// crosses no shape of the board but `near`, what holds it and `standIn` (the pill itself, where it is on the board), none of
    /// `avoiding` and none of `labels` (the labels of the arrows already at `near`); and leaves `near` as a landed one does: it
    /// cuts across none of the rows of `near` under the row, runs down no side of it that has rows beside the line, and for
    /// `level` (a line between rows, its end marked) is level with the row or leaves its end by the mark's room
    /// (`PlacingStyle.markRoom`), never straight under it. What a pill reused for a later line (a key, a move's rebinding) is
    /// asked before it is: where it isn't, a fresh one is put down. `bounds`: `near`'s where the caller's step changes them
    /// (or `near` is not on this board yet), else the board's.
    public func joinsClean(_ row: CGRect, of near: ShapeID, bounds nearBounds: CGRect? = nil, to pill: CGRect, standIn: ShapeID? = nil,
                           avoiding: [CGRect] = [], labels: [CGRect] = [], level: Bool = false) -> Bool {
        guard row.isFinite, !row.isNull, pill.isFinite, !pill.isNull,
              let bounds = nearBounds ?? reading.shapes.geometry(of: near)?.bounds, bounds.isFinite, !bounds.isNull else { return true }
        let own = obstacle(near), standing = standIn.flatMap(obstacle)
        let middle = CGPoint(x: pill.midX, y: pill.midY)
        let from = CGPoint(x: middle.x < row.midX ? row.minX : row.maxX, y: row.midY)
        let to = CGPoint(x: min(max(from.x, pill.minX), pill.maxX), y: min(max(from.y, pill.minY), pill.maxY))
        let line = CGRect(x: min(from.x, to.x), y: min(from.y, to.y), width: abs(to.x - from.x), height: abs(to.y - from.y)).insetBy(dx: -1, dy: -1)
        let crossed = grid.obstacles(in: line).contains { obstacle in
            obstacle.id != own && obstacle.id != standing && !obstacle.rect.contains(bounds) && Self.crosses(from, to, obstacle.rect)
        }
        guard !crossed, !avoiding.filter({ $0.isFinite && !$0.contains(bounds) }).contains(where: { Self.crosses(from, to, $0) }),
              !labels.contains(where: { Self.crosses(from, to, $0) }) else { return false }
        // `near`'s own rows: under this one a line may not cut across them, and straight down (or up) a side with rows beside it
        // runs along the shape's own edge.
        let below = CGRect(x: bounds.minX, y: row.maxY, width: bounds.width, height: max(0, bounds.maxY - row.maxY))
        if Self.crosses(from, to, below) { return false }
        let straight = abs(to.x - from.x) < 0.5 && abs(to.y - from.y) > 0.5
        if straight, to.y > from.y ? below.height > row.height / 2 : row.minY - bounds.minY > row.height / 2 { return false }
        if level, abs(to.y - from.y) > 1, abs(to.x - from.x) < PlacingStyle.markRoom - 0.5 { return false }
        return true
    }

    /// Whether the segment from `a` to `b` passes through `rect`'s inside (touching its edge isn't crossing): Liang and Barsky's
    /// clip against the rect a point in from each edge.
    static func crosses(_ a: CGPoint, _ b: CGPoint, _ rect: CGRect) -> Bool {
        let inner = rect.insetBy(dx: 1, dy: 1)
        guard !inner.isNull, !inner.isEmpty else { return false }
        let dx = b.x - a.x, dy = b.y - a.y
        var t0: CGFloat = 0, t1: CGFloat = 1
        for (p, q) in [(-dx, a.x - inner.minX), (dx, inner.maxX - a.x), (-dy, a.y - inner.minY), (dy, inner.maxY - a.y)] {
            if p == 0 {
                if q < 0 { return false }
                continue
            }
            let r = q / p
            if p < 0 { if r > t1 { return false }; t0 = max(t0, r) } else { if r < t0 { return false }; t1 = min(t1, r) }
        }
        return t0 < t1
    }

    /// The free box placed among the board's obstacles by DrawScript's solver: where it goes, and the
    /// shapes it sits on there (the zones), back to front; nil if the solver can't place it.
    private func place(_ free: LayoutProblem.Free, fixed: [LayoutProblem.Fixed] = [], avoiding: [CGRect] = [],
                       inView room: (view: ClearView, above: CGFloat)? = nil) -> (rect: CGRect, zones: [ShapeID])? {
        let grid = grid, shapes = reading.document.shapes
        // Boxes a caller has planned come after every shape of the board, each its own number.
        let planned = avoiding.filter(\.isFinite).enumerated().map { LayoutProblem.Obstacle(id: shapes.count + $0.offset, rect: $0.element) }
        let extra = planned.isEmpty ? nil : ObstacleGrid(planned)
        var problem = LayoutProblem(free: [free], fixed: fixed,
                                    obstacles: { area in extra.map { grid.obstacles(in: area) + $0.obstacles(in: area) } ?? grid.obstacles(in: area) },
                                    boardBounds: grid.bounds,
                                    viewMiddle: viewMiddle, view: reading.view)
        problem.landsInView = room.map { LayoutProblem.InView(clear: $0.view.rect, above: $0.above, covered: $0.view.covered) }
        guard let solution = try? problem.solve(), let rect = solution.rects.first, rect.isFinite else { return nil }
        let zones = solution.zones.first?.compactMap { shapes.indices.contains($0.id) ? shapes[$0.id].id : nil } ?? []
        return (rect, zones)
    }

    /// A shape's number as an obstacle, if it's one: its place in the document, where it has a solid.
    private func obstacle(_ id: ShapeID) -> Int? {
        reading.shapes.solidBounds(of: id) != nil ? reading.document.index(of: id) : nil
    }

    /// How far a box placed on one side of `bounds` is from them, along that side's axis.
    private static func gap(from bounds: CGRect, to rect: CGRect, _ side: Direction) -> CGFloat {
        switch side {
        case .right: rect.minX - bounds.maxX
        case .left: bounds.minX - rect.maxX
        case .below: rect.minY - bounds.maxY
        case .above: bounds.minY - rect.maxY
        default: .infinity
        }
    }

    /// Two sides as near as each other but for what arithmetic in another order leaves over, world units.
    private static let slack: CGFloat = 1e-6
    /// How the solver's messages, never shown, name the shape moved and the shape it's placed against.
    private static let moving = "the shape moved"
    private static let target = "the shape it goes to"
    private static let column = "the pill before it"
    private static let holder = "the frame it stays in"
}
