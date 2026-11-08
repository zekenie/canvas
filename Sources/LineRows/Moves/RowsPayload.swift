import AppKit
import Canvas
import Selection
import Topology

// Rows on the pasteboard: a small board file (`BoardCodec`, so a newer app migrates them as it migrates a board) holding the
// source's record with only those rows (the carrier, under the source's id) and the arrows bound to them, under a type of its
// own, with the rows' lines as text beside it for other apps. What a row says goes with it: a copy carries the arrows the
// rows start (a column's keys) and lets go of those that end at them; a cut carries every arrow bound to them on the board
// and deletes them with the rows, its step counted ("Cut Columns and 2 Arrows"). A paste of cut rows is a move (the rows the
// same rows: what names them follows, `PartsMoved`, and the arrows come back under their ids) while no shape on the board
// holds those rows; pasted again, they're copies. The pasteboard is the editor's (the core's `pasteboard`, Clipboard's): the line
// editor writes and reads rows itself while a row is typed in, Clipboard on the canvas.

/// Rows on the pasteboard.
public struct RowsPayload {
    /// The source's record, holding only these rows, untitled, under the source's id.
    public let carrier: AnyShapeRecord
    /// The arrows that go with them: a copy's, the arrows the rows start; a cut's, every arrow that was bound to them.
    public let bound: [AnyShapeRecord]
    /// A cut's mark: its paste moves the rows, while no shape on the board holds them.
    public let cut: UUID?

    public init(carrier: AnyShapeRecord, bound: [AnyShapeRecord] = [], cut: UUID? = nil) {
        self.carrier = carrier
        self.bound = bound
        self.cut = cut
    }
}

/// Where rows go on a pasteboard, and how they're read back.
@MainActor
public enum RowsPasteboard {
    /// Rows of this app's shapes: a board file of their carrier and the arrows that go with them.
    public static let type = NSPasteboard.PasteboardType("com.example.InfiniteCanvas.rows")
    /// A cut's mark beside them: a token, fresh each cut.
    public static let cutType = NSPasteboard.PasteboardType("com.example.InfiniteCanvas.rows.cut")

    /// Writes `payload` on `pasteboard` in place of what was there, with `lines` as text beside it. False, and nothing
    /// written, when it doesn't encode.
    @discardableResult
    public static func write(_ payload: RowsPayload, lines: [String], to pasteboard: NSPasteboard, registry: Registry) -> Bool {
        guard let data = try? BoardCodec(registry: registry).encode(CanvasDocument(shapes: [payload.carrier] + payload.bound)) else { return false }
        pasteboard.clearContents()
        pasteboard.setData(data, forType: type)
        if let cut = payload.cut { pasteboard.setString(cut.uuidString, forType: cutType) }
        pasteboard.setString(lines.joined(separator: "\n"), forType: .string)
        return true
    }

    /// Whether `pasteboard` holds rows.
    public static func holdsRows(_ pasteboard: NSPasteboard) -> Bool { pasteboard.types?.contains(type) == true }

    /// The rows on `pasteboard`, read as a board is (a newer kind's version migrated); nil for none, or none this app reads.
    public static func read(from pasteboard: NSPasteboard, registry: Registry) -> RowsPayload? {
        guard let data = pasteboard.data(forType: type), let board = try? BoardCodec(registry: registry).decode(data) else { return nil }
        let shapes = board.file.root.shapes.filter { !$0.isOpaque }
        guard let carrier = shapes.first(where: { registry.rowMoving(of: $0.kind) != nil }) else { return nil }
        let cut = pasteboard.string(forType: cutType).flatMap(UUID.init(uuidString:))
        return RowsPayload(carrier: carrier, bound: shapes.filter { $0.id != carrier.id }, cut: cut)
    }
}

extension CanvasEditor {
    /// The rows on the editor's pasteboard (the core's `pasteboard`, Clipboard's), if it holds some this app reads.
    public var pasteboardRows: RowsPayload? { pasteboard.flatMap { RowsPasteboard.read(from: $0, registry: registry) } }

    /// `rows` of `shape` (those it holds, in its order) as they'd go on the pasteboard: its record holding only them,
    /// untitled, and the arrows that go with them: a cut's, every arrow on the board bound to one of them; a copy's, the
    /// arrows that start at one (a column's keys), never those that end there. Nil for none.
    public func rowsPayload(_ rows: [PartID], of shape: ShapeID, cut: Bool) -> RowsPayload? {
        guard let record = document[shape], let moving = registry.rowMoving(of: record.kind) else { return nil }
        let wanted = Set(rows)
        let ids = (moving.rows(record) ?? []).filter(wanted.contains)
        guard !ids.isEmpty, let carrier = moving.carrier(record, ids) else { return nil }
        return RowsPayload(carrier: carrier, bound: cut ? arrowsBound(to: ids, of: shape) : arrowsStarted(by: ids, of: shape), cut: cut ? UUID() : nil)
    }

    /// The shapes on the board bound to one of `rows` of `shape` (an arrow's end), but read-only ones.
    private func arrowsBound(to rows: [PartID], of shape: ShapeID) -> [AnyShapeRecord] {
        let addresses = Set(rows.map { PartAddress(shape, part: $0) })
        let kinds = registry.referencingKinds
        return document.shapes.filter { record in
            kinds.contains(record.kind) && !isReadOnly(record.id) && record.boundParts(in: registry).contains(where: addresses.contains)
        }
    }

    /// The connections that start at one of `rows` of `shape` (Topology's edges as their carriers emit them), on the board.
    private func arrowsStarted(by rows: [PartID], of shape: ShapeID) -> [AnyShapeRecord] {
        let wanted = Set(rows)
        var carriers: [ShapeID] = [], seen: Set<ShapeID> = []
        topology?.forEachEdge(of: shape, .outgoing, view: .literal) { edge in
            guard edge.isConnection, let part = edge.sourcePart, wanted.contains(part), seen.insert(edge.carrier).inserted else { return }
            carriers.append(edge.carrier)
        }
        return carriers.compactMap { document[$0] }
    }

    /// Copies `rows` of `shape` to the editor's pasteboard, with the arrows they start, and their lines as text. False with no
    /// pasteboard or no rows.
    @discardableResult
    public func copyRows(_ rows: [PartID], of shape: ShapeID) -> Bool {
        guard let pasteboard, let payload = rowsPayload(rows, of: shape, cut: false),
              let moving = registry.rowMoving(of: payload.carrier.kind) else { return false }
        return RowsPasteboard.write(payload, lines: moving.lines(payload.carrier, self), to: pasteboard, registry: registry)
    }

    /// Cuts `rows` of `shape`: on the editor's pasteboard as a cut's, with every arrow bound to them, then taken out of the
    /// shape with those arrows, in one step that counts them ("Cut Columns and 2 Arrows"). A read-only shape copies and
    /// cuts nothing, and shakes. False with no pasteboard or no rows.
    @discardableResult
    public func cutRows(_ rows: [PartID], of shape: ShapeID) -> Bool {
        guard let pasteboard, let record = document[shape], let moving = registry.rowMoving(of: record.kind),
              let payload = rowsPayload(rows, of: shape, cut: true) else { return false }
        let ids = moving.rows(payload.carrier) ?? []
        RowsPasteboard.write(payload, lines: moving.lines(payload.carrier, self), to: pasteboard, registry: registry)
        var name = ""
        let registry = registry
        let done: Bool? = transactWhole(nil, shaking: [shape]) { transaction in
            guard let fresh = transaction.document[shape], let without = moving.removing(fresh, Set(ids)) else { throw Transaction.Refused([shape]) }
            transaction.update(shape) { $0 = without }
            guard transaction.refusedShapes.isEmpty else { throw Transaction.Refused([shape]) }
            // The arrows bound to them go with them, counted: those cut with them, and what the core takes along for the rest.
            let arrows = Set(payload.bound.map(\.id)).filter { transaction.document[$0] != nil }
            var counts: [KindCount] = []
            for id in arrows {
                guard let kind = transaction.document[id]?.kind else { continue }
                if let at = counts.firstIndex(where: { $0.kind == kind }) { counts[at].count += 1 } else { counts.append(KindCount(kind: kind, count: 1)) }
            }
            transaction.delete(arrows)
            transaction.removeParts(Set(ids.map { PartAddress(shape, part: $0) }))
            for item in transaction.deletedAlong {
                if let at = counts.firstIndex(where: { $0.kind == item.kind }) { counts[at].count += item.count } else { counts.append(item) }
            }
            name = RowSteps.cut(moving.noun, count: ids.count, along: counts, in: registry)
            transaction.stepName = name
            return true
        }
        guard done == true else { return false }
        if selectedItems?.shape == shape { selectionStateItemsDidGo(of: shape) }
        announce(name)
        return true
    }

    /// Rows put down at `place`, as one step: into a shape ("Paste Columns"), or out on their own,
    /// beside the selection or at a point ("Paste Columns", "Move Columns to New Table" for a cut's). A cut's paste moves them
    /// while no shape on the board holds them: what names them follows (`PartsMoved`) and their arrows come back under their
    /// ids; otherwise they're copies, their arrows under new ids. A row keeps its id where the target doesn't hold it. An
    /// arrow whose other end isn't on the board is left out. Returns the shape they're in; nil where nothing landed (a
    /// read-only target, which shakes, or a shape that takes no rows of their kind).
    @discardableResult
    public func pasteRows(_ payload: RowsPayload, to place: RowPlace) -> ShapeID? {
        guard let moving = registry.rowMoving(of: payload.carrier.kind) else { return nil }
        let rows = moving.rows(payload.carrier) ?? []
        guard !rows.isEmpty else { return nil }
        let moves = payload.cut != nil && !boardHolds(rows, of: payload.carrier.kind)
        let step: String = if case .into = place { RowSteps.paste(moving.noun, count: rows.count) } else if moves {
            RowSteps.takeOut(moving.noun, count: rows.count, into: payload.carrier.kind, in: registry)
        } else {
            RowSteps.paste(moving.noun, count: rows.count)
        }
        return landRows(payload.carrier, source: nil, arrows: payload.bound, moves: moves, at: place, step: step)
    }

    /// Whether a shape of `kind` on the board holds one of `rows`: a cut's rows pasted once already.
    private func boardHolds(_ rows: [PartID], of kind: ShapeKind) -> Bool {
        guard let moving = registry.rowMoving(of: kind) else { return false }
        let wanted = Set(rows)
        return document.shapes.contains { record in
            registry.rowMoving(of: record.kind) != nil && (moving.rows(record) ?? []).contains(where: wanted.contains)
        }
    }

    /// The items a cut took are gone: the shape stays selected.
    private func selectionStateItemsDidGo(of shape: ShapeID) {
        selectItems([], of: shape)
    }
}
