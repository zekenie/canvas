import Canvas
import CoreGraphics
import DrawScript
import Geometry

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

/// The constants of placing for plugins.
@MainActor
public enum PlacingStyle {
    /// The sides `near` tries, in order: of the sides that land as near the shape, the first wins.
    public static let sides: [Direction] = [.right, .below, .left, .above]
    /// The corners `inside` tries in a frame, in reading order: the first with room wins.
    public static let corners: [Part] = [.topLeft, .topRight, .bottomLeft, .bottomRight]
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
    public func near(_ target: ShapeID, within holder: ShapeID? = nil) -> Landing? {
        guard let bounds = reading.shapes.geometry(of: target)?.bounds else { return nil }
        return near(bounds, obstacle: obstacle(target), within: holder)
    }

    private func near(_ bounds: CGRect, obstacle targetObstacle: Int?, within holder: ShapeID?) -> Landing? {
        guard !bounds.isNull, bounds.isFinite else { return nil }
        var fixed = [LayoutProblem.Fixed(rect: bounds, obstacle: targetObstacle)]
        var held: LayoutProblem.Holder?
        if let holder, let holding = reading.shapes.geometry(of: holder)?.bounds, !holding.isNull, holding.isFinite {
            fixed.append(LayoutProblem.Fixed(rect: holding, obstacle: obstacle(holder)))
            held = LayoutProblem.Holder(.fixed(1), written: "in \(Self.holder)", direct: true)
        }
        var best: (rect: CGRect, gap: CGFloat, zones: [ShapeID])?
        for side in PlacingStyle.sides {
            let clause = LayoutProblem.ResolvedClause(relation: .direction(side), targets: [LayoutProblem.ResolvedTarget(.fixed(0), written: Self.target)],
                                                       written: "\(side.rawValue) \(Self.target)")
            guard let placed = place(LayoutProblem.Free(line: 1, name: Self.moving, size: size, clauses: [clause], holder: held, carries: carries),
                                     fixed: fixed)
            else { continue }
            let gap = Self.gap(from: bounds, to: placed.rect, side)
            if best.map({ gap < $0.gap - Self.slack }) ?? true { best = (placed.rect, gap, placed.zones) }
        }
        guard let best else {
            if let holder, held != nil { return inside(holder) }
            let gap = GapName.normal.value
            return Landing(board: reading.board, rect: CGRect(x: bounds.maxX + gap, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
        }
        return Landing(board: reading.board, rect: best.rect, above: best.zones + (held == nil ? [] : [holder].compactMap { $0 }))
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

    /// Anywhere on the board, as draw puts the one shape a script says nothing about the place of (no
    /// placements, and not on the board yet): at the middle of the view the board would be shown with,
    /// or the nearest spot around it clear of what's there, ring by ring; failing that, at the middle
    /// all the same.
    public func anywhere() -> Landing {
        let rect = place(LayoutProblem.Free(line: 1, name: Self.moving, size: size, carries: carries))?.rect
            ?? CGRect(x: viewMiddle.x - size.width / 2, y: viewMiddle.y - size.height / 2, width: size.width, height: size.height)
        return Landing(board: reading.board, rect: rect)
    }

    /// The free box placed among the board's obstacles by DrawScript's solver: where it goes, and the
    /// shapes it sits on there (the zones), back to front; nil if the solver can't place it.
    private func place(_ free: LayoutProblem.Free, fixed: [LayoutProblem.Fixed] = []) -> (rect: CGRect, zones: [ShapeID])? {
        let grid = grid, shapes = reading.document.shapes
        let problem = LayoutProblem(free: [free], fixed: fixed, obstacles: { grid.obstacles(in: $0) }, boardBounds: grid.bounds,
                                    viewMiddle: viewMiddle, view: reading.view)
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
    private static let holder = "the frame it stays in"
}
