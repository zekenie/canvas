import AppKit
import CoreGraphics
import Foundation
import Geometry

// The hosting view's side of the editor: `CanvasView` (and test harnesses) feed input in and ask
// for the cursor and the editing view. It's SPI: only modules that `@_spi(Host) import Canvas`
// see it, and build.sh lets only the ui, testsupport and test layers do that, so plugins can't
// call it. Drawing is in CanvasEditor+Drawing.swift.
extension CanvasEditor {
    /// A press's session's, else its tool's while it runs (the hand held during a drag is the next
    /// press's); with none, the open hand while it's held, else the tool's.
    @_spi(Host) public var cursor: CanvasCursor {
        if let session { return session.cursor(in: self) ?? currentTool.cursor(in: self) }
        return isHandHeld ? .openHand : currentTool.cursor(in: self)
    }

    /// The view's new size, in view points.
    @_spi(Host) public func viewportDidResize(to size: CGSize) { viewportSize = size }

    /// A press begins an undo step: everything it commits, through its release, is one. While the
    /// hand is held (`isHandHeld`), it pans, as the Hand's does.
    @_spi(Host) public func pointerDown(_ event: PointerEvent) {
        var pointer = sample(event)
        pointer.isControlClick = event.modifiers.contains(.control)
        pointer.activatesWindow = event.activatesWindow
        if isHandHeld {
            beginPan(pointer)
            return
        }
        guard !currentTool.ignoresPress(pointer, in: self) else { return }
        dismissPopover()
        tracker.resetVelocity()
        stopCameraMotion()
        endEditing()
        undoHistory.pressBegan()
        pressLocation = pointer.view
        pressDragged = false
        lastPointer = pointer
        currentTool.pointerDown(pointer, in: self)
        refreshCursor()
    }

    /// A press of the mouse's middle button: it pans, as the Hand's does,
    /// whatever the tool, which stays the tool, and editing goes on. Its drags and its release come
    /// through `pointerDragged` and `pointerUp`. Returns false, doing nothing, while a press is under
    /// way: then its drags and release are the host's to drop.
    @_spi(Host) public func panPointerDown(_ event: PointerEvent) -> Bool {
        guard session == nil else { return false }
        beginPan(sample(event))
        return true
    }

    /// A pan (the Hand's session) from a press, whatever the tool: the camera stops, the press is a
    /// step that commits nothing, and editing goes on.
    private func beginPan(_ pointer: Pointer) {
        dismissPopover()
        tracker.resetVelocity()
        stopCameraMotion()
        undoHistory.pressBegan()
        pressLocation = pointer.view
        pressDragged = false
        lastPointer = pointer
        session = HandSession(press: pointer.view)
        refreshCursor()
    }

    @_spi(Host) public func pointerDragged(_ event: PointerEvent) {
        let pointer = sample(event)
        session?.drag(pointer, in: self)
        dragDidReachSession(pointer)
        refreshCursor()
    }

    @_spi(Host) public func pointerUp(_ event: PointerEvent) {
        let pointer = sample(event)
        stopEdgeScrolling()
        pressLocation = nil
        lastPointer = nil
        if let finished = session {
            finished.end(pointer, in: self)
            if session === finished { session = nil }
        }
        // The session may have switched tools; the current one picks up the hover, or, while the
        // hand is held (pressed during the drag, when the tool heard nothing of it), hears the pointer
        // leave, so nothing it showed for the hover stays up (a port's dots).
        if session == nil {
            if isHandHeld { currentTool.pointerExited(in: self) } else { currentTool.pointerMoved(pointer, in: self) }
        }
        undoHistory.pressEnded()
        refreshCursor()
    }

    @_spi(Host) public func pointerMoved(_ event: PointerEvent) {
        let pointer = sample(event)
        guard session == nil, !isHandHeld else { return }
        currentTool.pointerMoved(pointer, in: self)
        refreshCursor()
    }

    /// The pointer is at `location` (view points), as a gesture that isn't a move says: a trackpad's
    /// smart zoom, which reaches a window that isn't key, where the canvas heard no move, and before
    /// the pointer has moved in a window just opened or brought forward. Only where the pointer is
    /// (`pointerWorldLocation`) changes: nothing is hovered, the tool hears nothing, and the jump
    /// makes no speed.
    @_spi(Host) public func pointerLocated(at location: CGPoint) {
        tracker.relocate(location)
    }

    @_spi(Host) public func pointerExited() {
        if session == nil { currentTool.pointerExited(in: self) }
    }

    /// The keys held now (from the view's flagsChanged). A released key counts as held for
    /// `Style.modifierReleaseDelay` longer, so letting go of ⌥ and the mouse together keeps ⌥.
    @_spi(Host) public func modifiersChanged(held: Modifiers) {
        let released = heldModifiers.subtracting(held)
        heldModifiers = held
        if !released.isEmpty {
            recentlyReleased.formUnion(released)
            releaseTimer?.cancel()
            releaseTimer = scheduler.schedule(after: Style.modifierReleaseDelay) { [weak self] in
                guard let self else { return }
                recentlyReleased = []
                dispatchModifiers(heldModifiers)
            }
        }
        dispatchModifiers(held.union(recentlyReleased))
    }

    /// A secondary click (a right-click, or a Control-click): the menu to open there, from the
    /// plugin that claims it (`registrar.menuForSecondaryClick`). Nil, the click does nothing: no
    /// plugin claims it, it has nothing to show, or a press is under way.
    @_spi(Host) public func menu(for event: PointerEvent) -> NSMenu? {
        guard session == nil, let make = registry.secondaryClickMenu else { return nil }
        let pointer = Pointer(view: event.location, world: camera.toWorld(event.location), modifiers: event.modifiers,
                              clickCount: event.clickCount, isControlClick: event.modifiers.contains(.control))
        guard let menu = make(self, pointer) else { return nil }
        stopCameraMotion()
        return menu
    }

    /// A key pressed on the canvas: the plugin that claims key strokes (`registrar.keyStrokes`) says
    /// what it does. False if none does anything with it; the view then gives it to AppKit. What it
    /// commits is one undo step, with what its repeats commit while it's held (a held arrow key's
    /// nudges), until anything else happens.
    @_spi(Host) public func keyDown(_ stroke: KeyStroke) -> Bool {
        dismissPopover()
        guard let handle = registry.keyStrokeHandler else { return false }
        return undoHistory.key(stroke) { handle(self, stroke) }
    }

    /// A key let go on the canvas: the plugin that claims key releases (`registrar.keyReleases`)
    /// hears it, for a key that does something while held (Space's pan), and the step its strokes
    /// held open for their repeats (a held arrow key's nudges) closes.
    @_spi(Host) public func keyUp(_ stroke: KeyStroke) {
        registry.keyReleaseHandler?(self, stroke)
        undoHistory.keyReleased(stroke)
    }

    /// Every key let go at once, as far as the canvas can tell: it lost the keyboard, or its window
    /// stopped being key, or a menu took over the keys, so no key's release will reach it.
    @_spi(Host) public func keysReleased() {
        registry.keyReleaseHandler?(self, nil)
        undoHistory.keyReleased(nil)
    }

    /// The editing view for the shape being edited (the view asks when `editingShapeID` changes).
    @_spi(Host) public func makeEditingView() -> EditingView? {
        guard let id = editingShapeID, let record = document[id],
              let definition = registry.definition(for: record.kind) as? any Editable else { return nil }
        return definition.erasedEditingView(for: record, editor: self)
    }

    private func sample(_ event: PointerEvent) -> Pointer {
        tracker.sample(event.location, at: event.timestamp)
        return Pointer(view: event.location, world: camera.toWorld(event.location),
                       modifiers: event.modifiers.union(recentlyReleased), clickCount: event.clickCount)
    }

    private func dispatchModifiers(_ modifiers: Modifiers) {
        if let session {
            session.modifiersChanged(modifiers, in: self)
        } else {
            currentTool.modifiersChanged(modifiers, in: self)
        }
    }
}
