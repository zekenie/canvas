import AppKit
import Canvas
import Selection

/// The editor's part in the sessions: the light an offer puts on a shape, the hops Tab and ⇧Tab make past a shape's ends
/// to the next shape of its kind, and the layout inputs a session set, taken back as editing ends.
@MainActor
public final class LineRowsService {
    unowned let editor: CanvasEditor
    /// The shape or row an offer lights, on the board shown.
    public private(set) var light: PartAddress?
    /// Which end of its stops a session Tab or ⇧Tab hopped to starts at.
    enum End { case first, last }
    /// The shape Tab or ⇧Tab hopped to, and the end it starts at.
    private var hopped: (id: ShapeID, end: End)?
    /// A session whose row's line is printed again once the commit it waits for settles: ⌘L's pick, made as the picker closes
    /// and the keyboard is back on the line.
    weak var awaitingReprint: LineRowsView?
    /// How wide the shape being edited is laid out while its typed line is wider than it stores (`LineRowsLayout.width`).
    private var widths: [ShapeID: CGFloat] = [:]
    /// What shows a row's card (the Card part's), given by the plugin.
    var cards: (any LineCardShowing)?
    /// The session of the shape being edited, as it started.
    weak var session: LineRowsView?
    /// The rows its session has selected whole (⇧↑ ⇧↓), and their shape: what's selected as items on the canvas as editing
    /// ends.
    var band: (shape: ShapeID, rows: [PartID])?

    init(editor: CanvasEditor) {
        self.editor = editor
    }

    /// How wide `id` is laid out while a line typed in it is wider than it is: nil at rest (`LineRowsLayout.width`'s
    /// provider).
    func width(of id: ShapeID) -> CGFloat? { widths[id] }

    /// Lays `id` out `width` wide while it's edited (nil: as stored), the arrows bound to it and its frame following.
    func setWidth(_ width: CGFloat?, of id: ShapeID) {
        guard widths[id] != width else { return }
        widths[id] = width
        editor.shapesDidChangeLayout([id])
    }

    /// Lights a shape or a row (nil: none), outlined as the selection is.
    public func setLight(_ light: PartAddress?) {
        guard light != self.light else { return }
        self.light = light
        editor.setNeedsDisplay()
    }

    /// What's outlined for the light: the shape as a whole, or its row's rect.
    func outlines() -> Outlines {
        guard let light, let record = editor.document[light.shape] else { return Outlines() }
        guard let part = light.part else { return Outlines(shapes: [record.id]) }
        guard let frame = editor.shapeContext.geometry(of: record.id)?.parts.frame(part) else { return Outlines(shapes: [record.id]) }
        return Outlines(rects: [frame.rect])
    }

    /// Tab (`.next`) or ⇧Tab (`.previous`) past `id`'s last or first stop: the next or previous shape of its kind in
    /// reading order among those in its container (Selection's `shape(_:from:among:)`), read-only ones passed over,
    /// selected, brought into view and edited, Tab at its first stop and ⇧Tab at its last. False with no other: the
    /// session comes round inside its shape.
    func hop(_ direction: AdjacentDirection, from id: ShapeID) -> Bool {
        let editor = editor
        guard let kind = editor.document[id]?.kind,
              let next = editor.shape(direction, from: id, among: { $0.kind == kind && !editor.isReadOnly($0.id) }), next != id else { return false }
        editor.endEditing()
        editor.selectedShapeIDs = [next]
        editor.revealIfOffscreen([next])
        hopped = (next, direction == .previous ? .last : .first)
        editor.beginEditing(next)
        return true
    }

    /// The card of a row (`address`), as a click on its "›" opens it: the shape edited at the row, if it isn't, then the card
    /// shown under the row. False where none shows (no such row, a row with nothing more, a shape that can't be edited).
    @discardableResult
    public func openCard(of address: PartAddress) -> Bool {
        guard let part = address.part, let record = editor.document[address.shape], editor.registry.lineRows(of: record.kind) != nil,
              editor.registry.lineRows(of: record.kind)?.rows(record)?.contains(where: { $0.id == part }) == true else { return false }
        if editor.editingShapeID != address.shape {
            editor.selectedShapeIDs = [address.shape]
            guard editor.beginEditing(address.shape) else { return false }
        }
        guard let session, editor.editingShapeID == address.shape else { return false }
        session.go(to: .row(part))
        return session.openCard()
    }

    /// A row edited, as Return on it selected on the canvas, or a click on it once it's the only row selected, edits it: the
    /// shape edited from `point` (the row under it, the caret there), else at the row's line's end. False where it can't be
    /// (a read-only shape, which shakes).
    @discardableResult
    public func edit(_ row: PartID, of shape: ShapeID, at point: CGPoint?) -> Bool {
        if editor.selectedShapeIDs != [shape] { editor.selectedShapeIDs = [shape] }
        if let point { return editor.beginEditing(shape, at: point) }
        guard editor.beginEditing(shape), let session, editor.editingShapeID == shape else { return false }
        session.go(to: .row(row))
        return true
    }

    /// Where `id`'s session starts when Tab or ⇧Tab hopped to it, as its editing view is made: asked once.
    func startingStop(_ id: ShapeID) -> End? {
        guard let hopped, hopped.id == id else { return nil }
        self.hopped = nil
        return hopped.end
    }
}

extension LineRowsService: EditorService {
    /// A pick that a session's line waits for is in: the line printed again, with what it drew.
    public func documentDidSettle(_ changes: ChangeSet, in editor: CanvasEditor) {
        cards?.follow(changes)
        guard let session = awaitingReprint else { return }
        awaitingReprint = nil
        session.reprint()
    }

    /// Editing's end takes back what the session set and puts the light out.
    public func editingDidEnd(_ id: ShapeID, in editor: CanvasEditor) {
        if hopped?.id == id { hopped = nil }
        // Rows selected whole stay selected, as items of their shape on the canvas (Escape, ⌘↑, a press on them).
        if let band, band.shape == id {
            self.band = nil
            if editor.document[id] != nil { editor.selectItems(band.rows.map(AnyHashable.init), of: id) }
        }
        setLight(nil)
        editor.setLayoutInput(LineRowsLayout.waiting, nil, for: id)
        editor.setLayoutInput(LineRowsLayout.focused, nil, for: id)
        setWidth(nil, of: id)
    }
}
