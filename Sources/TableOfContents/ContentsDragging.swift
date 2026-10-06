import AppKit
import Canvas
import Selection
import SwiftUI
import UniformTypeIdentifiers

// Dragging rows: a row is a drag of its shape (the selection's, when it's selected: the list drags
// every selected row then), and a drop on a row puts what's dragged above it, on it, or below it.
// Above or below a row, a drop puts the shapes beside its shape, in front of it or behind it, in its
// container or on its board directly; on a frame's or a subboard's row, in front of what it holds.
// A drop that leaves the shapes in their container restacks them, one step called Reorder; one that
// takes them elsewhere is `ContentsMoves`' (Moving's), which places them on the canvas and restacks
// them as one step. Rows of a board open under its owner's are rows like any other: a drop there
// is on that board, and they're dragged as the board shown's are.

/// Where a drag over a row points: above it, on it, or below it, as the list shows them (front to
/// back: above is in front).
public enum ContentsDropZone: Hashable, Sendable {
    case above, on, below
}

/// Where on the list a drag points: a row, and where on it.
public struct ContentsDropTarget: Hashable, Sendable {
    public let row: ShapeID
    public let zone: ContentsDropZone

    public init(row: ShapeID, zone: ContentsDropZone) {
        self.row = row
        self.zone = zone
    }
}

extension UTType {
    /// What a row's drag carries: its shape's id, seen only by this app (an item provider's
    /// `.ownProcess`), so dropping one in another app does nothing. The app declares it.
    static let contentsRows = UTType(exportedAs: "com.example.InfiniteCanvas.contents-rows", conformingTo: .data)
}

/// The drag under way from a table of contents, any window's: the editor whose list it began in,
/// and its shapes. A drag of rows ends in a drop or nowhere, and AppKit doesn't tell the list which,
/// so it's kept until the next begins: a list takes a drop only of a drag it began itself.
@MainActor
enum ContentsDrag {
    static var current: (editor: ObjectIdentifier, shapes: [ShapeID])?
    /// Counts the drags begun, so what's worked out for one isn't taken for the next.
    static var serial = 0
}

extension ContentsState {
    // MARK: Dragging

    /// What a drag of the shape's row takes: the selected shapes that can move and whose rows show (the
    /// list's table drags every selected row that shows then), in document order, when it's selected;
    /// else the shape alone. Nothing for a row whose shape can't move: one with no box (an arrow), kept
    /// aside, read-only (locked, or in a locked frame), or on a board the editor can't show. The table
    /// asks for every dragged row, so a selection's is worked out once, until the board, the selection or
    /// a row's disclosure changes.
    public func dragged(from id: ShapeID) -> [ShapeID] {
        guard movable(id) else { return [] }
        guard editor.isSelected(id) else { return [id] }
        if let kept = selectionDrag, kept.revision == editor.revision, kept.selectionRevision == editor.selectionRevision, kept.turns == turns {
            return kept.shapes
        }
        let shapes = inDocumentOrder(Set(editor.selectedShapeIDs.filter { movable($0) && showsRow(of: $0) }))
        selectionDrag = (editor.revision, editor.selectionRevision, turns, shapes)
        return shapes
    }

    /// A drag of the shape's row begins: what it takes is the drag under way (`dragShapes`). False for
    /// a row that doesn't drag.
    @discardableResult
    public func beginDrag(from id: ShapeID) -> Bool {
        let shapes = dragged(from: id)
        guard !shapes.isEmpty else { return false }
        if let current = ContentsDrag.current, current.editor == ObjectIdentifier(editor), current.shapes == shapes { return true }
        ContentsDrag.current = (ObjectIdentifier(editor), shapes)
        ContentsDrag.serial += 1
        return true
    }

    /// The shapes of the drag under way, if it began in this list.
    public var dragShapes: [ShapeID]? {
        guard let current = ContentsDrag.current, current.editor == ObjectIdentifier(editor) else { return nil }
        return current.shapes
    }

    /// What the row's drag carries, as it begins; nil for a row that doesn't drag (its row isn't
    /// dragged, whatever's selected). As plain data too, the type each row's drop target is registered
    /// for (SwiftUI's), so AppKit hands it the drag whether or not the system has read the app's
    /// declaration of the private type; the target takes only a drag with the private type.
    func dragItem(from id: ShapeID) -> NSItemProvider? {
        guard beginDrag(from: id) else { return nil }
        let provider = NSItemProvider()
        for type in [UTType.contentsRows, .data] {
            provider.registerDataRepresentation(forTypeIdentifier: type.identifier, visibility: .ownProcess) { done in
                done(Data(id.description.utf8), nil)
                return nil
            }
        }
        return provider
    }

    /// Whether a shape's row drags: a box, not kept aside, that can change, on a board the editor can
    /// show.
    private func movable(_ id: ShapeID) -> Bool {
        let file = editor.file
        guard let board = file.board(containing: id), let record = file[board][id], !record.isOpaque, record.box != nil,
              editor.canShow(board) else { return false }
        return !editor.registry.isReadOnly(record, in: editor.contents(of: board))
    }

    // MARK: Dropping

    /// Where a drag at `fraction` of a row's height (0 its top, 1 its bottom) points. On a row whose
    /// shape takes shapes (a frame's, a subboard's) the middle is on it, the top and bottom quarters
    /// above and below it (`ContentsStyle.dropEdge`); on any other, halves. Below a row that's open
    /// onto rows of its own is above the first of them: on it, for a row that takes shapes; nowhere,
    /// for one that doesn't (an arrow's shape's).
    public func target(onRow entry: ContentsEntry, at fraction: CGFloat) -> ContentsDropTarget? {
        let opens = isExpanded(entry) && (entry.children != nil || boardToOpen(under: entry) != nil)
        if takesShapes(entry.id) {
            if fraction < ContentsStyle.dropEdge { return ContentsDropTarget(row: entry.id, zone: .above) }
            if fraction > 1 - ContentsStyle.dropEdge, !opens { return ContentsDropTarget(row: entry.id, zone: .below) }
            return ContentsDropTarget(row: entry.id, zone: .on)
        }
        if fraction < 0.5 { return ContentsDropTarget(row: entry.id, zone: .above) }
        return opens ? nil : ContentsDropTarget(row: entry.id, zone: .below)
    }

    /// Whether the drag under way can drop at `target`, at the place it names (`place(for:)`): its shapes
    /// all in that place's container already, beside a shape that isn't one of them (not on a frame's or
    /// subboard's row: that's where they are); or the move's contributor takes them there
    /// (`ContentsMoves`, which refuses a place that goes with them). Asked on every move of the pointer
    /// over a row, so the answer is kept for the drag, the target and the editor's revision.
    public func admits(_ target: ContentsDropTarget) -> Bool {
        if let kept = admitted, kept.drag == ContentsDrag.serial, kept.revision == editor.revision, kept.target == target { return kept.answer }
        let answer = admitting(target)
        admitted = (ContentsDrag.serial, editor.revision, target, answer)
        return answer
    }

    private func admitting(_ target: ContentsDropTarget) -> Bool {
        guard let shapes = dragShapes, let place = place(for: target) else { return false }
        if isIn(shapes, place) { return place.position != .front && !(place.neighbor.map(shapes.contains) ?? false) }
        return mover?.admits(shapes, place, editor) ?? false
    }

    /// Drops the drag under way at `target`, if it admits it: restacked where it points, in one step
    /// called Reorder, if its shapes are all in the place's container already; else moved there by
    /// `ContentsMoves`' contributor. Whether it did. The drag is over either way.
    @discardableResult
    public func drop(on target: ContentsDropTarget) -> Bool {
        defer {
            if dragShapes != nil { ContentsDrag.current = nil }
            point(nil)
        }
        guard admits(target), let shapes = dragShapes, let place = place(for: target) else { return false }
        if isIn(shapes, place) {
            restack(shapes, at: place)
        } else {
            mover?.move(shapes, place, editor)
        }
        return true
    }

    /// The place a target names: on a frame's row, in the frame, in front of what it holds; on a
    /// subboard's row, on its board, in front of what it holds there; above or below a row, beside its
    /// shape where it is (its container, or its board directly), in front of it or behind it. Nil on a
    /// row whose shape takes nothing, for a shape with no box (an arrow: where it's stacked doesn't
    /// say where it's drawn), and beside a row nested under something other than its container (a
    /// shape it's pinned to): it isn't where its shape is.
    func place(for target: ContentsDropTarget) -> ContentsPlace? {
        let file = editor.file, registry = editor.registry
        guard let board = file.board(containing: target.row), let record = file[board][target.row], !record.isOpaque else { return nil }
        switch target.zone {
        case .on:
            if registry.ownsShowableBoard(record) { return ContentsPlace(board: BoardID(owner: target.row), container: nil, position: .front) }
            guard registry.isContainer(record) else { return nil }
            return ContentsPlace(board: board, container: target.row, position: .front)
        case .above, .below:
            guard record.box != nil else { return nil }
            let container = registry.container(of: record, in: editor.contents(of: board))
            if let named = kindNestingParent(of: record), named != container { return nil }
            return ContentsPlace(board: board, container: container, position: target.zone == .above ? .inFront(of: target.row) : .behind(target.row))
        }
    }

    /// Whether the shape's row is one a drop on it takes shapes into: a frame's or a subboard's.
    private func takesShapes(_ id: ShapeID) -> Bool {
        guard let record = editor.file.record(id), !record.isOpaque else { return false }
        return editor.registry.ownsShowableBoard(record) || editor.registry.isContainer(record)
    }

    /// Whether every shape is on the place's board, in its container (directly).
    private func isIn(_ shapes: [ShapeID], _ place: ContentsPlace) -> Bool {
        let document = editor.contents(of: place.board), kinds = editor.registry.containingKinds
        return shapes.allSatisfy { id in document[id] != nil && document.container(of: id, containingKinds: kinds) == place.container }
    }

    /// Restacks shapes in their container where `place` says, keeping their order among themselves.
    /// One step, Reorder.
    private func restack(_ shapes: [ShapeID], at place: ContentsPlace) {
        let kinds = editor.registry.containingKinds
        editor.transact(ContentsStyle.reorderStep) { place.restack(shapes, in: &$0, containingKinds: kinds) }
    }

    /// The contributor that moves shapes somewhere they aren't (`ContentsMoves`), if one is installed.
    private var mover: ContentsMoveContribution? {
        editor.registry.contributions(to: ContentsMoves.self).first?.value
    }

    // MARK: Pointing

    /// The drag under way moved over a row, `fraction` of the way down it (0 its top, 1 its bottom):
    /// where it points now, if it can drop there (`target(onRow:at:)`, `admits(_:)`), which the row
    /// shows (`dropZone(for:)`); nil, and nothing shown there, where it can't. Resting on a closed row
    /// that opens onto rows (a subboard's, a closed frame's) opens it after a while
    /// (`ContentsStyle.springDelay`), as Finder's folders spring open, unless it moves off first.
    @discardableResult
    public func dragMoved(over entry: ContentsEntry, at fraction: CGFloat) -> ContentsDropTarget? {
        let target = target(onRow: entry, at: fraction).flatMap { admits($0) ? $0 : nil }
        if let target { point(target, opening: entry) } else { endPointing(at: entry.id) }
        return target
    }

    /// The drag under way left a row: nothing shows there any more.
    public func dragLeft(_ entry: ContentsEntry) {
        endPointing(at: entry.id)
    }

    /// The drag under way dropped on a row, `fraction` of the way down it: `drop(on:)` where it points
    /// there. Whether it took it.
    @discardableResult
    public func drop(onRow entry: ContentsEntry, at fraction: CGFloat) -> Bool {
        guard let target = target(onRow: entry, at: fraction) else {
            endPointing(at: entry.id)
            return false
        }
        return drop(on: target)
    }

    /// The row a drag points at, and where on it, for that row's line or ring (`dropZone(for:)`); nil
    /// for none. Pointing on a closed row that opens onto rows a while opens it.
    func point(_ target: ContentsDropTarget?, opening entry: ContentsEntry? = nil) {
        if target?.zone != .on || target?.row != springing?.entry.id {
            springing?.task.cancel()
            springing = nil
        }
        if let target, target.zone == .on, springing == nil, let entry, entry.id == target.row, !isExpanded(entry),
           entry.children != nil || boardToOpen(under: entry) != nil {
            let task = editor.scheduler.schedule(after: ContentsStyle.springDelay) { [weak self] in
                guard let self, let springing, springing.entry.id == entry.id else { return }
                self.springing = nil
                if pointedDrop == target { setExpanded(entry, true) }
            }
            springing = (entry, task)
        }
        guard target != pointedDrop else { return }
        let old = pointedDrop?.row
        withMutation(keyPath: \.[dropZone: old ?? target!.row]) {
            withMutation(keyPath: \.[dropZone: target?.row ?? old!]) {
                pointedDrop = target
            }
        }
    }

    /// The drag left the row, if it was what the drag pointed at.
    func endPointing(at row: ShapeID) {
        guard pointedDrop?.row == row else { return }
        point(nil)
    }

    /// Where on the shape's row a drag points, if it does: its line above or below, or its ring.
    /// Observing it hears only this row's changes.
    public func dropZone(for id: ShapeID) -> ContentsDropZone? {
        access(keyPath: \.[dropZone: id])
        return pointedDrop?.row == id ? pointedDrop?.zone : nil
    }

    /// Only a key: one key path per shape, under which Observation keeps the observers of each row's
    /// line and ring apart.
    private subscript(dropZone id: ShapeID) -> Bool { pointedDrop?.row == id }
}

/// A drop on a row, SwiftUI's own target for each row's view, to which AppKit hands a drag of rows
/// over it: where on the row's height the drag is, for the state to point at (`dragMoved(over:at:)`)
/// and drop on (`drop(onRow:at:)`). Only a drag of rows from this list (`dragShapes`).
struct ContentsRowDrop: DropDelegate {
    let entry: ContentsEntry
    let state: ContentsState
    let height: CGFloat

    private func fraction(_ info: DropInfo) -> CGFloat? {
        height > 0 ? info.location.y / height : nil
    }

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.contentsRows]) && state.dragShapes != nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        let target = fraction(info).flatMap { state.dragMoved(over: entry, at: $0) }
        return DropProposal(operation: target == nil ? .forbidden : .move)
    }

    func dropExited(info: DropInfo) {
        state.dragLeft(entry)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let fraction = fraction(info) else {
            state.dragLeft(entry)
            return false
        }
        return state.drop(onRow: entry, at: fraction)
    }
}

/// A drop's line above or below a row, from a ring at its leading end, in the accent color, as a
/// Mac list's.
struct ContentsDropLine: View {
    var body: some View {
        HStack(spacing: 0) {
            Circle()
                .strokeBorder(Color.accentColor, lineWidth: ContentsStyle.dropLineWidth)
                .frame(width: ContentsStyle.dropLineDot, height: ContentsStyle.dropLineDot)
            Rectangle()
                .fill(Color.accentColor)
                .frame(height: ContentsStyle.dropLineWidth)
        }
        .frame(height: ContentsStyle.dropLineDot)
        .allowsHitTesting(false)
    }
}

/// A drop on a row: its highlight's shape, ringed in the accent color, faintly tinted.
struct ContentsDropHighlight: View {
    var body: some View {
        RoundedRectangle(cornerRadius: ContentsStyle.highlightRadius, style: .continuous)
            .fill(Color.accentColor.opacity(ContentsStyle.dropTintOpacity))
            .strokeBorder(Color.accentColor, lineWidth: ContentsStyle.dropRingWidth)
            .padding(.horizontal, ContentsStyle.highlightInset)
    }
}
