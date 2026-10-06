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
    /// `popover` changed: show it, over everything the canvas hosts, or take it down.
    func editorPopoverDidChange(_ editor: CanvasEditor)
    /// Another board is shown (`board`): swap whatever is kept of the board it left (the minimap's
    /// picture). Editing has ended by now, and the canvas is to be redrawn.
    func editorBoardDidChange(_ editor: CanvasEditor)
    /// The text selected in the editing view, if it shows text and some is selected: what
    /// `editingSelectedText` answers.
    func editorEditingSelectedText(_ editor: CanvasEditor) -> String?
}

@_spi(Host) extension CanvasEditorDelegate {
    public func editorBoardDidChange(_ editor: CanvasEditor) {}
    public func editorPopoverDidChange(_ editor: CanvasEditor) {}
    public func editorEditingSelectedText(_ editor: CanvasEditor) -> String? { nil }
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

    /// The board shown: the shapes you're looking at, which every tool, drawing, hit testing and
    /// service works on. Changes only through `transact`.
    public var document: CanvasDocument {
        if unobservedReads == 0 { access(keyPath: \.document) }
        return storedDocument
    }
    /// Observed through `document`, which a commit sets with `withMutation`: the macro's setter
    /// would first compare the old document with the new one, every shape of it, on every commit.
    @ObservationIgnored private(set) var storedDocument: CanvasDocument
    /// Which board of the file `document` is: the root, unless another is shown (`showBoard`).
    public private(set) var board: BoardID = .root
    /// The boards from the root down to the one shown: the root first, `board` last (the root alone
    /// at the root).
    public private(set) var boardPath: [BoardID] = [.root]
    /// Whether the board shown can't change: the shape that owns it can't (a plugin's rule says so of
    /// it, or of a container it's in: a locked subboard, one in a locked frame), or the board that one
    /// is on can't, and so on up to the root (`isReadOnly(board:)`), so every board under a locked
    /// subboard is read-only too, at any depth. It's shown, and its shapes are selected, copied and
    /// opened, but each is read-only (`isReadOnly(_:)`), nothing goes on it (a transaction drops an
    /// insert, and services hear the board's owner refused; `place` refuses), and no tool that places
    /// shapes is enabled there (`isToolEnabled(_:)`). Worked out again as each switch and commit
    /// leaves the file (a lock above it can come in a commit on another board, `transact(on:)`), and
    /// set only when it changes: observed apart from `document`, so a view that dims what can't be
    /// done here redraws as it changes, never on every commit.
    public private(set) var isBoardReadOnly = false
    /// Where `boardPath` turns read-only: the first board on it, root side first, that can't change
    /// (its owner can't); it, and every board after it on the path, the board shown too, is read-only.
    /// Nil while the board shown can change (`isBoardReadOnly` is whether this is one). Worked out with
    /// it, in one climb, and set only when it changes: what marks the path where the lock is, without
    /// asking each board above (`isReadOnly(board:)` of each would cost the path's depth squared).
    public private(set) var readOnlyStart: BoardID?
    /// Every board of the file: what a board file saves. `document` is its board `board`; the others
    /// change only with a commit on the shown one (a deletion taking the boards under a shape, a paste
    /// bringing some, a move taking shapes onto one), one on a board that isn't shown (`transact(on:)`)
    /// or the whole file's replacement. Read what's shown from `document`, never from here. Observed
    /// through `document`.
    public var file: CanvasFile {
        if unobservedReads == 0 { access(keyPath: \.document) }
        return storedFile
    }
    /// Kept as each commit leaves it, never copied while it changes (a transaction reads it through
    /// closures), so a commit's upkeep of it costs what the commit changed.
    @ObservationIgnored private(set) var storedFile: CanvasFile
    /// How deep `withoutObservingDocument` is.
    @ObservationIgnored private var unobservedReads = 0

    /// Runs `body` with `document` and `file`, and what reads through them (`contents(of:)`,
    /// `owner(of:)`, `shape(inFile:)`), read without observing them: for a service that reads the
    /// file for a view that observes a revision the service keeps (Mentions' backlinks), so the view
    /// redraws as that says rather than on every commit. What it reads is for the call: a copy of the
    /// file kept until the next commit would make that commit copy the file's tables, whatever it
    /// changed.
    public func withoutObservingDocument<T>(_ body: () throws -> T) rethrows -> T {
        unobservedReads += 1
        defer { unobservedReads -= 1 }
        return try body()
    }
    /// +1 per transaction that changed something.
    public private(set) var revision = 0
    /// Setting it stops the camera's slide or animation (CanvasEditor+Camera.swift), and a session
    /// that scrolls at the canvas's edges hears a drag where the pointer is (EdgeScrolling.swift). A
    /// zoom across `skeletonZoom` tells services (`drawsSkeletonsDidChange`).
    public var camera = Camera() {
        didSet {
            shapeIndex.cameraDidChange()
            stopCameraMotion()
            dismissPopover()
            setNeedsDisplay()
            tellSkeletonLevel()
            sessionFollowsCamera()
        }
    }

    /// The zoom where the camera is headed (`cameraTarget`), in whole percent: what the canvas shows
    /// above the minimap as it changes, and what the zoom commands step from. Observed apart from
    /// `camera`, and set only when it changes, so a view that shows it redraws as the zoom does,
    /// never as the camera pans.
    public internal(set) var zoomPercentage = 100

    /// The hosting view's size, in view points: the part of the world the camera shows is
    /// `camera.toWorld(CGRect(origin: .zero, size: viewportSize))`. Zero until the view has a size
    /// (and in tests that don't give one).
    @ObservationIgnored public internal(set) var viewportSize: CGSize = .zero

    /// How far down over the canvas the host's own views reach on a board, in view points, from the
    /// view's top edge (the path's pill inside a subboard): what fitting shapes into view leaves
    /// clear. None unless the host says (`unobscuredViewport`).
    @_spi(Host) @ObservationIgnored public var coveredTop: @MainActor (BoardID) -> CGFloat = { _ in 0 }

    /// The part of the view nothing the host puts over the canvas covers, on the board shown, in view
    /// points: the view, less the top the host covers there (`coveredTop`). What a fit fits shapes
    /// into: a board's first visit, Zoom to Fit, Selection's `reveal`. Empty before the view has a
    /// size.
    public var unobscuredViewport: CGRect { unobscuredViewport(on: board) }

    func unobscuredViewport(on target: BoardID) -> CGRect {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return .zero }
        let top = min(max(coveredTop(target), 0), viewportSize.height - 1)
        return CGRect(x: 0, y: top, width: viewportSize.width, height: viewportSize.height - top)
    }

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
    /// While true (Keyboard's Space, held), a press pans as the Hand does, whatever the tool, which
    /// stays the tool (nothing `setTool` resets, an arrow's targeting included): the cursor is the open
    /// hand, and the closed hand while it pans; the tool hears no hover meanwhile. A pan under way when
    /// it's let go goes on to its release. Held during another press (a drag), it waits for that
    /// press: the drag keeps its cursor, and at its release the tool hears the pointer leave and the
    /// open hand shows.
    public var isHandHeld = false {
        didSet {
            guard isHandHeld != oldValue else { return }
            if isHandHeld, session == nil { currentTool.pointerExited(in: self) }
            refreshCursor()
        }
    }
    public private(set) var editingShapeID: ShapeID?
    /// While a shape is edited, where the press that began it was, in world units
    /// (`beginEditing(_:at:)`); nil if none said, and once editing ends.
    public private(set) var editingStartPoint: CGPoint?
    /// While a shape is edited, how many clicks the press that began it was: 2 for a double-click
    /// (`beginEditing(_:at:clickCount:)`), else 1.
    public private(set) var editingStartClickCount = 1
    /// The press-drag-release in progress, if any. Tools start sessions; a session may hand over
    /// to another by setting this. Observed only as one starts and as the last ends, not as one
    /// hands over: a view that reads it (a control enabled only between presses, through
    /// `canPerform`) redraws once the press is let go.
    public var session: (any Session)? {
        get { isPressing ? runningSession : nil }
        set {
            runningSession = newValue
            // A press's drag goes by where shapes are: a glide under way ends there.
            if newValue != nil { endGlides() }
            if (newValue != nil) != isPressing { isPressing = newValue != nil }
            if newValue?.scrollsAtEdges != true { stopEdgeScrolling() }
            setNeedsDisplay()
        }
    }
    @ObservationIgnored private var runningSession: (any Session)?
    private var isPressing = false

    /// The keyboard's modifiers right now. Set by the hosting view (`NSEvent.modifierFlags`) and
    /// by test harnesses; plugins read `effectiveModifiers`.
    @_spi(Host) @ObservationIgnored public var liveModifiers: @MainActor () -> Modifiers = { [] }
    /// The board's undo and redo: every commit goes into a step (CanvasEditor+Undo.swift).
    @ObservationIgnored public let undoHistory = UndoHistory()

    @ObservationIgnored private var tools: [ToolID: any Tool] = [:]
    @ObservationIgnored private let serviceRegistrations: [ObjectIdentifier: ServiceRegistration]
    @ObservationIgnored private var services: [ObjectIdentifier: any EditorService] = [:]
    @ObservationIgnored private var serviceOrder: [any EditorService] = []
    @ObservationIgnored private var resolvingServices: Set<ObjectIdentifier> = []
    @ObservationIgnored private(set) var isTransacting = false
    /// Undo or redo is putting a step's records back: nothing may transact.
    @ObservationIgnored var isApplying = false
    /// A file is being put in place (`replaceFile`): what commits meanwhile, on the file it replaces,
    /// isn't an undo step, so it doesn't edit the file.
    @ObservationIgnored private var isReplacingFile = false
    /// Each shape's geometry and extent, and the paint order, kept from frame to frame: the shown
    /// board's.
    @ObservationIgnored var shapeIndex = ShapeIndex()
    /// The indexes of the boards shown lately, for when they're shown again (while they haven't
    /// changed).
    @ObservationIgnored private var warmIndexes = BoardStash<ShapeIndex>()
    /// Where the camera was on each board shown this session, as it was left.
    @ObservationIgnored private var leftCameras: [BoardID: Camera] = [:]
    /// The boards left this session, in the order they were last left (`boardsLeft`).
    @ObservationIgnored private var leftOrder: [BoardID] = []
    /// Where the camera was on boards of this file in an earlier session (the host remembers them):
    /// where a board shown for the first time this session starts.
    @_spi(Host) @ObservationIgnored public var rememberedCameras: [BoardID: Camera] = [:]
    /// Pictures of the boards the shapes drawn own (`RenderContext.drawBoardPreview`), built a
    /// frame's worth at a time while `draw(in:)` asks for the next frame (`nextPreviewFrame`).
    @_spi(Host) @ObservationIgnored public let boardPreviews: BoardPreviews
    @ObservationIgnored var nextPreviewFrame: ScheduledTask?
    /// Shapes drawn away from where they are, in view points (`setDrawingOffset`).
    @ObservationIgnored var drawingOffsets: [ShapeID: CGPoint] = [:]
    /// The shapes gliding to where they are (Glide.swift), and the glides' next frame.
    @ObservationIgnored var glides: [ShapeID: Glide] = [:]
    @ObservationIgnored var glideFrame: ScheduledTask?
    /// The dot grid under the shapes, and the tiles it keeps from frame to frame.
    @ObservationIgnored let dotGrid = DotGrid()
    /// Below this zoom the canvas draws shapes as skeletons (`drawsSkeletons`, `CustomSkeleton`):
    /// 35% (`Style.skeletonZoom`) unless the host says otherwise. 0 draws every shape in full at
    /// every zoom (a test held to pictures drawn before skeletons were). Setting it redraws, and
    /// tells services if it moves past the camera's zoom (`drawsSkeletonsDidChange`).
    @_spi(Host) @ObservationIgnored public var skeletonZoom: CGFloat = Style.skeletonZoom {
        didSet {
            guard skeletonZoom != oldValue else { return }
            setNeedsDisplay()
            tellSkeletonLevel()
        }
    }
    /// How far, in view points, the outline of a closed shape (the selection's, a hover's, the hint)
    /// stands off its edge: `Style.outlineStandoff`, 4, unless the host says otherwise. 0 outlines
    /// every shape right on its own path, as the proof of concept drew (a test held to pictures
    /// drawn before outlines stood off). Setting it redraws. Plugins that draw along an outline go
    /// by `outlineGap` and `outlinePath(of:)`, never the number.
    @_spi(Host) @ObservationIgnored public var outlineStandoff: CGFloat = Style.outlineStandoff {
        didSet {
            guard outlineStandoff != oldValue else { return }
            setNeedsDisplay()
        }
    }
    #if DEBUG
    /// How many closed outlines have been stood off by path arithmetic (debug builds), which costs
    /// far more than adding a rounded rect, as a rect or a rounded rect (every shipped box kind) is
    /// grown directly: a test holds the shipped kinds to none.
    @_spi(Host) @ObservationIgnored public internal(set) var outlinesGrownByArithmetic = 0
    #endif
    /// What services last heard of `drawsSkeletons` (`drawsSkeletonsDidChange`), which the camera
    /// and `skeletonZoom` are held to as they change.
    @ObservationIgnored private var toldDrawsSkeletons = false
    /// A board is being put in place (`show`): its camera's level is told once services have heard
    /// the switch.
    @ObservationIgnored private var isShowingBoard = false
    // Input state, used by CanvasEditor+Host.swift.
    @ObservationIgnored var tracker = PointerTracker()
    @ObservationIgnored var heldModifiers: Modifiers = []
    @ObservationIgnored var recentlyReleased: Modifiers = []
    @ObservationIgnored var releaseTimer: ScheduledTask?
    // The camera motion's next frame (a slide or an animation), and an animation's target, used by
    // CanvasEditor+Camera.swift.
    @ObservationIgnored var cameraMotion: ScheduledTask?
    @ObservationIgnored var cameraAnimationTarget: Camera?
    // The popover (Popovers.swift): the one showing, the one waiting its delay and its timer, and
    // while one has just gone, the end of that moment.
    @ObservationIgnored var shownPopover: CanvasPopover?
    @ObservationIgnored var waitingPopover: CanvasPopover?
    @ObservationIgnored var popoverTimer: ScheduledTask?
    @ObservationIgnored var popoverWarmth: ScheduledTask?
    /// An animation's frame is moving the camera: `zoomPercentage` stays its target's.
    @ObservationIgnored var isAnimationFrame = false
    // The press under way, for scrolling at the canvas's edges (EdgeScrolling.swift): where it was, in
    // view points; whether the pointer has gone past the drag threshold from it; the last pointer, for
    // a drag where it is when the camera moves; the edge's next tick; how long the pointer has been at
    // an edge, in milliseconds; and a drag of the camera's under way.
    @ObservationIgnored var pressLocation: CGPoint?
    @ObservationIgnored var pressDragged = false
    @ObservationIgnored var lastPointer: Pointer?
    @ObservationIgnored var edgeScrollTick: ScheduledTask?
    @ObservationIgnored var edgeScrollTime: CGFloat = 0
    @ObservationIgnored var isFollowingCamera = false

    /// An editor of the file, showing `showing` (the root, if it can't be shown: `canShow`). Every
    /// shape on every board must be of a kind the registry accepts, or kept aside (`isOpaque`);
    /// defaults are filled in on every board.
    public init(registry: Registry, file: CanvasFile, showing: BoardID = .root, scheduler: any Scheduler = TaskScheduler(),
                stackingKeys: StackingKeyGenerator = .jittered) {
        Self.expectAccepted(file, by: registry)
        self.registry = registry
        boardPreviews = BoardPreviews(registry: registry)
        storedFile = registry.fillingDefaults(file)
        let shown = Self.canShow(showing, in: storedFile, registry: registry) ? showing : .root
        storedDocument = storedFile[shown]
        self.scheduler = scheduler
        self.stackingKeys = stackingKeys
        currentToolID = registry.defaultTool
        serviceRegistrations = Dictionary(registry.services.map { ($0.type, $0) }, uniquingKeysWith: { first, _ in first })
        board = shown
        boardPath = storedFile.path(to: shown) ?? [.root]
        // Opened on a read-only board, it's read-only from the start, before services are made; a
        // default tool that places shapes gives way to the Hand there.
        readOnlyStart = registry.readOnlyStart(ofPathTo: shown, in: storedFile)
        isBoardReadOnly = readOnlyStart != nil
        if !isToolEnabled(currentToolID) { currentToolID = .hand }
        // Services first, so tools can look them up; each resolves the services it asks for.
        for registration in registry.services { _ = resolveService(registration.type) }
        for (id, make) in registry.toolFactories { tools[id] = make(self) }
        undoHistory.editor = self
        undoHistory.participants = serviceOrder.compactMap { $0 as? any UndoParticipant }
        toldDrawsSkeletons = drawsSkeletons
    }

    /// An editor of a file of this one board.
    public convenience init(registry: Registry, document: CanvasDocument = CanvasDocument(), scheduler: any Scheduler = TaskScheduler(),
                            stackingKeys: StackingKeyGenerator = .jittered) {
        self.init(registry: registry, file: CanvasFile(root: document), scheduler: scheduler, stackingKeys: stackingKeys)
    }

    private static func expectAccepted(_ file: CanvasFile, by registry: Registry) {
        for document in [file.root] + file.children.values {
            for record in document.shapes {
                precondition(record.isOpaque || registry.definition(for: record.kind)?.erasedAccepts(record) == true,
                             "no installed plugin defines \(record.kind) shapes with these props")
            }
        }
    }

    public func service<S: EditorService>(_ type: S.Type) -> S? { resolveService(ObjectIdentifier(S.self)) as? S }

    func resolveService(_ id: ObjectIdentifier) -> (any EditorService)? {
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
    ///
    /// What it commits goes into the undo step it's part of (`UndoHistory`): the action it's in (a
    /// press, a key, a command, a group), or an editing session's; outside those, a step of its own,
    /// or, with a `coalescing` key, part of a run of commits under that key (a panel field typed
    /// into) until something else happens. `name` names the step, if nothing it's in has named it:
    /// "Move", "Delete", as a menu says Undo Move.
    ///
    /// A body that throws commits nothing, whatever it changed first: services hear of no change
    /// and no refusal, the board isn't edited, no undo step opens (what there was to redo stays),
    /// and the error comes out of `transact` (untyped: catch it and cast). So work that must happen
    /// whole, or not at all, throws to leave.
    @discardableResult
    public func transact<T>(_ name: String? = nil, coalescing key: AnyHashable? = nil, _ body: (inout Transaction) throws -> T) rethrows -> T {
        try transact(name, coalescing: key, origin: .ordinary, body)
    }

    /// `origin` says whether an editing view commits (`EditContext`), whose commits are its session's step.
    func transact<T>(_ name: String?, coalescing key: AnyHashable?, origin: UndoHistory.Origin,
                     _ body: (inout Transaction) throws -> T) rethrows -> T {
        precondition(!isApplying, "nothing may transact while undo or redo puts a step back (a service's documentDidChange, say)")
        precondition(!isTransacting, "transactions don't nest; use the one you were given")
        isTransacting = true
        var transaction = Transaction(document: document, board: board, isBoardReadOnly: isBoardReadOnly, registry: registry, camera: camera,
                                      keys: stackingKeys, file: fileAccess)
        let result: T
        do {
            defer { isTransacting = false }
            result = try body(&transaction)
        }
        // Committing can end editing, and an editing view may save as it closes: outside the
        // transaction, so it can.
        if transaction.didChange, isReplacingFile {
            commit(transaction)
        } else if transaction.didChange {
            undoHistory.willCommit(transaction.changes, from: storedFile, name: name, coalescing: key, origin: origin)
            commit(transaction)
            undoHistory.didCommit()
        }
        if !transaction.refused.isEmpty { refuseChanges(to: transaction.refused) }
        return result
    }

    /// A transaction on a board of the file, shown or not: on the board shown it's `transact`; on
    /// another, the transaction's `document` is that board's shapes as the file has them, and its
    /// commit changes that board in the file without showing it (what lands there late: a language
    /// model's answer for a card on a board left since). That commit is an undo step of its own,
    /// named `name`, made on its board, so undoing it shows that board first (`undo()`); a step
    /// open on the board shown stays open, and comes after it. Services hear it as a commit that
    /// changed that board (`ChangeSet.boardsChanged`, the shapes it touched in `elsewhere`) and those
    /// it took or brought, the board shown as it was. Read-only shapes stay as they are, as in any
    /// transaction, and so does a read-only board (`isReadOnly(board:)`: nothing on it changes, and
    /// nothing goes on it), but nothing shows the refusal, since they aren't shown. A transaction that would
    /// take the board shown, or a board above it, with a shape it deletes, or that reaches the board
    /// shown (moving shapes onto it, or settling there), commits nothing: `document` would go stale.
    /// Returns nil, doing nothing, for a board the editor can't show (`canShow`).
    @discardableResult
    public func transact<T>(on target: BoardID, _ name: String? = nil, _ body: (inout Transaction) throws -> T) rethrows -> T? {
        guard target != board else { return try transact(name, coalescing: nil, origin: .ordinary, body) }
        guard canShow(target) else { return nil }
        precondition(!isApplying, "nothing may transact while undo or redo puts a step back (a service's documentDidChange, say)")
        precondition(!isTransacting, "transactions don't nest; use the one you were given")
        isTransacting = true
        var transaction = Transaction(document: storedFile[target], board: target, isBoardReadOnly: registry.isReadOnly(board: target, in: storedFile),
                                      registry: registry, camera: leftCameras[target] ?? camera, keys: stackingKeys, file: fileAccess)
        let result: T
        do {
            defer { isTransacting = false }
            result = try body(&transaction)
        }
        // The owners too: an empty board isn't among the boards a deletion takes.
        guard transaction.didChange, transaction.changes.boardsRemoved.isDisjoint(with: boardPath),
              transaction.changes.removed.isDisjoint(with: boardPath.lazy.compactMap(\.owner)),
              !transaction.changes.boardsReached.contains(board) else { return result }
        if isReplacingFile {
            commit(transaction, onHidden: target)
        } else {
            undoHistory.recordStep(on: target, name: name, changes: transaction.changes, from: storedFile) {
                commit(transaction, onHidden: target)
            }
        }
        return result
    }

    /// Whether the shape, on the board shown, can't change: a plugin's rule says so of it
    /// (`registrar.readOnlyShapes`), or of a container it's in, at any depth, or the board can't
    /// (`isBoardReadOnly`: a locked subboard's). No transaction changes, restacks or deletes it, a
    /// drag leaves it where it is, and it isn't edited. False for a shape that isn't there. O(its
    /// depth).
    public func isReadOnly(_ id: ShapeID) -> Bool {
        guard let record = document[id] else { return false }
        return isBoardReadOnly || registry.isReadOnly(record, in: document)
    }

    /// Whether a shape on any board of the file can't change, as `isReadOnly(_:)` says of one on the
    /// board shown: a rule says so of it, or of a container it's in, or its board can't
    /// (`isReadOnly(board:)`). False for a shape that isn't in the file. The board shown's in O(its
    /// depth), another's in O(its depth and its board's). Observed through `document`.
    public func isReadOnly(inFile id: ShapeID) -> Bool {
        if document[id] != nil { return isReadOnly(id) }
        let file = file
        guard let board = file.board(containing: id) else { return false }
        let holding = file[board]
        guard let record = holding[id] else { return false }
        return registry.isReadOnly(record, in: holding) || registry.isReadOnly(board: board, in: file)
    }

    /// Whether a board of the file can't change: the shape that owns it can't (a rule says so of it,
    /// or of a container it's in), or the board that one is on can't, and so on up to the root, which
    /// always can (`isBoardReadOnly`, for the board shown, which this answers with). Nothing on it
    /// changes, and nothing goes on it. O(the board's depth). Observed through `document`, or, for the
    /// board shown, through `isBoardReadOnly`.
    public func isReadOnly(board target: BoardID) -> Bool {
        target == board ? isBoardReadOnly : registry.isReadOnly(board: target, in: file)
    }

    /// Whether `setTool` takes a tool: any, but one that places shapes (a kind's tool,
    /// `ShapeRegistrar.tool`) on a board that can't change (`isBoardReadOnly`), so the toolbar dims
    /// those there, and their keys do nothing. Observed through `isBoardReadOnly`.
    public func isToolEnabled(_ id: ToolID) -> Bool { !isBoardReadOnly || !registry.placingTools.contains(id) }

    /// Works out again whether the board shown can't change, and where its path turns read-only, as a
    /// switch or a commit leaves the file (`isBoardReadOnly`, `readOnlyStart`), setting each only if it
    /// changed; returns whether the board changed to read-only, for what then leaves a tool that
    /// places shapes (`leaveDisabledTool`). One climb, O(the board's depth).
    private func noteBoardReadOnly() -> Bool {
        let start = registry.readOnlyStart(ofPathTo: board, in: storedFile)
        if start != readOnlyStart { readOnlyStart = start }
        let now = start != nil
        guard now != isBoardReadOnly else { return false }
        isBoardReadOnly = now
        return now
    }

    /// Leaves a tool that isn't enabled on the board shown (one that places shapes, on a board that
    /// has just become read-only) for the default tool, or for the Hand if that one isn't enabled
    /// either.
    private func leaveDisabledTool() {
        guard !isToolEnabled(currentToolID) else { return }
        setTool(isToolEnabled(registry.defaultTool) ? registry.defaultTool : .hand)
    }

    /// Something tried to change these read-only shapes, and didn't: services hear which
    /// (`EditorService.didRefuseChanges`: Selection shakes them), as they hear a transaction's
    /// refusals. A plugin calls it for a change it gave up whole, which no transaction committed to
    /// refuse (a paste a locked frame would take, thrown out of its transaction so no step is left).
    public func refuseChanges(to ids: Set<ShapeID>) {
        for service in serviceOrder { service.didRefuseChanges(to: ids, in: self) }
    }

    /// Services hear that the canvas started or stopped drawing skeletons, if it did since they last
    /// heard: a comparison, as the camera changes on every event of a pinch.
    private func tellSkeletonLevel() {
        guard !isShowingBoard, drawsSkeletons != toldDrawsSkeletons else { return }
        toldDrawsSkeletons = drawsSkeletons
        for service in serviceOrder { service.drawsSkeletonsDidChange(in: self) }
    }

    /// What a transaction reads of the rest of the file: the editor's file as it is.
    private var fileAccess: FileAccess {
        FileAccess(locate: { [unowned self] in storedFile.board(containing: $0) },
                   subtree: { [unowned self] in storedFile.subtree(ownedBy: $0) },
                   contents: { [unowned self] in storedFile[$0] },
                   canShow: { [unowned self] in Self.canShow($0, in: storedFile, registry: registry) })
    }

    /// A board of the file: `document` for the one shown, else its shapes as the file has them
    /// (empty for a board with none). Observed through `document`.
    public func contents(of board: BoardID) -> CanvasDocument {
        board == self.board ? document : file[board]
    }

    /// The shape that owns the board, wherever it is in the file; nil for the root, and for a board
    /// whose owner isn't in the file. Observed through `document`.
    public func owner(of board: BoardID) -> AnyShapeRecord? {
        board.owner.flatMap { file.record($0) }
    }

    /// Puts a whole other file in place: opening a board file, reverting it, reloading it after it
    /// changed on disk. It shows `showing`, if the new file can show it (`canShow`); else the board
    /// shown now, if it can; else the nearest board above it that it can; else the root. Cancels any
    /// press (`Session.cancel`, whatever it answers); services hear `boardWillChange` (to the board
    /// it'll show, maybe the same); editing and camera motion end, the board left keeping where its
    /// camera was headed; defaults are filled in on every board. Staying on the board shown, it
    /// commits that board as a transaction does; showing another, it goes there as `showBoard` does.
    /// Either way it isn't an undo step: it clears the history, so the file isn't edited by it, nor
    /// by what the press, services or an editing view commit as they end, which goes to the file it
    /// replaces and is no step. Every board's revision changes but those whose shapes are as they
    /// were (`CanvasFile.restamp(after:)`), so nothing kept about a board of the old file is taken for
    /// the new one's; the cameras boards were left with are kept.
    @_spi(Host) public func replaceFile(with newFile: CanvasFile, showing requested: BoardID? = nil) {
        precondition(!isTransacting, "a file can't be replaced inside a transaction")
        Self.expectAccepted(newFile, by: registry)
        isReplacingFile = true
        defer { isReplacingFile = false }
        dismissPopover()
        if let running = session {
            _ = running.cancel(in: self)
            session = nil
        }
        var newFile = registry.fillingDefaults(newFile)
        let showable = { [registry] (board: BoardID) in Self.canShow(board, in: newFile, registry: registry) }
        let target = requested.flatMap { showable($0) ? $0 : nil } ?? boardPath.reversed().first(where: showable) ?? .root
        for service in serviceOrder { service.boardWillChange(from: board, to: target, in: self) }
        endEditing(discarding: false)
        let left = cameraTarget
        stopCameraMotion()
        // After what services saved as they heard it: a board the file had then has a revision past it.
        newFile.restamp(after: storedFile)
        warmIndexes.removeAll()
        if target == board {
            var changes = ChangeSet(from: storedDocument, to: newFile[board])
            changes.elsewhere = newFile.shapesChanged(from: storedFile, except: board)
            storedFile = newFile
            boardPath = newFile.path(to: board) ?? [.root]
            documentDidChange(to: newFile[board], changes: changes)
        } else {
            switchTool(to: registry.defaultTool)
            storedFile = newFile
            show(target, leaving: left, replacingFile: true)
        }
        undoHistory.clear()
    }

    /// Puts a file of this one board in place (`replaceFile`).
    @_spi(Host) public func replaceDocument(with newDocument: CanvasDocument) {
        replaceFile(with: CanvasFile(root: newDocument))
    }

    /// Deletes what the file keeps without showing (Delete Hidden Shapes): these shapes, kept aside
    /// (`LoadReport.keptAside`), wherever they are, with the boards they own and every board under
    /// those; and these boards (`LoadReport.KeptBoard.key`), with every board under them, or the
    /// entries under these keys that didn't read as boards (a board that can be shown by now, whose
    /// shapes took such an entry's key, stays). Each shape goes as a transaction's
    /// `delete` would take it, on its own board (its `willDelete` handlers run, and what names it lets
    /// go), refused by nothing. It's one undo step, "Delete Hidden Shapes", committed as a
    /// transaction's: what it did to the board shown shape by shape, and every other board it
    /// changed or took whole (`boardsChanged`, `boardsRemoved`), with the entries it took, so
    /// undoing it puts back the file as it was. If nothing changed, nothing happens. Returns
    /// whether anything changed.
    @discardableResult
    @_spi(Host) public func discardKeptAside(shapes ids: Set<ShapeID>, boards keys: Set<String>) -> Bool {
        precondition(!isTransacting, "a file can't be replaced inside a transaction")
        let old = storedFile, access = FileAccess(old, boardOwningKinds: registry.boardOwningKinds)
        var newFile = old, removed: Set<BoardID> = []
        let byBoard = Dictionary(grouping: ids.filter { old.record($0)?.isOpaque == true }) { old.board(containing: $0)! }
        for (board, ids) in byBoard {
            // Refused by nothing: a read-only board's hidden shapes go too.
            var transaction = Transaction(document: old[board], board: board, isBoardReadOnly: false, registry: registry, camera: camera,
                                          keys: stackingKeys, file: access)
            transaction.discard(Set(ids))
            newFile.set(transaction.document, for: board, changes: transaction.changes)
            removed.formUnion(transaction.changes.boardsRemoved)
        }
        for key in keys {
            // A key the report kept may name a board that can be shown by now (an entry that didn't
            // read, taken since by a board that has shapes): that one isn't hidden, so it stays.
            if let owner = BoardID(key)?.owner, owner.description == key, old.children[owner] != nil,
               !Self.canShow(BoardID(owner: owner), in: old, registry: registry) {
                removed.insert(BoardID(owner: owner))
                removed.formUnion(old.subtree(ownedBy: old[BoardID(owner: owner)].shapes.map(\.id)))
            }
            newFile.unreadableBoards[key] = nil
        }
        newFile.removeBoards(removed)
        guard newFile != old else { return false }
        // An edit, not a board read again: what it deleted is gone as any deletion's is.
        var changes = ChangeSet(from: storedDocument, to: newFile[board])
        changes.replacedDocument = false
        changes.boardsRemoved = removed
        changes.boardsChanged = Set(byBoard.keys).subtracting(removed).subtracting([board])
        changes.elsewhere = newFile.shapesChanged(from: old, except: board)
        undoHistory.group("Delete Hidden Shapes") {
            undoHistory.willCommit(changes, from: storedFile, name: nil, coalescing: nil, origin: .ordinary)
            storedFile = newFile
            for board in removed { leftCameras[board] = nil }
            warmIndexes.forget(removed)
            documentDidChange(to: newFile[board], changes: changes)
            undoHistory.didCommit()
        }
        return true
    }

    /// Writes the transaction through to the file (the boards it took and brought too), then shows
    /// what it did. The undo step it's part of has noted, from the file as it was, what it's about to
    /// change, the boards it takes included, so undoing it puts them back with every id.
    private func commit(_ transaction: Transaction) {
        var changes = transaction.changes
        changes.elsewhere = writeBoards(of: transaction, own: (board, transaction.document, changes))
        documentDidChange(to: transaction.document, changes: changes)
    }

    /// Writes a transaction on a board that isn't shown (`transact(on:)`) through to the file, and
    /// tells services as a commit that changed that board and those it took, brought or changed (shapes
    /// moved onto them, or settled there): the board shown is as it was.
    private func commit(_ transaction: Transaction, onHidden target: BoardID) {
        let local = transaction.changes
        var changes = ChangeSet()
        changes.boardsChanged = local.boardsChanged.union([target])
        changes.boardsAdded = local.boardsAdded
        changes.boardsRemoved = local.boardsRemoved
        changes.byAgent = local.byAgent
        changes.elsewhere = writeBoards(of: transaction, own: (target, transaction.document, local)).union(local.shapeIDs)
        documentDidChange(to: storedDocument, changes: changes)
    }

    /// Writes the board a transaction was on (`own`, with what it changed there), takes out of the file
    /// the boards it took, writes over those it changed (shapes moved onto a board that held some, the
    /// root included, moved off one, or settled there), and puts in those it brought; returns the
    /// shapes it touched on the others: every shape of a board it took or brought, and each that
    /// differs on a board it changed (what came or went, and what settling there nudged or took in).
    private func writeBoards(of transaction: Transaction, own: (board: BoardID, document: CanvasDocument, changes: ChangeSet)) -> Set<ShapeID> {
        let changes = transaction.changes
        var touched = storedFile.shapeIDs(on: changes.boardsRemoved)
        for board in changes.boardsRemoved { leftCameras[board] = nil }
        storedFile.removeBoards(changes.boardsRemoved)
        warmIndexes.forget(changes.boardsRemoved)
        // The boards the file has are set together, the transaction's own among them, so a shape moved
        // from one onto another, either way, is on one at a time; a board it brought is inserted, which
        // wants a new one, after them all.
        var written = [own], brought: [ShapeID: CanvasDocument] = [:]
        for (board, document) in transaction.stagedBoards {
            if changes.boardsChanged.contains(board) {
                let change = ChangeSet(from: storedFile[board], to: document)
                touched.formUnion(change.shapeIDs)
                written.append((board, document, change))
            } else if let owner = board.owner {
                touched.formUnion(document.shapes.lazy.map(\.id))
                brought[owner] = document
            }
        }
        storedFile.set(written)
        warmIndexes.forget(changes.boardsChanged)
        storedFile.insertBoards(brought)
        return touched
    }

    /// Undo's and redo's commit, on the board shown, the delta's: `newDocument` is the board with it
    /// applied, `changes` what it did (`ChangeSet(delta)`); the boards it names whole go in or out
    /// of the file (each with a new revision, so nothing kept about one is taken for it), and
    /// services hear it as a transaction's.
    func commit(_ newDocument: CanvasDocument, changes: ChangeSet, applying delta: DocumentDelta) {
        storedFile.apply(delta, document: newDocument, changes: changes)
        for board in changes.boardsRemoved { leftCameras[board] = nil }
        warmIndexes.forget(changes.boardsReached)
        documentDidChange(to: newDocument, changes: changes)
    }

    /// The shown board is now `newDocument`, `changes` from what it was: everything that follows it.
    private func documentDidChange(to newDocument: CanvasDocument, changes: ChangeSet) {
        // What the shape being edited was, for its editing view is that kind's.
        let editedKind = editingShapeID.flatMap { storedDocument[$0]?.kind }
        withMutation(keyPath: \.document) { storedDocument = newDocument }
        revision += 1
        // Before services hear the commit, which may have locked the board's owner (a commit on the
        // board above, `transact(on:)`) or put another file in place.
        let becameReadOnly = noteBoardReadOnly()
        shapeIndex.documentDidChange(changes, in: newDocument, registry: registry)
        for id in changes.removed where drawingOffsets[id] != nil { drawingOffsets[id] = nil }
        // A shape gliding that something changes is where it is now.
        if !glides.isEmpty { endGlides(changes.shapeIDs.filter { glides[$0] != nil }) }
        // Services drop what no longer names a shape, as the hint's setter does.
        for service in serviceOrder { service.documentDidChange(changes, in: self) }
        hintedShapeID = hintedID
        // A shape that's gone, can no longer change (it, a container it's in, or its board), or is of
        // another kind now (turned, `Transaction.turn`), isn't edited.
        if let editing = editingShapeID,
           document[editing].map({ isBoardReadOnly || registry.isReadOnly($0, in: newDocument) || $0.kind != editedKind }) ?? true {
            endEditing(discarding: false)
        }
        if becameReadOnly { leaveDisabledTool() }
        setNeedsDisplay()
    }

    // MARK: Boards

    /// Whether `showBoard` can show a board: the root, or a board whose owners, from the root down,
    /// are all in the file, none kept aside, each of a kind that owns boards (`BoardOwning`). The
    /// board itself may have no shapes (yet). O(the board's depth). Observed through `document`.
    public func canShow(_ target: BoardID) -> Bool { Self.canShow(target, in: file, registry: registry) }

    static func canShow(_ target: BoardID, in file: CanvasFile, registry: Registry) -> Bool {
        file.canShow(target, boardOwningKinds: registry.boardOwningKinds)
    }

    /// A shape on the board shown, or on another board of the file it can show (`canShow`); nil for
    /// one in no board of the file, and for one on a board it can't show (under an owner kept aside,
    /// of a kind that owns none, or not in the file), which the app keeps without using: what names
    /// shapes anywhere in the file (a mention) shows such a one as it shows one it can't use. The
    /// board shown's in O(1), another's in O(its depth). Observed through `document`.
    public func shape(inFile id: ShapeID) -> AnyShapeRecord? {
        document[id] ?? Self.shape(id, inFile: file, registry: registry)
    }

    /// `shape(inFile:)`, in a file as it is (what a frame draws from).
    static func shape(_ id: ShapeID, inFile file: CanvasFile, registry: Registry) -> AnyShapeRecord? {
        guard let board = file.board(containing: id), canShow(board, in: file, registry: registry) else { return nil }
        return file[board][id]
    }

    /// Shows another board of the file, which `document` becomes, and every tool, drawing, hit test
    /// and service goes by from then on. Not an edit, nor an undo step: the file isn't changed by
    /// it, and the step under way closes, since a step is made on one board (undoing it from another
    /// shows its board first, with this). In order: services hear
    /// `boardWillChange` while the board left is still shown; editing ends (a view that saves as it
    /// closes saves on its own board); the default tool comes back; camera motion stops, and the
    /// camera the board is left with is kept for it; the step under way closes; the board shown gets
    /// what the editor kept of it, if it hasn't changed since (its geometry, paint order and bounds;
    /// for the 8 boards shown last, those above the one shown kept longest), else works it out
    /// afresh; `revision` changes; the camera is the one the board was left with this session, else the one
    /// the host remembers (`rememberedCameras`), else, on a first visit, its shapes fitted into view
    /// (no closer than 100%), or where it starts (`Camera()`) with none; then services hear
    /// `boardDidChange`, and the host redraws.
    ///
    /// Returns true if the board is shown (now, or already); false, doing nothing, while a press is
    /// under way (a session), or for a board it can't show (`canShow`).
    @discardableResult
    public func showBoard(_ target: BoardID) -> Bool {
        precondition(!isTransacting, "a board can't be shown inside a transaction")
        guard session == nil else { return false }
        guard target != board else { return true }
        guard canShow(target) else { return false }
        for service in serviceOrder { service.boardWillChange(from: board, to: target, in: self) }
        endEditing(discarding: false)
        switchTool(to: registry.defaultTool)
        let left = cameraTarget
        stopCameraMotion()
        warmIndexes.keep(shapeIndex, for: board, in: self)
        show(target, leaving: left)
        return true
    }

    /// Where the camera was left on each board (this session, or remembered from an earlier one):
    /// what the host remembers of the file's view. The shown board's is where its camera is headed.
    @_spi(Host) public var boardCameras: [BoardID: Camera] {
        var cameras = rememberedCameras.merging(leftCameras) { _, left in left }
        cameras[board] = cameraTarget
        return cameras
    }

    /// The boards left this session that are still in the file, the one left last first: which of
    /// `boardCameras` were shown most lately, for a host that remembers only so many.
    @_spi(Host) public var boardsLeft: [BoardID] { leftOrder.reversed().filter { leftCameras[$0] != nil } }

    /// Goes to `target` once services have heard of it, editing has ended, the default tool is back
    /// and camera motion has stopped: `left` is the camera the board shown now is left with.
    private func show(_ target: BoardID, leaving left: Camera, replacingFile: Bool = false) {
        // A step is the board's it was made on: the one under way closes here.
        undoHistory.close()
        dismissPopover()
        leftCameras[board] = left
        leftOrder.removeAll { $0 == board }
        leftOrder.append(board)
        let change = BoardChange(from: board, to: target, leftCamera: left, left: storedDocument, shown: storedFile[target],
                                 isFileReplaced: replacingFile)
        withMutation(keyPath: \.document) { storedDocument = storedFile[target] }
        board = target
        boardPath = storedFile.path(to: target) ?? [.root]
        // Whether this board takes shapes, before services hear of it.
        _ = noteBoardReadOnly()
        shapeIndex = warmIndexes.take(for: target, in: self) ?? ShapeIndex()
        hintedID = nil
        drawingOffsets = [:]
        glides = [:]
        glideFrame?.cancel()
        glideFrame = nil
        // What the board left asked for isn't drawn now; what this one draws asks for its own.
        boardPreviews.stopWaiting()
        revision += 1
        isShowingBoard = true
        camera = arrivalCamera(for: target)
        isShowingBoard = false
        for service in serviceOrder { service.boardDidChange(change, in: self) }
        tellSkeletonLevel()
        delegate?.editorBoardDidChange(self)
        setNeedsDisplay()
        refreshCursor()
        // Once the board is in place and heard: a default tool that places shapes doesn't stay on one
        // that takes none.
        leaveDisabledTool()
    }

    /// The camera a board is shown with: as it was left, else as the host remembers it, else its
    /// shapes fitted into the part of the view the host leaves clear there (`unobscuredViewport`), no
    /// closer than 100%, else where a board starts.
    private func arrivalCamera(for target: BoardID) -> Camera {
        arrivalCamera(for: target) { shapeBounds }
    }

    /// The same, for a board as its shapes' bounds say (read only for a first visit's fit).
    private func arrivalCamera(for target: BoardID, bounds: () -> CGRect) -> Camera {
        if let kept = leftCameras[target] ?? rememberedCameras[target] { return kept }
        let view = unobscuredViewport(on: target)
        guard !view.isEmpty else { return Camera() }
        let bounds = bounds()
        guard !bounds.isNull else { return Camera() }
        return Camera(fitting: bounds, in: view, inset: Style.firstVisitInset, maxZoom: 1)
    }

    /// A board of the file read as it is now, shown or not (`BoardReading`): for what works on a
    /// board without showing it (`canvas draw --on`). The board shown's is the editor's own (its
    /// index, its camera where it's headed); another's is worked out afresh from the file, O(its
    /// shapes), with the camera it would be shown with (`showBoard`'s, a first visit's fit
    /// included). Nil for a board it can't show (`canShow`). Observed through `document`.
    public func reading(of target: BoardID) -> BoardReading? {
        if target == board {
            let clear = unobscuredViewport
            return BoardReading(board: board, document: document, shapes: shapeContext, index: shapeIndex,
                                view: clear.isEmpty ? nil : cameraTarget.toWorld(clear), isBoardReadOnly: isBoardReadOnly)
        }
        guard canShow(target) else { return nil }
        let contents = file[target]
        let arrival = arrivalCamera(for: target) {
            let index = ShapeIndex()
            return index.bounds(in: ShapeContext(document: contents, registry: registry, camera: Camera(), index: index))
        }
        let index = ShapeIndex(), clear = unobscuredViewport(on: target)
        return BoardReading(board: target, document: contents,
                            shapes: ShapeContext(document: contents, registry: registry, camera: arrival, index: index), index: index,
                            view: clear.isEmpty ? nil : arrival.toWorld(clear), isBoardReadOnly: isReadOnly(board: target))
    }

    // MARK: Tools

    /// Makes a tool current, if it's enabled here (`isToolEnabled`): one that places shapes isn't on a
    /// board that can't change.
    public func setTool(_ id: ToolID) {
        guard isToolEnabled(id) else { return }
        switchTool(to: id)
    }

    /// `setTool`, enabled or not: the default tool coming back as another board is shown, before
    /// whether that board takes shapes is worked out (`show` leaves it then if it isn't enabled there).
    private func switchTool(to id: ToolID) {
        guard id != currentToolID, tools[id] != nil else { return }
        let old = currentToolID
        currentToolID = id
        hintedShapeID = nil
        for service in serviceOrder { service.toolDidChange(from: old, to: id, in: self) }
        setNeedsDisplay()
        refreshCursor()
    }

    /// Where place tools (and any plugin with a `Placement`) create shapes: the shape goes in, the
    /// default tool comes back, services hear `didPlace` (the selection selects it), and, while the
    /// press that placed it lasts, the shape follows the pointer (`PlacingSession`), whatever the
    /// placement; on the release it settles (into a container, or out, `Transaction.settle`, gliding
    /// there), and an editing placement's shape is edited, and Escape before it takes the shape away
    /// and selects again what was selected before (the undo participants' state from before the
    /// press, as undoing its step would), so the press comes to nothing. Placed with no press under
    /// way, it settles at once, in the same step, and an editing placement's shape is edited at once.
    /// A read-only container (a locked frame) takes nothing: placed into one, the shape doesn't stay,
    /// and services hear the container refused. Nor does a read-only board (`isBoardReadOnly`): nothing
    /// is placed, nothing else happens (the tool stays, nothing's selected), and services hear the
    /// board's owner refused. (Other tools create shapes with `transact { $0.insert(...) }`, as a
    /// port's drag does.)
    /// The insert names its undo step "Add" and the placing tool's label ("Add Note").
    public func place(_ placement: Placement, at point: CGPoint) {
        put(placement.shape(at: point), placing: placement, from: undoHistory.isPressHeld && session == nil ? point : nil)
    }

    /// Puts one down with this frame (world units), where `place(_:at:)` centers one of its size on a
    /// point: what a tool that draws its shape's rect with a drag puts down at the release (the Frame
    /// tool). As `place(_:at:)` with no press under way: it settles at once (into a container, or out,
    /// gliding there), in the step under way, a read-only container or board refusing it (nothing is
    /// placed, and the container, or the board's owner, is heard refused); the default tool comes back,
    /// services hear `didPlace`, and an editing placement's shape is edited. It never follows the
    /// pointer.
    public func place(_ placement: Placement, in frame: CGRect) {
        put(placement.make(frame), placing: placement, from: nil)
    }

    /// Puts a new container down around shapes on the board shown, holding them (Frames' Create
    /// Frame): `shape`, of a `ShapeContaining` kind, its id new to the file, framed around those of
    /// `ids` with a box (and what's bound to them alone among `ids`, an arrow between two of them), grown
    /// by `padding` and to `minimumSize` (world units), in the innermost container they're all in, just
    /// below the lowest of them in the stack (`Transaction.enclose`). They stay where they are; what it
    /// lands on beside them is settled as what a container's drawn over is, gliding there. One step,
    /// named as a placement's ("Add Frame", unless a group it's in names it); the default tool comes
    /// back, and services hear `didPlace` (the selection selects it). All or nothing: if one it would
    /// hold is read-only (locked, in a locked container, or on a read-only board), nothing changes, no
    /// step is left, and services hear which were refused (they shake). Returns the new shape's id; nil
    /// when it put nothing down (none of `ids` has a box, one was refused, or `shape` holds nothing).
    @discardableResult
    public func place<P: ShapeProps>(_ shape: ShapeRecord<P>, around ids: [ShapeID], padding: CGFloat = 0,
                                     minimumSize: CGSize = .zero) -> ShapeID? {
        place(AnyShapeRecord(shape), around: ids, padding: padding, minimumSize: minimumSize)
    }

    /// `place(_:around:padding:minimumSize:)`, over any record (a copy, say), whatever container it names.
    @discardableResult
    public func place(_ shape: AnyShapeRecord, around ids: [ShapeID], padding: CGFloat = 0, minimumSize: CGSize = .zero) -> ShapeID? {
        var refused: Set<ShapeID> = []
        // A refusal throws it all away with it: nothing is put down, and no step is left.
        let nudges = try? transact("Add \(registry.label(of: shape.kind).name)") { transaction -> [ShapeID: CGPoint]? in
            let nudges = transaction.enclose(ids, in: shape, padding: padding, minimumSize: minimumSize)
            refused = transaction.refusedShapes
            if !refused.isEmpty { throw PlacementRefused() }
            return nudges
        }
        if !refused.isEmpty {
            refuseChanges(to: refused)
            return nil
        }
        guard let nudges else { return nil }
        setTool(registry.defaultTool)
        for service in serviceOrder { service.didPlace(shape.id, in: self) }
        glide(nudges)
        return shape.id
    }

    /// `record`, `placement`'s, put down; following the pointer from `point` (world units, the press)
    /// while the press lasts, or with no point, settled at once.
    private func put(_ record: AnyShapeRecord, placing placement: Placement, from point: CGPoint?) {
        // A read-only board takes nothing, as its transaction would refuse the insert: said so, and
        // nothing more done.
        guard !isBoardReadOnly else {
            if let owner = board.owner { refuseChanges(to: [owner]) }
            return
        }
        let tool = ToolID(placing: placement.kind)
        let label = registry.tools.first { $0.id == tool }?.label
        let follows = point != nil
        let before = follows ? undoHistory.snapshots() : [:]
        var settled = Settlement.settled(nudges: [:])
        if follows || registry.containingKinds.isEmpty {
            transact("Add \(label ?? "Shape")") { $0.insert(record) }
        } else {
            // A refusal throws the insert away with it: nothing is placed.
            try? transact("Add \(label ?? "Shape")") { transaction in
                transaction.insert(record)
                settled = transaction.settle([record.id])
                if case .refused = settled { throw PlacementRefused() }
            }
            if case .refused(let container) = settled {
                refuseChanges(to: [container])
                return
            }
        }
        setTool(registry.defaultTool)
        for service in serviceOrder { service.didPlace(record.id, in: self) }
        let edits = placement.completion == .edit
        if let point, session == nil {
            session = PlacingSession(record.id, from: point, edits: edits, restoring: before, in: self)
            return
        }
        var nudges = settled.nudges
        // Its editing view is laid out where it is.
        if edits { nudges[record.id] = nil }
        glide(nudges)
        if edits { beginEditing(record.id) }
    }

    /// What leaves a placement with no press that a read-only container refused (`place`), or a
    /// container put down around shapes one of which is read-only (`place(_:around:)`).
    private struct PlacementRefused: Error {}

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
    /// plugin. Returns false if no plugin claims it, or it can't. What it commits is one undo step.
    @discardableResult
    public func perform(_ command: CanvasCommand) -> Bool {
        guard let registration = registry.command(command), registration.isEnabled(self) else { return false }
        undoHistory.group { registration.run(self) }
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

    /// Edits a shape of an `Editable` kind in place. Returns false for any other shape, and for a
    /// read-only one, which is refused (services hear it, `didRefuseChanges`). `point`, in world
    /// units, is where the press that began it was, if one did, and `clickCount` how many clicks it
    /// was: the editing view reads them (`EditContext.startPoint`, `startClickCount`) to put its
    /// selection there, as a text view would (a caret for a click, a word for a double-click). Nil
    /// (Return, a placement) leaves the view to choose.
    @discardableResult
    public func beginEditing(_ id: ShapeID, at point: CGPoint? = nil, clickCount: Int = 1) -> Bool {
        endEditing()
        guard let record = document[id], !record.isOpaque, registry.definition(for: record.kind) is any Editable else { return false }
        guard !isReadOnly(id) else {
            refuseChanges(to: [id])
            return false
        }
        editingStartPoint = point
        editingStartClickCount = point == nil ? 1 : clickCount
        editingShapeID = id
        undoHistory.editingBegan(stepName: (registry.definition(for: record.kind) as? any Editable)?.editingStepName)
        dismissPopover()
        delegate?.editorEditingDidChange(self)
        setNeedsDisplay()
        return true
    }

    /// The text selected in the shape being edited's view, while one is edited and its view is text
    /// with something selected (nil otherwise, and with no view: headless): what a search seeds its
    /// query with, as a browser's ⌘F takes what's selected.
    public var editingSelectedText: String? {
        guard editingShapeID != nil else { return nil }
        return delegate?.editorEditingSelectedText(self)
    }

    /// What the editing view saves as it closes is part of the session's undo step. Services hear it
    /// once the step is closed (`editingDidEnd`). A shape whose kind answers
    /// `Editable.discardsWhenEditingEnds` is deleted inside that step, unless an action is under way
    /// (a command, a draw, a group) or something else is ending the session (undo, redo, a board
    /// shown, the file replaced): that owns the step.
    /// `discarding: false` (a draw) never asks.
    public func endEditing(discarding: Bool = true) {
        guard let id = editingShapeID else { return }
        let mayDiscard = discarding && !undoHistory.isInAction
        editingShapeID = nil
        editingStartPoint = nil
        editingStartClickCount = 1
        dismissPopover()
        delegate?.editorEditingDidChange(self)
        setNeedsDisplay()
        if mayDiscard, let record = document[id], !record.isOpaque,
           (registry.definition(for: record.kind) as? any Editable)?.erasedDiscardsWhenEditingEnds(record) == true {
            transact(nil, coalescing: nil, origin: .editing) { $0.delete([id]) }
        }
        undoHistory.editingEnded()
        for service in serviceOrder { service.editingDidEnd(id, in: self) }
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
