import Canvas
import CoreGraphics
import DrawScript
import Geometry

// Where a moved shape lands, worked out as `canvas draw` places a shape (Automation's DrawLayout): a
// layout problem for DrawScript's solver, with the shape as its one free box and the shapes of the board
// it lands on as its obstacles. It's put down anew, as a new shape is (no `current`): where it is now
// holds it nowhere, and it's in its own way nowhere.

/// Where a moved shape goes: the board, its box there, and the shapes there it's raised above, as draw
/// raises a shape over the zones it sits on and what it's drawn inside.
struct Landing {
    let board: BoardID
    let rect: CGRect
    var above: [ShapeID] = []
}

/// A board a shape lands on, as `canvas draw` reads the board it places shapes on: read in place
/// (`editor.reading(of:)`, shown or not), every shape there with a solid (`ShapeContext.solidBounds(of:)`)
/// an obstacle, in paint order, numbered by its place in the document, filed once in an `ObstacleGrid`,
/// which keeps each answer for the problems asked of it. On the moving shape's own board the shape is no
/// obstacle, and what it holds goes with it (`LayoutProblem.Free.carries`), so it's never in its way.
@MainActor
struct Surroundings {
    let reading: BoardReading
    private let grid: ObstacleGrid
    /// The moving shape's size: the free box's.
    private let size: CGSize
    /// What the shape holds, by place in the document, on its own board; none on another.
    private let carries: Set<Int>
    /// The middle of the view the board would be shown with (draw's), where a shape with nothing to hang
    /// on goes.
    private let viewMiddle: CGPoint

    /// `board` as it is now, for `shape` (a shape with a box on the board shown) to land on; nil for a
    /// board the editor can't show.
    init?(on board: BoardID, moving shape: AnyShapeRecord, in editor: CanvasEditor) {
        guard let reading = editor.reading(of: board), let box = shape.box else { return nil }
        self.reading = reading
        size = box.size
        let own = board == editor.board, document = reading.document, shapes = reading.shapes
        var obstacles: [LayoutProblem.Obstacle] = []
        for record in reading.paintOrder() where !(own && record.id == shape.id) {
            guard let rect = shapes.solidBounds(of: record.id), let index = document.index(of: record.id) else { continue }
            obstacles.append(LayoutProblem.Obstacle(id: index, rect: rect))
        }
        grid = ObstacleGrid(obstacles)
        let kinds = editor.registry.containingKinds
        carries = own && !kinds.isEmpty ? Set(document.descendants(of: shape.id, containingKinds: kinds).compactMap { document.index(of: $0) }) : []
        viewMiddle = reading.view.map { CGPoint(x: $0.midX, y: $0.midY) } ?? shapes.camera.toWorld(.zero)
    }

    /// Beside `target`: on each of its four sides in turn (`MovingStyle.sides`), placed as draw places
    /// `right of "X"`, draw's normal gap from it and centered on it the other way, and pushed out along
    /// that side's axis past whatever's in its way there (the solver's separation). The side that lands
    /// nearest it wins, the earlier on a tie: so the first side that's free, and with none free, the one
    /// that frees up nearest. A side the solver can't place is passed over; with none placed, it's right
    /// of the target, centered, over what's there. Nil for a target with nothing drawn to be beside.
    func near(_ target: ShapeID) -> Landing? {
        guard let bounds = reading.shapes.geometry(of: target)?.bounds, !bounds.isNull, bounds.isFinite else { return nil }
        let fixed = LayoutProblem.Fixed(rect: bounds, obstacle: obstacle(target))
        var best: (rect: CGRect, gap: CGFloat, zones: [ShapeID])?
        for side in MovingStyle.sides {
            let clause = LayoutProblem.ResolvedClause(relation: .direction(side), targets: [LayoutProblem.ResolvedTarget(.fixed(0), written: Self.target)],
                                                       written: "\(side.rawValue) \(Self.target)")
            guard let placed = place(LayoutProblem.Free(line: 1, name: Self.moving, size: size, clauses: [clause], carries: carries), fixed: [fixed])
            else { continue }
            let gap = Self.gap(from: bounds, to: placed.rect, side)
            if best.map({ gap < $0.gap - Self.slack }) ?? true { best = (placed.rect, gap, placed.zones) }
        }
        guard let best else {
            let gap = GapName.normal.value
            return Landing(board: reading.board, rect: CGRect(x: bounds.maxX + gap, y: bounds.midY - size.height / 2, width: size.width, height: size.height))
        }
        return Landing(board: reading.board, rect: best.rect, above: best.zones)
    }

    /// In `container`, a shape on this board that holds shapes (a frame), as draw places a shape
    /// `in "F"`: against its top-left, draw's tight gap in (`inside "F" top-left`), pushed clear of what's
    /// in it and kept within it (the frame its holder); with no room that way, against each of its other
    /// corners in turn (`MovingStyle.corners`), pushed the other ways. It goes in the frame itself
    /// (`Holder.direct`): a frame in it is in its way like any shape there, never a zone it lands in, so
    /// `/move-to` a frame doesn't leave it in one nested in that frame where there's room beside. With
    /// no room from any corner, at its top-left all the same, as far in (less, where it's barely bigger
    /// than the shape: half the room it has), over what's there. It's raised above the zones it sits on
    /// and the frame, as draw raises a shape over what it's drawn inside. Nil for a frame with nothing
    /// drawn.
    func inside(_ container: ShapeID) -> Landing? {
        guard let bounds = reading.shapes.geometry(of: container)?.bounds, !bounds.isNull, bounds.isFinite else { return nil }
        let fixed = LayoutProblem.Fixed(rect: bounds, obstacle: obstacle(container))
        let written = "in \(Self.target)"
        for corner in MovingStyle.corners {
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
    func anywhere() -> Landing {
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
}
