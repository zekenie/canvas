import Canvas
import CoreGraphics
import Observation

/// The selection, the hovered shape and the hovered handle, one per editor. Plugins reach them
/// through `CanvasEditor`'s members below. The selection and the hover only ever name selectable
/// shapes in the document; the handle is one of the only selected shape's.
@MainActor
@Observable
final class SelectionState {
    @ObservationIgnored private unowned let editor: CanvasEditor
    /// Each kind's rule (`ShapeSelectability`), found once: the registry is frozen.
    @ObservationIgnored private let rules: [ShapeKind: @MainActor (AnyShapeRecord) -> Bool]
    private(set) var selectedIDs: [ShapeID] = []
    private(set) var onlySelectedID: ShapeID?
    private(set) var hoveredID: ShapeID?
    var hoveredHandle: AnyHashable? {
        didSet {
            guard hoveredHandle != oldValue else { return }
            editor.setNeedsDisplay()
            editor.refreshCursor()
        }
    }

    init(editor: CanvasEditor) {
        self.editor = editor
        let registry = editor.registry
        rules = registry.kinds.reduce(into: [:]) { rules, kind in
            rules[kind] = registry.contributions(to: ShapeSelectability.self, for: kind).first
        }
    }

    /// The kind's own rule, else one for every kind, else selectable.
    func isSelectable(_ record: AnyShapeRecord) -> Bool { rules[record.kind]?(record) ?? true }

    private func isSelectable(id: ShapeID) -> Bool { editor.document[id].map(isSelectable) ?? false }

    /// Drops what isn't there or isn't selectable, and repeats. Does nothing if that's what's
    /// selected already.
    func select(_ ids: [ShapeID]) {
        var seen = Set<ShapeID>()
        let kept = ids.filter { isSelectable(id: $0) && seen.insert($0).inserted }
        guard kept != selectedIDs else { return }
        selectedIDs = kept
        let only = kept.count == 1 ? kept[0] : nil
        if only != onlySelectedID {
            onlySelectedID = only
            hoveredHandle = nil            // handles belong to the only selected shape
        }
        editor.setNeedsDisplay()
    }

    func hover(_ id: ShapeID?) {
        let kept = id.flatMap { isSelectable(id: $0) ? $0 : nil }
        guard kept != hoveredID else { return }
        hoveredID = kept
        editor.setNeedsDisplay()
    }
}

extension SelectionState: EditorService {
    func toolDidChange(from old: ToolID, to new: ToolID, in editor: CanvasEditor) {
        hover(nil)
        hoveredHandle = nil
    }

    func documentDidChange(in editor: CanvasEditor) {
        select(selectedIDs)
        hover(hoveredID)
    }

    /// A placed shape is the only one selected.
    func didPlace(_ id: ShapeID, in editor: CanvasEditor) { select([id]) }
}

extension CanvasEditor {
    var selectionState: SelectionState? { service(SelectionState.self) }

    /// Every selected shape, in the order it was selected, each once: setting drops ids that
    /// aren't there or aren't selectable, and repeats (the first is kept). Setting what's already
    /// selected does nothing (no redraw, no Observation notification). Changing which shape is the
    /// only selected one drops the hovered handle. Without the Selection plugin, always empty.
    public var selectedShapeIDs: [ShapeID] {
        get { selectionState?.selectedIDs ?? [] }
        set { selectionState?.select(newValue) }
    }

    /// The only selected shape: nil when none or several are (tldraw's onlySelectedShape). Setting
    /// it selects exactly that shape; nil selects none. Handles, Return and editing follow this, so
    /// they apply only to a lone shape. Observers of this hear only changes to the only selected
    /// shape, not 2 → 3.
    public var selection: ShapeID? {
        get { selectionState?.onlySelectedID }
        set { selectedShapeIDs = newValue.map { [$0] } ?? [] }
    }

    public func isSelected(_ id: ShapeID) -> Bool { selectedShapeIDs.contains(id) }

    /// Whether the shape is there and its kind's rule (`ShapeSelectability`) lets it be selected.
    public func isSelectable(_ id: ShapeID) -> Bool {
        guard let record = document[id], let state = selectionState else { return false }
        return state.isSelectable(record)
    }

    /// The union of the selected shapes' geometry bounds, in world units; nil with nothing
    /// selected. Shapes with no outline (nothing drawn) don't count.
    public var selectionBounds: CGRect? {
        let context = shapeContext
        let rects = selectedShapeIDs.compactMap { context.geometry(of: $0) }
            .filter { !$0.outline.isEmpty && !$0.bounds.isNull }.map(\.bounds)
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Whether a world point is inside the box around several selected shapes, where a press on
    /// empty space acts on the selection (tldraw's selection bounds). False with one or none.
    public func isInSelectionBox(_ point: CGPoint) -> Bool {
        selectedShapeIDs.count > 1 && selectionBounds?.contains(point) == true
    }

    /// Under the pointer in the select tool, outlined as a hover hint.
    public internal(set) var hovered: ShapeID? {
        get { selectionState?.hoveredID }
        set { selectionState?.hover(newValue) }
    }

    /// A handle of the only selected shape under the pointer (its definition's `Handle`).
    public internal(set) var hoveredHandle: AnyHashable? {
        get { selectionState?.hoveredHandle }
        set { selectionState?.hoveredHandle = newValue }
    }

    /// The marquee being dragged in the select tool, in world units; nil otherwise.
    public var brush: CGRect? { (session as? BrushingSession)?.brush }

    /// The front-most selectable shape under a world point: what the select tool presses and
    /// hovers. Nil without the Selection plugin.
    public func selectableShape(at point: CGPoint) -> ShapeID? {
        guard let state = selectionState else { return nil }
        return shape(at: point) { state.isSelectable($0) }
    }

    // MARK: Commands

    /// ⌘A (tldraw's selectAll): ends editing, switches to select, and selects every selectable
    /// shape in document order. Does nothing mid-gesture.
    public func selectAll() {
        guard session == nil else { return }
        endEditing()
        setTool(.select)
        selectedShapeIDs = document.shapes.map(\.id)
    }

    /// Delete: removes every selected shape in one transaction. willDelete handlers see them all,
    /// so arrows bound to them let go where they are.
    public func deleteSelection() {
        let ids = selectedShapeIDs
        guard !ids.isEmpty else { return }
        transact { $0.delete(Set(ids)) }         // the commit drops them from the selection
        hovered = nil                                   // and this, a hover over a shape that stays
    }

    /// Return: edits the only selected shape if its kind is editable.
    public func editSelection() {
        if let selection { beginEditing(selection) }
    }

    // MARK: Drawing

    /// The hover outline (in the select tool, with nothing under way), the selection's outlines,
    /// and the box around several selected shapes (tldraw's selection bounds). Unlike tldraw's,
    /// they stay while the selection moves, and follow it.
    var selectionOutlines: Outlines {
        var shapes: [ShapeID] = []
        if currentToolID == .select, session == nil, let hovered, !isSelected(hovered) {
            shapes.append(hovered)
        }
        shapes += selectedShapeIDs
        let box = selectedShapeIDs.count > 1 ? selectionBounds : nil
        return Outlines(shapes: shapes, rects: box.map { [$0] } ?? [])
    }
}
