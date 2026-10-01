import AppKit
@_spi(Host) import Canvas
import Geometry

/// The AppKit view around a `CanvasEditor`: turns NSEvents into editor calls, draws it, and hosts
/// its subviews: a shape's editing view, the minimap when it shows, and the editor's popover over
/// everything. Plugins can't import this module.
public final class CanvasView: NSView {
    public let editor: CanvasEditor
    private var editingView: EditingView?
    /// The editor's popover while one shows (`editor.popover`), over the rest.
    private var popoverBubble: PopoverView?
    /// The view showing the editor's popover while one shows, over everything the canvas hosts.
    public var popoverView: NSView? { popoverBubble }
    /// The minimap, in the bottom-left corner, over everything else; nil while the host doesn't show
    /// it (and hidden, though there, while the board is empty).
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

    /// A click in a window that isn't key (or of an app that isn't active) reaches the canvas, as it
    /// always has; AppKit asks here before it brings the window forward and hands the click on, so
    /// the canvas notes which click it is, for the editor (`PointerEvent.activatesWindow`).
    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        if let event, event.type == .leftMouseDown, window?.isKeyWindow != true || !NSApp.isActive { firstMouse = event.eventNumber }
        return true
    }

    /// The event number of the click that brings the window forward, until it reaches `mouseDown`.
    private var firstMouse: Int?

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        editor.viewportDidResize(to: newSize)
        layoutMinimap()
        layoutPopover()
    }

    private func layoutMinimap() {
        guard let minimap else { return }
        let size = MinimapStyle.size(in: bounds.size)
        minimap.frame = CGRect(x: MinimapStyle.margin, y: bounds.height - MinimapStyle.margin - size.height, width: size.width, height: size.height)
    }

    /// Whether a point (view points) is on the minimap, which takes its own clicks while it shows
    /// (on an empty board it's hidden, and the corner is the canvas's).
    private func isOnMinimap(_ point: CGPoint) -> Bool { minimap.map { !$0.isHidden && $0.frame.contains(point) } ?? false }

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

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
        }
        super.viewWillMove(toWindow: newWindow)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey(_:)), name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(menuDidBeginTracking(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
            Self.watchCommandKeyUps()
        }
        window?.makeFirstResponder(self)
    }

    /// The window stopped being key: no key's release will reach the canvas, so every key held is
    /// let go (Space's pan).
    @objc private func windowDidResignKey(_ notification: Notification) { editor.keysReleased() }

    /// A menu began tracking (the canvas's context menu, the toolbar's zoom menu, the path's "…", the
    /// menu bar): its loop takes the keys, a key's release too, while the window stays key and the
    /// canvas keeps the keyboard, so every key held is let go. One still down when the menu closes
    /// is held again by its next repeat.
    @objc private func menuDidBeginTracking(_ notification: Notification) { editor.keysReleased() }

    /// A key let go while ⌘ is held never reaches the key window (NSApplication keeps it), so the
    /// canvas that has the keyboard hears it here: Space let go before ⌘ (after a ⌘-scroll zoom
    /// while panning) lets go of the hand. Once per app.
    private static var commandKeyUps: Any?

    private static func watchCommandKeyUps() {
        guard commandKeyUps == nil else { return }
        commandKeyUps = NSEvent.addLocalMonitorForEvents(matching: .keyUp) { event in
            MainActor.assumeIsolated {
                if event.modifierFlags.contains(.command), let canvas = event.window?.firstResponder as? CanvasView {
                    canvas.editor.keyUp(KeyStroke(event))
                }
            }
            return event
        }
    }

    /// So is every key held when the canvas loses the keyboard (to a panel's field, say).
    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { editor.keysReleased() }
        return resigned
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        editor.draw(in: context, bounds: bounds, dirtyRect: dirtyRect)
    }

    /// Keeps the editing view over its shape's editing frame as the camera or the shape moves. Its
    /// frame is in view points and its bounds in world units, so AppKit scales it with the zoom.
    private func layoutEditingView() {
        guard let view = editingView?.view, let box = editor.editingFrame else { return }
        view.frame = editor.camera.toView(box)
        view.bounds = CGRect(origin: .zero, size: box.size)
    }

    /// Keeps the popover beside what it's about, as the camera or its anchor moves: below it, else
    /// above it where there's more room there, within the view's margin, starting where its anchor
    /// does less its padding, so its text starts under the anchor's; hidden while its anchor is out
    /// of view.
    private func layoutPopover() {
        guard let popoverView = popoverBubble, let popover = editor.popover else { return }
        let anchor = editor.camera.toView(popover.anchor)
        let margin = PopoverStyle.margin, gap = PopoverStyle.gap
        let below = bounds.height - margin - (anchor.maxY + gap), above = anchor.minY - gap - margin
        let wanted = popoverView.bubbleSize(maxHeight: .greatestFiniteMagnitude)
        let under = wanted.height <= below || below >= above
        let size = popoverView.bubbleSize(maxHeight: max(under ? below : above, 0))
        let x = min(max(anchor.minX - PopoverStyle.padding.width, margin), bounds.width - margin - size.width)
        popoverView.place(CGRect(x: max(x, margin), y: under ? anchor.maxY + gap : anchor.minY - gap - size.height,
                                 width: size.width, height: size.height))
        popoverView.isHidden = !bounds.intersects(anchor)
    }

    private func cursor(_ cursor: CanvasCursor) -> NSCursor {
        switch cursor {
        case .standard: .arrow
        case .crosshair: .crosshair
        case .openHand: .openHand
        case .closedHand: .closedHand
        case .pointingHand: .pointingHand
        case .resize(let position): Self.resizeCursor(position)
        }
    }

    /// The frame-resize cursor for a place on a box: macOS 15's, both ways; before it, the
    /// left-right and up-down arrows on a side, and on a corner, which has no public cursor there,
    /// the crosshair.
    private static func resizeCursor(_ position: CanvasCursor.ResizePosition) -> NSCursor {
        if #available(macOS 15, *) {
            let place: NSCursor.FrameResizePosition = switch position {
            case .top: .top
            case .left: .left
            case .bottom: .bottom
            case .right: .right
            case .topLeft: .topLeft
            case .topRight: .topRight
            case .bottomLeft: .bottomLeft
            case .bottomRight: .bottomRight
            }
            return .frameResize(position: place, directions: .all)
        }
        switch position {
        case .left, .right: return .resizeLeftRight
        case .top, .bottom: return .resizeUpDown
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return .crosshair
        }
    }

    // MARK: Mouse

    private func pointerEvent(_ event: NSEvent) -> PointerEvent {
        PointerEvent(location: convert(event.locationInWindow, from: nil), timestamp: event.timestamp,
                     modifiers: Modifiers(event.modifierFlags), clickCount: event.clickCount)
    }

    /// A Control-click comes here only when `menu(for:)` had nothing for it; the tool decides
    /// whether it's a click (`Pointer.isControlClick`). One press at a time: a left press during the
    /// middle button's pan ends the pan there, and is the press from then on (its drags and release;
    /// the middle button's are dropped).
    public override func mouseDown(with event: NSEvent) {
        pointerPlace = .canvas
        if isPanningWithOtherButton {
            isPanningWithOtherButton = false
            editor.pointerUp(pointerEvent(event))
        }
        var press = pointerEvent(event)
        press.activatesWindow = firstMouse == event.eventNumber
        firstMouse = nil
        editor.pointerDown(press)
    }
    public override func mouseDragged(with event: NSEvent) { editor.pointerDragged(pointerEvent(event)) }

    /// A press of the middle button pans, as the Hand does, whatever the tool; while another press
    /// is under way it does nothing, and nor do its drags and release. A pan is a press on the canvas,
    /// wherever it began (over the text of the note being edited, say), so its release over a view the
    /// canvas hosts, or one over it, is the pointer leaving the canvas there, as a left press's is.
    private var isPanningWithOtherButton = false

    public override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2, !isOnMinimap(convert(event.locationInWindow, from: nil)) else { return super.otherMouseDown(with: event) }
        isPanningWithOtherButton = editor.panPointerDown(pointerEvent(event))
        if isPanningWithOtherButton { pointerPlace = .canvas }
    }
    public override func otherMouseDragged(with event: NSEvent) {
        guard isPanningWithOtherButton else { return super.otherMouseDragged(with: event) }
        editor.pointerDragged(pointerEvent(event))
    }
    public override func otherMouseUp(with event: NSEvent) {
        guard isPanningWithOtherButton else { return super.otherMouseUp(with: event) }
        isPanningWithOtherButton = false
        let pointer = pointerEvent(event)
        editor.pointerUp(pointer)
        minimap?.updateVisibility()
        let place = place(of: pointer.location)
        if place != .canvas { pointerLeftCanvas(for: place) }
    }
    /// A release over the editing view (the press began editing: a double-click) leaves the pointer
    /// there, off the canvas, as a move there would; so does one over the minimap. The minimap, which
    /// waits for a press that placed the first shape under it, is asked again.
    public override func mouseUp(with event: NSEvent) {
        let pointer = pointerEvent(event)
        editor.pointerUp(pointer)
        minimap?.updateVisibility()
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

    /// A two-finger double-tap (smart zoom) on the canvas: the command a plugin claims (Selection's,
    /// which brings the shape under the pointer into view, and again goes back), with the pointer
    /// where the gesture was, since a gesture reaches a window that isn't key, where no move reached
    /// the canvas. Over the views the canvas hosts, nothing.
    public override func smartMagnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard place(of: point) == .canvas else { return }
        editor.pointerLocated(at: point)
        editor.perform(.smartMagnify)
    }

    // MARK: Keyboard and menu commands

    /// Every key goes to the plugin that claims key strokes: Keyboard, in the shipped app, whose
    /// shortcuts say what each key does (a tool's letter, Delete, Return, Escape, ⌘A). A key it
    /// passes on goes to AppKit's key bindings, as any view's would (see the standard actions below).
    public override func keyDown(with event: NSEvent) {
        guard !editor.keyDown(KeyStroke(event)) else { return }
        interpretKeyEvents([event])
    }

    /// A key let go: the shortcut done while it's held hears it (Space's pan ends).
    public override func keyUp(with event: NSEvent) {
        editor.keyUp(KeyStroke(event))
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

    /// A key no shortcut took that types (a letter no tool has) types nothing on the canvas, and
    /// doesn't beep.
    public override func insertText(_ insertString: Any) {}

    /// The moves AppKit's key bindings make of a key no shortcut took (an arrow key with nothing
    /// selected: `moveLeft:`; Page Down, Home: `scrollPageDown:`, `scrollToBeginningOfDocument:`) do
    /// nothing on the canvas, and don't beep. Any other action goes on as ever: the canvas's own
    /// (above), or up the responder chain.
    public override func doCommand(by selector: Selector) {
        let name = NSStringFromSelector(selector)
        if !responds(to: selector), ["move", "scroll", "page"].contains(where: name.hasPrefix) { return }
        super.doCommand(by: selector)
    }

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
}

extension CanvasView: NSMenuItemValidation {
    /// Edit › Delete and Select All are enabled while their commands can run (`canPerform`): Delete
    /// while something's selected, Select All while the board has shapes.
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(delete(_:)): editor.canPerform(.delete)
        case #selector(selectAll(_:)): editor.canPerform(.selectAll)
        default: true
        }
    }
}

@_spi(Host) extension CanvasView: CanvasEditorDelegate {
    public func editorNeedsDisplay(_ editor: CanvasEditor) {
        needsDisplay = true
        minimap?.updateVisibility()
        minimap?.needsDisplay = true
        layoutEditingView()
        layoutPopover()
    }

    /// Shows the popover over everything else, in place of the one before, or takes it down.
    public func editorPopoverDidChange(_ editor: CanvasEditor) {
        guard let popover = editor.popover else {
            popoverBubble?.removeFromSuperview()
            popoverBubble = nil
            return
        }
        if popoverBubble?.popoverID != popover.id {
            popoverBubble?.removeFromSuperview()
            let view = PopoverView(popover)
            addSubview(view)
            popoverBubble = view
        }
        layoutPopover()
    }

    /// Over a view the canvas hosts, that view's cursor stands.
    public func editorCursorDidChange(_ editor: CanvasEditor) {
        guard pointerPlace == .canvas else { return }
        cursor(editor.cursor).set()
    }

    public func editorBoardDidChange(_ editor: CanvasEditor) {
        minimap?.boardDidChange()
        minimap?.updateVisibility()
    }

    public func editorEditingDidChange(_ editor: CanvasEditor) {
        // The minimap waits for editing to end before it fades in over the first shape.
        defer { minimap?.updateVisibility() }
        if let old = editingView {
            // The keyboard comes back to the canvas, unless it has gone to a view outside it (the
            // inspector's text, whose click ended editing as it took the keyboard).
            if !keyboardIsElsewhere { window?.makeFirstResponder(self) }
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

    /// Whether the keyboard is in a view outside the canvas and the views it hosts.
    private var keyboardIsElsewhere: Bool {
        guard let responder = window?.firstResponder as? NSView else { return false }
        return responder !== self && !responder.isDescendant(of: self)
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
        self.init(event.charactersIgnoringModifiers ?? "", modifiers: Modifiers(event.modifierFlags), isRepeat: event.isARepeat,
                  numberRowKey: Self.numberRow[event.keyCode])
    }

    /// The number row's keys, by their key codes (the same key whatever the layout, `kVK_ANSI_1`…),
    /// and the digit each is.
    static let numberRow: [UInt16: Character] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
    ]
}
