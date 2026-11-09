import Canvas
import CoreGraphics

/// Moving between shapes, as tldraw does (`Editor.selectAdjacentShape`, `selectParentShape` and
/// `selectFirstChildShape`): Tab and ⇧Tab step through the shapes in reading order, ⌥⌘ and an arrow key
/// to the nearest in that direction, and in and out of groups and containers. Every stop is what a
/// click there selects (`selectionUnit(of:)`: a group whole, else the shape), and the stops are the
/// selection's siblings: in the same container, inside the same group.

/// Where a step goes (tldraw's `TLAdjacentDirection`): to the next or previous shape in reading order, or
/// to the nearest in a direction.
public enum AdjacentDirection: Hashable, Sendable {
    case next, previous, left, right, up, down

    /// The way back: ⇧Tab's for Tab's, ←'s for →'s.
    var opposite: AdjacentDirection {
        switch self {
        case .next: .previous
        case .previous: .next
        case .left: .right
        case .right: .left
        case .up: .down
        case .down: .up
        }
    }
}

/// The steps Tab, ⇧Tab and ⌥⌘ with an arrow (⇧ too, adding) took the selection on, latest last, so the
/// opposite key undoes each exactly (P4), back to where it began even where that was no stop (several shapes,
/// an arrow, nothing): tldraw's nearest-scoring and the reading order need not lead back on their own. The
/// selection keeps it until anything else changes it. Holds the last `limit` steps.
struct StepTrail {
    struct Step {
        let before: [ShapeID]
        /// The items selected inside the shape stepped from (a table's row): its opposite selects them again.
        let beforeItems: HeldItems?
        let after: [ShapeID]
        let direction: AdjacentDirection
        let adding: Bool
    }

    static let limit = 50

    private(set) var steps: [Step] = []

    mutating func push(_ step: Step) {
        steps.append(step)
        if steps.count > Self.limit { steps.removeFirst(steps.count - Self.limit) }
    }

    /// The latest step, taken off, if `direction` (with `adding` as it was) undoes it from `selection`, where
    /// it left the selection.
    mutating func undo(_ direction: AdjacentDirection, adding: Bool, from selection: [ShapeID]) -> Step? {
        guard let last = steps.last, last.after == selection, last.direction == direction.opposite, last.adding == adding else { return nil }
        return steps.removeLast()
    }
}

/// What stepping out of the selection selects (`editor.selectionEnclosure`): ⌘↑'s step before it goes up a
/// board.
public enum SelectionEnclosure: Hashable, Sendable {
    /// The selection is inside a group (`editor.selectionFocus`): the innermost one, whole.
    case group
    /// The selected shapes are all in one container: that container.
    case container(ShapeID)
}

/// A shape or group the selection can step to: what a click there selects, and the middle of those
/// shapes' bounds.
struct Stop {
    let shapes: [ShapeID]
    let center: CGPoint
}

/// The order stops are stepped in, and the nearest in a direction: tldraw's, with its numbers
/// (`SelectionStyle`).
@MainActor
enum StopOrder {
    /// The stops in reading order, left to right and top to bottom (tldraw's `_getShapesInReadingOrder`):
    /// sorted top to bottom by center, then grouped into rows (a stop joins the latest row, searching from
    /// the last, whose last stop is less than `readingRowRange` above or below it), each row sorted left to
    /// right, then within a row the next two are swapped where the one after next is closer to the stop
    /// by under `readingSwapCloseness` of the squared distance and no more than `readingSwapAngle` degrees
    /// off the horizontal to its right. Stops level with one another stay in the order they came.
    static func reading(_ stops: [Stop]) -> [Stop] { reading(stops) { $0.center } }

    /// Anything in reading order by a middle of its own, as stops are (a shape's parts, by their rects'). `rowRange`: how near two
    /// middles are in height to be read in one row (shapes', by default; a shape's parts are smaller, and their rows closer).
    static func reading<Item>(_ items: [Item], rowRange: CGFloat? = nil, center: (Item) -> CGPoint) -> [Item] {
        guard items.count > 1 else { return items }
        let range = rowRange ?? SelectionStyle.readingRowRange
        let byHeight = items.map { (item: $0, center: center($0)) }.enumerated()
            .sorted { ($0.element.center.y, $0.offset) < ($1.element.center.y, $1.offset) }.map(\.element)
        var rows: [[(item: Item, center: CGPoint)]] = []
        for stop in byHeight {
            if let row = rows.indices.reversed().first(where: { abs(stop.center.y - rows[$0][rows[$0].count - 1].center.y) < range }) {
                rows[row].append(stop)
            } else {
                rows.append([stop])
            }
        }
        for row in rows.indices {
            rows[row] = rows[row].enumerated().sorted { ($0.element.center.x, $0.offset) < ($1.element.center.x, $1.offset) }.map(\.element)
            guard rows[row].count > 2 else { continue }
            for i in 0..<(rows[row].count - 2) {
                let current = rows[row][i].center, next = rows[row][i + 1].center, afterNext = rows[row][i + 2].center
                let nearer = squaredDistance(current, afterNext) < squaredDistance(current, next) * SelectionStyle.readingSwapCloseness
                if nearer, abs(atan2(afterNext.y - current.y, afterNext.x - current.x) * 180 / .pi) <= SelectionStyle.readingSwapAngle {
                    rows[row].swapAt(i + 1, i + 2)
                }
            }
        }
        return rows.flatMap { $0.map(\.item) }
    }

    private static func squaredDistance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        (a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)
    }

    /// The stop nearest to `origin` in a direction (tldraw's `getNearestAdjacentShape`), among those in
    /// its wedge (across the way no farther than `stepWedge` times along it, and on that side), by the
    /// lowest score: the distance, plus `stepAcrossWeight` times how far off the line through the
    /// origin it is, plus `stepDiagonalWeight` times how much farther it is than if it were straight
    /// ahead, plus `stepAngleWeight` times how many degrees off the direction. The first of equals. Nil
    /// for none that way, and for a direction that isn't one of the four.
    static func nearest(to origin: CGPoint, among stops: [Stop], toward direction: AdjacentDirection) -> Stop? {
        let degrees: CGFloat, isHorizontal: Bool
        switch direction {
        case .right: (degrees, isHorizontal) = (0, true)
        case .down: (degrees, isHorizontal) = (90, false)
        case .left: (degrees, isHorizontal) = (180, true)
        case .up: (degrees, isHorizontal) = (270, false)
        case .next, .previous: return nil
        }
        var best: (stop: Stop, score: CGFloat)?
        for stop in stops {
            let dx = stop.center.x - origin.x, dy = stop.center.y - origin.y
            let along = isHorizontal ? dx : dy, across = isHorizontal ? dy : dx
            let isAhead = direction == .right || direction == .down ? along > 0 : !(along > 0)
            guard abs(across) < abs(along) * SelectionStyle.stepWedge, isAhead else { continue }
            let distance = hypot(dx, dy)
            let angle = (atan2(dy, dx) * 180 / .pi + 360).truncatingRemainder(dividingBy: 360)
            let off = abs(angle - degrees)
            let score = distance + abs(across) * SelectionStyle.stepAcrossWeight + (distance - abs(along)) * SelectionStyle.stepDiagonalWeight
                + min(off, 360 - off) * SelectionStyle.stepAngleWeight
            if best == nil || score < best!.score { best = (stop, score) }
        }
        return best?.stop
    }
}

/// Which shapes stepping looks at: those the selection's siblings are.
enum StepScope: Equatable {
    /// The board's own shapes, in no container.
    case top
    /// The shapes in a container.
    case inside(ShapeID)
    /// Any shape, in any container: nothing is selected, and the focus is a group.
    case anywhere
}

/// What the stops in reading order were worked out from: the board, its shapes and their layout, which
/// shapes stepping looks at, and the groups the selection is inside.
struct ReadingOrderKey: Equatable {
    let board: BoardID
    let revision: Int
    let layoutRevision: Int
    let scope: StepScope
    let focus: [AnyHashable]
}

extension SelectionState {
    /// A stop of these shapes: nil if none of them has a box (an arrow is never a stop; a group with a
    /// shape that has one is) or they have no bounds.
    func stop(of shapes: [ShapeID], needsBox: Bool = true) -> Stop? {
        let document = editor.document
        if needsBox, !shapes.contains(where: { document[$0]?.box != nil }) { return nil }
        guard let bounds = editor.shapeContext.bounds(of: shapes) else { return nil }
        return Stop(shapes: shapes, center: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    /// The container the selected shapes are all in, if they are all in one.
    func commonContainer() -> ShapeID? {
        let document = editor.document, registry = editor.registry
        var common: ShapeID?
        for (index, id) in selectedIDs.enumerated() {
            guard let record = document[id], let container = registry.container(of: record, in: document) else { return nil }
            if index == 0 { common = container } else if container != common { return nil }
        }
        return common
    }

    /// tldraw's: the container the selected shapes are all in if they are, else the board's own. With
    /// nothing selected, those inside the group the selection was in, if it was in one.
    var stepScope: StepScope {
        guard !selectedIDs.isEmpty else { return focus.isEmpty ? .top : .anywhere }
        return commonContainer().map(StepScope.inside) ?? .top
    }

    /// The stops in `scope`, inside the group `focus` names (the one the selection is inside, by
    /// default), each once, in the board's order: a shape that has a box and can be selected, taken as
    /// a click there takes it (a group whole).
    private func stops(in scope: StepScope, within focus: [AnyHashable]? = nil) -> [Stop] {
        let document = editor.document, registry = editor.registry, focus = focus ?? self.focus
        var seen = Set<ShapeID>(), stops: [Stop] = []
        for record in document.shapes where record.box != nil && !seen.contains(record.id) && isSelectable(record) {
            switch scope {
            case .top: guard registry.container(of: record, in: document) == nil else { continue }
            case .inside(let container): guard registry.container(of: record, in: document) == container else { continue }
            case .anywhere: break
            }
            guard focus.isEmpty || groups(of: record.id).starts(with: focus) else { continue }
            let unit = unit(of: record.id, within: focus)
            seen.formUnion(unit)
            if let stop = stop(of: unit) { stops.append(stop) }
        }
        return stops
    }

    /// Where a step goes from the selection, or nil: Tab and ⇧Tab to the next and previous stop in reading
    /// order, from the first selected one, wrapping; with a selection that holds no stop (an arrow), from
    /// where the middle of its bounds reads among the stops, never from either end; with nothing selected,
    /// the first stop (the last, going back). An arrow key to the nearest stop that way from the stop
    /// selected last, leaving out, when `adding`, those selected already.
    func adjacentStop(_ direction: AdjacentDirection, adding: Bool) -> Stop? {
        switch direction {
        case .next, .previous:
            let order = orderedStops(), step = direction == .next ? 1 : -1
            guard !order.isEmpty else { return nil }
            if let current = order.firstIndex(where: { $0.shapes.contains(where: selectedSet.contains) }) {
                return order[(current + step + order.count) % order.count]
            }
            guard let bounds = selectionBounds else { return order[direction == .previous ? order.count - 1 : 0] }
            // The selection's middle read among the stops, as a stop of no shapes: the one after it, or before.
            let placed = StopOrder.reading(order + [Stop(shapes: [], center: CGPoint(x: bounds.midX, y: bounds.midY))])
            guard let middle = placed.firstIndex(where: \.shapes.isEmpty) else { return nil }
            return placed[(middle + step + placed.count) % placed.count]
        case .left, .right, .up, .down:
            guard let last = selectedIDs.last else { return nil }
            let unit = unit(of: last, within: focus)
            guard let origin = stop(of: unit, needsBox: false) else { return nil }
            let own = Set(unit)
            let candidates = stops(in: stepScope).filter { stop in
                !stop.shapes.contains(where: own.contains) && !(adding && stop.shapes.contains(where: selectedSet.contains))
            }
            return StopOrder.nearest(to: origin.center, among: candidates, toward: direction)
        }
    }

    /// The stops Tab steps through where the selection is, in reading order, each one's shapes in turn (a
    /// group's back to front): the order VoiceOver walks the board in (`registrar.accessibleOrder`).
    var readingOrder: [ShapeID] { orderedStops().flatMap(\.shapes) }

    /// The stops in `stepScope`, in reading order, kept until the board, its shapes, their layout, the scope
    /// or the group the selection is inside changes: Tab and VoiceOver ask for the same ones, and a step to a
    /// sibling, or a pan, finds them kept.
    private func orderedStops() -> [Stop] {
        let scope = stepScope
        let key = ReadingOrderKey(board: editor.board, revision: editor.revision, layoutRevision: editor.layoutRevision, scope: scope, focus: focus)
        if let kept = keptReadingOrder, kept.key == key { return kept.stops }
        let ordered = StopOrder.reading(stops(in: scope))
        keptReadingOrder = (key, ordered)
        return ordered
    }

    // MARK: In and out

    /// What ⌘↓ and Return select in place of opening `ids`, if they are a group whole (its first part,
    /// one level in: the part a click on the group, selected, selects, first in reading order) or a
    /// container alone that is neither opened nor edited (the first stop inside it, in reading order);
    /// nil otherwise.
    func shapesInside(_ ids: [ShapeID]) -> [ShapeID]? {
        if let group = wholeGroup(ids) {
            var seen = Set<ShapeID>(), parts: [[ShapeID]] = []
            for id in group.shapes where !seen.contains(id) {
                let part = unit(inside: id, within: group.focus)
                seen.formUnion(part)
                parts.append(part)
            }
            guard let part = StopOrder.reading(parts.compactMap { stop(of: $0) }).first?.shapes ?? parts.first,
                  Set(part) != Set(group.shapes) else { return nil }
            return part
        }
        guard let container = containerToEnter(ids) else { return nil }
        // What a container holds is in none of the groups it is in (a group is its shapes', not their
        // containers'), so inside it the focus is none.
        return StopOrder.reading(stops(in: .inside(container), within: [])).first?.shapes
    }

    /// Whether `shapesInside` would find something to select, without working out which: a group whole,
    /// or a container to go into that holds a shape that can be a stop.
    func canStepInto(_ ids: [ShapeID]) -> Bool {
        if wholeGroup(ids) != nil { return true }
        guard let container = containerToEnter(ids) else { return false }
        return editor.shapeContext.contents(of: container).contains(where: isSelectable(id:))
    }

    /// `ids` as a group whole, if they are one: what a click on the first of them selects once they are
    /// the selection (its outermost group past the groups they are all inside, as `select` works out the
    /// selection's focus), when that is more than one shape and every one of them. Its shapes are the
    /// group's, back to front, and its focus the groups it is inside.
    private func wholeGroup(_ ids: [ShapeID]) -> (shapes: [ShapeID], focus: [AnyHashable])? {
        guard ids.count > 1, !groups(of: ids[0]).isEmpty else { return nil }
        let whole = Set(ids), focus = focus(of: ids, selected: whole)
        let unit = unit(of: ids[0], within: focus)
        return unit.count > 1 && Set(unit) == whole ? (unit, focus) : nil
    }

    /// `ids`' one shape, if it is a container whose kind neither opens nor edits (a frame).
    private func containerToEnter(_ ids: [ShapeID]) -> ShapeID? {
        guard ids.count == 1, let record = editor.document[ids[0]], editor.registry.isContainer(record), !editor.canOpen(ids[0]) else { return nil }
        return ids[0]
    }

    /// What ⌘↑ selects before it goes up a board: the innermost group the selection is inside, whole (as
    /// Escape does), else the container all the selected shapes are in.
    var enclosure: SelectionEnclosure? {
        guard !selectedIDs.isEmpty else { return nil }
        if let innermost = focus.last, !members(of: innermost).isEmpty { return .group }
        if let container = commonContainer(), isSelectable(id: container) { return .container(container) }
        return nil
    }

    /// A step of Tab, ⇧Tab or ⌥⌘ and an arrow (`adding`, with ⇧): the latest step undone exactly when this is
    /// its opposite and the selection is where it left it (`trail`), else the selection moved to the adjacent
    /// stop (`adjacentStop`), or the stop added to it, and the step kept for its opposite. A step back to shapes
    /// that are gone, or can't be selected now (deleted, undone, drawn away by an agent), can't be undone exactly:
    /// the trail goes, and the key steps as with none. The shapes to bring into view, or nil for nowhere to step.
    func step(_ direction: AdjacentDirection, adding: Bool) -> [ShapeID]? {
        var trail = self.trail
        if let undone = trail.undo(direction, adding: adding, from: selectedIDs) {
            if undone.before.allSatisfy(isSelectable(id:)) {
                select(undone.before)
                if let held = undone.beforeItems, selectedIDs == [held.shape] { setItems(held.ids, of: held.shape, anchor: held.anchor) }
                self.trail = trail
                return undone.before
            }
            trail = StepTrail()
        }
        guard let stop = adjacentStop(direction, adding: adding) else { return nil }
        let before = selectedIDs, beforeItems = items
        select(adding ? before + stop.shapes : stop.shapes)
        if selectedIDs != before {
            trail.push(StepTrail.Step(before: before, beforeItems: beforeItems, after: selectedIDs, direction: direction, adding: adding))
        }
        self.trail = trail
        return stop.shapes
    }

    /// Selects the enclosure (`enclosure`); false if there is none.
    func selectEnclosure() -> Bool {
        guard let enclosure else { return false }
        switch enclosure {
        case .group: select(members(of: focus[focus.count - 1]))
        case .container(let container): select([container])
        }
        return true
    }
}

extension CanvasEditor {
    /// Whether the keys that step between shapes take: nothing is under way or being edited.
    public var canStepSelection: Bool { session == nil && editingShapeID == nil }

    /// Tab, ⇧Tab and ⌥⌘ with an arrow key (tldraw's `selectAdjacentShape`): selects the next or previous
    /// shape in reading order, or the nearest in a direction, among the selection's siblings (in the same
    /// container, inside the same group), and brings it into view if it is not (`revealIfOffscreen`).
    /// What a stop is: what a click there selects, a group whole, else the shape; an arrow, which has
    /// no box, is never one. Next and previous wrap, with nothing selected go to the first stop (the
    /// last, going back), and from a selection that is no stop (an arrow) to the stop after (before) its
    /// middle in reading order; a direction goes from the stop selected last, and with nothing that way, or
    /// nothing selected, does nothing. With `adding`, a direction adds the nearest stop that is not
    /// selected yet to the selection, after what is selected. The opposite key undoes a step exactly
    /// while nothing else has changed the selection: ⇧Tab after Tab, ← after →, and the ⇧ step's opposite
    /// takes off what it added (`StepTrail`). Does nothing while a gesture runs or a shape is edited.
    public func selectAdjacentShape(_ direction: AdjacentDirection, adding: Bool = false) {
        guard canStepSelection, let state = selectionState, let shapes = state.step(direction, adding: adding) else { return }
        revealIfOffscreen(shapes)
    }

    /// The shape after (`.next`) or before (`.previous`) `id` in reading order, the order Tab steps in,
    /// among the shapes in `id`'s container (the board's own, in none) that `include` takes, each a stop
    /// of its own at the middle of its bounds (no group taken whole), wrapping: what Tab in a note's
    /// editor goes to (StickyNotes'). Nil when no other shape is taken, for a direction that isn't next
    /// or previous, and for a shape with no box.
    public func shape(_ direction: AdjacentDirection, from id: ShapeID, among include: (AnyShapeRecord) -> Bool) -> ShapeID? {
        guard direction == .next || direction == .previous, let record = document[id], record.box != nil else { return nil }
        let document = document, registry = registry, container = registry.container(of: record, in: document)
        let stops = document.shapes.compactMap { other -> Stop? in
            guard other.id == id || (other.box != nil && include(other) && registry.container(of: other, in: document) == container),
                  let bounds = shapeContext.bounds(of: [other.id]) else { return nil }
            return Stop(shapes: [other.id], center: CGPoint(x: bounds.midX, y: bounds.midY))
        }
        let order = StopOrder.reading(stops)
        guard order.count > 1, let index = order.firstIndex(where: { $0.shapes == [id] }) else { return nil }
        return order[(index + (direction == .next ? 1 : -1) + order.count) % order.count].shapes[0]
    }

    /// The shape nearest `point` in a direction, by the rule ⌥⌘ and an arrow step to the nearest shape by
    /// (`StopOrder.nearest`), among the shapes on the board shown that have a box and `include` takes, in
    /// any container, each a stop of its own at the middle of its bounds (no group taken whole): where
    /// ⌥⌘ and an arrow take an arrow's focused end (Arrows'). Nil for none that way, and for a direction
    /// that is next or previous.
    public func nearestShape(to point: CGPoint, toward direction: AdjacentDirection, among include: (AnyShapeRecord) -> Bool) -> ShapeID? {
        let stops = document.shapes.compactMap { record -> Stop? in
            guard record.box != nil, include(record), let bounds = shapeContext.bounds(of: [record.id]) else { return nil }
            return Stop(shapes: [record.id], center: CGPoint(x: bounds.midX, y: bounds.midY))
        }
        return StopOrder.nearest(to: point, among: stops, toward: direction)?.shapes[0]
    }

    /// What ⌘↑ selects before it goes up a board (`selectEnclosure`): the innermost group the selection
    /// is inside, else the container all its shapes are in. Nil with nothing selected, and for a selection
    /// in neither.
    public var selectionEnclosure: SelectionEnclosure? { selectionState?.enclosure }

    /// Steps out of the group or container the selection is in, selecting it, and pans to it if none of it
    /// is in view (tldraw's `selectParentShape`, never zooming out: `revealEnclosure`); false if the selection is in neither.
    @discardableResult
    public func selectEnclosure() -> Bool {
        guard let state = selectionState, state.selectEnclosure() else { return false }
        revealEnclosure(selectedShapeIDs)
        return true
    }
}
