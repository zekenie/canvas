import CoreGraphics
import Foundation
import Geometry
import Observation

/// What an editor tells the view hosting it.
@_spi(Host) @MainActor
public protocol CanvasEditorDelegate: AnyObject {
    /// Something visible changed (document, camera, selection, hover, ...): redraw, and keep any
    /// editing view over its shape.
    func editorNeedsDisplay(_ editor: CanvasEditor)
    func editorCursorDidChange(_ editor: CanvasEditor)
    /// `editingShapeID` changed: show, or take down, the definition's editing view.
    func editorEditingDidChange(_ editor: CanvasEditor)
}

/// The canvas's brain, with no view: document, camera, selection, tools, sessions and input.
/// `CanvasView` feeds it events and draws it through its host API (CanvasEditor+Host.swift);
/// plugins get everything else.
@MainActor
@Observable
public final class CanvasEditor {
    public let registry: Registry
    @ObservationIgnored public let scheduler: any Scheduler
    /// Set by the hosting view.
    @_spi(Host) @ObservationIgnored public weak var delegate: (any CanvasEditorDelegate)?

    /// Changes only through `transact`.
    public private(set) var document: CanvasDocument
    /// +1 per transaction that changed something.
    public private(set) var revision = 0
    /// Setting it stops the camera's slide (CanvasEditor+Camera.swift).
    public var camera = Camera() {
        didSet {
            stopCameraSlide()
            setNeedsDisplay()
        }
    }

    // The selection, hover and hint always name shapes in the document: setting one to a shape
    // that isn't there drops it (nil, or out of the set).

    /// Every selected shape, in the order it was selected, each once: setting drops ids that
    /// aren't there and repeats (the first is kept). Setting what's already selected does nothing
    /// (no redraw, no Observation notification). Changing which shape is the only selected one
    /// drops the hovered handle.
    public var selectedShapeIDs: [ShapeID] {
        get { selectedIDs }
        set {
            var seen = Set<ShapeID>()
            let ids = newValue.filter { document[$0] != nil && seen.insert($0).inserted }
            guard ids != selectedIDs else { return }
            selectedIDs = ids
            let only = ids.count == 1 ? ids[0] : nil
            if only != onlySelectedID {
                onlySelectedID = only
                hoveredHandle = nil            // handles belong to the only selected shape
            }
            setNeedsDisplay()
        }
    }
    /// The only selected shape: nil when none or several are (tldraw's onlySelectedShape). Setting
    /// it selects exactly that shape; nil selects none. Handles, Return and editing follow this, so
    /// they apply only to a lone shape. Observers of this hear only changes to the only selected
    /// shape, not 2 → 3.
    public var selection: ShapeID? {
        get { onlySelectedID }
        set { selectedShapeIDs = newValue.map { [$0] } ?? [] }
    }
    public func isSelected(_ id: ShapeID) -> Bool { selectedIDs.contains(id) }
    /// The union of the selected shapes' geometry bounds, in world units; nil with nothing
    /// selected. Shapes with no outline (nothing drawn) don't count.
    public var selectionBounds: CGRect? {
        let context = shapeContext
        let rects = selectedIDs.compactMap { context.geometry(of: $0) }
            .filter { !$0.outline.isEmpty && !$0.bounds.isNull }.map(\.bounds)
        guard let first = rects.first else { return nil }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }
    /// The marquee being dragged in the select tool, in world units, for drawing; nil otherwise.
    public var brush: CGRect? { (session as? BrushingSession)?.brush }
    /// Under the pointer in the select tool, outlined as a hover hint.
    public internal(set) var hovered: ShapeID? {
        get { hoveredID }
        set {
            let id = existing(newValue)
            guard id != hoveredID else { return }
            hoveredID = id
            setNeedsDisplay()
        }
    }
    /// A shape outlined as a target, whatever the tool (a connector tool sets it while aiming).
    public var hintedShapeID: ShapeID? {
        get { hintedID }
        set {
            let id = existing(newValue)
            guard id != hintedID else { return }
            hintedID = id
            setNeedsDisplay()
        }
    }
    private var selectedIDs: [ShapeID] = []
    private var onlySelectedID: ShapeID?
    private var hoveredID: ShapeID?
    private var hintedID: ShapeID?
    private func existing(_ id: ShapeID?) -> ShapeID? { id.flatMap { document[$0] == nil ? nil : $0 } }
    /// A handle of the only selected shape under the pointer (its definition's `Handle`).
    public internal(set) var hoveredHandle: AnyHashable? {
        didSet {
            guard hoveredHandle != oldValue else { return }
            setNeedsDisplay()
            refreshCursor()
        }
    }
    public private(set) var currentToolID: ToolID = .select
    public private(set) var editingShapeID: ShapeID?
    /// The press-drag-release in progress, if any. Tools start sessions; a session may hand over
    /// to another by setting this.
    @ObservationIgnored public var session: (any Session)? { didSet { setNeedsDisplay() } }

    /// The keyboard's modifiers right now. Set by the hosting view (`NSEvent.modifierFlags`) and
    /// by test harnesses; plugins read `effectiveModifiers`.
    @_spi(Host) @ObservationIgnored public var liveModifiers: @MainActor () -> Modifiers = { [] }

    @ObservationIgnored private var tools: [ToolID: any Tool] = [:]
    @ObservationIgnored private let serviceRegistrations: [ObjectIdentifier: ServiceRegistration]
    @ObservationIgnored private var services: [ObjectIdentifier: any EditorService] = [:]
    @ObservationIgnored private var serviceOrder: [any EditorService] = []
    @ObservationIgnored private var resolvingServices: Set<ObjectIdentifier> = []
    @ObservationIgnored private var isTransacting = false
    // Input state, used by CanvasEditor+Host.swift.
    @ObservationIgnored var tracker = PointerTracker()
    @ObservationIgnored var heldModifiers: Modifiers = []
    @ObservationIgnored var recentlyReleased: Modifiers = []
    @ObservationIgnored var releaseTimer: ScheduledTask?
    // The camera's slide's next frame, used by CanvasEditor+Camera.swift.
    @ObservationIgnored var cameraSlide: ScheduledTask?

    public init(registry: Registry, document: CanvasDocument = CanvasDocument(), scheduler: any Scheduler = TaskScheduler()) {
        for record in document.shapes {
            precondition(registry.definition(for: record.kind)?.erasedAccepts(record) == true,
                         "no installed plugin defines \(record.kind) shapes with these props")
        }
        self.registry = registry
        self.document = document
        self.scheduler = scheduler
        serviceRegistrations = Dictionary(registry.services.map { ($0.type, $0) }, uniquingKeysWith: { first, _ in first })
        // Services first, so tools can look them up; each resolves the services it asks for.
        for registration in registry.services { _ = resolveService(registration.type) }
        for (id, make) in registry.toolFactories { tools[id] = make(self) }
    }

    public func service<S: EditorService>(_ type: S.Type) -> S? { resolveService(ObjectIdentifier(S.self)) as? S }

    private func resolveService(_ id: ObjectIdentifier) -> (any EditorService)? {
        if let service = services[id] { return service }
        guard let registration = serviceRegistrations[id] else { return nil }
        precondition(!resolvingServices.contains(id), "service \(registration.name) needs itself to be made")
        resolvingServices.insert(id)
        defer { resolvingServices.remove(id) }
        let service = registration.make(self)
        services[id] = service
        serviceOrder.append(service)
        return service
    }

    var currentTool: any Tool { tools[currentToolID]! }
    public var shapeContext: ShapeContext { ShapeContext(document: document, registry: registry, camera: camera) }

    /// Redraw. The core redraws for everything it owns (the document, camera, selection, hover,
    /// sessions); a plugin whose drawn state changes some other way (a timer, say) calls this.
    public func setNeedsDisplay() { delegate?.editorNeedsDisplay(self) }

    func refreshCursor() { delegate?.editorCursorDidChange(self) }

    // MARK: Document

    /// The only way to change the document. Commits once, if anything changed. Transactions don't
    /// nest: code that runs inside one (a `willDelete` handler) edits the transaction it's given.
    @discardableResult
    public func transact<T>(_ body: (inout Transaction) throws -> T) rethrows -> T {
        precondition(!isTransacting, "transactions don't nest; use the one you were given")
        isTransacting = true
        var transaction = Transaction(document: document, registry: registry, camera: camera)
        let result: T
        do {
            defer { isTransacting = false }
            result = try body(&transaction)
        }
        // Committing can end editing, and an editing view may save as it closes: outside the
        // transaction, so it can.
        if transaction.didChange { commit(transaction.document) }
        return result
    }

    private func commit(_ newDocument: CanvasDocument) {
        document = newDocument
        revision += 1
        // The setters drop ids that no longer name a shape.
        selectedShapeIDs = selectedIDs
        hovered = hoveredID
        hintedShapeID = hintedID
        if let editing = editingShapeID, document[editing] == nil { endEditing() }
        setNeedsDisplay()
    }

    // MARK: Tools

    public func setTool(_ id: ToolID) {
        guard id != currentToolID, tools[id] != nil else { return }
        let old = currentToolID
        currentToolID = id
        hintedShapeID = nil
        hovered = nil
        hoveredHandle = nil
        for service in serviceOrder { service.toolDidChange(from: old, to: id, in: self) }
        setNeedsDisplay()
        refreshCursor()
    }

    /// Where place tools and the double-click claim create shapes. (Other tools create shapes
    /// with `transact { $0.insert(...) }`, as the arrow tool does.)
    public func place(_ placement: Placement, at point: CGPoint) {
        let record = placement.make(CGRect(center: point, size: placement.size))
        transact { $0.insert(record) }
        selection = record.id
        setTool(.select)
        switch placement.completion {
        case .translate: session = TranslatingSession(ids: [record.id], from: point, in: self)
        case .edit: beginEditing(record.id)
        }
    }

    // MARK: Commands

    /// Escape: cancels a session that can be cancelled (and does nothing during any other),
    /// otherwise leaves a non-select tool, otherwise deselects all.
    public func cancel() {
        if let running = session {
            if running.cancel(in: self), session === running { session = nil }
            return
        }
        if currentToolID != .select { setTool(.select) } else { selection = nil }
    }

    /// Return: edits the only selected shape if its kind is editable.
    public func editSelection() {
        if let selection { beginEditing(selection) }
    }

    /// Delete: removes every selected shape in one transaction. willDelete handlers see them all,
    /// so arrows bound to them let go where they are.
    public func deleteSelection() {
        let ids = selectedShapeIDs
        guard !ids.isEmpty else { return }
        transact { $0.delete(Set(ids)) }
        selectedShapeIDs = []
        hovered = nil
        hoveredHandle = nil
    }

    /// ⌘A (tldraw's selectAll): ends editing, switches to select, and selects every shape in
    /// document order. Does nothing mid-gesture.
    public func selectAll() {
        guard session == nil else { return }
        endEditing()
        setTool(.select)
        selectedShapeIDs = document.shapes.map(\.id)
    }

    // MARK: Input, for tools and sessions

    /// World units, through the current camera.
    public var pointerWorldLocation: CGPoint { camera.toWorld(tracker.location) }
    /// View points per millisecond, smoothed.
    public var pointerSpeed: CGFloat { tracker.speed }
    /// View points per millisecond, per axis, smoothed like `pointerSpeed`; reset on every press.
    public var pointerVelocity: CGPoint { tracker.velocity }
    /// Held now, plus any released within `Style.modifierReleaseDelay`.
    public var effectiveModifiers: Modifiers { liveModifiers().union(recentlyReleased) }

    // MARK: Editing

    @discardableResult
    public func beginEditing(_ id: ShapeID) -> Bool {
        endEditing()
        guard let record = document[id], registry.definition(for: record.kind) is any Editable else { return false }
        editingShapeID = id
        selection = id
        delegate?.editorEditingDidChange(self)
        setNeedsDisplay()
        return true
    }

    public func endEditing() {
        guard editingShapeID != nil else { return }
        editingShapeID = nil
        delegate?.editorEditingDidChange(self)
        setNeedsDisplay()
    }

    // MARK: Hit testing and order

    /// Back to front: document order, with each anchored shape just above its anchor (anchored
    /// shapes whose anchor is missing go on top).
    public func paintOrder() -> [AnyShapeRecord] {
        var anchors: [ShapeID: ShapeID?] = [:]
        for record in document.shapes {
            if let anchored = registry.definition(for: record.kind) as? any PaintOrderAnchored {
                anchors.updateValue(anchored.erasedPaintAnchor(of: record, in: document), forKey: record.id)
            }
        }
        var above: [ShapeID: [AnyShapeRecord]] = [:]
        var plain: [AnyShapeRecord] = []
        var top: [AnyShapeRecord] = []
        for record in document.shapes {
            guard let anchor = anchors[record.id] else {
                plain.append(record)
                continue
            }
            // Only a plain shape that's still there can anchor another.
            if let anchor, document[anchor] != nil, anchors[anchor] == nil {
                above[anchor, default: []].append(record)
            } else {
                top.append(record)
            }
        }
        return plain.flatMap { [$0] + (above[$0.id] ?? []) } + top
    }

    /// The front-most shape under a world point.
    public func shape(at point: CGPoint) -> ShapeID? {
        let context = shapeContext
        return paintOrder().reversed().first { record in
            registry.definition(for: record.kind)?.erasedHitTest(point, on: record, in: context) ?? false
        }?.id
    }

    /// The shapes a brush (a world rect) selects, back to front. Bounds strictly inside the brush
    /// always count; with `mustContain` (⌘) nothing else does; otherwise a shape whose bounds the
    /// brush overlaps or touches counts if its definition's `brushHitTest` says so. Shapes with no
    /// outline never count.
    func shapes(inBrush brush: CGRect, mustContain: Bool) -> [ShapeID] {
        let context = shapeContext
        return paintOrder().filter { record in
            guard let definition = registry.definition(for: record.kind),
                  let geometry = definition.erasedGeometry(of: record, in: context),
                  !geometry.outline.isEmpty, !geometry.bounds.isNull else { return false }
            if brush.containsStrictly(geometry.bounds) { return true }
            guard !mustContain, brush.touches(geometry.bounds) else { return false }
            return definition.erasedBrushHitTest(brush, on: record, in: context)
        }.map(\.id)
    }

    /// The only selected shape's handles, in view space, front to back.
    func visibleHandles() -> [(handle: AnyHashable, point: CGPoint)] {
        guard let id = selection, let record = document[id],
              let definition = registry.definition(for: record.kind) as? any HandleProviding else { return [] }
        return definition.erasedHandles(of: record, in: shapeContext).map { ($0.handle, camera.toView($0.point)) }
    }

    /// The only selected shape's handle under a view point: the nearest within `Style.handleHitRadius`.
    @_spi(Host) public func handle(atViewPoint viewPoint: CGPoint) -> AnyHashable? {
        visibleHandles()
            .map { ($0.handle, $0.point.distance(to: viewPoint)) }
            .filter { $0.1 <= Style.handleHitRadius }
            .min { $0.1 < $1.1 }?
            .0
    }

    func pressHandle(_ handle: AnyHashable, with pointer: Pointer) {
        guard let id = selection, let record = document[id],
              let definition = registry.definition(for: record.kind) as? any HandleProviding else { return }
        if definition.erasedPressHandle(handle, of: record, at: pointer, in: self) == .drag {
            session = PointingHandleSession(shapeID: id, handle: handle, origin: pointer.view)
        }
    }
}
