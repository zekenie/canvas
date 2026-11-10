import AppKit
import Canvas
import CoreGraphics
import Selection

// Rows dragged (T4 panel 3: status into order_items; T5 panel 3: street to country onto the board), any kind's written as
// lines: started by a press on rows selected as items dragged past the threshold, or by a row's lead at any time (Selection's
// `ShapeItemActions.drag` and `lead`). Each event finds the shape under the pointer that takes the rows (`shape(at:where:)`, the
// spatial grid) and the gap among its lines nearest the pointer, and works out where the rows would land there through the
// kind's own move, so the line is drawn where they go (an API places an endpoint under its header); a gap inside the block is
// no move. Nothing is written until the release: the rows stay where they are, drawn faded (`LineRowsLayout.faded`), the drop
// line at the gap (ending where the ghost begins), the target outlined as a hint, and a ghost of the rows, a card of their own, at
// the pointer's right, level with it. It scrolls at the edges; Escape changes nothing. The release is `moveRows`: into the target before the gap (a folded
// one unfolded, so the rows stay in sight), or onto the board, the kind's take-out where the ghost is. Over a read-only shape
// that would take them, nothing shows and the release shakes it.

/// How a drag of rows is drawn.
@MainActor
public enum RowDragStyle {
    /// The rows a drag takes, where they are: drawn at this opacity by the kind (`LineRowsLayout.faded`).
    public static let fadedOpacity: CGFloat = 0.35
    /// The drop line: view points wide, in the accent.
    static let lineWidth: CGFloat = 2
    /// How far in from the target's sides the drop line starts and ends, world units.
    static let lineInset: CGFloat = 8
    /// How far right of the pointer the ghost's card starts, view points: the pointer is at its leading edge, as the frames
    /// draw it, so the drop line (which ends where the card begins) stays clear of the rows in it.
    public static let ghostGap: CGFloat = 6
}

/// A drag of rows, from the press to the release.
@MainActor
final class RowDragSession {
    /// Where the rows would go now.
    enum Drop: Equatable {
        /// Nowhere: the pointer is where they are (a gap inside the block), or no change would come of it.
        case none
        /// Into a shape before a row (nil: after its last); the line drawn at `y`, from `x` to `x + width`.
        case into(ShapeID, before: PartID?, line: CGRect)
        /// Onto the board: the kind's take-out, its top-left where the ghost's is.
        case board(CGPoint)
        /// A read-only shape that would take them: the release shakes it.
        case refused(ShapeID)
    }

    let source: ShapeID
    /// The rows dragged, in the source's order, a header's rows with it.
    let rows: [PartID]
    let moving: LineRowsMoving
    /// The rows as a shape of their own, under an id no shape has: the ghost, moved with the pointer.
    private var ghost: AnyShapeRecord
    /// The middle of the ghost's first line, from its top: the pointer is level with it.
    private let firstLineMiddle: CGFloat
    /// Where the take-out is a shape of another kind (one endpoint out of an API: an endpoint of its own), that shape, the ghost
    /// while the rows would go onto the board, and the middle of its first line; nil where it's the rows' own kind.
    private var outGhost: (record: AnyShapeRecord, firstLineMiddle: CGFloat)?
    private(set) var drop: Drop = .none
    /// The last place worked out, and where they'd land there: one event at the same gap costs no landing.
    private var landed: (target: ShapeID, revision: Int, gap: Int, drop: Drop)?

    /// A drag of `rows` of `shape` (those it holds, a header's rows with it) from a world point; nil for a shape whose rows don't
    /// move, a read-only one, or none of its rows.
    init?(rows: [PartID], of shape: ShapeID, from press: CGPoint, in editor: CanvasEditor) {
        guard !editor.isReadOnly(shape), let record = editor.document[shape], let moving = editor.registry.rowMoving(of: record.kind),
              let kind = editor.registry.lineRows(of: record.kind) else { return nil }
        let wanted = editor.withGroups(Set(rows), of: record)
        let ids = (moving.rows(record) ?? []).filter(wanted.contains)
        guard !ids.isEmpty, let carrier = moving.carrier(record, ids), let size = editor.laidOutSize(of: carrier) else { return nil }
        source = shape
        self.rows = ids
        self.moving = moving
        // The ghost's first line over the first row dragged, so the rows leave from where they are; once the pointer moves, the
        // ghost stands at its right, level with it.
        let first = editor.shapeContext.geometry(of: shape)?.parts.frame(ids[0])?.rect ?? CGRect(origin: press, size: .zero)
        let line = kind.lineRect(0, CGRect(origin: .zero, size: size))
        let origin = CGPoint(x: first.minX - line.minX, y: first.minY - line.minY)
        firstLineMiddle = line.midY
        var ghost = carrier.copy(as: ShapeID())
        ghost.box = CGRect(origin: origin, size: size)
        self.ghost = ghost
        if !moving.goesWithItsRows, let out = moving.takeOut(carrier), out.kind != carrier.kind,
           let middle = Self.firstPartMiddle(of: out, in: editor.registry) {
            outGhost = (out, middle)
        }
        editor.setLayoutInput(LineRowsLayout.faded, Set(ids), for: shape)
    }

    /// The middle of `record`'s first part from its top, laid out on its own: where the pointer is level with a ghost of it.
    private static func firstPartMiddle(of record: AnyShapeRecord, in registry: Registry) -> CGFloat? {
        let context = ShapeContext(document: CanvasDocument(shapes: [record]), registry: registry)
        guard let geometry = context.geometry(of: record.id), let first = geometry.parts.first?.rect else { return nil }
        return first.midY - geometry.bounds.minY
    }

    /// Where the drop would be with the pointer at `point`, world units.
    private func update(at point: CGPoint, in editor: CanvasEditor) {
        let gap = RowDragStyle.ghostGap / editor.shapeContext.zoom
        if let box = ghost.box {
            ghost.box = CGRect(origin: CGPoint(x: point.x + gap, y: point.y - firstLineMiddle), size: box.size)
        }
        if let out = outGhost, let box = out.record.box {
            outGhost?.record.box = CGRect(origin: CGPoint(x: point.x + gap, y: point.y - out.firstLineMiddle), size: box.size)
        }
        let registry = editor.registry
        let kind = ghost.kind
        // A shape written as lines that takes the rows' kind (its own, or an API an endpoint's).
        let target = editor.shape(at: point) { record in
            registry.lineRows(of: record.kind) != nil && registry.rowMoving(of: record.kind)?.takes(kind) == true
        }
        let next: Drop
        if let target {
            next = editor.isReadOnly(target) ? .refused(target) : landing(at: point, in: target, editor) ?? .none
        } else if moving.goesWithItsRows {
            // A shape that is its rows has no take-out: off every shape that takes them, nothing.
            next = .none
        } else {
            next = .board((outGhost?.record ?? ghost).box?.origin ?? point)
        }
        drop = next
        if case .into(let shape, _, _) = next { editor.hintedShapeID = shape } else { editor.hintedShapeID = nil }
        editor.setNeedsDisplay()
    }

    /// The drop into `target` at the gap nearest `point` among the lines it shows: where the kind would put the rows there, the
    /// line drawn at the gap they'd land in; nil where they'd change nothing.
    private func landing(at point: CGPoint, in target: ShapeID, _ editor: CanvasEditor) -> Drop? {
        let shapes = editor.shapeContext
        guard let record = editor.document[target], let kind = editor.registry.lineRows(of: record.kind),
              let into = editor.registry.rowMoving(of: record.kind), let frame = shapes.frame(of: record) else { return nil }
        let order = into.rows(record) ?? []
        let shown = shapes.layoutInput(LineRowsLayout.shown, of: record)
        let lines = shown?.count ?? order.count
        func gapY(_ gap: Int) -> CGFloat { gap < max(lines, 1) ? kind.lineRect(gap, frame).minY : kind.lineRect(lines - 1, frame).maxY }
        // The gap nearest the pointer: the lines go down the shape, so it's found by halves.
        var low = 0, high = lines
        while low < high {
            let middle = (low + high) / 2
            if (gapY(middle) + gapY(middle + 1)) / 2 < point.y { low = middle + 1 } else { high = middle }
        }
        let gap = low
        if let kept = landed, kept.target == target, kept.revision == editor.revision, kept.gap == gap { return kept.drop }
        // The row the gap is before: past all a line stands for (a closed header's rows, the "+N ›" line's).
        var index = gap
        if let shown, gap > 0 {
            index = (order.indices.last { shown.line(standingFor: $0) == gap - 1 } ?? -1) + 1
            if gap < lines, let row = shown.row(atLine: gap) { index = min(index, row) }
        }
        let before = index < order.count ? order[index] : nil
        let result = simulated(into: record, before: before, order: order, editor) ?? .none
        landed = (target, editor.revision, gap, result)
        return result
    }

    /// The rows put in `record` before `before`, as the kind would put them (an API's endpoint under its header): the line drawn at
    /// the gap they land in, before the first of the rows that were there that comes after the first of them; nil for no change.
    private func simulated(into record: AnyShapeRecord, before: PartID?, order: [PartID], _ editor: CanvasEditor) -> Drop? {
        guard let into = editor.registry.rowMoving(of: record.kind), let kind = editor.registry.lineRows(of: record.kind),
              let frame = editor.shapeContext.frame(of: record) else { return nil }
        let block = Set(rows)
        let after: [PartID]
        let rest: [PartID]
        let first: PartID
        if record.id == source {
            if let before, block.contains(before) { return nil }
            rest = order.filter { !block.contains($0) }
            let index = before.flatMap { rest.firstIndex(of: $0) } ?? rest.count
            guard let reordered = into.reordering(record, rows, index), reordered != record else { return nil }
            after = into.rows(reordered) ?? []
            first = rows[0]
        } else {
            guard let carrier = editor.document[source].flatMap({ moving.carrier($0, rows) }) else { return nil }
            rest = order
            let taken = Set(order)
            var renaming: [PartID: PartID] = [:]
            for row in rows where taken.contains(row) { renaming[row] = PartID() }
            let index = before.flatMap { order.firstIndex(of: $0) } ?? order.count
            guard let filled = into.inserting(record, carrier, index, renaming) else { return nil }
            after = into.rows(filled) ?? []
            first = renaming[rows[0]] ?? rows[0]
        }
        guard let at = after.firstIndex(of: first) else { return nil }
        // Among the rows that were there, how many come before the first that landed: the line goes above the next of them.
        let landedIDs = Set(after).subtracting(rest)
        let ahead = after[..<at].filter { !landedIDs.contains($0) }.count
        let shown = editor.shapeContext.layoutInput(LineRowsLayout.shown, of: record)
        let line: Int
        let y: CGFloat
        if ahead < rest.count, let index = order.firstIndex(of: rest[ahead]) {
            line = shown?.line(standingFor: index) ?? index
            y = kind.lineRect(line, frame).minY
        } else {
            line = max(0, (shown?.count ?? order.count) - 1)
            y = order.isEmpty ? kind.lineRect(0, frame).minY : kind.lineRect(line, frame).maxY
        }
        let rect = kind.lineRect(line, frame)
        let inset = RowDragStyle.lineInset
        return .into(record.id, before: before, line: CGRect(x: rect.minX + inset, y: y, width: max(0, rect.width - 2 * inset), height: 0))
    }

    /// What the drag set on the board, taken back.
    private func finish(in editor: CanvasEditor) {
        editor.setLayoutInput(LineRowsLayout.faded, nil, for: source)
        editor.hintedShapeID = nil
    }
}

extension RowDragSession: Session {
    func cursor(in editor: CanvasEditor) -> CanvasCursor? { .closedHand }
    var scrollsAtEdges: Bool { true }

    /// The rows as they'd land: over the board, the take-out where it's of another kind (an endpoint of its own), else the rows.
    var ghosts: [AnyShapeRecord] {
        if case .board = drop, let out = outGhost { return [out.record] }
        return [ghost]
    }

    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        update(at: pointer.world, in: editor)
    }

    func end(_ pointer: Pointer, in editor: CanvasEditor) {
        update(at: pointer.world, in: editor)
        finish(in: editor)
        switch drop {
        case .none: break
        case .refused(let target): editor.refuseChanges(to: [target])
        case .board(let origin): editor.moveRows(rows, of: source, to: .board(origin: origin))
        case .into(let target, let before, _):
            // A folded target shows every row once they land in it, so they stay in sight: it is unfolded for the step (a view, no
            // write), which measures its growth from the frame it had folded and pushes what's below for all it shows now, not only
            // the rows dropped (review R9). A refused move folds it back.
            let fold = editor.rowFolds?.fold(of: target)
            var was: CGRect?
            if fold != nil {
                was = editor.document[target].flatMap { editor.shapeContext.frame(of: $0) }
                editor.rowFolds?.unfold([target])
            }
            let moved = editor.moveRows(rows, of: source, to: .into(target, before: before), coalescing: nil, targetWas: was) != nil
            if !moved, let fold { editor.rowFolds?.restore(fold, of: target) }
        }
    }

    func cancel(in editor: CanvasEditor) -> Bool {
        finish(in: editor)
        return true
    }

    func draw(in context: OverlayContext) {
        guard case .into(_, _, var line) = drop else { return }
        // It ends where the ghost's card begins: never struck through the rows in it.
        if let edge = ghost.box?.minX { line.size.width = min(line.width, edge - line.minX) }
        guard line.width > 0 else { return }
        let cg = context.cg
        cg.setStrokeColor((context.editor.selectionOutlineColor ?? .controlAccentColor).cgColor)
        cg.setLineWidth(RowDragStyle.lineWidth / context.zoom)
        cg.setLineCap(.round)
        cg.move(to: CGPoint(x: line.minX, y: line.minY))
        cg.addLine(to: CGPoint(x: line.maxX, y: line.minY))
        cg.strokePath()
    }
}
