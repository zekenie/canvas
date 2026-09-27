import AppKit
import CoreGraphics
import Foundation
import Geometry

// The hosting view's side of the editor: `CanvasView` (and test harnesses) feed input in and ask
// for the cursor and the editing view. It's SPI: only modules that `@_spi(Host) import Canvas`
// see it, and build.sh lets only the ui, testsupport and test layers do that, so plugins can't
// call it. Drawing is in CanvasEditor+Drawing.swift.
extension CanvasEditor {
    @_spi(Host) public var cursor: CanvasCursor { session?.cursor(in: self) ?? currentTool.cursor(in: self) }

    @_spi(Host) public func pointerDown(_ event: PointerEvent) {
        var pointer = sample(event)
        pointer.isControlClick = event.modifiers.contains(.control)
        tracker.resetVelocity()
        stopCameraSlide()
        endEditing()
        currentTool.pointerDown(pointer, in: self)
        refreshCursor()
    }

    @_spi(Host) public func pointerDragged(_ event: PointerEvent) {
        let pointer = sample(event)
        session?.drag(pointer, in: self)
        refreshCursor()
    }

    @_spi(Host) public func pointerUp(_ event: PointerEvent) {
        let pointer = sample(event)
        if let finished = session {
            finished.end(pointer, in: self)
            if session === finished { session = nil }
        }
        // The session may have switched tools; the current one picks up the hover.
        if session == nil { currentTool.pointerMoved(pointer, in: self) }
        refreshCursor()
    }

    @_spi(Host) public func pointerMoved(_ event: PointerEvent) {
        let pointer = sample(event)
        guard session == nil else { return }
        currentTool.pointerMoved(pointer, in: self)
        refreshCursor()
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
        stopCameraSlide()
        return menu
    }

    /// An unmodified key typed on the canvas. Returns false if no tool claims it.
    @_spi(Host) public func handleShortcut(_ text: String) -> Bool {
        guard text.count == 1, let key = text.lowercased().first, let id = registry.tool(forShortcut: key) else { return false }
        setTool(id)
        return true
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
