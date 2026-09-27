import AppKit
@_spi(Host) import Canvas
import Geometry

/// The AppKit view around a `CanvasEditor`: turns NSEvents into editor calls, draws it, and hosts
/// the one subview, a shape's editing view. Plugins can't import this module.
public final class CanvasView: NSView {
    public let editor: CanvasEditor
    private var editingView: EditingView?

    public init(editor: CanvasEditor) {
        self.editor = editor
        super.init(frame: .zero)
        editor.delegate = self
        editor.liveModifiers = { Modifiers(NSEvent.modifierFlags) }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect],
            owner: self
        ))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { true }
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        editor.draw(in: context, bounds: bounds, dirtyRect: dirtyRect)
    }

    /// Keeps the editing view over its shape as the camera or the shape moves. Its frame is in
    /// view points and its bounds in world units, so AppKit scales it with the zoom.
    private func layoutEditingView() {
        guard let view = editingView?.view, let id = editor.editingShapeID, let box = editor.document[id]?.box else { return }
        view.frame = editor.camera.toView(box)
        view.bounds = CGRect(origin: .zero, size: box.size)
    }

    private func cursor(_ cursor: CanvasCursor) -> NSCursor {
        switch cursor {
        case .standard: .arrow
        case .crosshair: .crosshair
        case .openHand: .openHand
        case .closedHand: .closedHand
        }
    }

    // MARK: Mouse

    private func pointerEvent(_ event: NSEvent) -> PointerEvent {
        PointerEvent(location: convert(event.locationInWindow, from: nil), timestamp: event.timestamp,
                     modifiers: Modifiers(event.modifierFlags), clickCount: event.clickCount)
    }

    /// A Control-click comes here only when `menu(for:)` had nothing for it; the tool decides
    /// whether it's a click (`Pointer.isControlClick`).
    public override func mouseDown(with event: NSEvent) { editor.pointerDown(pointerEvent(event)) }
    public override func mouseDragged(with event: NSEvent) { editor.pointerDragged(pointerEvent(event)) }
    public override func mouseUp(with event: NSEvent) { editor.pointerUp(pointerEvent(event)) }
    public override func mouseMoved(with event: NSEvent) { editor.pointerMoved(pointerEvent(event)) }
    public override func mouseExited(with event: NSEvent) { editor.pointerExited() }
    public override func cursorUpdate(with event: NSEvent) { cursor(editor.cursor).set() }
    public override func flagsChanged(with event: NSEvent) { editor.modifiersChanged(held: Modifiers(event.modifierFlags)) }

    /// A right-click or a Control-click (AppKit asks for both, and shows what this returns): the
    /// editor's menu for it, from whichever plugin claims secondary clicks. Nil does nothing.
    /// AppKit may also ask with some other event (the accessibility Show Menu action), which has no
    /// location or click count to give: then there's no menu.
    public override func menu(for event: NSEvent) -> NSMenu? {
        guard [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) else { return nil }
        return editor.menu(for: pointerEvent(event))
    }

    // MARK: Trackpad and scroll wheel

    /// Two-finger scroll pans (with the system's momentum); holding Command zooms instead.
    public override func scrollWheel(with event: NSEvent) {
        // Mouse wheels report coarse line deltas rather than points.
        let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
        let dx = event.scrollingDeltaX * scale
        let dy = event.scrollingDeltaY * scale
        if event.modifierFlags.contains(.command) {
            editor.camera.zoom(by: exp(dy * 0.01), around: convert(event.locationInWindow, from: nil))
        } else {
            editor.camera.pan(by: CGSize(width: dx, height: dy))
        }
    }

    public override func magnify(with event: NSEvent) {
        editor.camera.zoom(by: 1 + event.magnification, around: convert(event.locationInWindow, from: nil))
    }

    // MARK: Keyboard and menu commands

    public override func keyDown(with event: NSEvent) {
        // Routes keys to the standard action methods below (Delete, Return, Escape, ...).
        interpretKeyEvents([event])
    }

    public override func insertText(_ insertString: Any) {
        guard let text = insertString as? String, editor.handleShortcut(text) else {
            super.insertText(insertString)
            return
        }
    }

    // The editor hands these to whichever plugin claims them (the selection, in the shipped app);
    // unclaimed, they do nothing.
    public override func deleteBackward(_ sender: Any?) { editor.perform(.delete) }
    public override func deleteForward(_ sender: Any?) { editor.perform(.delete) }
    public override func insertNewline(_ sender: Any?) { editor.perform(.insertNewline) }
    public override func cancelOperation(_ sender: Any?) { editor.cancel() }
    /// Edit › Select All (⌘A), sent to the first responder when the canvas has the keyboard. Text
    /// being edited (a note, a panel field) selects its own text instead.
    public override func selectAll(_ sender: Any?) { editor.perform(.selectAll) }

    @objc public func zoomIn(_ sender: Any?) {
        editor.camera.zoom(by: 1.25, around: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    @objc public func zoomOut(_ sender: Any?) {
        editor.camera.zoom(by: 0.8, around: CGPoint(x: bounds.midX, y: bounds.midY))
    }

    @objc public func zoomToActualSize(_ sender: Any?) {
        editor.camera.setZoom(1, around: CGPoint(x: bounds.midX, y: bounds.midY))
    }
}

@_spi(Host) extension CanvasView: CanvasEditorDelegate {
    public func editorNeedsDisplay(_ editor: CanvasEditor) {
        needsDisplay = true
        layoutEditingView()
    }

    public func editorCursorDidChange(_ editor: CanvasEditor) { cursor(editor.cursor).set() }

    public func editorEditingDidChange(_ editor: CanvasEditor) {
        if let old = editingView {
            window?.makeFirstResponder(self)
            old.view.removeFromSuperview()
            editingView = nil
        }
        guard let new = editor.makeEditingView() else { return }
        addSubview(new.view)
        editingView = new
        layoutEditingView()
        window?.makeFirstResponder(new.firstResponder)
    }
}

extension Modifiers {
    init(_ flags: NSEvent.ModifierFlags) {
        self = []
        if flags.contains(.shift) { insert(.shift) }
        if flags.contains(.option) { insert(.option) }
        if flags.contains(.command) { insert(.command) }
        if flags.contains(.control) { insert(.control) }
    }
}
