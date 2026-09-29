import AppKit
import Canvas
import Geometry

/// The select tool (tldraw's). A plugin's canvas buttons win (a lock chip); then handles; then the
/// shape under the pointer, or something drawn for it outside it (`DecorationHits`: a title's pill);
/// then empty space inside a multi-selection's box; then the canvas, where a drag brushes. ⇧ adds to
/// the selection or takes away from it, and ⌘ (tldraw's accel) does too, without selecting on the
/// press. A lone box pressed without ⇧ or ⌘ follows the pointer from the press, with no drag
/// threshold, unless the press is on a face (`ShapeFaces`), which is still the shape's press but
/// waits for the threshold, so that a release within it can click the face. A click on a face that
/// goes somewhere makes the rest of its double-click the click's (`ignoresPress`). A plain click on
/// the shape that was already the only one selected, of a kind edited in place (a note), edits it
/// from where it's released (tldraw's), so that press waits for the threshold too; a double-click
/// edits a shape from where it's pressed.
final class SelectTool {}

extension SelectTool: Tool {
    func cursor(in editor: CanvasEditor) -> CanvasCursor {
        if let button = editor.selectionState?.hoveredButton { return button.source.cursor }
        return editor.hoveredHandle != nil ? .openHand : .standard
    }

    /// The rest of a double-click (a press whose click count is 2 or more) whose first click, on a
    /// face, went somewhere: to another selection or another view (a link's `goTo`). It's that
    /// click's, not a press of whatever the moving camera has brought under the pointer, so the
    /// camera goes on to where the click sent it, and nothing is placed, edited, pressed or brushed.
    /// A press that isn't (a click count of 1) ends that.
    func ignoresPress(_ pointer: Pointer, in editor: CanvasEditor) -> Bool {
        guard let state = editor.selectionState, state.clickWentElsewhere else { return false }
        guard pointer.clickCount >= 2 else {
            state.clickWentElsewhere = false
            return false
        }
        return true
    }

    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {
        // A Control-click is the Mac's secondary click: whatever menu it has, AppKit already showed.
        // It doesn't press. (Other tools still get it, as a press with ⌃ held.)
        guard !pointer.isControlClick else { return }
        // Whatever this press does to the selection, through the end of its drag, is one step back.
        editor.selectionState?.pressBegan()
        defer { editor.selectionState?.pressEnded() }
        if let hit = editor.buttonHit(atViewPoint: pointer.view) {
            editor.pressedButton = hit.button
            editor.session = PressingButtonSession(source: hit.source, button: hit.button, press: pointer.view)
            return
        }
        if let handle = editor.handle(atViewPoint: pointer.view) {
            editor.pressHandle(handle, with: pointer)
            return
        }
        defer { editor.hovered = nil }
        let shift = pointer.modifiers.contains(.shift)
        let command = pointer.modifiers.contains(.command)
        // tldraw ignores double clicks while adding to or toggling the selection.
        let isDoubleClick = pointer.clickCount == 2 && !shift && !command
        let insideSelection = editor.isInSelectionBox(pointer.world)
        guard let hit = editor.selectableHit(at: pointer.world), let record = editor.document[hit.id],
              let definition = editor.registry.definition(for: record.kind) else {
            if isDoubleClick, let placement = editor.registry.contributions(to: DoubleClickPlacement.self).first?.value {
                editor.selection = nil
                editor.place(placement, at: pointer.world)
            } else if insideSelection {
                editor.session = PointingSelectionSession(press: pointer.view)
            } else {
                if !shift && !command { editor.selection = nil }       // deselected on the press
                editor.session = PointingCanvasSession(press: pointer.view)
            }
            return
        }
        let id = hit.id
        // A face in the shape's content, asked only for a plain press.
        let isPlain = pointer.modifiers.isDisjoint(with: [.shift, .command, .option])
        let face = isPlain ? editor.faceHit(on: hit, at: pointer.world) : nil
        // tldraw's PointingShape: not selected on the press with ⌘, when already selected, or
        // inside a multi-selection's box; otherwise ⇧ adds it, and a plain press selects just it.
        let keepsSelection = command || editor.isSelected(id) || insideSelection
        let wasOnlySelection = editor.selectedShapeIDs == [id]
        if !keepsSelection {
            editor.selectedShapeIDs = shift ? editor.selectedShapeIDs + [id] : [id]
        }
        // A press never restacks: the shape keeps its place in the paint order (as in tldraw; the
        // POC brought it to the front).
        if isDoubleClick, let face, let doubleClick = face.source.doubleClick {
            editor.selection = id
            doubleClick(face.face, editor)
            return
        }
        // A double-click opens the shape, selected alone: its kind's opener (a board-owning kind's
        // shows its board), else editing, for an `Editable` kind, from where it's pressed if that's on
        // the shape itself (on what's drawn for it outside, a title's pill, the view puts the caret
        // where it would with no press: the press isn't in its text).
        if isDoubleClick, editor.canOpen(id) {
            editor.selection = id
            editor.open(id, at: hit.isOnShape ? pointer.world : nil, clickCount: pointer.clickCount)
            return
        }
        // A face waits for the drag threshold, even on a lone box: released within it, it clicks.
        if let face {
            editor.session = PointingShapeSession(shapeID: id, press: pointer.view, didSelectOnPress: !keepsSelection,
                                                  brushesOnDrag: false, face: face)
            return
        }
        // A click on the only selected shape edits it, if its kind is edited in place and it can
        // be (a locked one is only selected: a click isn't a try); a drag past the threshold moves it.
        // Not a click on what's drawn for it outside it (a title's pill), which isn't in its text,
        // nor the click that brings the window forward (as Finder's click-to-rename ignores it).
        if isPlain, pointer.clickCount == 1, hit.isOnShape, !pointer.activatesWindow, wasOnlySelection, definition is any Editable,
           !editor.isReadOnly(id) {
            editor.session = PointingShapeSession(shapeID: id, press: pointer.view, didSelectOnPress: false,
                                                  brushesOnDrag: false, editsOnClick: true)
            return
        }
        // A lone box follows the pointer from the press, with no drag threshold.
        if !shift, !command, editor.selectedShapeIDs == [id], record.box != nil, !(definition is any CustomTranslation) {
            editor.session = TranslatingSession(ids: [id], from: pointer.world, in: editor)
            return
        }
        editor.session = PointingShapeSession(shapeID: id, press: pointer.view,
                                              didSelectOnPress: !keepsSelection, brushesOnDrag: command)
    }

    func pointerMoved(_ pointer: Pointer, in editor: CanvasEditor) {
        editor.selectionState?.lastPointer = pointer.view
        let state = editor.selectionState
        if let hit = editor.buttonHit(atViewPoint: pointer.view) {
            state?.hoveredButton = hit
            editor.hoveredHandle = nil
            editor.hovered = nil
        } else if let handle = editor.handle(atViewPoint: pointer.view) {
            state?.hoveredButton = nil
            editor.hoveredHandle = handle
            editor.hovered = nil
        } else {
            state?.hoveredButton = nil
            editor.hoveredHandle = nil
            editor.hovered = editor.shapeToHover(at: pointer.world)
        }
    }

    func pointerExited(in editor: CanvasEditor) {
        editor.selectionState?.lastPointer = nil
        editor.hovered = nil
        editor.hoveredHandle = nil
        editor.selectionState?.hoveredButton = nil
    }

    /// Escape with nothing under way deselects all.
    func cancel(in editor: CanvasEditor) -> Bool {
        editor.selection = nil
        return true
    }
}

/// A shape was pressed (tldraw's PointingShape). Past the drag threshold the selection moves, or,
/// if ⌘ was held at the press, a brush starts from the press. Released without a drag, it settles
/// the selection, or, pressed on a face, selects the shape alone and clicks the face, or, pressed as
/// the only selected shape of a kind edited in place (`editsOnClick`), edits it from the release.
@MainActor
final class PointingShapeSession {
    let shapeID: ShapeID
    let press: CGPoint                 // view points
    let didSelectOnPress: Bool
    let brushesOnDrag: Bool
    let face: FaceHit?
    let editsOnClick: Bool
    init(shapeID: ShapeID, press: CGPoint, didSelectOnPress: Bool, brushesOnDrag: Bool, face: FaceHit? = nil, editsOnClick: Bool = false) {
        self.shapeID = shapeID
        self.press = press
        self.didSelectOnPress = didSelectOnPress
        self.brushesOnDrag = brushesOnDrag
        self.face = face
        self.editsOnClick = editsOnClick
    }
}

extension PointingShapeSession: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        guard pointer.view.distance(to: press) > Style.dragThreshold else { return }
        let origin = editor.camera.toWorld(press)
        let next: any Session
        if brushesOnDrag {
            next = BrushingSession(origin: origin, in: editor)
        } else {
            if editor.selectedShapeIDs.isEmpty { editor.selection = shapeID }
            next = TranslatingSession(ids: editor.selectedShapeIDs, from: origin, in: editor)
        }
        editor.session = next
        next.drag(pointer, in: editor)
    }

    /// tldraw's PointingShape.onPointerUp: the release point is hit-tested again. ⇧ or ⌘ toggles
    /// the shape there; otherwise it becomes the only selected shape. A click on a face is the
    /// face's, on its shape: that shape is selected alone, whatever's under the release, and the
    /// press is over before the face is clicked, so the click may go to shapes (`goTo`) or back,
    /// which do nothing mid-gesture, and what it selects is a step of its own. If it changes the
    /// selection or moves the camera, the rest of its double-click is its (`ignoresPress`).
    func end(_ pointer: Pointer, in editor: CanvasEditor) {
        if editsOnClick {
            // The press is over before editing begins: the release is the editing view's to take.
            editor.session = nil
            editor.beginEditing(shapeID, at: pointer.world)
            return
        }
        if let face {
            editor.selection = shapeID
            editor.session = nil
            let revision = editor.selectionRevision, camera = editor.cameraTarget
            face.click(in: editor)
            editor.selectionState?.clickWentElsewhere = editor.selectionRevision != revision || editor.cameraTarget != camera
            return
        }
        guard !didSelectOnPress else { return }
        let hit = editor.selectableShape(at: pointer.world) ?? shapeID
        let additive = !pointer.modifiers.isDisjoint(with: [.shift, .command])
        if editor.isSelected(hit) {
            if additive { editor.selectedShapeIDs.removeAll { $0 == hit } } else { editor.selection = hit }
        } else {
            editor.selectedShapeIDs = additive ? editor.selectedShapeIDs + [hit] : [hit]
        }
    }

    /// Escape drops the press (tldraw); the rest of the drag does nothing.
    func cancel(in editor: CanvasEditor) -> Bool { true }
}

/// tldraw's selectOnCanvasPointerUp: the release of a press on empty canvas, or on empty space in
/// a multi-selection's box. ⇧ or ⌘ toggles the shape under the release; otherwise it's selected
/// (if it isn't already), or with nothing there, nothing is.
@MainActor
func selectOnCanvasRelease(_ pointer: Pointer, in editor: CanvasEditor) {
    let additive = !pointer.modifiers.isDisjoint(with: [.shift, .command])
    guard let hit = editor.selectableShape(at: pointer.world) else {
        if !additive { editor.selection = nil }
        return
    }
    if additive {
        if editor.isSelected(hit) { editor.selectedShapeIDs.removeAll { $0 == hit } } else { editor.selectedShapeIDs += [hit] }
    } else if !editor.isSelected(hit) {
        editor.selection = hit
    }
}

/// Empty canvas was pressed (tldraw's PointingCanvas). Past the drag threshold, a brush. Escape
/// does nothing until the release, as in tldraw.
@MainActor
final class PointingCanvasSession {
    let press: CGPoint                 // view points
    init(press: CGPoint) { self.press = press }
}

extension PointingCanvasSession: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        guard pointer.view.distance(to: press) > Style.dragThreshold else { return }
        let brushing = BrushingSession(origin: editor.camera.toWorld(press), in: editor)
        editor.session = brushing
        brushing.drag(pointer, in: editor)
    }

    func end(_ pointer: Pointer, in editor: CanvasEditor) { selectOnCanvasRelease(pointer, in: editor) }
}

/// Empty space inside a multi-selection's box was pressed (tldraw's PointingSelection): a drag
/// moves the selection; a click is a click on the canvas.
@MainActor
final class PointingSelectionSession {
    let press: CGPoint                 // view points
    init(press: CGPoint) { self.press = press }
}

extension PointingSelectionSession: Session {
    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        guard pointer.view.distance(to: press) > Style.dragThreshold else { return }
        let move = TranslatingSession(ids: editor.selectedShapeIDs, from: editor.camera.toWorld(press), in: editor)
        editor.session = move
        move.drag(pointer, in: editor)
    }

    func end(_ pointer: Pointer, in editor: CanvasEditor) { selectOnCanvasRelease(pointer, in: editor) }

    func cancel(in editor: CanvasEditor) -> Bool { true }
}

/// A marquee from the press (tldraw's Brushing). It selects as it goes: what it touches, or with
/// ⌘ only what it strictly contains; with ⇧, added to the selection from before the brush. ⇧ and
/// ⌘ take effect as they change, without a pointer move. Escape restores the old selection.
@MainActor
final class BrushingSession {
    let origin: CGPoint                // world units, at the press
    let initial: [ShapeID]
    private(set) var brush: CGRect
    init(origin: CGPoint, in editor: CanvasEditor) {
        self.origin = origin
        initial = editor.selectedShapeIDs
        brush = CGRect(origin: origin, size: .zero)
    }

    private func update(to point: CGPoint, modifiers: Modifiers, in editor: CanvasEditor) {
        brush = CGRect(enclosing: [origin, point])
        let hits = editor.shapes(inBrush: brush, mustContain: modifiers.contains(.command))
        editor.selectedShapeIDs = modifiers.contains(.shift) ? initial + hits : hits    // the setter drops repeats
        editor.setNeedsDisplay()                                                       // the brush moved even if the selection didn't
    }
}

extension BrushingSession: Session {
    /// The canvas scrolls at its edges while it grows (tldraw's Brushing).
    var scrollsAtEdges: Bool { true }

    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        update(to: pointer.world, modifiers: pointer.modifiers, in: editor)
    }

    func modifiersChanged(_ modifiers: Modifiers, in editor: CanvasEditor) {
        update(to: editor.pointerWorldLocation, modifiers: modifiers, in: editor)
    }

    /// tldraw's complete: one last hit test, at the release point.
    func end(_ pointer: Pointer, in editor: CanvasEditor) {
        update(to: pointer.world, modifiers: pointer.modifiers, in: editor)
    }

    func cancel(in editor: CanvasEditor) -> Bool {
        editor.selectedShapeIDs = initial
        return true
    }

    func draw(in context: OverlayContext) {
        let cg = context.cg
        cg.setFillColor(SelectionStyle.brushFill.cgColor)
        cg.fill(brush)
        cg.setStrokeColor(SelectionStyle.brushStroke.cgColor)
        cg.setLineWidth(SelectionStyle.brushStrokeWidth / context.zoom)
        cg.stroke(brush)
    }
}
