import CoreGraphics
import Foundation
import Geometry
import Observation

/// What an editor tells the view hosting it.
@_spi(Host) @MainActor
public protocol CanvasEditorDelegate: AnyObject {
    /// Something visible changed (document, camera, tool, session, ...): redraw, and keep any
    /// editing view over its shape.
    func editorNeedsDisplay(_ editor: CanvasEditor)
    func editorCursorDidChange(_ editor: CanvasEditor)
    /// `editingShapeID` changed: show, or take down, the definition's editing view.
    func editorEditingDidChange(_ editor: CanvasEditor)
}

/// The canvas's brain, with no view: document, camera, tools, sessions and input.
/// `CanvasView` feeds it events and draws it through its host API (CanvasEditor+Host.swift);
/// plugins get everything else.
@MainActor
@Observable
public final class CanvasEditor {
    public let registry: Registry
    @ObservationIgnored public let scheduler: any Scheduler
    /// How transactions make stacking keys for shapes they add or reorder.
    @ObservationIgnored public let stackingKeys: StackingKeyGenerator
    /// Set by the hosting view.
    @_spi(Host) @ObservationIgnored public weak var delegate: (any CanvasEditorDelegate)?

    /// Changes only through `transact`.
    public var document: CanvasDocument {
        access(keyPath: \.document)
        return storedDocument
    }
    /// Observed through `document`, which a commit sets with `withMutation`: the macro's setter
    /// would first compare the old document with the new one, every shape of it, on every commit.
    @ObservationIgnored private var storedDocument: CanvasDocument
    /// +1 per transaction that changed something.
    public private(set) var revision = 0
    /// Setting it stops the camera's slide or animation (CanvasEditor+Camera.swift).
    public var camera = Camera() {
        didSet {
            shapeIndex.cameraDidChange()
            stopCameraMotion()
            setNeedsDisplay()
        }
    }

    /// The hosting view's size, in view points: the part of the world the camera shows is
    /// `camera.toWorld(CGRect(origin: .zero, size: viewportSize))`. Zero until the view has a size
    /// (and in tests that don't give one).
    @ObservationIgnored public internal(set) var viewportSize: CGSize = .zero

    /// A shape outlined as a target, whatever the tool (a connector tool sets it while aiming).
    /// Setting it to a shape that isn't there drops it.
    public var hintedShapeID: ShapeID? {
        get { hintedID }
        set {
            let id = newValue.flatMap { document[$0] == nil ? nil : $0 }
            guard id != hintedID else { return }
            hintedID = id
            setNeedsDisplay()
        }
    }
    private var hintedID: ShapeID?
    /// Starts as the registry's default tool.
    public private(set) var currentToolID: ToolID
    public private(set) var editingShapeID: ShapeID?
    /// The press-drag-release in progress, if any. Tools start sessions; a session may hand over
    /// to another by setting this.
    @ObservationIgnored public var session: (any Session)? { didSet { setNeedsDisplay() } }

    /// The keyboard's modifiers right now. Set by the hosting view (`NSEvent.modifierFlags`) and
    /// by test harnesses; plugins read `effectiveModifiers`.
    @_spi(Host) @ObservationIgnored public var liveModifiers: @MainActor () -> Modifiers = { [] }
    /// Called after every transaction that changed the document, once everything has heard of it:
    /// the board it belongs to has been edited. (Not for `replaceDocument`.)
    @_spi(Host) @ObservationIgnored public var didCommitTransaction: (@MainActor (CanvasEditor) -> Void)?

    @ObservationIgnored private var tools: [ToolID: any Tool] = [:]
    @ObservationIgnored private let serviceRegistrations: [ObjectIdentifier: ServiceRegistration]
    @ObservationIgnored private var services: [ObjectIdentifier: any EditorService] = [:]
    @ObservationIgnored private var serviceOrder: [any EditorService] = []
    @ObservationIgnored private var resolvingServices: Set<ObjectIdentifier> = []
    @ObservationIgnored private var isTransacting = false
    /// Each shape's geometry and extent, and the paint order, kept from frame to frame.
    @ObservationIgnored let shapeIndex = ShapeIndex()
    // Input state, used by CanvasEditor+Host.swift.
    @ObservationIgnored var tracker = PointerTracker()
    @ObservationIgnored var heldModifiers: Modifiers = []
    @ObservationIgnored var recentlyReleased: Modifiers = []
    @ObservationIgnored var releaseTimer: ScheduledTask?
    // The camera motion's next frame (a slide or an animation), and an animation's target, used by
    // CanvasEditor+Camera.swift.
    @ObservationIgnored var cameraMotion: ScheduledTask?
    @ObservationIgnored var cameraAnimationTarget: Camera?

    public init(registry: Registry, document: CanvasDocument = CanvasDocument(), scheduler: any Scheduler = TaskScheduler(),
                stackingKeys: StackingKeyGenerator = .jittered) {
        for record in document.shapes {
            precondition(record.isOpaque || registry.definition(for: record.kind)?.erasedAccepts(record) == true,
                         "no installed plugin defines \(record.kind) shapes with these props")
        }
        self.registry = registry
        storedDocument = registry.fillingDefaults(document)
        self.scheduler = scheduler
        self.stackingKeys = stackingKeys
        currentToolID = registry.defaultTool
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
    public var shapeContext: ShapeContext { ShapeContext(document: document, registry: registry, camera: camera, index: shapeIndex) }

    /// Redraw. The core redraws for everything it owns (the document, camera, tool, sessions); a
    /// plugin whose drawn state changes some other way (its own state, a timer) calls this.
    public func setNeedsDisplay() { delegate?.editorNeedsDisplay(self) }

    /// Sets the cursor again. The core does after every pointer event and tool switch; a tool
    /// whose cursor follows state that changes some other way (a key press) calls this.
    public func refreshCursor() { delegate?.editorCursorDidChange(self) }

    // MARK: Document

    /// The only way to change the document. Commits once, if anything changed. Transactions don't
    /// nest: code that runs inside one (a `willDelete` handler) edits the transaction it's given.
    @discardableResult
    public func transact<T>(_ body: (inout Transaction) throws -> T) rethrows -> T {
        precondition(!isTransacting, "transactions don't nest; use the one you were given")
        isTransacting = true
        var transaction = Transaction(document: document, registry: registry, camera: camera, keys: stackingKeys)
        let result: T
        do {
            defer { isTransacting = false }
            result = try body(&transaction)
        }
        // Committing can end editing, and an editing view may save as it closes: outside the
        // transaction, so it can.
        if transaction.didChange {
            commit(transaction.document, changes: transaction.changes)
            didCommitTransaction?(self)
        }
        return result
    }

    /// Puts a whole other document in place: opening a board, reverting it, reloading it after it
    /// changed on disk. Ends any press and any editing, then commits as a transaction does, except
    /// that the board isn't edited by it (`didCommitTransaction` isn't called).
    @_spi(Host) public func replaceDocument(with newDocument: CanvasDocument) {
        precondition(!isTransacting, "a document can't be replaced inside a transaction")
        for record in newDocument.shapes {
            precondition(record.isOpaque || registry.definition(for: record.kind)?.erasedAccepts(record) == true,
                         "no installed plugin defines \(record.kind) shapes with these props")
        }
        session = nil
        endEditing()
        let newDocument = registry.fillingDefaults(newDocument)
        commit(newDocument, changes: ChangeSet(from: storedDocument, to: newDocument))
    }

    private func commit(_ newDocument: CanvasDocument, changes: ChangeSet) {
        withMutation(keyPath: \.document) { storedDocument = newDocument }
        revision += 1
        shapeIndex.documentDidChange(changes, in: newDocument, registry: registry)
        // Services drop what no longer names a shape, as the hint's setter does.
        for service in serviceOrder { service.documentDidChange(changes, in: self) }
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
        for service in serviceOrder { service.toolDidChange(from: old, to: id, in: self) }
        setNeedsDisplay()
        refreshCursor()
    }

    /// Where place tools (and any plugin with a `Placement`) create shapes: the shape goes in, the
    /// default tool comes back, services hear `didPlace` (the selection selects it), and the shape
    /// follows the pointer or is edited. (Other tools create shapes with
    /// `transact { $0.insert(...) }`, as the arrow tool does.)
    public func place(_ placement: Placement, at point: CGPoint) {
        let record = placement.make(CGRect(center: point, size: placement.size))
        transact { $0.insert(record) }
        setTool(registry.defaultTool)
        for service in serviceOrder { service.didPlace(record.id, in: self) }
        switch placement.completion {
        case .translate: session = TranslatingSession(ids: [record.id], from: point, in: self)
        case .edit: beginEditing(record.id)
        }
    }

    // MARK: Commands

    /// What Escape does (the plugin that keeps the keys calls it): cancels a session that can be
    /// cancelled (and does nothing during any other); otherwise the tool's own Escape; otherwise
    /// leaves a tool that isn't the default one.
    public func cancel() {
        if let running = session {
            if running.cancel(in: self), session === running { session = nil }
            return
        }
        if currentTool.cancel(in: self) { return }
        setTool(registry.defaultTool)
    }

    /// Runs the command a plugin claimed, if it can run now: from a menu item (the canvas view
    /// forwards Edit › Delete and Edit › Select All, the board's window Go › Back), a key, or any
    /// plugin. Returns false if no plugin claims it, or it can't.
    @discardableResult
    public func perform(_ command: CanvasCommand) -> Bool {
        guard let registration = registry.command(command), registration.isEnabled(self) else { return false }
        registration.run(self)
        return true
    }

    /// Whether `perform` would run the command: a plugin claims it, and says it can now. A menu
    /// asks, to enable its item.
    public func canPerform(_ command: CanvasCommand) -> Bool {
        registry.command(command)?.isEnabled(self) ?? false
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

    /// Edits a shape of an `Editable` kind in place. Returns false for any other shape.
    @discardableResult
    public func beginEditing(_ id: ShapeID) -> Bool {
        endEditing()
        guard let record = document[id], !record.isOpaque, registry.definition(for: record.kind) is any Editable else { return false }
        editingShapeID = id
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
        let list = shapeIndex.paintList(in: shapeContext), shapes = document.shapes
        return list.order.map { shapes[$0] }
    }

    /// Back to front, the shapes that may show in a world rect: those whose geometry, or box,
    /// meets it, and any with no outline to go by. What drawing goes through, and overlays should
    /// too, so that a frame costs what's in view rather than what's on the board.
    public func paintOrder(in rect: CGRect) -> [AnyShapeRecord] {
        let list = shapeIndex.paintList(in: shapeContext), shapes = document.shapes
        var shown: [AnyShapeRecord] = []
        for (position, extent) in list.extents.enumerated() where extent.touches(rect) {
            shown.append(shapes[list.order[position]])
        }
        return shown
    }

    /// The front-most shape under a world point, of those `include` accepts. Only shapes near the
    /// point are asked (see `ShapeDefinition.hitMargin`).
    public func shape(at point: CGPoint, where include: (AnyShapeRecord) -> Bool = { _ in true }) -> ShapeID? {
        let context = shapeContext
        let list = shapeIndex.paintList(in: context), shapes = document.shapes, zoom = camera.zoom
        for position in list.order.indices.reversed()
        where ShapeIndex.mayHit(point, extent: list.extents[position], margin: list.hitMargins[position], zoom: zoom) {
            let record = shapes[list.order[position]]
            if include(record), registry.definition(for: record.kind)?.erasedHitTest(point, on: record, in: context) == true {
                return record.id
            }
        }
        return nil
    }
}
