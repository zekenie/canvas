import AppKit
@_spi(Host) import Canvas
import Geometry

// The canvas as VoiceOver sees it: a layout area named for the board, whose children are its shapes
// (`ShapeElement`s, layout items) and then the views it hosts. The core says what each shape is
// (`editor.accessibleDescription(of:)`), which of them VoiceOver sees (`accessibleShapes(limit:)`) and
// where the focus is (the selection); this is the only place that turns that into NSAccessibility.
// Nothing here runs until an assistive app asks: AppKit asks these only for one, and no frame does.

/// A shape on the canvas as VoiceOver sees it: a layout item, kept by the canvas by its id, so it stays
/// the same element as the camera moves. What it says and where it is are asked of the editor each time
/// VoiceOver asks, never kept, so a pan, a glide or a commit leaves nothing stale. Pressing it selects
/// the shape (`editor.selectForAccessibility`). AppKit asks it on the main thread only.
final class ShapeElement: NSAccessibilityElement {
    let id: ShapeID
    private weak var canvas: CanvasView?

    init(id: ShapeID, canvas: CanvasView) {
        self.id = id
        self.canvas = canvas
        super.init()
    }

    /// The canvas, on the main actor (where AppKit asks).
    private func onCanvas<T: Sendable>(_ fallback: T, _ body: @escaping @MainActor (CanvasView, ShapeID) -> T) -> T {
        guard let canvas else { return fallback }
        let id = id
        return MainActor.assumeIsolated { body(canvas, id) }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .layoutItem }
    override func accessibilityLabel() -> String? { onCanvas(nil) { $0.editor.accessibleDescription(of: $1)?.label } }
    override func accessibilityValue() -> Any? { onCanvas(String?.none) { $0.editor.accessibleDescription(of: $1)?.value } }
    override func accessibilityHelp() -> String? { onCanvas(nil) { $0.editor.accessibleDescription(of: $1)?.help } }
    override func accessibilityParent() -> Any? { canvas }
    override func accessibilityFrame() -> NSRect { onCanvas(.zero) { $0.shapeElements.screenFrame(of: $1) } }
    override func isAccessibilitySelected() -> Bool { onCanvas(false) { $0.editor.accessibleSelection.contains($1) } }
    override func isAccessibilityFocused() -> Bool { onCanvas(false) { $0.shapeElements.isFocused($1) } }
    override func accessibilityPerformPress() -> Bool { onCanvas(false) { $0.editor.selectForAccessibility([$1]) } }
    /// VoiceOver's Show Menu (VO-Shift-M): the selection's menu, as Shape › Show Context Menu opens it, with
    /// the shape selected first if it isn't among the selection.
    override func accessibilityPerformShowMenu() -> Bool { onCanvas(false) { $0.shapeElements.showMenu(for: $1) } }

    /// While the shape is edited, its editing view's controls (`ShapeElements.children(of:)`); otherwise its parts
    /// (`PartElement`s), in the order ⌥Tab steps through them.
    override func accessibilityChildren() -> [Any]? {
        guard let canvas else { return [] }
        let id = id
        // AppKit asks on the main thread, as it asks a view anything.
        nonisolated(unsafe) var children: [Any] = []
        MainActor.assumeIsolated { children = canvas.shapeElements.children(of: id) }
        return children
    }
}

/// A part drawn on a shape as VoiceOver sees it (`editor.accessibleParts(of:)`: a chip, a pill, a button,
/// a handle, an arrow of it), its shape's element's child, kept by the canvas by the part's id. What it
/// says and where it is are asked of the editor each time, as a shape's are. Pressing it presses the part
/// (as Return does on the part ⌥Tab focuses), and while it has the keyboard it is VoiceOver's focus.
final class PartElement: NSAccessibilityElement {
    let shape: ShapeID
    let part: AnyHashable
    private weak var canvas: CanvasView?

    init(shape: ShapeID, part: AnyHashable, canvas: CanvasView) {
        self.shape = shape
        self.part = part
        self.canvas = canvas
        super.init()
    }

    /// The part as the editor lists it now, on the main actor (where AppKit asks); `fallback` when it's gone.
    private func onPart<T: Sendable>(_ fallback: T, _ body: @MainActor (CanvasView, AccessiblePart) -> T) -> T {
        guard let canvas else { return fallback }
        // The part's key is only ever read on the main thread, where AppKit asks.
        let shape = shape
        nonisolated(unsafe) let id = part
        return MainActor.assumeIsolated {
            guard let part = canvas.shapeElements.listedParts(of: shape).first(where: { $0.id == id }) else { return fallback }
            return body(canvas, part)
        }
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { onPart(NSAccessibility.Role.unknown) { _, part in part.role.accessibilityRole } }
    override func accessibilityLabel() -> String? { onPart(nil) { _, part in part.title } }
    override func accessibilityFrame() -> NSRect {
        onPart(.zero) { canvas, part in NSAccessibility.screenRect(fromView: canvas, rect: canvas.editor.camera.toView(part.rect)) }
    }
    override func accessibilityParent() -> Any? {
        guard let canvas else { return nil }
        let shape = shape
        nonisolated(unsafe) var parent: ShapeElement?
        MainActor.assumeIsolated { parent = canvas.shapeElements.element(for: shape) }
        return parent
    }
    override func isAccessibilityFocused() -> Bool {
        let shape = shape
        nonisolated(unsafe) let id = part
        return onPart(false) { canvas, _ in
            canvas.editor.hasKeyboard && canvas.editor.accessibleFocusedPart == AccessiblePartFocus(shape: shape, part: id)
        }
    }
    override func accessibilityPerformPress() -> Bool {
        onPart(false) { canvas, part in
            part.press(canvas.editor)
            // What the press did may change what the shape lists.
            canvas.shapeElements.forgetListedParts()
            return true
        }
    }
}

extension AccessiblePart.Role {
    /// The accessibility role it is shown with: an arrow at the shape goes there, as a link does.
    var accessibilityRole: NSAccessibility.Role {
        switch self {
        case .button: .button
        case .menuButton: .menuButton
        case .link, .connection: .link
        case .checkbox: .checkBox
        case .handle: .handle
        }
    }
}

/// The canvas's shape elements, kept by shape id until the shape goes or another board is shown, and
/// the children it last gave VoiceOver, kept until the board, its layout, the camera, the view's size
/// or the selection changes. Also what it tells an assistive app, once one has asked anything.
@MainActor
final class ShapeElements {
    private unowned let canvas: CanvasView
    private var elements: [ShapeID: ShapeElement] = [:]
    /// Each shape's parts' elements, by part id, as VoiceOver last asked for them.
    private var partElements: [ShapeID: [AnyHashable: PartElement]] = [:]
    private var shown: [ShapeElement] = []
    private var shownKey: Key?
    /// Each shape's parts as last listed (`editor.accessibleParts(of:)`), while what they were listed for holds
    /// (`listedFor`): VoiceOver asks each part's role, label, frame and focus apart, and a listing costs the shape's
    /// adornments' layout and its connections.
    private var listed: [ShapeID: [AccessiblePart]] = [:]
    private var listedFor: PartsKey?
    /// An assistive app has asked the canvas something: from then on it's told what changes.
    private(set) var isListening = false
    /// Notifications waiting for the next turn of the run loop, so a burst of changes (a marquee's
    /// drag, a commit and the selection it leaves) tells VoiceOver once.
    private var focusWaits = false, layoutWaits = false
    #if DEBUG
    /// How many times the children were worked out, and what was posted, in order (debug builds
    /// only), for tests.
    private(set) var builds = 0
    private(set) var posted: [NSAccessibility.Notification] = []
    #endif

    /// What the children were worked out for.
    private struct Key: Equatable {
        let board: BoardID
        let revision: Int
        let layoutRevision: Int
        let camera: Camera
        let viewport: CGSize
        let selection: [ShapeID]
    }

    /// What a shape's parts were listed for: what its children were, and the shape being edited (which lists none).
    private struct PartsKey: Equatable {
        let key: Key
        let editing: ShapeID?
    }

    /// The editor's state the children are worked out for, now.
    private var key: Key {
        Key(board: editor.board, revision: editor.revision, layoutRevision: editor.layoutRevision, camera: editor.camera,
            viewport: editor.viewportSize, selection: editor.accessibleSelection)
    }

    init(canvas: CanvasView) { self.canvas = canvas }

    private var editor: CanvasEditor { canvas.editor }

    /// An assistive app asked: from now on it hears what changes, and the shape being edited, if one
    /// is, is named for it.
    func listen() {
        guard !isListening else { return }
        isListening = true
        nameEditingView()
    }

    func element(for id: ShapeID) -> ShapeElement {
        if let element = elements[id] { return element }
        let element = ShapeElement(id: id, canvas: canvas)
        elements[id] = element
        return element
    }

    /// The shapes VoiceOver sees (`accessibleShapes`, at most `CanvasUIStyle.accessibleShapesLimit`),
    /// worked out again only when what they depend on changed.
    func children() -> [ShapeElement] {
        listen()
        let key = key
        guard key != shownKey else { return shown }
        #if DEBUG
        builds += 1
        #endif
        let ids = editor.accessibleShapes(limit: CanvasUIStyle.accessibleShapesLimit)
        shown = ids.map(element(for:))
        shownKey = key
        // Elements of shapes long out of view go, past a few times the most shown at once.
        if elements.count > 4 * CanvasUIStyle.accessibleShapesLimit {
            let keep = Set(ids).union(key.selection)
            elements = elements.filter { keep.contains($0.key) }
            partElements = partElements.filter { keep.contains($0.key) }
        }
        return shown
    }

    /// A shape's element's children: while it's edited, what VoiceOver sees of its editing view (`editedControls`);
    /// otherwise its parts' elements. Asked of the editor each time, so editing ending leaves nothing behind.
    func children(of id: ShapeID) -> [Any] {
        editedControls(of: id) ?? parts(of: id)
    }

    /// What VoiceOver sees of the shape's editing view while it's edited (nil while it isn't), as AppKit would show the
    /// view anywhere: the view if it's an element, else its controls (a note's words and its rows, each with what's in
    /// it). The editing view's parent is the shape's element, so theirs is too.
    private func editedControls(of id: ShapeID) -> [Any]? {
        guard editor.editingShapeID == id, let view = canvas.editingView?.view else { return nil }
        let element = element(for: id)
        if view.accessibilityParent() as AnyObject !== element { view.setAccessibilityParent(element) }
        return NSAccessibility.unignoredChildren(from: [view])
    }

    /// The editing view is taken away: its shape's element is no longer its parent.
    func editingEnded(_ view: NSView) { view.setAccessibilityParent(nil) }

    /// A shape's parts' elements (`editor.accessibleParts(of:)`), in the order listed, each kept by its id
    /// while the shape lists it.
    func parts(of id: ShapeID) -> [PartElement] {
        listen()
        let kept = partElements[id] ?? [:]
        var now: [AnyHashable: PartElement] = [:]
        let parts = listedParts(of: id).map { part in
            let element = now[part.id] ?? kept[part.id] ?? PartElement(shape: id, part: part.id, canvas: canvas)
            now[part.id] = element
            return element
        }
        partElements[id] = now.isEmpty ? nil : now
        return parts
    }

    /// A shape's parts as the editor lists them now (`editor.accessibleParts(of:)`), listed once while the board, its
    /// layout, the camera, the view's size, the selection and the shape being edited stay as they were.
    func listedParts(of id: ShapeID) -> [AccessiblePart] {
        let now = PartsKey(key: key, editing: editor.editingShapeID)
        if now != listedFor {
            listed = [:]
            listedFor = now
        }
        if let parts = listed[id] { return parts }
        let parts = editor.accessibleParts(of: id)
        listed[id] = parts
        return parts
    }

    /// Lists every shape's parts afresh when next asked (a part was pressed).
    func forgetListedParts() {
        listed = [:]
        listedFor = nil
    }

    /// The element of a part, kept while its shape lists it.
    private func element(for focus: AccessiblePartFocus) -> PartElement {
        if let element = partElements[focus.shape]?[focus.part] { return element }
        let element = PartElement(shape: focus.shape, part: focus.part, canvas: canvas)
        partElements[focus.shape, default: [:]][focus.part] = element
        return element
    }

    /// The shape VoiceOver's focus is on: the one selected last, while the canvas has the keyboard (`editor.hasKeyboard`);
    /// none while a list, a field or the editing view has it, though a row of the table of contents selects as it goes.
    var focusedShape: ShapeID? { editor.hasKeyboard ? editor.accessibleSelection.last : nil }

    /// Whether the shape's element has the focus: the canvas has the keyboard, it's the one selected last, and no part of
    /// it has the keyboard.
    func isFocused(_ id: ShapeID) -> Bool {
        focusedShape == id && editor.accessibleFocusedPart?.shape != id
    }

    /// The element that has the keyboard, while the canvas does: the part of the selected shape that has
    /// it (⌥Tab), else the shape selected last; nil for none.
    func focused() -> NSAccessibilityElement? {
        listen()
        guard let shape = focusedShape else { return nil }
        if let part = editor.accessibleFocusedPart, part.shape == shape { return element(for: part) }
        return element(for: shape)
    }

    /// The selection's menu (`menuForPoppedSelection`), popped below the selection, as Shape › Show Context Menu
    /// pops it: the shape is selected first unless it's among the selection. False when there's no menu.
    func showMenu(for id: ShapeID) -> Bool {
        if !editor.accessibleSelection.contains(id) { editor.selectForAccessibility([id]) }
        let selection = editor.accessibleSelection
        guard let menu = editor.menuForPoppedSelection(),
              let bounds = editor.shapeContext.bounds(of: selection.isEmpty ? [id] : selection) else { return false }
        editor.popUpMenu(menu, below: bounds)
        return true
    }

    /// The selected shapes among the children (`children()`), in the selection's order: every one of a selection
    /// VoiceOver is given, never more than it is (⌘A on a board of thousands makes no element for each).
    func selected() -> [ShapeElement] {
        let shown = children()
        let selection = editor.accessibleSelection
        guard !selection.isEmpty else { return [] }
        // In the selection's order, as before.
        let given = Dictionary(shown.lazy.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return selection.compactMap { given[$0] }
    }

    /// Where a shape is, in screen coordinates, as the camera has it now; zero for one without bounds.
    func screenFrame(of id: ShapeID) -> CGRect {
        guard let bounds = editor.shapeContext.bounds(of: CollectionOfOne(id)) else { return .zero }
        return NSAccessibility.screenRect(fromView: canvas, rect: editor.camera.toView(bounds))
    }

    /// The shape under a point, in screen coordinates; nil off the canvas or its shapes.
    func element(atScreen point: CGPoint) -> ShapeElement? {
        guard let window = canvas.window else { return nil }
        let local = canvas.convert(window.convertPoint(fromScreen: point), from: nil)
        guard canvas.bounds.contains(local), let id = editor.shape(at: editor.camera.toWorld(local)) else { return nil }
        return element(for: id)
    }

    // MARK: Telling VoiceOver

    /// The selection, or the focused part, changed: VoiceOver's focus follows on the next turn, and
    /// with several shapes selected it hears how many; only while the canvas has the keyboard, so a list
    /// that selects shapes as it's walked (the table of contents, Find's results) keeps VoiceOver on its row.
    func focusDidChange() {
        guard isListening, !focusWaits else { return }
        focusWaits = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.postFocus() } }
    }

    private func postFocus() {
        focusWaits = false
        guard editor.hasKeyboard else { return }
        post(.focusedUIElementChanged, element: focused().map { $0 as Any } ?? canvas)
        let count = editor.accessibleSelection.count
        if count > 1 {
            post(.selectedChildrenChanged, element: canvas)
            editor.announce(CanvasUIStyle.selected(count))
        }
    }

    /// A commit added shapes or took some off: their elements go, and VoiceOver hears the layout
    /// changed, once, on the next turn, when one it sees came or went.
    func shapesCameOrWent(added: Set<ShapeID>, removed: Set<ShapeID>) {
        for id in removed {
            elements[id] = nil
            partElements[id] = nil
        }
        guard isListening, !layoutWaits else { return }
        let seen = shown.contains { removed.contains($0.id) }
        let view = editor.camera.toWorld(CGRect(origin: .zero, size: editor.viewportSize))
        let arrived = added.contains { id in editor.shapeContext.bounds(of: CollectionOfOne(id)).map(view.intersects) ?? false }
        guard seen || arrived else { return }
        layoutChanged()
    }

    /// Another board is shown: every element is the board left's.
    func boardDidChange() {
        elements = [:]
        partElements = [:]
        shown = []
        shownKey = nil
        forgetListedParts()
        guard isListening else { return }
        layoutChanged()
        focusDidChange()
    }

    private func layoutChanged() {
        guard !layoutWaits else { return }
        layoutWaits = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.layoutWaits = false
                self.post(.layoutChanged, element: self.canvas)
            }
        }
    }

    /// Says `text` to whoever uses VoiceOver.
    func announce(_ text: String, priority: AnnouncementPriority) {
        let level: NSAccessibilityPriorityLevel = switch priority {
        case .low: .low
        case .medium: .medium
        case .high: .high
        }
        post(.announcementRequested, element: canvas, userInfo: [.announcement: text, .priority: level.rawValue])
    }

    private func post(_ notification: NSAccessibility.Notification, element: Any, userInfo: [NSAccessibility.NotificationUserInfoKey: Any]? = nil) {
        #if DEBUG
        posted.append(notification)
        #endif
        if let userInfo { NSAccessibility.post(element: element, notification: notification, userInfo: userInfo) } else {
            NSAccessibility.post(element: element, notification: notification)
        }
    }

    // MARK: Editing

    /// The shape being edited, if one is and an assistive app is listening: its editing view's first
    /// responder is named for it (when it has no name of its own), and the editing view's controls are its
    /// element's children (`children(of:)`).
    func nameEditingView() {
        guard isListening, let id = editor.editingShapeID, let responder = canvas.editingResponder,
              let description = editor.accessibleDescription(of: id) else { return }
        _ = editedControls(of: id)
        if (responder.accessibilityLabel() ?? "").isEmpty { responder.setAccessibilityLabel(description.label) }
    }
}

extension CanvasView {
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .layoutArea }
    public override func accessibilityLabel() -> String? { editor.accessibleBoardName ?? CanvasUIStyle.unnamedBoard }

    /// The shapes VoiceOver sees, then the views the canvas hosts (the minimap, the zoom, a card, a
    /// popover); the editing view is its shape's element's child.
    public override func accessibilityChildren() -> [Any]? {
        let shapes: [Any] = shapeElements.children()
        let editing = editingView?.view
        let hosted = (super.accessibilityChildren() ?? []).filter { child in
            guard let editing, let view = child as? NSView else { return true }
            return view !== editing && !view.isDescendant(of: editing)
        }
        return shapes + hosted
    }

    public override func accessibilitySelectedChildren() -> [Any]? { shapeElements.selected() }

    /// The selected shape's element, the last selected of several, or its part that has the keyboard
    /// (⌥Tab); the canvas with none.
    public override var accessibilityFocusedUIElement: Any? {
        // AppKit asks on the main thread, as it asks a view anything.
        nonisolated(unsafe) var focused: NSAccessibilityElement?
        MainActor.assumeIsolated { focused = shapeElements.focused() }
        return focused ?? self
    }

    /// A view the canvas hosts, else the shape under the point, else the canvas.
    public override func accessibilityHitTest(_ point: NSPoint) -> Any? {
        MainActor.assumeIsolated { shapeElements.listen() }
        if let hit = super.accessibilityHitTest(point), hit as AnyObject !== self { return hit }
        nonisolated(unsafe) var under: ShapeElement?
        MainActor.assumeIsolated { under = shapeElements.element(atScreen: point) }
        return under ?? self
    }

    /// The view that has the keyboard while a shape is edited: its editing view's first responder.
    var editingResponder: NSView? { editingView?.firstResponder as? NSView }

    #if DEBUG
    /// How many times the canvas has worked out which shapes VoiceOver sees (debug builds only).
    @_spi(Host) public var accessibleChildrenBuilds: Int { shapeElements.builds }
    /// What the canvas posted to assistive apps, in order (debug builds only).
    @_spi(Host) public var accessibilityPosts: [NSAccessibility.Notification] { shapeElements.posted }
    #endif
}

@_spi(Host) extension CanvasView {
    public func editorAccessibilityFocusDidChange(_ editor: CanvasEditor) { shapeElements.focusDidChange() }

    public func editorAnnounce(_ editor: CanvasEditor, _ text: String, priority: AnnouncementPriority) {
        shapeElements.announce(text, priority: priority)
    }

    public func editorShapesDidComeOrGo(_ editor: CanvasEditor, added: Set<ShapeID>, removed: Set<ShapeID>) {
        shapeElements.shapesCameOrWent(added: added, removed: removed)
    }
}
