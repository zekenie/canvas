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
    /// Another board is shown (`board`): swap whatever is kept of the board it left (the minimap's
    /// picture). Editing has ended by now, and the canvas is to be redrawn.
    func editorBoardDidChange(_ editor: CanvasEditor)
}

@_spi(Host) extension CanvasEditorDelegate {
    public func editorBoardDidChange(_ editor: CanvasEditor) {}
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
    /// Every board of the file: what a board file saves. `document` is its board `board`; the others
    /// change only with a commit on the shown one (a deletion taking the boards under a shape, a paste
    /// bringing some) or the whole file's replacement. Read what's shown from `document`, never from
    /// here. Observed through `document`.
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
            setNeedsDisplay()
            tellSkeletonLevel()
            sessionFollowsCamera()
        }
    }

    /// The zoom where the camera is headed (`cameraTarget`), in whole percent: what the toolbar shows,
    /// and what the zoom commands step from. Observed apart from `camera`, and set only when it
    /// changes, so a view that shows it redraws as the zoom does, never as the camera pans.
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
        var transaction = Transaction(document: document, board: board, registry: registry, camera: camera, keys: stackingKeys,
                                      file: fileAccess)
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
    /// transaction, but nothing shows the refusal, since they aren't shown. A transaction that would
    /// take the board shown, or a board above it, with a shape it deletes commits nothing. Returns
    /// nil, doing nothing, for a board the editor can't show (`canShow`).
    @discardableResult
    public func transact<T>(on target: BoardID, _ name: String? = nil, _ body: (inout Transaction) throws -> T) rethrows -> T? {
        guard target != board else { return try transact(name, coalescing: nil, origin: .ordinary, body) }
        guard canShow(target) else { return nil }
        precondition(!isApplying, "nothing may transact while undo or redo puts a step back (a service's documentDidChange, say)")
        precondition(!isTransacting, "transactions don't nest; use the one you were given")
        isTransacting = true
        var transaction = Transaction(document: storedFile[target], board: target, registry: registry, camera: leftCameras[target] ?? camera,
                                      keys: stackingKeys, file: fileAccess)
        let result: T
        do {
            defer { isTransacting = false }
            result = try body(&transaction)
        }
        // The owners too: an empty board isn't among the boards a deletion takes.
        guard transaction.didChange, transaction.changes.boardsRemoved.isDisjoint(with: boardPath),
              transaction.changes.removed.isDisjoint(with: boardPath.lazy.compactMap(\.owner)) else { return result }
        if isReplacingFile {
            commit(transaction, onHidden: target)
        } else {
            undoHistory.recordStep(on: target, name: name, changes: transaction.changes, from: storedFile) {
                commit(transaction, onHidden: target)
            }
        }
        return result
    }

    /// Whether a plugin's rule says the shape can't change (`registrar.readOnlyShapes`): no
    /// transaction changes, restacks or deletes it, a drag leaves it where it is, and it isn't
    /// edited. False for a shape that isn't there.
    public func isReadOnly(_ id: ShapeID) -> Bool {
        document[id].map(registry.isReadOnly) ?? false
    }

    /// Something tried to change these read-only shapes, and didn't: services hear which.
    func refuseChanges(to ids: Set<ShapeID>) {
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
                   contents: { [unowned self] in storedFile[$0] })
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
        if let running = session {
            _ = running.cancel(in: self)
            session = nil
        }
        var newFile = registry.fillingDefaults(newFile)
        let showable = { [registry] (board: BoardID) in Self.canShow(board, in: newFile, registry: registry) }
        let target = requested.flatMap { showable($0) ? $0 : nil } ?? boardPath.reversed().first(where: showable) ?? .root
        for service in serviceOrder { service.boardWillChange(from: board, to: target, in: self) }
        endEditing()
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
            setTool(registry.defaultTool)
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
        let old = storedFile, access = FileAccess(old)
        var newFile = old, removed: Set<BoardID> = []
        let byBoard = Dictionary(grouping: ids.filter { old.record($0)?.isOpaque == true }) { old.board(containing: $0)! }
        for (board, ids) in byBoard {
            var transaction = Transaction(document: old[board], board: board, registry: registry, camera: camera, keys: stackingKeys,
                                          file: access)
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
        storedFile.set(transaction.document, for: board, changes: changes)
        changes.elsewhere = writeBoards(of: transaction)
        documentDidChange(to: transaction.document, changes: changes)
    }

    /// Writes a transaction on a board that isn't shown (`transact(on:)`) through to the file, and
    /// tells services as a commit that changed that board and those it took or brought: the board
    /// shown is as it was.
    private func commit(_ transaction: Transaction, onHidden target: BoardID) {
        let local = transaction.changes
        var changes = ChangeSet()
        changes.boardsChanged = [target]
        changes.boardsAdded = local.boardsAdded
        changes.boardsRemoved = local.boardsRemoved
        changes.byAgent = local.byAgent
        storedFile.set(transaction.document, for: target, changes: local)
        changes.elsewhere = writeBoards(of: transaction).union(local.shapeIDs)
        documentDidChange(to: storedDocument, changes: changes)
    }

    /// Takes out of the file the boards a transaction took, and puts in those it brought; returns
    /// the shapes on them.
    private func writeBoards(of transaction: Transaction) -> Set<ShapeID> {
        let changes = transaction.changes
        var touched = storedFile.shapeIDs(on: changes.boardsRemoved)
        for board in changes.boardsRemoved { leftCameras[board] = nil }
        storedFile.removeBoards(changes.boardsRemoved)
        warmIndexes.forget(changes.boardsRemoved)
        for board in transaction.stagedBoards.values { touched.formUnion(board.shapes.lazy.map(\.id)) }
        storedFile.insertBoards(transaction.stagedBoards)
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
        withMutation(keyPath: \.document) { storedDocument = newDocument }
        revision += 1
        shapeIndex.documentDidChange(changes, in: newDocument, registry: registry)
        for id in changes.removed where drawingOffsets[id] != nil { drawingOffsets[id] = nil }
        // Services drop what no longer names a shape, as the hint's setter does.
        for service in serviceOrder { service.documentDidChange(changes, in: self) }
        hintedShapeID = hintedID
        // A shape that's gone, or can no longer change, isn't edited.
        if let editing = editingShapeID, document[editing].map(registry.isReadOnly) ?? true { endEditing() }
        setNeedsDisplay()
    }

    // MARK: Boards

    /// Whether `showBoard` can show a board: the root, or a board whose owners, from the root down,
    /// are all in the file, none kept aside, each of a kind that owns boards (`BoardOwning`). The
    /// board itself may have no shapes (yet). O(the board's depth). Observed through `document`.
    public func canShow(_ target: BoardID) -> Bool { Self.canShow(target, in: file, registry: registry) }

    static func canShow(_ target: BoardID, in file: CanvasFile, registry: Registry) -> Bool {
        guard !target.isRoot else { return true }
        guard let path = file.path(to: target) else { return false }
        return path.dropFirst().allSatisfy { board in
            board.owner.flatMap(file.record).map(registry.ownsShowableBoard) ?? false
        }
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
        endEditing()
        setTool(registry.defaultTool)
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
        leftCameras[board] = left
        leftOrder.removeAll { $0 == board }
        leftOrder.append(board)
        let change = BoardChange(from: board, to: target, leftCamera: left, left: storedDocument, shown: storedFile[target],
                                 isFileReplaced: replacingFile)
        withMutation(keyPath: \.document) { storedDocument = storedFile[target] }
        board = target
        boardPath = storedFile.path(to: target) ?? [.root]
        shapeIndex = warmIndexes.take(for: target, in: self) ?? ShapeIndex()
        hintedID = nil
        drawingOffsets = [:]
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
    }

    /// The camera a board is shown with: as it was left, else as the host remembers it, else its
    /// shapes fitted into the part of the view the host leaves clear there (`unobscuredViewport`), no
    /// closer than 100%, else where a board starts.
    private func arrivalCamera(for target: BoardID) -> Camera {
        if let kept = leftCameras[target] ?? rememberedCameras[target] { return kept }
        let view = unobscuredViewport(on: target)
        guard !view.isEmpty else { return Camera() }
        let bounds = shapeBounds
        guard !bounds.isNull else { return Camera() }
        return Camera(fitting: bounds, in: view, inset: Style.firstVisitInset, maxZoom: 1)
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
    /// default tool comes back, services hear `didPlace` (the selection selects it), and, while the
    /// press that placed it lasts, the shape follows the pointer (`PlacingSession`), whatever the
    /// placement; on the release an editing placement's shape is edited, and Escape before it takes
    /// the shape away and selects again what was selected before (the undo participants' state from
    /// before the press, as undoing its step would), so the press comes to nothing. Placed with no
    /// press under way, an editing placement's shape is edited at once. (Other tools create shapes
    /// with `transact { $0.insert(...) }`, as a port's drag does.)
    /// The insert names its undo step "Add" and the placing tool's label ("Add Note").
    public func place(_ placement: Placement, at point: CGPoint) {
        let record = placement.shape(at: point)
        let tool = ToolID(placing: placement.kind)
        let label = registry.tools.first { $0.id == tool }?.label
        let follows = undoHistory.isPressHeld && session == nil
        let before = follows ? undoHistory.snapshots() : [:]
        transact("Add \(label ?? "Shape")") { $0.insert(record) }
        setTool(registry.defaultTool)
        for service in serviceOrder { service.didPlace(record.id, in: self) }
        let edits = placement.completion == .edit
        if follows, session == nil {
            session = PlacingSession(record.id, from: point, edits: edits, restoring: before, in: self)
        } else if edits {
            beginEditing(record.id)
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
        guard !registry.isReadOnly(record) else {
            refuseChanges(to: [id])
            return false
        }
        editingStartPoint = point
        editingStartClickCount = point == nil ? 1 : clickCount
        editingShapeID = id
        undoHistory.editingBegan()
        delegate?.editorEditingDidChange(self)
        setNeedsDisplay()
        return true
    }

    /// What the editing view saves as it closes is part of the session's undo step.
    public func endEditing() {
        guard editingShapeID != nil else { return }
        editingShapeID = nil
        editingStartPoint = nil
        editingStartClickCount = 1
        delegate?.editorEditingDidChange(self)
        setNeedsDisplay()
        undoHistory.editingEnded()
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
