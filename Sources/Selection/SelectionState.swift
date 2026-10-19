import Canvas
import CoreGraphics
import Geometry
import Observation

/// The selection, the way back through it, the hovered shape, the shape hovered where the canvas
/// doesn't show it, the hovered handle, and the canvas button hovered and pressed, one per editor.
/// Plugins reach them through `CanvasEditor`'s members below. The selection and the hover only ever
/// name selectable shapes in the document; the shape hovered elsewhere is one of the file's, on
/// another board; the handle is one of the only selected shape's.
@MainActor
@Observable
final class SelectionState {
    @ObservationIgnored unowned let editor: CanvasEditor
    /// Each kind's rule (`ShapeSelectability`), found once: the registry is frozen.
    @ObservationIgnored private let rules: [ShapeKind: @MainActor (AnyShapeRecord) -> Bool]
    /// Each kind's opener (`ShapeOpening`), found once.
    @ObservationIgnored let openers: [ShapeKind: ShapeOpener]
    /// The zoom each kind that says so reads at (`ReadableZoom`), found once.
    @ObservationIgnored let readableZooms: [ShapeKind: CGFloat]
    /// The smallest each resizable kind's shapes go (`ShapeResizing`), found once. A kind laid out
    /// past its box (`LaidOutBox`) is left out: handles on the box it stores would sit under a shape
    /// drawn larger, and a resize would write the stored box under it.
    @ObservationIgnored let minimumSizes: [ShapeKind: CGSize]
    private(set) var selectedIDs: [ShapeID] = []
    /// `selectedIDs`, for asking whether a shape is among them.
    @ObservationIgnored private(set) var selectedSet: Set<ShapeID> = []
    /// +1 each time `selectedIDs` changes.
    private(set) var revision = 0
    private(set) var onlySelectedID: ShapeID?
    /// The groups the selection is inside, outermost first (tldraw's focused group, as a path:
    /// `SelectionGroups`): a click on a shape in them selects a part of them, not the whole. Worked
    /// out from each selection (`focus(of:)`); an empty one keeps it, till a click outside it or
    /// Escape leaves it.
    @ObservationIgnored var focus: [AnyHashable] = [] {
        didSet { if focus != oldValue { editor.setNeedsDisplay() } }
    }
    /// Where the groups come from (`SelectionGroups`), asked for on first use: the plugin's service is
    /// made after this one.
    @ObservationIgnored var groupSourceFound: (any SelectionGroupSource)??
    /// Whether the hover is the pointer's over the canvas (the select tool's), which outlines what a
    /// click there would select (a whole group), rather than a plugin's (a row of a list), which
    /// outlines the shape alone.
    @ObservationIgnored var hoversCanvas = false
    /// The selections to go back to (`editor.goBack()`).
    private(set) var history = SelectionHistory()
    /// The select tool's press under way, from the press until the session it starts ends.
    @ObservationIgnored private var press: Press?
    /// Going back, which records nothing.
    @ObservationIgnored private var isGoingBack = false
    /// Doing what's one step back of its own (`asOneStep`), which records nothing else.
    @ObservationIgnored private var isOneStep = false
    /// A board was just shown, and nothing has been selected or pressed there since: the arrival's
    /// empty selection, which undo's restoring a selection there doesn't make a step of its own.
    @ObservationIgnored private var hasJustArrived = false
    /// Observed whole through `hoveredID`, and a shape at a time through `isHovered`.
    @ObservationIgnored private var storedHover: ShapeID?
    var hoveredID: ShapeID? {
        access(keyPath: \.hoveredID)
        return storedHover
    }
    /// The shape the pointer is on where a plugin shows one the canvas doesn't (`hoveredElsewhere`).
    /// Observed whole.
    private(set) var hoveredElsewhereID: ShapeID?
    var hoveredHandle: AnyHashable? {
        didSet {
            guard hoveredHandle != oldValue else { return }
            editor.setNeedsDisplay()
            editor.refreshCursor()
        }
    }
    /// Every plugin's canvas buttons (`CanvasButtons`), found once.
    @ObservationIgnored let buttonSources: [CanvasButtonSource]
    /// What plugins draw for shapes outside them (`DecorationHits`), found once: the last plugin's
    /// first, as its drawing is over the others'.
    @ObservationIgnored let decorationHits: [DecorationHits.Contribution]
    /// Every plugin's faces (`ShapeFaces`), found once: the last plugin's first.
    @ObservationIgnored let faceSources: [ShapeFaceSource]
    /// Every plugin's popovers (`ShapePopovers`), found once: the last plugin's first.
    @ObservationIgnored let popoverSources: [ShapePopoverSource]
    /// The button under the pointer, with its plugin's buttons, which say what the cursor is.
    @ObservationIgnored var hoveredButton: ButtonHit? {
        didSet {
            guard hoveredButton?.button != oldValue?.button || hoveredButton?.source.cursor != oldValue?.source.cursor else { return }
            editor.setNeedsDisplay()
            editor.refreshCursor()
        }
    }
    @ObservationIgnored var pressedButton: AnyHashable? {
        didSet { if pressedButton != oldValue { editor.setNeedsDisplay() } }
    }
    /// The select tool's last click was on a face, and went somewhere: it changed the selection or
    /// moved the camera (a link's `goTo`). The rest of its double-click is that click's
    /// (`SelectTool.ignoresPress`), until a press that isn't.
    @ObservationIgnored var clickWentElsewhere = false
    /// A smart zoom's (`smartMagnify`): the camera before it, and the one it went to, so the next
    /// goes back while the camera is still there.
    @ObservationIgnored var smartZoom: (before: Camera, shown: Camera)?
    /// Where the pointer was last seen over the canvas in the select tool, in view points: where to
    /// look for a button again when buttons change under a pointer that's still.
    @ObservationIgnored var lastPointer: CGPoint? {
        // What's drawn only while the pointer's over the canvas (a port's dots) comes and goes with it.
        didSet { if (lastPointer == nil) != (oldValue == nil) { editor.setNeedsDisplay() } }
    }
    /// The selection's bounds as last worked out (`selectionBounds`), and what from.
    @ObservationIgnored private var keptBounds: KeptBounds?
    #if DEBUG
    @ObservationIgnored private(set) var boundsWorkedOut = 0
    #endif

    init(editor: CanvasEditor) {
        self.editor = editor
        rules = editor.registry.contributionByKind(to: ShapeSelectability.self)
        openers = editor.registry.contributionByKind(to: ShapeOpening.self)
        readableZooms = editor.registry.contributionByKind(to: ReadableZoom.self)
        minimumSizes = editor.registry.contributionByKind(to: ShapeResizing.self).filter { !editor.registry.isLaidOutBox($0.key) }
        buttonSources = editor.registry.contributions(to: CanvasButtons.self).map(\.value)
        decorationHits = editor.registry.contributions(to: DecorationHits.self).map(\.value).reversed()
        faceSources = editor.registry.contributions(to: ShapeFaces.self).map(\.value).reversed()
        popoverSources = editor.registry.contributions(to: ShapePopovers.self).map(\.value).reversed()
    }

    /// The button under the pointer, looked for again: in the select tool, with nothing under way. A
    /// button found takes the hover, as the pointer moving onto it would.
    func findHoveredButton() {
        guard !buttonSources.isEmpty, editor.currentToolID == .select, editor.session == nil else { return }
        let hit = lastPointer.flatMap { editor.buttonHit(atViewPoint: $0) }
        hoveredButton = hit
        if hit != nil {
            hoveredHandle = nil
            hover(nil)
        }
    }

    /// What the pointer at a view point hovers in the select tool, as it moves there: a canvas
    /// button, else a handle of the only selected shape, else the shape there, or the one a face
    /// there names in its place (`shapeToHover`), and the popover that part of it shows, if any
    /// (`ShapePopovers`).
    func hover(atViewPoint point: CGPoint) {
        var popover: CanvasPopover?
        if let hit = editor.buttonHit(atViewPoint: point) {
            hoveredButton = hit
            hoveredHandle = nil
            hover(nil)
        } else if let handle = editor.handle(atViewPoint: point) {
            hoveredButton = nil
            hoveredHandle = handle
            hover(nil)
        } else {
            hoveredButton = nil
            hoveredHandle = nil
            let world = editor.camera.toWorld(point)
            let hit = editor.selectableHit(at: world)
            let hovering = editor.shapeToHover(hit, at: world)
            hover(hovering)
            // A face that names another shape (a pill's) outlines that shape alone: a click there doesn't select its group.
            hoversCanvas = hovering == hit?.id
            popover = hit.flatMap { editor.popoverHit(on: $0, at: world) }
        }
        editor.hoverPopover(popover)
    }

    /// The union of the selected shapes' geometry bounds, in world units (`selectionBounds`), kept
    /// while what it's worked out from stays as it was: the selection, the board's shapes (the
    /// editor's `revision`: every commit, undo and redo, another board shown), the layout (the editor's
    /// `layoutRevision`: shapes laid out again with no commit, a note whose type gained a field) and the
    /// camera (a kind's geometry may read it). So the box around several is worked out again only after one
    /// of those changed, which saves each read (the canvas's frame, the minimap's, a hover's
    /// `isInSelectionBox`) a pass over the selection; the selected shapes' outlines still go through
    /// every one of them each frame (on the canvas a lookup of each one's extent, only those in view
    /// stroked; in the minimap each one's silhouette). Any commit works it out again, not only one
    /// naming a selected shape, since a shape's geometry may follow another's (a link's, its ends').
    var selectionBounds: CGRect? {
        let document = editor.revision, layout = editor.layoutRevision, camera = editor.camera
        if let kept = keptBounds, kept.selection == revision, kept.document == document, kept.layout == layout, kept.camera == camera {
            return kept.bounds
        }
        let bounds = editor.shapeContext.bounds(of: selectedIDs)
        keptBounds = KeptBounds(selection: revision, document: document, layout: layout, camera: camera, bounds: bounds)
        #if DEBUG
        boundsWorkedOut += 1
        #endif
        return bounds
    }

    private struct KeptBounds {
        let selection: Int
        let document: Int
        let layout: Int
        let camera: Camera
        let bounds: CGRect?
    }

    /// Never a shape the board keeps aside; otherwise the kind's own rule, else one for every
    /// kind, else selectable.
    func isSelectable(_ record: AnyShapeRecord) -> Bool { !record.isOpaque && (rules[record.kind]?(record) ?? true) }

    func isSelectable(id: ShapeID) -> Bool { editor.document[id].map(isSelectable) ?? false }

    /// Drops what isn't there or isn't selectable, and repeats. Does nothing if that's what's
    /// selected already. Unless `recording` is false, the selection left is a step back. What the
    /// selection is inside (`focus`) is worked out again, unless nothing is selected now.
    func select(_ ids: [ShapeID], recording: Bool = true) {
        var seen = Set<ShapeID>()
        let kept = ids.filter { isSelectable(id: $0) && seen.insert($0).inserted }
        guard kept != selectedIDs else { return }
        hasJustArrived = false
        if recording { record(leaving: selectedIDs, for: kept) }
        let left = selectedIDs
        selectedIDs = kept
        selectedSet = seen
        if !kept.isEmpty { focus = focus(of: kept, selected: seen) }
        revision += 1
        let only = kept.count == 1 ? kept[0] : nil
        if only != onlySelectedID {
            onlySelectedID = only
            hoveredHandle = nil            // handles belong to the only selected shape
        }
        editor.setNeedsDisplay()
        tellObservers(left: left)
    }

    /// The plugins that follow the selection (`SelectionObservers`) are told it changed.
    private func tellObservers(left: [ShapeID]) {
        for observer in editor.registry.contributions(to: SelectionObservers.self) { observer.value(editor, left, selectedIDs) }
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
    func pressBegan() {
        press = Press()
        hasJustArrived = false
    }
    func pressEnded() { press?.isPressing = false }

    /// The selection is about to change from `previous` to `next`: `previous` goes on the stack,
    /// with the camera as it is now (or, mid-animation, where it's headed), unless this is going
    /// back or part of one step (`asOneStep`), it isn't the press's first change, or it only
    /// reorders the shapes.
    private func record(leaving previous: [ShapeID], for next: [ShapeID]) {
        guard !isGoingBack, !isOneStep else { return }
        if let current = press, !current.isPressing, editor.session == nil { press = nil }
        guard press?.isRecorded != true, Set(previous) != Set(next) else { return }
        press?.isRecorded = true
        history.push(SelectionHistory.Entry(board: editor.board, selection: previous, camera: editor.cameraTarget))
    }

    /// What going back to `entry` selects: its shapes, less any that are gone or can no longer be
    /// selected. On the board shown, nil if it would change nothing: its shapes are all gone
    /// (unless it selected nothing), or they're what's selected. On another board, nil only if the
    /// board can't be shown (its owner is gone); going there is a change, even to nothing selected.
    private func restoration(of entry: SelectionHistory.Entry) -> [ShapeID]? {
        guard entry.board == editor.board else {
            guard editor.canShow(entry.board) else { return nil }
            let shapes = editor.contents(of: entry.board)
            return entry.selection.filter { shapes[$0].map(isSelectable) ?? false }
        }
        let kept = entry.selection.filter { isSelectable(id: $0) }
        guard entry.selection.isEmpty || !kept.isEmpty, Set(kept) != Set(selectedIDs) else { return nil }
        return kept
    }

    /// Runs `body` as one step back, to the board and selection before it, with the camera as it
    /// was (or where it was headed), however many selections and boards it goes through; none if it
    /// leaves the board and the selection as they were.
    func asOneStep(_ body: () -> Void) {
        guard !isOneStep else { return body() }
        let entry = SelectionHistory.Entry(board: editor.board, selection: selectedIDs, camera: editor.cameraTarget)
        isOneStep = true
        body()
        isOneStep = false
        if editor.board != entry.board || Set(selectedIDs) != Set(entry.selection) { history.push(entry) }
    }

    /// Runs `body` as part of one step back to `entry` (`editor.navigate(from:_:)`), recording
    /// nothing of its own; `entry` goes on the stack the first time `body` moves the board, the
    /// selection or the camera, and not again while it's on the stack (a click or a pan between two
    /// calls adds no second copy; a call that moves nothing, after a pan, adds none).
    func asOneStep(from entry: SelectionHistory.Entry, _ body: () -> Void) {
        guard !isOneStep else { return body() }
        let board = editor.board, selection = Set(selectedIDs), camera = editor.cameraTarget
        isOneStep = true
        body()
        isOneStep = false
        guard editor.board != board || Set(selectedIDs) != selection || editor.cameraTarget != camera else { return }
        if !history.entries.contains(entry) { history.push(entry) }
    }

    /// Whether `goBack` would change the selection, or the board: some step on the stack would be
    /// restored.
    var canGoBack: Bool { history.entries.reversed().contains { restoration(of: $0) != nil } }

    /// Takes steps off the stack until one would change the selection or the board, and restores
    /// it: on the board shown, its selection and its camera (animated); on another, shows that
    /// board, then selects there, with the camera where it was (set, not animated: gliding from
    /// another board's camera means nothing).
    func goBack() {
        while let entry = history.pop() {
            guard let kept = restoration(of: entry) else { continue }
            isGoingBack = true
            defer { isGoingBack = false }
            guard entry.board != editor.board else {
                select(kept)
                editor.animateCamera(to: entry.camera, duration: SelectionStyle.goBackDuration)
                return
            }
            guard editor.showBoard(entry.board) else { return }
            select(kept)
            editor.camera = entry.camera
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

    /// The pointer is on a shape the canvas doesn't show, or leaves it (nil). Only a shape of the file
    /// that isn't on the board shown is kept: one that is is the hover's (`hover(_:)`), and one that
    /// isn't in the file isn't there.
    func hoverElsewhere(_ id: ShapeID?) {
        let kept = id.flatMap { editor.document[$0] == nil && editor.file.board(containing: $0) != nil ? $0 : nil }
        guard kept != hoveredElsewhereID else { return }
        hoveredElsewhereID = kept
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
        clearPointerState()
    }

    /// Another board is shown: what was selected on the board left is a step back (even nothing
    /// selected, so Back returns to that board), unless this is going back, part of one step
    /// (`asOneStep`: going into a shape), or a file put in place (opening one on the board left
    /// open, or a revert that took the board shown) came with the switch, which no one took;
    /// nothing is selected on arrival, which isn't a step of its own; and the press, the hover, the
    /// hover elsewhere, the handle and the canvas buttons, all the board left's, are let go.
    /// Keeps no state per board, so the switch's change set is never worked out.
    func boardDidChange(_ change: BoardChange, in editor: CanvasEditor) {
        if !isGoingBack && !isOneStep && !change.isFileReplaced {
            history.push(SelectionHistory.Entry(board: change.from, selection: selectedIDs, camera: change.leftCamera))
        }
        // Going back arrives at a step of its own, what it selects there.
        hasJustArrived = !isGoingBack
        clearPointerState()
        focus = []
        guard !selectedIDs.isEmpty else { return }
        let left = selectedIDs
        selectedIDs = []
        selectedSet = []
        onlySelectedID = nil
        revision += 1
        tellObservers(left: left)
    }

    /// What the pointer was doing: the press, the hover (and the one elsewhere), the hovered handle
    /// and canvas button, the pressed button, and where it was last seen.
    private func clearPointerState() {
        press = nil
        clickWentElsewhere = false
        hover(nil)
        hoverElsewhere(nil)
        hoveredHandle = nil
        hoveredButton = nil
        pressedButton = nil
        lastPointer = nil
    }

    func documentDidChange(_ changes: ChangeSet, in editor: CanvasEditor) {
        select(selectedIDs)
        hover(hoveredID)
        hoverElsewhere(hoveredElsewhereID)
        // A shape that became read-only has no handles.
        if hoveredHandle != nil, let id = onlySelectedID, editor.isReadOnly(id) { hoveredHandle = nil }
        // Buttons go with their shapes: one may have come or gone under the pointer.
        findHoveredButton()
    }

    /// A placed shape is the only one selected.
    func didPlace(_ id: ShapeID, in editor: CanvasEditor) { select([id]) }

    /// Shapes are drawn as skeletons now, or in full again, so their faces and adornments went or
    /// came (a note's pills, a lock chip) under a pointer that may be still: what it hovers is looked
    /// for again where it rests, as a move there would, in the select tool with nothing under way. A
    /// pill's target hovered as the level drops gives way to its note.
    func drawsSkeletonsDidChange(in editor: CanvasEditor) {
        guard editor.currentToolID == .select, editor.session == nil, let point = lastPointer else { return }
        hover(atViewPoint: point)
    }
}

/// The selection goes back and forth with undo, as tldraw's does: undoing a step selects what was
/// selected as it began (the shapes a Delete took, back selected), and redoing it what was as it
/// ended. It's an ordinary change of the selection, a step back like any other, except on a board
/// just shown (the one undo shows for a step made there), where the switch and the selection are
/// one step, as `showBoard(_:selecting:)` makes them: Back returns to the board left.
extension SelectionState: UndoParticipant {
    func undoSnapshot(in editor: CanvasEditor) -> any Sendable { selectedIDs }

    func restoreUndoSnapshot(_ snapshot: any Sendable, in editor: CanvasEditor) {
        if let ids = snapshot as? [ShapeID] { select(ids, recording: !hasJustArrived) }
    }
}

/// The shape the select tool presses at a point: on the shape itself, or on something a plugin draws
/// for it outside it (`DecorationHits`).
struct SelectableHit {
    let id: ShapeID
    let isOnShape: Bool
}

extension CanvasEditor {
    var selectionState: SelectionState? { service(SelectionState.self) }

    #if DEBUG
    /// How many times the selection's bounds have been worked out (debug builds only), so tests can
    /// hold a frame, or a read, to keeping them.
    public var selectionBoundsWorkedOut: Int { selectionState?.boundsWorkedOut ?? 0 }
    #endif

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
    /// selected. Shapes with no outline (nothing drawn) don't count. Kept from one read to the next
    /// while the selection, the board and the camera don't change.
    public var selectionBounds: CGRect? { selectionState?.selectionBounds }

    /// Whether a world point is inside the box around several selected shapes, where a press on
    /// empty space acts on the selection (tldraw's selection bounds). False with one or none.
    public func isInSelectionBox(_ point: CGPoint) -> Bool {
        selectedShapeIDs.count > 1 && selectionBounds?.contains(point) == true
    }

    /// The shape the pointer is over: on the canvas, where the select tool sets it as the pointer
    /// moves and clears it as the pointer leaves, or wherever else a plugin shows shapes (their rows
    /// in the table of contents). Outlined faintly unless it's selected, and not while a session
    /// runs. Setting it drops a shape that isn't there or isn't selectable; changing tools clears
    /// it. Set here, it's outlined alone, never with its group (the select tool's hover outlines what
    /// a click would select). Without the Selection plugin, always nil.
    public var hovered: ShapeID? {
        get { selectionState?.hoveredID }
        set {
            selectionState?.hover(newValue)
            selectionState?.hoversCanvas = false
        }
    }

    /// Whether this shape is `hovered`. Observers of it hear only this shape's hover change, not the
    /// hover moving between two others, so a view per shape (a row of the table of contents)
    /// redraws when its own shape's hover changes. Without the Selection plugin, false.
    public func isHovered(_ id: ShapeID) -> Bool { selectionState?.isHovered(id) ?? false }

    /// The shape the pointer is on where a plugin shows a shape the canvas doesn't: a row of another
    /// board's shapes in the table of contents, say. Any plugin may set it, and it's observed. A shape
    /// on the board shown isn't one (that is `hovered`), nor is one that isn't in the file: setting
    /// either drops it. Changing tools, showing another board and the shape leaving the file clear
    /// it. The canvas outlines faintly the shape on the board shown that holds it
    /// (`file.shape(on:holding:)`: a subboard's card, for a shape on its board at any depth), as it
    /// does the hover, while nothing is under way, and not on a selected shape; where `hovered` is a
    /// shape, that one is outlined alone. Without the Selection plugin, always nil.
    public var hoveredElsewhere: ShapeID? {
        get { selectionState?.hoveredElsewhereID }
        set { selectionState?.hoverElsewhere(newValue) }
    }

    /// A handle of the only selected shape under the pointer (its definition's `Handle`).
    public internal(set) var hoveredHandle: AnyHashable? {
        get { selectionState?.hoveredHandle }
        set { selectionState?.hoveredHandle = newValue }
    }

    /// The marquee being dragged in the select tool, in world units; nil otherwise.
    public var brush: CGRect? { (session as? BrushingSession)?.brush }

    /// The front-most selectable shape under a world point, counting what's drawn for a shape outside
    /// it (`DecorationHits`: above every shape, so asked first): what the select tool presses and
    /// hovers, and what a right-click's menu is for. Nil without the Selection plugin.
    public func selectableShape(at point: CGPoint) -> ShapeID? { selectableHit(at: point)?.id }

    /// `selectableShape(at:)`, and whether the point is on the shape itself.
    func selectableHit(at point: CGPoint) -> SelectableHit? {
        guard let state = selectionState else { return nil }
        for hits in state.decorationHits {
            if let id = hits(self, point, { state.isSelectable($0) }) { return SelectableHit(id: id, isOnShape: false) }
        }
        return shape(at: point) { state.isSelectable($0) }.map { SelectableHit(id: $0, isOnShape: true) }
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

    /// Delete: removes every selected shape in one transaction (`deleteShapes`).
    public func deleteSelection() { deleteShapes(selectedShapeIDs) }

    /// Removes these shapes in one transaction ("Delete"): what `.delete` does to its shapes.
    /// willDelete handlers see them all, so arrows bound to them let go where they are; a read-only
    /// one is refused, and shakes.
    public func deleteShapes(_ ids: [ShapeID]) {
        guard !ids.isEmpty else { return }
        transact("Delete") { $0.delete(Set(ids)) }   // the commit drops them from the selection
        hovered = nil                                   // and this, a hover over a shape that stays
    }

    /// Whether the arrow keys nudge: something's selected, and nothing's under way or being edited.
    public var canNudge: Bool { session == nil && editingShapeID == nil && !selectedShapeIDs.isEmpty }

    /// An arrow key's nudge: moves every selected shape by `delta`, in world units, as `translate`
    /// does, in one transaction ("Move"), with no snapping. Read-only shapes stay, refused (a locked
    /// one shakes), and the rest move. Does nothing unless it `canNudge`.
    public func nudgeSelection(by delta: CGPoint) {
        guard canNudge else { return }
        let ids = Set(selectedShapeIDs)
        transact("Move") { $0.translate(ids, by: delta) }
    }

    /// Edits the only selected shape if its kind is editable, whatever else opening it would do
    /// (Return opens it: `openSelection`).
    public func editSelection() {
        if let selection { beginEditing(selection) }
    }

    /// Go › Back (⌘[; data-canvas's goBack): selects what was selected before the selection last
    /// changed, and moves the camera back to where it was when that selection was left (where it
    /// was headed, if it was moving), animated.
    /// Each change of the selection is a step back, however it came (a click, a row of the table of
    /// contents, Escape, a deletion), except that a press of the select tool and its drag are one
    /// step, and going back isn't one. So is showing another board, even with nothing selected:
    /// going back to a step on another board shows that board, then selects there, and puts the
    /// camera where it was (not animated). The stack holds the last 50 steps, skips repeats, and
    /// skips a selection whose shapes have all gone on the board shown, and a step on a board that
    /// can't be shown (its owner deleted). Ends editing; does nothing mid-gesture.
    public func goBack() {
        guard session == nil, let state = selectionState else { return }
        endEditing()
        state.goBack()
    }

    // MARK: Drawing

    /// The selection's outlines, the box around several selected shapes (tldraw's selection
    /// bounds), and, with nothing under way, the hover's faint outline (the core leaves it out on
    /// a selected shape): the shape hovered, else, for one hovered elsewhere (a row of a shape the
    /// canvas doesn't show), the shape on the board shown that holds it. Unlike tldraw's, the
    /// selection's stay while it moves, and follow it, and the hover's is fainter than theirs, so a
    /// hovered shape doesn't read as selected.
    var selectionOutlines: Outlines {
        let box = selectedShapeIDs.count > 1 ? selectionBounds : nil
        return Outlines(shapes: selectedShapeIDs, rects: box.map { [$0] } ?? [], faintShapes: session == nil ? hoverOutlines : [])
    }

    /// What the hover outlines faintly: the shape hovered (on the canvas, what a click there would
    /// select: its group, whole), else the shape on the board shown that holds the one hovered
    /// elsewhere, none if no shape on it does (one on a board above).
    private var hoverOutlines: [ShapeID] {
        if let hovered {
            guard let state = selectionState, state.hoversCanvas else { return [hovered] }
            return state.unit(of: hovered, within: state.focus)
        }
        guard let elsewhere = hoveredElsewhere, let holder = file.shape(on: board, holding: elsewhere) else { return [] }
        return [holder]
    }
}
