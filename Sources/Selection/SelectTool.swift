import AppKit
import Canvas
import Geometry

/// The select tool (tldraw's). Handles win; then the shape under the pointer; then empty
/// space inside a multi-selection's box; then the canvas, where a drag brushes. ⇧ adds to the
/// selection or takes away from it, and ⌘ (tldraw's accel) does too, without selecting on the
/// press. A lone box pressed without ⇧ or ⌘ follows the pointer from the press, with no drag
/// threshold.
final class SelectTool {}

extension SelectTool: Tool {
    func cursor(in editor: CanvasEditor) -> CanvasCursor { editor.hoveredHandle != nil ? .openHand : .standard }

    func pointerDown(_ pointer: Pointer, in editor: CanvasEditor) {
        // A Control-click is the Mac's secondary click: whatever menu it has, AppKit already showed.
        // It doesn't press. (Tools that read ⌃ as a modifier, like the arrow tool's, still get it.)
        guard !pointer.isControlClick else { return }
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
        guard let id = editor.selectableShape(at: pointer.world), let record = editor.document[id],
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
        // tldraw's PointingShape: not selected on the press with ⌘, when already selected, or
        // inside a multi-selection's box; otherwise ⇧ adds it, and a plain press selects just it.
        let keepsSelection = command || editor.isSelected(id) || insideSelection
        if !keepsSelection {
            editor.selectedShapeIDs = shift ? editor.selectedShapeIDs + [id] : [id]
        }
        // A press that leaves the shape as the only selection brings it to the front, unless it's
        // painted by anchor. A multi-selection is never reordered.
        if editor.selection == id, !(definition is any PaintOrderAnchored) {
            editor.transact { $0.bringToFront(id) }
        }
        if isDoubleClick, definition is any Editable {
            editor.selection = id
            editor.beginEditing(id)
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
        if let handle = editor.handle(atViewPoint: pointer.view) {
            editor.hoveredHandle = handle
            editor.hovered = nil
        } else {
            editor.hoveredHandle = nil
            editor.hovered = editor.selectableShape(at: pointer.world)
        }
    }

    func pointerExited(in editor: CanvasEditor) {
        editor.hovered = nil
        editor.hoveredHandle = nil
    }

    /// Escape with nothing under way deselects all.
    func cancel(in editor: CanvasEditor) -> Bool {
        editor.selection = nil
        return true
    }
}

/// A shape was pressed (tldraw's PointingShape). Past the drag threshold the selection moves, or,
/// if ⌘ was held at the press, a brush starts from the press. Released without a drag, it settles
/// the selection.
@MainActor
final class PointingShapeSession {
    let shapeID: ShapeID
    let press: CGPoint                 // view points
    let didSelectOnPress: Bool
    let brushesOnDrag: Bool
    init(shapeID: ShapeID, press: CGPoint, didSelectOnPress: Bool, brushesOnDrag: Bool) {
        self.shapeID = shapeID
        self.press = press
        self.didSelectOnPress = didSelectOnPress
        self.brushesOnDrag = brushesOnDrag
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
    /// the shape there; otherwise it becomes the only selected shape.
    func end(_ pointer: Pointer, in editor: CanvasEditor) {
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
