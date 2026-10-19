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
    static func reading(_ stops: [Stop]) -> [Stop] {
        guard stops.count > 1 else { return stops }
        let byHeight = stops.enumerated().sorted { ($0.element.center.y, $0.offset) < ($1.element.center.y, $1.offset) }.map(\.element)
        var rows: [[Stop]] = []
        for stop in byHeight {
            if let row = rows.indices.reversed().first(where: { abs(stop.center.y - rows[$0][rows[$0].count - 1].center.y) < SelectionStyle.readingRowRange }) {
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
        return rows.flatMap { $0 }
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
private enum StepScope {
    /// The board's own shapes, in no container.
    case top
    /// The shapes in a container.
    case inside(ShapeID)
    /// Any shape, in any container: nothing is selected, and the focus is a group.
    case anywhere
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
    private var stepScope: StepScope {
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
    /// order, from the first selected one (the first stop with nothing selected, the last going back),
    /// wrapping; an arrow to the nearest stop that way from the stop selected last, leaving out, when
    /// `adding`, those selected already.
    func adjacentStop(_ direction: AdjacentDirection, adding: Bool) -> Stop? {
        switch direction {
        case .next, .previous:
            let order = StopOrder.reading(stops(in: stepScope))
            guard !order.isEmpty else { return nil }
            let current = order.firstIndex { $0.shapes.contains(where: selectedSet.contains) }
            let from = current ?? (direction == .previous ? 0 : -1)
            return order[(from + (direction == .next ? 1 : -1) + order.count) % order.count]
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
    /// no box, is never one. Next and previous wrap, and with nothing selected go to the first stop (the
    /// last, going back); a direction goes from the stop selected last, and with nothing that way, or
    /// nothing selected, does nothing. With `adding`, a direction adds the nearest stop that is not
    /// selected yet to the selection, after what is selected. Does nothing while a gesture runs or a shape
    /// is edited.
    public func selectAdjacentShape(_ direction: AdjacentDirection, adding: Bool = false) {
        guard canStepSelection, let state = selectionState, let stop = state.adjacentStop(direction, adding: adding) else { return }
        selectedShapeIDs = adding ? selectedShapeIDs + stop.shapes : stop.shapes
        revealIfOffscreen(stop.shapes)
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

    /// What ⌘↑ selects before it goes up a board (`selectEnclosure`): the innermost group the selection
    /// is inside, else the container all its shapes are in. Nil with nothing selected, and for a selection
    /// in neither.
    public var selectionEnclosure: SelectionEnclosure? { selectionState?.enclosure }

    /// Steps out of the group or container the selection is in, selecting it, and brings it into view
    /// if it is not (tldraw's `selectParentShape`); false if the selection is in neither.
    @discardableResult
    public func selectEnclosure() -> Bool {
        guard let state = selectionState, state.selectEnclosure() else { return false }
        revealIfOffscreen(selectedShapeIDs)
        return true
    }
}
