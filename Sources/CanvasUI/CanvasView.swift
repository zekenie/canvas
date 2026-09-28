import AppKit
@_spi(Host) import Canvas
import Geometry

/// The AppKit view around a `CanvasEditor`: turns NSEvents into editor calls, draws it, and hosts
/// its subviews: a shape's editing view, and the minimap when it shows. Plugins can't import this
/// module.
public final class CanvasView: NSView {
    public let editor: CanvasEditor
    private var editingView: EditingView?
    /// The minimap, in the bottom-left corner, over everything else; nil while it's hidden.
    public private(set) var minimap: MinimapView?
    /// Where the pointer is, as the canvas last heard it: on the canvas, or over a view that has the
    /// pointer there, where the tool has been told it left: one it hosts (the minimap, the editing
    /// view), or one the host puts over it (`covered`: the path over a subboard's canvas, and its
    /// menus).
    private var pointerPlace = PointerPlace.canvas

    private enum PointerPlace { case canvas, minimap, editingView, covered }

    /// Whether the minimap shows. Off unless the host turns it on (the app does, per board).
    public var showsMinimap = false {
        didSet {
            guard showsMinimap != (minimap != nil) else { return }
            if showsMinimap {
                let minimap = MinimapView(editor: editor)
                addSubview(minimap)
                self.minimap = minimap
                layoutMinimap()
            } else {
                minimap?.removeFromSuperview()
                minimap = nil
                if pointerPlace == .minimap { pointerPlace = .canvas }
            }
        }
    }

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

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        editor.viewportDidResize(to: newSize)
        layoutMinimap()
    }

    private func layoutMinimap() {
        guard let minimap else { return }
        let size = MinimapStyle.size(in: bounds.size)
        minimap.frame = CGRect(x: MinimapStyle.margin, y: bounds.height - MinimapStyle.margin - size.height, width: size.width, height: size.height)
    }

    /// Whether a point (view points) is on the minimap, which takes its own clicks.
    private func isOnMinimap(_ point: CGPoint) -> Bool { minimap?.frame.contains(point) ?? false }

    /// Where a point (view points) is: on the minimap (which is over everything), on the editing
    /// view (which takes the pointer where it is: its text, its cursor), under a view the host put
    /// over the canvas, or on the canvas.
    private func place(of point: CGPoint) -> PointerPlace {
        if isOnMinimap(point) { return .minimap }
        if editingView?.view.frame.contains(point) == true { return .editingView }
        if isCovered(point) { return .covered }
        return .canvas
    }

    /// Whether a view that isn't the canvas's is over it at a point (view points): what the host
    /// puts over the canvas, which takes a click there (the path's pill, a crumb's menu), and so
    /// the pointer. AppKit still tells the canvas the pointer moved there (its tracking area covers
    /// it), as it does over the views the canvas hosts.
    private func isCovered(_ point: CGPoint) -> Bool {
        guard let content = window?.contentView, let frame = content.superview else { return false }
        guard let hit = content.hitTest(frame.convert(convert(point, to: nil), from: nil)) else { return false }
        return hit !== self && !hit.isDescendant(of: self)
    }

    /// The pointer is over a view the canvas hosts, or one over it: the tool hears that it left,
    /// unless it has. Under a view over the canvas the cursor is the arrow (the views it hosts set
    /// their own).
    private func pointerLeftCanvas(for place: PointerPlace) {
        if pointerPlace == .canvas { editor.pointerExited() }
        if place == .covered, pointerPlace != .covered { NSCursor.arrow.set() }
        pointerPlace = place
    }

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
        case .pointingHand: .pointingHand
        }
    }

    // MARK: Mouse

    private func pointerEvent(_ event: NSEvent) -> PointerEvent {
        PointerEvent(location: convert(event.locationInWindow, from: nil), timestamp: event.timestamp,
                     modifiers: Modifiers(event.modifierFlags), clickCount: event.clickCount)
    }

    /// A Control-click comes here only when `menu(for:)` had nothing for it; the tool decides
    /// whether it's a click (`Pointer.isControlClick`).
    public override func mouseDown(with event: NSEvent) {
        pointerPlace = .canvas
        editor.pointerDown(pointerEvent(event))
    }
    public override func mouseDragged(with event: NSEvent) { editor.pointerDragged(pointerEvent(event)) }
    /// A release over the editing view (the press began editing: a double-click) leaves the pointer
    /// there, off the canvas, as a move there would; so does one over the minimap.
    public override func mouseUp(with event: NSEvent) {
        let pointer = pointerEvent(event)
        editor.pointerUp(pointer)
        let place = place(of: pointer.location)
        if place != .canvas { pointerLeftCanvas(for: place) }
    }
    /// Over the minimap, the editing view or a view over the canvas (the path, a crumb's menu) the
    /// pointer isn't over the canvas, though AppKit still tells the canvas (its tracking area covers
    /// them): the tool hears that it left, once, so it doesn't hover a shape under the minimap, the
    /// one being edited under its text, or one under the path. Under a view over the canvas the
    /// cursor is the arrow, and back on the canvas the tool's again.
    public override func mouseMoved(with event: NSEvent) {
        let pointer = pointerEvent(event)
        let place = place(of: pointer.location)
        guard place == .canvas else {
            pointerLeftCanvas(for: place)
            return
        }
        if pointerPlace == .covered { cursor(editor.cursor).set() }
        pointerPlace = .canvas
        editor.pointerMoved(pointer)
    }
    public override func mouseExited(with event: NSEvent) {
        pointerPlace = .canvas
        editor.pointerExited()
    }
    public override func cursorUpdate(with event: NSEvent) {
        (pointerPlace == .covered ? NSCursor.arrow : cursor(editor.cursor)).set()
    }
    public override func flagsChanged(with event: NSEvent) { editor.modifiersChanged(held: Modifiers(event.modifierFlags)) }

    /// A right-click or a Control-click (AppKit asks for both, and shows what this returns): the
    /// editor's menu for it, from whichever plugin claims secondary clicks. Nil does nothing.
    /// AppKit may also ask with some other event (the accessibility Show Menu action), which has no
    /// location or click count to give: then there's no menu.
    public override func menu(for event: NSEvent) -> NSMenu? {
        guard [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) else { return nil }
        let pointer = pointerEvent(event)
        guard !isOnMinimap(pointer.location) else { return nil }
        return editor.menu(for: pointer)
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

    /// Every key goes to the plugin that claims key strokes: Keyboard, in the shipped app, whose
    /// shortcuts say what each key does (a tool's letter, Delete, Return, Escape, ⌘A). A key it
    /// passes on goes to AppKit's key bindings, as any view's would (see the standard actions below).
    public override func keyDown(with event: NSEvent) {
        guard !editor.keyDown(KeyStroke(event)) else { return }
        interpretKeyEvents([event])
    }

    /// A key held with ⌘ comes here before the menu bar has it: AppKit asks the key window's views
    /// for a key equivalent before the menus. While the canvas has the keyboard, the shortcuts get
    /// it first, so a ⌘ key a menu item also has (⌘A) does what its shortcut says; with a field
    /// focused, the canvas passes, and the menu has it (Edit › Select All selects the field's text).
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown, event.modifierFlags.contains(.command), window?.firstResponder === self,
           editor.keyDown(KeyStroke(event)) {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    // AppKit's key bindings turn a key the shortcuts passed on into a standard action (⌃H is
    // deleteBackward:, and a user's own bindings may send any of these), and accessibility sends
    // some too. The ones with a key of their own go back to the shortcuts as that key, so they do
    // what it does. The canvas answers no other, and those go on up the responder chain.
    public override func deleteBackward(_ sender: Any?) { standardAction(asKey: "\u{7f}") }
    public override func deleteForward(_ sender: Any?) { standardAction(asKey: "\u{F728}") }
    public override func insertNewline(_ sender: Any?) { standardAction(asKey: "\r") }
    public override func cancelOperation(_ sender: Any?) { standardAction(asKey: "\u{1b}") }

    /// `key` as `NSEvent.charactersIgnoringModifiers` reports it: Delete, Forward Delete, Return,
    /// Escape.
    private func standardAction(asKey key: String) {
        let event = NSApp.currentEvent.flatMap { $0.type == .keyDown ? $0 : nil }
        _ = editor.keyDown(KeyStroke(key, isRepeat: event?.isARepeat ?? false))
    }

    // Menu items send these to the first responder, which is the canvas when it has the keyboard;
    // the editor runs the command a plugin claims (the selection's, in the shipped app), the same
    // one the keys for it run. Unclaimed, they do nothing.
    /// Edit › Select All. Text being edited (a note, a panel field) selects its own text instead.
    public override func selectAll(_ sender: Any?) { editor.perform(.selectAll) }
    /// Edit › Delete.
    @objc public func delete(_ sender: Any?) { editor.perform(.delete) }

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
        minimap?.needsDisplay = true
        layoutEditingView()
    }

    /// Over a view the canvas hosts, that view's cursor stands.
    public func editorCursorDidChange(_ editor: CanvasEditor) {
        guard pointerPlace == .canvas else { return }
        cursor(editor.cursor).set()
    }

    public func editorBoardDidChange(_ editor: CanvasEditor) {
        minimap?.boardDidChange()
    }

    public func editorEditingDidChange(_ editor: CanvasEditor) {
        if let old = editingView {
            window?.makeFirstResponder(self)
            old.view.removeFromSuperview()
            editingView = nil
            // Where it was is the canvas again; the tool hears the pointer when it next moves.
            if pointerPlace == .editingView { pointerPlace = .canvas }
        }
        guard let new = editor.makeEditingView() else { return }
        addSubview(new.view, positioned: .below, relativeTo: minimap)
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

extension KeyStroke {
    init(_ event: NSEvent) {
        self.init(event.charactersIgnoringModifiers ?? "", modifiers: Modifiers(event.modifierFlags), isRepeat: event.isARepeat)
    }
}
