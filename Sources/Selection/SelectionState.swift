import Canvas
import CoreGraphics
import Observation

/// The selection, the way back through it, the hovered shape and the hovered handle, one per
/// editor. Plugins reach them through `CanvasEditor`'s members below. The selection and the hover
/// only ever name selectable shapes in the document; the handle is one of the only selected shape's.
@MainActor
@Observable
final class SelectionState {
    @ObservationIgnored private unowned let editor: CanvasEditor
    /// Each kind's rule (`ShapeSelectability`), found once: the registry is frozen.
    @ObservationIgnored private let rules: [ShapeKind: @MainActor (AnyShapeRecord) -> Bool]
    private(set) var selectedIDs: [ShapeID] = []
    /// +1 each time `selectedIDs` changes.
    private(set) var revision = 0
    private(set) var onlySelectedID: ShapeID?
    /// The selections to go back to (`editor.goBack()`).
    private(set) var history = SelectionHistory()
    /// The select tool's press under way, from the press until the session it starts ends.
    @ObservationIgnored private var press: Press?
    /// Going back, which records nothing.
    @ObservationIgnored private var isGoingBack = false
    /// Observed whole through `hoveredID`, and a shape at a time through `isHovered`.
    @ObservationIgnored private var storedHover: ShapeID?
    var hoveredID: ShapeID? {
        access(keyPath: \.hoveredID)
        return storedHover
    }
    var hoveredHandle: AnyHashable? {
        didSet {
            guard hoveredHandle != oldValue else { return }
            editor.setNeedsDisplay()
            editor.refreshCursor()
        }
    }

    init(editor: CanvasEditor) {
        self.editor = editor
        rules = editor.registry.contributionByKind(to: ShapeSelectability.self)
    }

    /// Never a shape the board keeps aside; otherwise the kind's own rule, else one for every
    /// kind, else selectable.
    func isSelectable(_ record: AnyShapeRecord) -> Bool { !record.isOpaque && (rules[record.kind]?(record) ?? true) }

    private func isSelectable(id: ShapeID) -> Bool { editor.document[id].map(isSelectable) ?? false }

    /// Drops what isn't there or isn't selectable, and repeats. Does nothing if that's what's
    /// selected already.
    func select(_ ids: [ShapeID]) {
        var seen = Set<ShapeID>()
        let kept = ids.filter { isSelectable(id: $0) && seen.insert($0).inserted }
        guard kept != selectedIDs else { return }
        record(leaving: selectedIDs, for: kept)
        selectedIDs = kept
        revision += 1
        let only = kept.count == 1 ? kept[0] : nil
        if only != onlySelectedID {
            onlySelectedID = only
            hoveredHandle = nil            // handles belong to the only selected shape
        }
        editor.setNeedsDisplay()
    }

    // MARK: Going back

    /// A press of the select tool. Every selection change it makes, from the press through the
    /// session it starts (the marquee's, a release that settles the selection), is one step back,
    /// to the selection before the press. The press is over once its session is, which is noticed
    /// at the next change.
    private struct Press {
        /// The select tool is still handling the press, before it starts any session.
        var isPressing = true
        var isRecorded = false
    }

    /// The select tool calls these around its handling of a press.
    func pressBegan() { press = Press() }
    func pressEnded() { press?.isPressing = false }

    /// The selection is about to change from `previous` to `next`: `previous` goes on the stack,
    /// with the camera as it is now (or, mid-animation, where it's headed), unless this is going
    /// back, it isn't the press's first change, or it only reorders the shapes.
    private func record(leaving previous: [ShapeID], for next: [ShapeID]) {
        guard !isGoingBack else { return }
        if let current = press, !current.isPressing, editor.session == nil { press = nil }
        guard press?.isRecorded != true, Set(previous) != Set(next) else { return }
        press?.isRecorded = true
        history.push(SelectionHistory.Entry(selection: previous, camera: editor.cameraTarget))
    }

    /// What going back to `entry` selects: its shapes, less any that are gone or can no longer be
    /// selected. Nil if it would change nothing: its shapes are all gone (unless it selected
    /// nothing), or they're what's selected.
    private func restoration(of entry: SelectionHistory.Entry) -> [ShapeID]? {
        let kept = entry.selection.filter { isSelectable(id: $0) }
        guard entry.selection.isEmpty || !kept.isEmpty, Set(kept) != Set(selectedIDs) else { return nil }
        return kept
    }

    /// Whether `goBack` would change the selection: some step on the stack would be restored.
    var canGoBack: Bool { history.entries.reversed().contains { restoration(of: $0) != nil } }

    /// Takes steps off the stack until one would change the selection, and restores it and its
    /// camera (animated).
    func goBack() {
        while let entry = history.pop() {
            guard let kept = restoration(of: entry) else { continue }
            isGoingBack = true
            select(kept)
            isGoingBack = false
            editor.animateCamera(to: entry.camera, duration: SelectionStyle.goBackDuration)
            return
        }
    }

    // MARK: Hovering

    func hover(_ id: ShapeID?) {
        let kept = id.flatMap { isSelectable(id: $0) ? $0 : nil }
        let left = storedHover
        guard kept != left else { return }
        withMutation(keyPath: \.hoveredID) {
            changingHover(of: left) { changingHover(of: kept) { storedHover = kept } }
        }
        editor.setNeedsDisplay()
    }

    /// Whether `id` is the hovered shape. Observing it hears only this shape's hover change.
    func isHovered(_ id: ShapeID) -> Bool {
        access(keyPath: \.[hovering: id])
        return storedHover == id
    }

    /// Runs `change` as a change to `id`'s hover, for whoever observes that shape's (`isHovered`).
    private func changingHover(of id: ShapeID?, _ change: () -> Void) {
        guard let id else { return change() }
        withMutation(keyPath: \.[hovering: id], change)
    }

    /// Only a key: one key path per shape, under which Observation keeps the observers of that
    /// shape's hover apart from every other shape's.
    private subscript(hovering id: ShapeID) -> Bool { storedHover == id }
}

extension SelectionState: EditorService {
    func toolDidChange(from old: ToolID, to new: ToolID, in editor: CanvasEditor) {
        press = nil
        hover(nil)
        hoveredHandle = nil
    }

    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
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

    /// +1 each time the selection changes, as `revision` counts document changes. A plugin that
    /// remembers a selection it made can tell whether it's still the one in place, even once the
    /// same shapes have been deselected and selected again. Without the Selection plugin, 0.
    public var selectionRevision: Int { selectionState?.revision ?? 0 }

    public func isSelected(_ id: ShapeID) -> Bool { selectedShapeIDs.contains(id) }

    /// Whether going back (`goBack`) would change the selection: there's a step back whose shapes
    /// aren't all gone, and aren't what's selected. Without the Selection plugin, false.
    public var canGoBack: Bool { selectionState?.canGoBack ?? false }

    /// Whether the shape is there and its kind's rule (`ShapeSelectability`) lets it be selected.
    public func isSelectable(_ id: ShapeID) -> Bool {
        guard let record = document[id], let state = selectionState else { return false }
        return state.isSelectable(record)
    }

    /// The union of the selected shapes' geometry bounds, in world units; nil with nothing
    /// selected. Shapes with no outline (nothing drawn) don't count.
    public var selectionBounds: CGRect? { shapeContext.bounds(of: selectedShapeIDs) }

    /// Whether a world point is inside the box around several selected shapes, where a press on
    /// empty space acts on the selection (tldraw's selection bounds). False with one or none.
    public func isInSelectionBox(_ point: CGPoint) -> Bool {
        selectedShapeIDs.count > 1 && selectionBounds?.contains(point) == true
    }

    /// The shape the pointer is over: on the canvas, where the select tool sets it as the pointer
    /// moves and clears it as the pointer leaves, or wherever else a plugin shows shapes (their rows
    /// in the table of contents). Outlined faintly unless it's selected, and not while a session
    /// runs. Setting it drops a shape that isn't there or isn't selectable; changing tools clears
    /// it. Without the Selection plugin, always nil.
    public var hovered: ShapeID? {
        get { selectionState?.hoveredID }
        set { selectionState?.hover(newValue) }
    }

    /// Whether this shape is `hovered`. Observers of it hear only this shape's hover change, not the
    /// hover moving between two others, so a view per shape (a row of the table of contents)
    /// redraws when its own shape's hover changes. Without the Selection plugin, false.
    public func isHovered(_ id: ShapeID) -> Bool { selectionState?.isHovered(id) ?? false }

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

    /// Go › Back (⌘[; data-canvas's goBack): selects what was selected before the selection last
    /// changed, and moves the camera back to where it was when that selection was left (where it
    /// was headed, if it was moving), animated.
    /// Each change of the selection is a step back, however it came (a click, a row of the table of
    /// contents, Escape, a deletion), except that a press of the select tool and its drag are one
    /// step, and going back isn't one. The stack holds the last 50 steps, skips repeats, and skips
    /// a selection whose shapes have all gone. Ends editing; does nothing mid-gesture.
    public func goBack() {
        guard session == nil, let state = selectionState else { return }
        endEditing()
        state.goBack()
    }

    // MARK: Drawing

    /// The selection's outlines, the box around several selected shapes (tldraw's selection
    /// bounds), and, with nothing under way, the hover's faint outline (the core leaves it out on
    /// a selected shape). Unlike tldraw's, the selection's stay while it moves, and follow it, and
    /// the hover's is fainter than theirs, so a hovered shape doesn't read as selected.
    var selectionOutlines: Outlines {
        let box = selectedShapeIDs.count > 1 ? selectionBounds : nil
        let hover = session == nil ? hovered.map { [$0] } ?? [] : []
        return Outlines(shapes: selectedShapeIDs, rects: box.map { [$0] } ?? [], faintShapes: hover)
    }
}
