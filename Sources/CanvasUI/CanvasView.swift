import AppKit
@_spi(Host) import Canvas
import Chrome
import Geometry

/// The AppKit view around a `CanvasEditor`: turns NSEvents into editor calls, draws it, and hosts
/// its subviews: a shape's editing view, the minimap when it shows, the zoom above it while it
/// changes, the editor's card (`editor.card`, a plugin's view under a rect of the board) over all of
/// those, and the editor's popover over everything. Plugins can't import this module.
public final class CanvasView: NSView {
    public let editor: CanvasEditor
    private(set) var editingView: EditingView?
    /// Its shapes as VoiceOver sees them (ShapeElements.swift), made when an assistive app first asks.
    private(set) lazy var shapeElements = ShapeElements(canvas: self)
    /// The editor's popover while one shows (`editor.popover`), over the rest.
    private var popoverBubble: PopoverView?
    /// The view showing the editor's popover while one shows, over everything the canvas hosts.
    public var popoverView: NSView? { popoverBubble }
    /// The box around the editor's card while one shows (`editor.card`): over the editing view, the
    /// minimap and the zoom, under the popover.
    private var cardHost: CardView?
    /// The plugin's view while a card shows.
    public var cardView: NSView? { cardHost?.content }
    /// The card's bubble in view points (less its shadow's margin), while one shows: tests.
    @_spi(Host) public var cardFrame: CGRect? { cardHost?.bubbleFrame }
    /// Watches for presses anywhere in the window while a card shows, which the card closes on
    /// (`pressBeganInWindow`).
    private var cardPressMonitor: Any?
    /// Watches for the keys held changing anywhere in the window, while the canvas is in one
    /// (`modifiersChangedInWindow`).
    private var modifierMonitor: Any?
    /// The minimap, in the bottom-left corner, over everything else; nil while the host doesn't show
    /// it (and hidden, though there, while the board is empty).
    public private(set) var minimap: MinimapView?
    /// The zoom, above the minimap (in its corner without one), while it changes.
    public let zoomIndicator: ZoomIndicator
    /// Where the pointer is, as the canvas last heard it: on the canvas, or over a view that has the
    /// pointer there, where the tool has been told it left: one it hosts (the minimap, the editing
    /// view), or one the host puts over it (`covered`: the path over a subboard's canvas, and its
    /// menus).
    private var pointerPlace = PointerPlace.canvas

    private enum PointerPlace { case canvas, minimap, editingView, covered, card }

    /// How a menu the editor queued (`popUpMenu`) is shown, given the menu, the point in this view it
    /// opens at (the bottom-left of the rect it is below) and the item it opens with highlighted, if
    /// one: AppKit's pop-up, which runs the menu's tracking, unless a test puts in one that notes it
    /// (a menu's tracking runs in no unshown window).
    @_spi(Host) public var menuPresenter: (@MainActor (NSMenu, CGPoint, NSMenuItem?) -> Void)?

    /// Whether the minimap shows. Off unless the host turns it on (the app does, per board).
    public var showsMinimap = false {
        didSet {
            guard showsMinimap != (minimap != nil) else { return }
            if showsMinimap {
                let minimap = MinimapView(editor: editor)
                // Under the card and the popover, which are over everything.
                if let overlay = cardHost ?? popoverBubble { addSubview(minimap, positioned: .below, relativeTo: overlay) } else { addSubview(minimap) }
                self.minimap = minimap
                layoutMinimap()
            } else {
                minimap?.removeFromSuperview()
                minimap = nil
                editor.coveredCorners = CoveredCorners()
                if pointerPlace == .minimap { pointerPlace = .canvas }
            }
            layoutZoomIndicator()
        }
    }

    public init(editor: CanvasEditor) {
        self.editor = editor
        zoomIndicator = ZoomIndicator(editor: editor)
        super.init(frame: .zero)
        addSubview(zoomIndicator)
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
        layoutZoomIndicator()
        layoutCard()
        layoutPopover()
    }

    /// The part of the view the host's chrome leaves clear (`editor.coveredEdges`: under the title bar's
    /// row, between the sheets), whose bottom-left corner the minimap and the zoom sit in.
    private var clearOfChrome: CGRect { editor.coveredEdges.clear(in: bounds.size) }

    private func layoutMinimap() {
        guard let minimap else {
            editor.coveredCorners = CoveredCorners()
            return
        }
        minimap.frame = MinimapStyle.frame(in: clearOfChrome)
        reportMinimapCorner()
    }

    /// The editor is told the clear part's bottom-left corner is covered while the minimap shows there (hidden on an empty board
    /// too: its place is kept for the first shape), its margin from the corner included, so what is put down for a person or
    /// kept in view keeps out of it (`CanvasEditor.coveredCorners`).
    private func reportMinimapCorner() {
        let size = MinimapStyle.size(in: clearOfChrome.size)
        editor.coveredCorners = CoveredCorners(bottomLeft: CGSize(width: MinimapStyle.margin + size.width, height: MinimapStyle.margin + size.height))
    }

    private func layoutZoomIndicator() {
        let below = minimap.flatMap { $0.isHidden ? nil : $0.frame }
        zoomIndicator.frame = ZoomIndicatorStyle.frame(zoomIndicator.labelSize, in: clearOfChrome, above: below)
    }

    /// What the host's chrome covers changed (a sheet came or went, or was resized): the minimap and the
    /// zoom go with the corner they sit in, gliding as a sheet slides in or out, and following a sheet's
    /// edge at once as it's dragged; the card and the popover follow the part left clear.
    public func editorCoveredEdgesDidChange(_ editor: CanvasEditor) {
        let glides = !editor.coveredEdges.hasSameSides(as: coveredEdgesLaidOut)
        coveredEdgesLaidOut = editor.coveredEdges
        guard glides else {
            layoutMinimap()
            layoutZoomIndicator()
            layoutCard()
            layoutPopover()
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = ChromeStyle.paneIn
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            if let minimap {
                minimap.animator().frame = MinimapStyle.frame(in: clearOfChrome)
                reportMinimapCorner()
            }
            let below = minimap.flatMap { $0.isHidden ? nil : MinimapStyle.frame(in: clearOfChrome) }
            zoomIndicator.animator().frame = ZoomIndicatorStyle.frame(zoomIndicator.labelSize, in: clearOfChrome, above: below)
        }
        layoutCard()
        layoutPopover()
    }

    /// What the chrome covered when the minimap and the zoom were last placed for it.
    private var coveredEdgesLaidOut = CoveredEdges()

    /// Whether a point (view points) is on the minimap, which takes its own clicks while it shows
    /// (on an empty board it's hidden, and the corner is the canvas's).
    private func isOnMinimap(_ point: CGPoint) -> Bool { minimap.map { !$0.isHidden && $0.frame.contains(point) } ?? false }

    /// Where a point (view points) is: on the card (which is over the minimap and takes the pointer
    /// where it is: its content's cursor), on the minimap (which is over the rest), on the editing
    /// view (which takes the pointer where it is: its text, its cursor), under a view the host put
    /// over the canvas, or on the canvas.
    private func place(of point: CGPoint) -> PointerPlace {
        if cardHost?.bubbleFrame.contains(point) == true { return .card }
        if isOnMinimap(point) { return .minimap }
        if editingView?.view.frame.contains(point) == true { return .editingView }
        if isCovered(point) { return .covered }
        return .canvas
    }

    /// Whether a view that isn't the canvas's is over it at a point (view points): what the host
    /// puts over the canvas, which takes a click there (a sheet, the path's pill, a crumb's menu), and
    /// so the pointer; and the window's title bar's row, which the canvas runs under and the window
    /// takes clicks in (its toolbar, or a drag of the window). AppKit still tells the canvas the
    /// pointer moved there (its tracking area covers it), as it does over the views the canvas hosts.
    private func isCovered(_ point: CGPoint) -> Bool {
        guard let window, let content = window.contentView, let frame = content.superview else { return false }
        if !window.contentLayoutRect.contains(convert(point, to: nil)) { return true }
        guard let hit = content.hitTest(frame.convert(convert(point, to: nil), from: nil)) else { return false }
        return hit !== self && !hit.isDescendant(of: self)
    }

    /// The pointer is over a view the canvas hosts, or one over it: the tool hears that it left,
    /// unless it has. Under a view over the canvas the cursor is the arrow (the views it hosts set
    /// their own).
    private func pointerLeftCanvas(for place: PointerPlace) {
        if pointerPlace == .canvas { editor.pointerExited() }
        if place == .covered || place == .card, pointerPlace != place { NSCursor.arrow.set() }
        pointerPlace = place
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if let window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.removeObserver(self, name: NSMenu.didBeginTrackingNotification, object: nil)
            stopWatchingPresses()
            stopWatchingModifiers()
            editor.modifiersChangedInWindow(held: [])
        }
        super.viewWillMove(toWindow: newWindow)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(windowDidResignKey(_:)), name: NSWindow.didResignKeyNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(menuDidBeginTracking(_:)), name: NSMenu.didBeginTrackingNotification, object: nil)
            Self.watchCommandKeyUps()
            watchModifiers()
            if cardHost != nil { watchPresses() }
        }
        window?.makeFirstResponder(self)
    }

    /// The window stopped being key: no key's release will reach the canvas, so every key held is
    /// let go (Space's pan), and none is held as far as the editor can tell (`modifiersHeld`).
    @objc private func windowDidResignKey(_ notification: Notification) {
        editor.keysReleased()
        editor.modifiersChangedInWindow(held: [])
    }

    /// The keys held changed somewhere in the window (the monitor's): the editor hears it wherever the
    /// keyboard is, a panel's field or the table of contents too, which the canvas's own
    /// `flagsChanged` doesn't (`modifiersHeld`: ⌥ while a row is hovered). Another window's is not this
    /// canvas's.
    @_spi(Host) public func modifiersChangedInWindow(_ event: NSEvent) {
        guard event.type == .flagsChanged, let window, event.window === window else { return }
        editor.modifiersChangedInWindow(held: Modifiers(event.modifierFlags))
    }

    private func watchModifiers() {
        guard modifierMonitor == nil, window != nil else { return }
        modifierMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            MainActor.assumeIsolated { self?.modifiersChangedInWindow(event) }
            return event
        }
    }

    /// As `stopWatchingPresses`: a view is released only by leaving its window, which ends this.
    private func stopWatchingModifiers() {
        guard let monitor = modifierMonitor else { return }
        NSEvent.removeMonitor(monitor)
        modifierMonitor = nil
    }

    /// A menu began tracking (the canvas's context menu, the path's "…", the menu bar): its loop
    /// takes the keys, a key's release too, while the window stays key and the canvas keeps the
    /// keyboard, so every key held is let go. One still down when the menu closes is held again by
    /// its next repeat.
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

    /// So is every key held when the canvas loses the keyboard (to a panel's field, say). The editor
    /// hears where the keyboard is either way (`hasKeyboard`): the selection is outlined quieter without it.
    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            editor.keysReleased()
            editor.keyboardDidChange(hasKeyboard: false)
        }
        return resigned
    }

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { editor.keyboardDidChange(hasKeyboard: true) }
        return became
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

    /// Keeps the card under its rect as the camera or the rect moves: 4 points below it, left edges
    /// together, or above it when it doesn't fit below and there is more room above; inside the part
    /// of the view the host leaves clear (`unobscuredViewport`) less a margin, cut to the room there
    /// with its content scrolling itself. Its size in points is the plugin's (`card.size`, asked with
    /// the room), whatever the zoom. Nothing before the view has a size.
    private func layoutCard() {
        guard let host = cardHost, let card = editor.card else { return }
        // Past the canvas in the responder chain: AppKit sets it whenever the view is added.
        if host.nextResponder !== nextResponder { host.nextResponder = nextResponder }
        let viewport = editor.unobscuredViewport
        guard !viewport.isEmpty else { return }
        let clear = viewport.insetBy(dx: CardStyle.margin, dy: CardStyle.margin)
        guard !clear.isNull, clear.width > 0, clear.height > 0 else { return }
        let anchor = editor.camera.toView(card.anchor)
        let gap = CardStyle.gap
        let below = clear.maxY - (anchor.maxY + gap), above = anchor.minY - gap - clear.minY
        let wanted = card.size(CGSize(width: clear.width, height: .greatestFiniteMagnitude))
        let under = wanted.height <= below || below >= above
        let size = card.size(CGSize(width: clear.width, height: max(under ? below : above, CardStyle.minHeight)))
        let x = min(max(anchor.minX, clear.minX), clear.maxX - size.width)
        let y = under ? anchor.maxY + gap : anchor.minY - gap - size.height
        host.place(CGRect(x: max(x, clear.minX), y: min(max(y, clear.minY), max(clear.maxY - size.height, clear.minY)),
                          width: size.width, height: size.height))
    }

    /// A press began somewhere in the window (the monitor's, while a card shows): the card closes unless
    /// it was on the card, or on the rect the card hangs from, which is the card's own ground (the
    /// plugin that showed it hears its own click and decides). Anything else closes it: the canvas, the
    /// note being edited, a view the host put over the canvas, the panel, the toolbar. A press in
    /// another window (a list beside a caret) or a menu closes nothing. The press goes on to what it
    /// landed on.
    @_spi(Host) public func pressBeganInWindow(_ event: NSEvent) {
        guard let card = editor.card, let host = cardHost, event.window === window else { return }
        if let content = window?.contentView, let frame = content.superview,
           let hit = content.hitTest(frame.convert(event.locationInWindow, from: nil)) {
            if hit === host || hit.isDescendant(of: host) { return }
            if hit === self || hit.isDescendant(of: self),
               editor.camera.toView(card.anchor).contains(convert(event.locationInWindow, from: nil)) { return }
        }
        editor.closeCard(.pressedElsewhere)
    }

    private func watchPresses() {
        guard cardPressMonitor == nil, window != nil else { return }
        cardPressMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { [weak self] event in
            MainActor.assumeIsolated { self?.pressBeganInWindow(event) }
            return event
        }
    }

    /// A view in a window is released only by leaving it (`viewWillMove(toWindow:)`, which ends this), and
    /// `watchPresses` needs a window, so a view that is released has no monitor.
    private func stopWatchingPresses() {
        guard let monitor = cardPressMonitor else { return }
        NSEvent.removeMonitor(monitor)
        cardPressMonitor = nil
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
    /// the middle button's are dropped). A press in the window's title bar's row, which the canvas runs
    /// under, is the window's (`TitleRow`): the board hears none of it.
    public override func mouseDown(with event: NSEvent) {
        let activatesWindow = firstMouse == event.eventNumber
        firstMouse = nil
        if let window, !window.contentLayoutRect.contains(event.locationInWindow) {
            // The title bar's row, which the canvas runs under, is the window's: a press there drags it (`TitleRow`).
            TitleRow.press(event, in: window)
            // A drag of the window tracks the release itself: only a press still held has its drag and release to come.
            isPressInTitleRow = NSEvent.pressedMouseButtons & 1 != 0
            return
        }
        isPressInTitleRow = false
        pointerPlace = .canvas
        if isPanningWithOtherButton {
            isPanningWithOtherButton = false
            editor.pointerUp(pointerEvent(event))
        }
        var press = pointerEvent(event)
        press.activatesWindow = activatesWindow
        editor.pointerDown(press)
    }
    public override func mouseDragged(with event: NSEvent) {
        guard !isPressInTitleRow else { return }
        editor.pointerDragged(pointerEvent(event))
    }

    /// Whether the press under way began in the title bar's row, so the board hears none of it.
    private var isPressInTitleRow = false

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
        guard !isPressInTitleRow else {
            isPressInTitleRow = false
            return
        }
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
        if pointerPlace == .covered || pointerPlace == .card { cursor(editor.cursor).set() }
        pointerPlace = .canvas
        editor.pointerMoved(pointer)
    }
    public override func mouseExited(with event: NSEvent) {
        pointerPlace = .canvas
        editor.pointerExited()
    }
    public override func cursorUpdate(with event: NSEvent) {
        (pointerPlace == .covered || pointerPlace == .card ? NSCursor.arrow : cursor(editor.cursor)).set()
    }
    public override func flagsChanged(with event: NSEvent) { editor.modifiersChanged(held: Modifiers(event.modifierFlags)) }

    /// A right-click or a Control-click (AppKit asks for both, and shows what this returns): the
    /// editor's menu for it, from whichever plugin claims secondary clicks. Nil does nothing.
    /// AppKit also asks with some other event (the accessibility Show Menu action, VoiceOver's
    /// VO-Shift-M), which has no location or click count to give: then it's the selection's menu, as
    /// Shape › Show Context Menu opens (nil with nothing selected).
    public override func menu(for event: NSEvent) -> NSMenu? {
        guard [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) else {
            return editor.menuForPoppedSelection()
        }
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

    /// A two-finger double-tap (smart zoom) on the canvas: the command that answers it (Selection's,
    /// which brings the shape under the pointer into view, and again goes back), with the pointer
    /// where the gesture was, since a gesture reaches a window that isn't key, where no move reached
    /// the canvas. Over the views the canvas hosts, nothing.
    public override func smartMagnify(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard place(of: point) == .canvas else { return }
        editor.pointerLocated(at: point)
        editor.perform(answering: .smartMagnify)
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
    // the editor runs the command that answers each (the selection's, in the shipped app), the same
    // one the keys for it run. With none, they do nothing.
    /// Edit › Select All. Text being edited (a note, a panel field) selects its own text instead.
    public override func selectAll(_ sender: Any?) { editor.perform(answering: .selectAll) }
    /// Edit › Delete.
    @objc public func delete(_ sender: Any?) { editor.perform(answering: .delete) }
}

extension CanvasView: NSMenuItemValidation {
    /// Edit › Delete and Select All are enabled while the commands that answer them can run
    /// (`canPerform`): Delete while something's selected, Select All while the board has shapes.
    public func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if editor.editingShapeID != nil, !(window?.firstResponder is NSText), Self.editMenuActions.contains(item.action) { return false }
        switch item.action {
        case #selector(delete(_:)): return editor.canPerform(answering: .delete)
        case #selector(selectAll(_:)): return editor.canPerform(answering: .selectAll)
        default: return true
        }
    }

    /// Edit's items that act on the board's shapes: dimmed while a shape is edited and its text isn't
    /// what has the keyboard (a note's box row), so their keys do nothing to the note being edited.
    static let editMenuActions: Set<Selector?> = [
        #selector(NSText.cut(_:)), #selector(NSText.copy(_:)), #selector(NSText.paste(_:)), #selector(delete(_:)), #selector(selectAll(_:)),
    ]
}

@_spi(Host) extension CanvasView: CanvasEditorDelegate {
    public func editorNeedsDisplay(_ editor: CanvasEditor) {
        needsDisplay = true
        minimap?.updateVisibility()
        minimap?.needsDisplay = true
        // Placed again while it shows, as the minimap under it may have shown or hidden meanwhile.
        if zoomIndicator.zoomMayHaveChanged() || !zoomIndicator.isHidden { layoutZoomIndicator() }
        layoutEditingView()
        layoutCard()
        layoutPopover()
    }

    /// Shows the card over what the canvas hosts, under the popover, in place of the one before, and
    /// gives its view the keyboard; or takes it down and gives the keyboard back to the editing view,
    /// else the canvas, if the card had it. Laid out again when it moved or its content resized.
    public func editorCardDidChange(_ editor: CanvasEditor) {
        guard let card = editor.card else {
            removeCardHost()
            return
        }
        let isNew = cardHost?.cardID != card.id || cardHost?.content !== card.view
        if isNew {
            removeCardHost()
            let host = CardView(card)
            // Over the minimap and the zoom, under the popover.
            if let popoverBubble { addSubview(host, positioned: .below, relativeTo: popoverBubble) } else { addSubview(host) }
            cardHost = host
            host.onEscape = { [weak self] in self?.editor.closeCard(.asked) }
            host.nextResponder = nextResponder
            watchPresses()
            layoutCard()
            if let responder = card.firstResponder { window?.makeFirstResponder(responder) }
        } else {
            cardHost?.setAccessibilityLabel(card.accessibilityLabel ?? CardStyle.accessibilityLabel)
            layoutCard()
        }
    }

    /// Whether the keyboard is in the card's view.
    private var cardHasKeyboard: Bool {
        guard let host = cardHost, let responder = window?.firstResponder as? NSView else { return false }
        return responder === host || responder.isDescendant(of: host)
    }

    /// Takes the card down: the keyboard goes back to what the card says (a row's line in the editing view), else the editing
    /// view, else the canvas, if the card had it, and the pointer over it is on the canvas again (the tool hears it when it next
    /// moves).
    private func removeCardHost() {
        guard let host = cardHost else { return }
        // First, so a field being typed in ends its edit as the keyboard leaves it.
        if cardHasKeyboard {
            let back = host.returnsKeyboardTo.flatMap { responder in (responder as? NSView)?.window === window ? responder : nil }
            window?.makeFirstResponder(back ?? editingView?.firstResponder ?? self)
        }
        host.removeFromSuperview()
        cardHost = nil
        stopWatchingPresses()
        if pointerPlace == .card { pointerBackOnCanvas() }
    }

    /// The pointer is over the canvas again where a view it hosted was (the editing view, a card), with
    /// no move to say so: the editor is told where it is (`pointerLocated`, no speed, nothing hovered),
    /// so what reads `isPointerOverCanvas` (Paste at Pointer) has it; the tool hears it when it moves.
    private func pointerBackOnCanvas() {
        pointerPlace = .canvas
        guard let window else { return }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        if bounds.contains(point), place(of: point) == .canvas { editor.pointerLocated(at: point) }
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

    /// Pops up the menu the editor queued (`popUpMenu`) on the next turn of the run loop: the click
    /// that asked is still inside its press's bookkeeping, and a menu's tracking loop there would run
    /// inside it.
    public func editorMenuToPopUpDidChange(_ editor: CanvasEditor) {
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.popUpWaitingMenu() } }
    }

    private func popUpWaitingMenu() {
        // Dropped meanwhile (a press began), or already popped up for an earlier turn's request.
        guard let waiting = editor.menuToPopUp else { return }
        let highlighting = editor.menuItemToHighlight
        editor.menuDidPopUp()
        let rect = editor.camera.toView(waiting.rect)
        let point = CGPoint(x: rect.minX, y: rect.maxY)
        if let menuPresenter {
            menuPresenter(waiting.menu, point, highlighting)
        } else if window != nil {
            // A view taken off its window meanwhile has nowhere to open one: it's dropped.
            waiting.menu.popUp(positioning: highlighting, at: point, in: self)
        }
    }

    /// Over a view the canvas hosts, that view's cursor stands.
    public func editorCursorDidChange(_ editor: CanvasEditor) {
        guard pointerPlace == .canvas else { return }
        cursor(editor.cursor).set()
    }

    public func editorBoardDidChange(_ editor: CanvasEditor) {
        shapeElements.boardDidChange()
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
            shapeElements.editingEnded(old.view)
            old.view.removeFromSuperview()
            editingView = nil
            // Where it was is the canvas again; the tool hears the pointer when it next moves.
            if pointerPlace == .editingView { pointerBackOnCanvas() }
        }
        guard let new = editor.makeEditingView() else { return }
        // Under everything else the canvas hosts.
        addSubview(new.view, positioned: .below, relativeTo: nil)
        editingView = new
        layoutEditingView()
        window?.makeFirstResponder(new.firstResponder)
        // VoiceOver hears what's edited by the shape's name, under its element.
        shapeElements.nameEditingView()
    }

    public func editorEditingSelectedText(_ editor: CanvasEditor) -> String? {
        guard let text = editingView?.firstResponder as? NSTextView else { return nil }
        let range = text.selectedRange()
        guard range.length > 0, NSMaxRange(range) <= (text.string as NSString).length else { return nil }
        // A pill, or any attachment that reads as text, as what it reads as; other attachments dropped.
        let selected = text.attributedString().readingAttachments(in: range)
        return selected.isEmpty ? nil : selected
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
        var characters = event.charactersIgnoringModifiers ?? "", modifiers = Modifiers(event.modifierFlags)
        // ⇧Tab types the back-tab character: the key Tab is, held with ⇧, as a chord names it (⇧⇥).
        if characters == Self.backTab {
            characters = "\t"
            modifiers.insert(.shift)
        }
        self.init(characters, modifiers: modifiers, isRepeat: event.isARepeat, numberRowKey: Self.numberRow[event.keyCode])
    }

    /// What ⇧Tab types (`NSBackTabCharacter`).
    private static let backTab = "\u{19}"

    /// The number row's keys, by their key codes (the same key whatever the layout, `kVK_ANSI_1`…),
    /// and the digit each is.
    static let numberRow: [UInt16: Character] = [
        18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0",
    ]
}
