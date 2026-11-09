import AppKit
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
    /// A menu is waiting to be popped up (`menuToPopUp`): pop it up on the next turn of the run loop
    /// and say so (`menuDidPopUp`).
    func editorMenuToPopUpDidChange(_ editor: CanvasEditor)
    /// `card` changed (shown, taken down, moved, resized): show it over what the canvas hosts, under the
    /// popover, give its `firstResponder` the keyboard, or take it down and give the keyboard back.
    func editorCardDidChange(_ editor: CanvasEditor)
    /// Where VoiceOver's focus is moved (`accessibilityFocusDidChange`): the selection changed, or the
    /// part of a shape focused. Tell an assistive app, if one is listening.
    func editorAccessibilityFocusDidChange(_ editor: CanvasEditor)
    /// Something to be said to whoever uses VoiceOver (`announce`).
    func editorAnnounce(_ editor: CanvasEditor, _ text: String, priority: AnnouncementPriority)
    /// A commit, settled, added shapes to the board shown or took some off it (never one that only
    /// changed shapes): what an assistive app is told its elements changed by.
    func editorShapesDidComeOrGo(_ editor: CanvasEditor, added: Set<ShapeID>, removed: Set<ShapeID>)
    /// What the host's chrome covers of the canvas's edges changed (`coveredEdges`): lay out again
    /// what the canvas hosts in the part left clear (the minimap, in its corner).
    func editorCoveredEdgesDidChange(_ editor: CanvasEditor)
}

@_spi(Host) extension CanvasEditorDelegate {
    public func editorAccessibilityFocusDidChange(_ editor: CanvasEditor) {}
    public func editorAnnounce(_ editor: CanvasEditor, _ text: String, priority: AnnouncementPriority) {}
    public func editorShapesDidComeOrGo(_ editor: CanvasEditor, added: Set<ShapeID>, removed: Set<ShapeID>) {}
    public func editorBoardDidChange(_ editor: CanvasEditor) {}
    public func editorPopoverDidChange(_ editor: CanvasEditor) {}
    public func editorMenuToPopUpDidChange(_ editor: CanvasEditor) {}
    public func editorCardDidChange(_ editor: CanvasEditor) {}
    public func editorEditingSelectedText(_ editor: CanvasEditor) -> String? { nil }
    public func editorCoveredEdgesDidChange(_ editor: CanvasEditor) {}
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
    /// The kits turned on in the file (File ▸ Kits), those a plugin joins: what the file keeps (`KitsOn`)
    /// that the registry has. A plugin in a kit that isn't here is off in this file, and what it gives a point
    /// a kit switches is left out (`isOn(plugin:)`, `contributions(to:)`). Worked out again as a commit, an
    /// undo or a redo changes the value and as a file is put in place, and set only when it changes:
    /// observed apart from `document`, so what shows a kit's tools or items redraws as it changes, never on
    /// every commit.
    public internal(set) var kits: Set<KitID> = []
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
    /// file for a view that is drawn again by something else it observes (Mentions' quote of a
    /// mentioner's text, in a row its list draws again as each answer lands), so the view redraws as
    /// that says rather than on every commit. What it reads is for the call: a copy of the
    /// file kept until the next commit would make that commit copy the tables it writes (the shapes of a
    /// board and which board each is on in pieces, the file's other tables whole), whatever it changed.
    public func withoutObservingDocument<T>(_ body: () throws -> T) rethrows -> T {
        unobservedReads += 1
        defer { unobservedReads -= 1 }
        return try body()
    }
    /// +1 per change services hear: a transaction that changed something, another board shown.
    public private(set) var revision = 0
    #if DEBUG
    /// Everything `announce` was asked to say, in order (debug builds only), for tests.
    @ObservationIgnored public internal(set) var announcements: [String] = []
    #endif
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
            cardFollowsCamera()
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
    /// top of the part its chrome leaves clear (`coveredEdges`; the path's pill inside a subboard):
    /// what fitting shapes into view leaves clear. None unless the host says (`unobscuredViewport`).
    @_spi(Host) @ObservationIgnored public var coveredTop: @MainActor (BoardID) -> CGFloat = { _ in 0 }

    /// What the host's own chrome covers of the canvas along its edges, in view points, on every
    /// board: the window's title bar along the top, and the sidebar and the inspector along the sides
    /// while they show, over a canvas that fills the window, so that showing or hiding one moves
    /// nothing on the board. None unless the host says (`unobscuredViewport`). A change keeps a view
    /// kept while the view settles in what is clear then, as a change of the view's size does
    /// (`keepInViewWhileSettling`: a shape just selected that the inspector comes in over is panned
    /// clear), lets go of a card it covers, and tells the host (`editorCoveredEdgesDidChange`).
    @_spi(Host) @ObservationIgnored public var coveredEdges = CoveredEdges() {
        didSet {
            guard coveredEdges != oldValue else { return }
            // Eased as a pane slides in or out; at once as one is resized, following the drag.
            keepViewAfterViewChange(easing: coveredEdges.hasSameSides(as: oldValue) ? nil : Style.coveredEdgesDuration)
            cardFollowsCamera()
            delegate?.editorCoveredEdgesDidChange(self)
        }
    }

    /// What the host's chrome will cover of the canvas along its edges once it settles with what the editor shows now
    /// (the inspector a selection just made shows, which comes in on the window's next pass): `coveredEdges` as it is
    /// headed, as `cameraTarget` is the camera as it is headed. Nil, as by default, for the edges as they are laid out.
    /// What the clear part a fit, a reveal or an insertion goes by is worked out from (`unobscuredViewport`), so a shape
    /// put down and selected at once is placed and brought into view in what will be clear of the inspector, never in
    /// what it is about to cover. Read when asked, so it reads the selection as it is then.
    @_spi(Host) @ObservationIgnored public var coveredEdgesAhead: (@MainActor () -> CoveredEdges)?

    /// How far down the host's views over the canvas reach on the board shown, in view points, from the top
    /// of the part its chrome leaves clear (`coveredTop`: the path's pill inside a subboard): where a view
    /// the host places in that part (a plugin's, `registrar.hostOverlay`) goes to stay clear of them. None
    /// unless the host says.
    public var hostViewsReach: CGFloat { max(coveredTop(board), 0) }

    /// The part of the view nothing the host puts over the canvas covers, on the board shown, in view
    /// points: the view, less what the host's chrome covers along its edges as it is headed
    /// (`coveredEdgesAhead`, else `coveredEdges`: the inspector a selection just made counts before it has
    /// slid in) and, under the top's, what its views over the canvas cover there (`coveredTop`). What a
    /// fit fits shapes into: a board's first visit, Zoom to Fit, Selection's `reveal`; and where Insert
    /// puts a shape down. Empty before the view has a size; at least a point either way however much is
    /// covered.
    public var unobscuredViewport: CGRect { unobscuredViewport(on: board) }

    /// How much of the clear part's corners the host's own views over the canvas cover, in view points from each corner (the
    /// minimap, bottom-left, while it shows; `CoveredCorners`). None unless the host says. A fit fills the clear part
    /// (`unobscuredViewport`) whatever its corners; what keeps one shape in view reads `clearView`, which leaves them out.
    @_spi(Host) @ObservationIgnored public var coveredCorners = CoveredCorners()

    /// The part of the view a shape is kept in, in view points: the clear part (`unobscuredViewport`), less the corners of it the
    /// host's views cover (`coveredCorners`). What a reveal by the least pan (`animateCamera(toShow:…)`), the caret kept in view
    /// (`EditContext.keepInView`) and a shape put down for a person (Draw's `PutBeside`, through `reading(of:)`'s `covered`)
    /// judge "in view" by, so nothing lands, or is kept, under the minimap.
    public var clearView: ClearView { clearView(on: board) }

    func clearView(on target: BoardID) -> ClearView {
        let rect = unobscuredViewport(on: target)
        return ClearView(rect: rect, covered: coveredCorners.rects(in: rect))
    }

    /// The same, of the chrome as it is laid out now (`coveredEdges`), whatever it is headed for: what of a
    /// selection is in view now, which the view keeps as the inspector slides in (`keepInViewWhileSettling`).
    var laidOutViewport: CGRect { unobscuredViewport(on: board, edges: coveredEdges) }

    func unobscuredViewport(on target: BoardID) -> CGRect {
        // While a service takes a change in, what the host's rule reads (the selection) may be half taken in: the edges as laid out.
        let ahead = hearing.contains(where: \.isBusy) ? nil : coveredEdgesAhead?()
        return unobscuredViewport(on: target, edges: ahead ?? coveredEdges)
    }

    private func unobscuredViewport(on target: BoardID, edges: CoveredEdges) -> CGRect {
        guard viewportSize.width > 0, viewportSize.height > 0 else { return .zero }
        let left = min(max(edges.left, 0), viewportSize.width - 1)
        let right = min(max(edges.right, 0), viewportSize.width - 1 - left)
        let top = min(max(edges.top + max(coveredTop(target), 0), 0), viewportSize.height - 1)
        let bottom = min(max(edges.bottom, 0), viewportSize.height - 1 - top)
        return CGRect(x: left, y: top, width: viewportSize.width - left - right, height: viewportSize.height - top - bottom)
    }

    /// What the root board is called: the file's name, which only the host knows (a board's window
    /// says it as it titles itself, `nameRoot(_:)`). Every other board is named by the shape that
    /// owns it, which is a plugin's to read; the root has no owner, so whatever names boards reads
    /// this for it. Empty until the host says, and headless. Observed apart from `document`, and set
    /// only when it changes, so what shows it redraws as the file is renamed, never on a commit.
    public private(set) var rootName = ""

    /// The host's: what the root board is called from now on (`rootName`).
    @_spi(Host) public func nameRoot(_ name: String) {
        guard name != rootName else { return }
        rootName = name
        // What the canvas draws may say it (a reference's place led by the root), and a rename is no commit.
        setNeedsDisplay()
    }

    /// A shape outlined as a target, whatever the tool (a connector tool sets it while aiming).
    /// Setting it to a shape that isn't there drops it.
    public var hintedShapeID: ShapeID? {
        get { hintedID }
        set {
            let id = newValue.flatMap { document[$0] == nil ? nil : $0 }
            guard id != hintedID else { return }
            hintedID = id
            hintedPartID = nil
            setNeedsDisplay()
        }
    }
    private var hintedID: ShapeID?

    /// A part of the hinted shape lit as the target (a row a connection would end on: `PartedShape`), its rect from the shape's
    /// kept geometry (`ShapeGeometry.parts`) drawn in the hint's color. Set after `hintedShapeID`, which clears it whenever it
    /// changes; nil with no hint, and drawn only while the hinted shape's geometry lists the part.
    public var hintedPart: PartID? {
        get { hintedPartID }
        set {
            let part = hintedID == nil ? nil : newValue
            guard part != hintedPartID else { return }
            hintedPartID = part
            setNeedsDisplay()
        }
    }
    private var hintedPartID: PartID?
    /// Starts as the registry's default tool.
    public private(set) var currentToolID: ToolID
    /// While true (tool lock, tldraw's `toggle-tool-lock`: Keyboard's Q), putting a shape down keeps the
    /// tool instead of going back to the default tool (`place`), so the next press puts another down.
    /// Escape still leaves the tool, and the lock stays on for the next one; nothing else turns it
    /// off. Observed, so the toolbar shows it on the selected tool.
    public var isToolLocked = false
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
    /// While a shape is edited, the part of it the keys are on (a row with the caret, or the one row selected whole while it's
    /// typed in), as its editing view says; nil while the keys are on none (its title), and once editing ends. What a panel shows
    /// as its subject: the row, not the shape.
    public var editingPart: PartID? {
        didSet { if editingShapeID == nil, editingPart != nil { editingPart = nil } }
    }
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
    /// The shapes waiting to be placed, while their tool is current (`placeLater`).
    @ObservationIgnored var pendingPlacement: PendingPlacement?
    @ObservationIgnored private let serviceRegistrations: [ObjectIdentifier: ServiceRegistration]
    /// Each service, by its type: its place in `serviceOrder`.
    @ObservationIgnored private var services: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private var serviceOrder: [any EditorService] = []
    /// The revision each service, by its place in `serviceOrder`, has taken in (`tell`).
    @ObservationIgnored private var heardRevisions: [Int] = []
    /// What each service, by its place in `serviceOrder`, looked up as it was made: a service reads what it kept
    /// from its `make` without a lookup, so those take each change in before it does (`tell`).
    @ObservationIgnored private var madeWith: [[Int]] = []
    /// The services being made now, the innermost last, each with what it has looked up so far.
    @ObservationIgnored private var making: [(id: ObjectIdentifier, lookedUp: [Int])] = []
    /// The change being delivered, from `beginDelivery` to `finishDelivery`.
    @ObservationIgnored private var delivery: Delivery?
    /// The services taking the change in now, the innermost last (`tell`).
    @ObservationIgnored private var hearing: [Hearing] = []
    /// What waits for every service to have settled the change being delivered (`onceSettled`).
    @ObservationIgnored private var onceSettledBodies: [@MainActor () -> Void] = []
    /// A cursor asked for while a change is delivered: asked of the host once it's over.
    @ObservationIgnored private var cursorAsked = false
    @ObservationIgnored private(set) var isTransacting = false
    /// Undo or redo is putting a step's records back: nothing may transact.
    @ObservationIgnored var isApplying = false
    /// What a rehearsal was made from (`rehearsal()`): the editor and its file as it was then, which `adopt` holds the
    /// editor's file to. Nil for an editor that isn't a rehearsal.
    @ObservationIgnored var rehearsed: (of: ObjectIdentifier, file: CanvasFile)?
    /// A file is being put in place (`replaceFile`): what commits meanwhile, on the file it replaces,
    /// isn't an undo step, so it doesn't edit the file.
    @ObservationIgnored private var isReplacingFile = false
    /// Each shape's geometry and extent, and the paint order, kept from frame to frame: the shown
    /// board's.
    @ObservationIgnored var shapeIndex = ShapeIndex()
    /// What geometries read that no record holds (`setLayoutInput`).
    @ObservationIgnored let layoutInputs = LayoutInputs()
    /// The sizes shapes are laid out at, by shape id, for the whole file (`LaidOutBox`).
    @ObservationIgnored let laidOutSizes = LaidOutSizes()
    /// What the editor's own contexts lay shapes out with: those inputs, its services and its file.
    @ObservationIgnored lazy var layoutSource = LayoutSource(
        inputs: layoutInputs, sizes: laidOutSizes, lend: { [unowned self] in resolveService($0) },
        shape: { [unowned self] in storedDocument[$0] ?? Self.shape($0, inFile: storedFile, registry: registry) },
        board: { [unowned self] in storedFile.board(containing: $0) },
        fileValues: { [unowned self] in storedFile.fileValues },
        nearby: { [unowned self] board, rect in board == self.board ? shapeIndex.ids(touching: rect, in: shapeContext) : nil })
    /// Moves whenever shapes were laid out again without a commit (`shapesDidChangeLayout`). What
    /// keeps something worked out from geometry keys it by this beside `revision`.
    @ObservationIgnored public internal(set) var layoutRevision = 0
    /// The indexes of the boards shown lately, for when they're shown again (while they haven't
    /// changed).
    @ObservationIgnored var warmIndexes = BoardStash<ShapeIndex>()
    /// Where the camera was on each board shown this session, as it was left.
    @ObservationIgnored private var leftCameras: [BoardID: Camera] = [:]
    /// The boards left this session, in the order they were last left (`boardsLeft`).
    @ObservationIgnored private var leftOrder: [BoardID] = []
    /// Where the camera was on boards of this file in an earlier session (the host remembers them):
    /// where a board shown for the first time this session starts.
    @_spi(Host) @ObservationIgnored public var rememberedCameras: [BoardID: Camera] = [:]
    /// What plugins keep of how the file is viewed on this Mac (`setViewValue`), by key, encoded.
    @ObservationIgnored var viewValueStore: [String: Data] = [:]
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
    /// The shapes' shadows (`RenderContext.fillWithShadow`), left out where their fills hide them.
    @ObservationIgnored let shapeShadows = ShapeShadows()
    /// The lists of shapes outlined, as sets, kept from frame to frame (`strokeOutlines`).
    @ObservationIgnored let outlineMembers = OutlineMembers()
    /// Below this zoom the canvas draws shapes as skeletons (`drawsSkeletons`, `CustomSkeleton`):
    /// 35% (`Style.skeletonZoom`) unless the host says otherwise. 0 draws every shape in full at
    /// every zoom (a test held to pictures drawn before skeletons were). Setting it redraws, and
    /// tells services if it moves past the camera's zoom (`drawsSkeletonsDidChange`).
    @_spi(Host) @ObservationIgnored public var skeletonZoom: CGFloat = Style.skeletonZoom {
        didSet {
            guard skeletonZoom != oldValue else { return }
            setNeedsDisplay()
            tellSkeletonLevel()
            cardFollowsCamera()
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
    /// Whether the pointer is over the canvas itself (`isPointerOverCanvas`).
    @ObservationIgnored var pointerIsOverCanvas = false
    /// Whether the canvas view has the keyboard (`hasKeyboard`).
    @ObservationIgnored var canvasHasKeyboard = true
    @ObservationIgnored var heldModifiers: Modifiers = []
    @ObservationIgnored var recentlyReleased: Modifiers = []
    @ObservationIgnored var releaseTimer: ScheduledTask?
    // The camera motion's next frame (a slide or an animation), and an animation's target, used by
    // CanvasEditor+Camera.swift.
    @ObservationIgnored var cameraMotion: ScheduledTask?
    @ObservationIgnored var cameraAnimationTarget: Camera?
    /// The last Zoom to Fit's camera and the camera it left (CanvasEditor+Camera.swift): Zoom to Fit
    /// again, while the camera is still headed for that fit, goes back to this.
    @ObservationIgnored var cameraBeforeFit: (before: Camera, fit: Camera)?
    /// What the camera keeps in view while the view around it settles (CanvasEditor+Camera.swift).
    @ObservationIgnored var keptView: KeptView?
    /// What the shape Insert is putting down goes beside (`insert(_:named:beside:)`), while it is placed: what a service
    /// told it was placed (`didPlace`) keeps in view with it, as it brings it into view. Empty otherwise.
    @ObservationIgnored public internal(set) var placingBeside: [ShapeID] = []
    /// A command that says its own step as it ends (the command bar's) is running: a shape it puts down is heard in
    /// those words, once, not also as the editor's own ("Add Note"). The bar's, set as it runs a command and cleared once
    /// it has said it.
    @ObservationIgnored public var isSayingStep = false
    // The popover (Popovers.swift): the one showing, the one waiting its delay and its timer, and
    // while one has just gone, the end of that moment.
    @ObservationIgnored var shownPopover: CanvasPopover?
    @ObservationIgnored var waitingPopover: CanvasPopover?
    @ObservationIgnored var popoverTimer: ScheduledTask?
    @ObservationIgnored var popoverWarmth: ScheduledTask?
    // The card showing (Cards.swift).
    @ObservationIgnored var shownCard: CanvasCard?
    // The menu waiting to be popped up (MenuPopUp.swift).
    @ObservationIgnored var menuWaiting: (menu: NSMenu, rect: CGRect, highlighting: NSMenuItem?)?
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
        kits = Self.kits(on: storedFile, registry: registry)
        if !isToolEnabled(currentToolID) { currentToolID = .hand }
        // Services first, so tools can look them up; each resolves the services it asks for.
        for registration in registry.services { _ = resolveService(registration.type) }
        for (id, make) in registry.toolFactories { tools[id] = make(self) }
        tools[.pendingPlacement] = PendingPlacementTool()
        undoHistory.editor = self
        undoHistory.participants = serviceOrder.compactMap { $0 as? any UndoParticipant }
        toldDrawsSkeletons = drawsSkeletons
        // A board's preview draws each shape in the color it's listed in.
        boardPreviews.tint = { [weak self] record in self?.tint(of: record) }
    }

    /// An editor of a file of this one board.
    public convenience init(registry: Registry, document: CanvasDocument = CanvasDocument(), scheduler: any Scheduler = TaskScheduler(),
                            stackingKeys: StackingKeyGenerator = .jittered) {
        self.init(registry: registry, file: CanvasFile(root: document), scheduler: scheduler, stackingKeys: stackingKeys)
    }

    private static func expectAccepted(_ file: CanvasFile, by registry: Registry) {
        for document in file.everyBoard.map({ file[$0] }) {
            for record in document.shapes {
                precondition(record.isOpaque || registry.definition(for: record.kind)?.erasedAccepts(record) == true,
                             "no installed plugin defines \(record.kind) shapes with these props")
            }
        }
    }

    /// The service of this type; nil if no plugin registers one. Asked while a commit or another board shown is
    /// delivered, it takes that in first, if it hasn't yet (`beginDelivery`), so it answers as of the change. One
    /// asked while it's taking the change in (its hook hasn't returned) is busy: a mistake, which stops tests and
    /// debug builds (`busy`), while the app goes on with it as it is.
    public func service<S: EditorService>(_ type: S.Type) -> S? { resolveService(ObjectIdentifier(S.self)) as? S }

    func resolveService(_ id: ObjectIdentifier) -> (any EditorService)? {
        if let index = services[id] {
            if !making.isEmpty { making[making.count - 1].lookedUp.append(index) }
            if delivery != nil {
                if heardRevisions[index] != revision { tell(index) } else { noteIfBusy(index) }
            }
            return serviceOrder[index]
        }
        guard let registration = serviceRegistrations[id] else { return nil }
        precondition(!making.contains { $0.id == id }, "service \(registration.name) needs itself to be made")
        making.append((id, []))
        let service = registration.make(self)
        var once = Set<Int>()
        let lookedUp = making.removeLast().lookedUp.filter { once.insert($0).inserted }
        let index = serviceOrder.count
        services[id] = index
        serviceOrder.append(service)
        heardRevisions.append(revision)
        madeWith.append(lookedUp)
        if !making.isEmpty { making[making.count - 1].lookedUp.append(index) }
        return service
    }

    /// Starts delivering `change`, the change that brought `revision` (a commit, or another board shown), as
    /// `revision` moves: from here a service asked for (`resolveService`) takes it in first, so what the editor
    /// itself asks of services before they're all told (a first visit's camera fit lays the board out) is
    /// answered as of the change. Nothing may change the file until `finishDelivery`: a transaction, a board
    /// shown or a file put in place then is a precondition failure.
    private func beginDelivery(_ change: ServiceChange) {
        precondition(delivery == nil, "nothing may change the file while services hear a change (a service's documentDidChange, say)")
        if case .commit(let changes) = change {
            assert(changes.priors.holdsRecords || (changes.shapeIDs.isEmpty && changes.elsewhere.isEmpty),
                   "a commit that touched shapes holds the records it found (`ChangeSet.priors`), which `before` reads")
        }
        delivery = Delivery(change: change)
    }

    /// Tells every service the change being delivered, in the order they were made: each that hasn't taken it in
    /// yet, as one asked for while another took it in has (`resolveService`). So each takes each change in once,
    /// in the order they came. Then every service settles (`documentDidSettle`, `boardDidSettle`), none busy, and
    /// what waited for that runs (`onceSettled`); then the host hears of the cursor asked for meanwhile.
    private func finishDelivery() {
        guard let change = delivery?.change else { return }
        defer {
            delivery = nil
            if cursorAsked { refreshCursor() }
        }
        for index in serviceOrder.indices where heardRevisions[index] != revision { tell(index) }
        delivery?.isSettling = true
        switch change {
        case .commit(let changes): for service in serviceOrder { service.documentDidSettle(changes, in: self) }
        case .board(let change): for service in serviceOrder { service.boardDidSettle(change, in: self) }
        }
        // What runs here may ask for more, which runs after it.
        var next = 0
        while next < onceSettledBodies.count {
            let body = onceSettledBodies[next]
            next += 1
            body()
        }
        onceSettledBodies = []
    }

    /// Tells the service at `index` in `serviceOrder` the change being delivered. What it looked up as it was made
    /// takes the change in first (and what those tell may ask for it, which tells it then, so it's told once); then,
    /// noting that it has taken the change in, so it isn't told again by what it reads as it does, its hook, busy
    /// until the hook returns; then what it asked to do once it had the change (`onceHeard`), in the order asked,
    /// what those ask for after them.
    private func tell(_ index: Int) {
        guard let change = delivery?.change else { return }
        for made in madeWith[index] where heardRevisions[made] != revision { tell(made) }
        guard heardRevisions[index] != revision else { return }
        heardRevisions[index] = revision
        hearing.append(Hearing(service: index))
        switch change {
        case .commit(let changes): serviceOrder[index].documentDidChange(changes, in: self)
        case .board(let change): serviceOrder[index].boardDidChange(change, in: self)
        }
        let top = hearing.count - 1
        hearing[top].isBusy = false
        var next = 0
        while next < hearing[top].then.count {
            let body = hearing[top].then[next]
            next += 1
            body()
        }
        hearing.removeLast()
    }

    #if DEBUG
    /// What asking for a busy service does in debug builds instead of stopping (`busy`): a test that holds the
    /// mistake sets it, and is handed each one's message.
    @_spi(Host) @ObservationIgnored public var busyRead: (@MainActor (String) -> Void)?
    #endif

    /// A service was asked for while it's taking in the change being delivered (its `documentDidChange` or
    /// `boardDidChange` hasn't returned), so it would answer with half of what it's about to know: something it told, or something that asks around, ran too
    /// early (what tells others belongs in `onceHeard`, what asks around or tells the window in `onceSettled` or
    /// `documentDidSettle`). Tests and debug builds stop here; the app goes on.
    private func noteIfBusy(_ index: Int) {
        #if DEBUG
        guard hearing.contains(where: { $0.service == index && $0.isBusy }) else { return }
        let name = { (index: Int) in String(describing: type(of: self.serviceOrder[index])) }
        let busy = hearing.filter(\.isBusy).map { name($0.service) }.joined(separator: " > ")
        let message = "\(name(index)) was asked for while it takes a change in (busy: \(busy))"
        if let busyRead { return busyRead(message) }
        assertionFailure(message)
        #endif
    }

    /// Runs `body` once the service taking a change in now has (as soon as its `documentDidChange` or
    /// `boardDidChange` returns), after what it asked before; at once if none is: how a service that others follow
    /// tells them, so they may read it then. Still within the delivery: a follower hears before the services after
    /// it, and what it reads beyond the one it follows may not have the change yet (`onceSettled` for that).
    public func onceHeard(_ body: @escaping @MainActor () -> Void) {
        guard !hearing.isEmpty else { return body() }
        hearing[hearing.count - 1].then.append(body)
    }

    /// Runs `body` once every service has settled the change being delivered (after every `documentDidSettle` or
    /// `boardDidSettle`), after what was asked before; at once outside a delivery. For what a service is told
    /// while services take a change in and must read around the file, look at what others laid out, or tell the
    /// window: it runs with every service holding the change and none busy. Nothing may change the file then
    /// either; a write in answer waits a turn (`scheduler`).
    public func onceSettled(_ body: @escaping @MainActor () -> Void) {
        guard delivery != nil else { return body() }
        onceSettledBodies.append(body)
    }

    var currentTool: any Tool { tools[currentToolID]! }
    public var shapeContext: ShapeContext { ShapeContext(document: document, registry: registry, camera: camera, index: shapeIndex, layout: layoutSource) }

    /// Redraw. The core redraws for everything it owns (the document, camera, tool, sessions); a
    /// plugin whose drawn state changes some other way (its own state, a timer) calls this. Asked while a
    /// change is delivered, it's the redraw the change ends with: a commit and a board shown redraw once
    /// services have settled.
    public func setNeedsDisplay() {
        guard delivery == nil else { return }
        delegate?.editorNeedsDisplay(self)
    }

    /// Sets the cursor again. The core does after every pointer event and tool switch; a tool
    /// whose cursor follows state that changes some other way (a key press) calls this. Asked while a
    /// change is delivered, the host hears it once the services have settled.
    public func refreshCursor() {
        cursorAsked = delivery != nil
        guard !cursorAsked else { return }
        delegate?.editorCursorDidChange(self)
    }

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
    /// The file's own values (`FileProperty`) change here too (`transaction.setFileValue`), in the
    /// same commit and the same step.
    ///
    /// A body that throws commits nothing, whatever it changed first: services hear of no change
    /// and no refusal, the board isn't edited, no undo step opens (what there was to redo stays),
    /// and the error comes out of `transact` (untyped: catch it and cast). Work that must happen
    /// whole, or not at all, goes through `transactWhole`, which gives it up when anything is refused
    /// and shakes what was.
    @discardableResult
    public func transact<T>(_ name: String? = nil, coalescing key: AnyHashable? = nil, _ body: (inout Transaction) throws -> T) rethrows -> T {
        try transact(name, coalescing: key, origin: .ordinary, body)
    }

    /// Whether a transaction may begin now: none is under way, no change is being delivered, and no step
    /// is being put back. What a view that commits as it's torn down asks first (a row's draft, as editing ends).
    public var canTransact: Bool { !isApplying && delivery == nil && !isTransacting }

    /// `origin` says whether an editing view commits (`EditContext`), whose commits are its session's step.
    func transact<T>(_ name: String?, coalescing key: AnyHashable?, origin: UndoHistory.Origin,
                     _ body: (inout Transaction) throws -> T) rethrows -> T {
        precondition(!isApplying, "nothing may transact while undo or redo puts a step back (a service's documentDidChange, say)")
        precondition(delivery == nil, "nothing may transact while services hear a change (a service's documentDidChange, say)")
        precondition(!isTransacting, "transactions don't nest; use the one you were given")
        if !isReplacingFile { undoHistory.willTransact(coalescing: key, origin: origin) }
        isTransacting = true
        var transaction = Transaction(document: document, board: board, isBoardReadOnly: isBoardReadOnly, registry: registry, camera: camera,
                                      keys: stackingKeys, file: fileAccess, layout: layoutSource)
        let result: T
        do {
            defer { isTransacting = false }
            result = try body(&transaction)
            // What it grew makes room below it, in the same step (MakingRoom.swift).
            if !isReplacingFile { transaction.makeRoom() }
        }
        // Committing can end editing, and an editing view may save as it closes: outside the
        // transaction, so it can.
        if transaction.hasChanges, isReplacingFile {
            commit(transaction)
        } else if transaction.hasChanges {
            undoHistory.willCommit(transaction.changes, from: storedFile, name: transaction.stepName ?? name, coalescing: key, origin: origin)
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
    /// take the board shown, or a board above it, with a shape it deletes (on its own board or, with
    /// `delete(_:on:)`, another), or that reaches the board shown (moving shapes onto it, or settling
    /// there), commits nothing: `document` would go stale.
    /// Returns nil, doing nothing, for a board the editor can't show (`canShow`). One of the file's
    /// own values set there (`setFileValue`) is the file's, as from any board: a transaction that
    /// sets nothing else says no board changed.
    @discardableResult
    public func transact<T>(on target: BoardID, _ name: String? = nil, _ body: (inout Transaction) throws -> T) rethrows -> T? {
        guard target != board else { return try transact(name, coalescing: nil, origin: .ordinary, body) }
        guard canShow(target) else { return nil }
        precondition(!isApplying, "nothing may transact while undo or redo puts a step back (a service's documentDidChange, say)")
        precondition(delivery == nil, "nothing may transact while services hear a change (a service's documentDidChange, say)")
        precondition(!isTransacting, "transactions don't nest; use the one you were given")
        isTransacting = true
        var transaction = Transaction(document: storedFile[target], board: target, isBoardReadOnly: registry.isReadOnly(board: target, in: storedFile),
                                      registry: registry, camera: leftCameras[target] ?? camera, keys: stackingKeys, file: fileAccess,
                                      layout: layoutSource)
        transaction.mayReachBoardShown = false
        transaction.boardShown = board
        let result: T
        do {
            defer { isTransacting = false }
            result = try body(&transaction)
            if !isReplacingFile { transaction.makeRoom() }
        }
        // The owners too: an empty board isn't among the boards a deletion takes. Whatever the transaction
        // deleted counts, on whichever board, brought there or not.
        guard transaction.hasChanges, transaction.changes.boardsRemoved.isDisjoint(with: boardPath),
              transaction.changes.removed.isDisjoint(with: boardPath.lazy.compactMap(\.owner)),
              transaction.deleted.isDisjoint(with: boardPath.lazy.compactMap(\.owner)),
              !transaction.changes.boardsReached.contains(board) else { return result }
        if isReplacingFile {
            commit(transaction, onHidden: target)
        } else {
            undoHistory.recordStep(on: target, name: transaction.stepName ?? name, changes: transaction.changes, from: storedFile) {
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

    /// Whether a shape can't change on its board, `holding`, by a rule of a plugin's or of a container it is in: the
    /// shape's part of `isReadOnly(inFile:)`, blind to the board (`isReadOnly(board:)`), for a caller that asks of
    /// many shapes of one board and asks the board once.
    public func isReadOnly(_ record: AnyShapeRecord, in holding: CanvasDocument) -> Bool { registry.isReadOnly(record, in: holding) }

    /// Whether a board of the file can't change: the shape that owns it can't (a rule says so of it,
    /// or of a container it's in), or the board that one is on can't, and so on up to the root, which
    /// always can (`isBoardReadOnly`, for the board shown, which this answers with). Nothing on it
    /// changes, and nothing goes on it. O(the board's depth). Observed through `document`, or, for the
    /// board shown, through `isBoardReadOnly`.
    public func isReadOnly(board target: BoardID) -> Bool {
        target == board ? isBoardReadOnly : registry.isReadOnly(board: target, in: file)
    }

    /// Whether `setTool` takes a tool: any, but one that places shapes (a kind's tool,
    /// `ShapeRegistrar.tool`, or the core's for shapes waiting to be placed, `placeLater`) on a board that
    /// can't change (`isBoardReadOnly`), so the toolbar dims those there, and their keys do nothing; and
    /// one a plugin in a kit gives while the kit is off in the file (`kits`), which the toolbar leaves out.
    /// Observed through `isBoardReadOnly` and `kits`.
    public func isToolEnabled(_ id: ToolID) -> Bool {
        (!isBoardReadOnly || !(registry.placingTools.contains(id) || id == .pendingPlacement)) && isOn(tool: id)
    }

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
    /// has just become read-only, or a kit's whose kit has just gone off) for the default tool, or for
    /// the Hand if that one isn't enabled either.
    private func leaveDisabledTool() {
        guard !isToolEnabled(currentToolID) else { return }
        setTool(isToolEnabled(registry.defaultTool) ? registry.defaultTool : .hand)
    }

    /// Something tried to change these read-only shapes, and didn't: services hear which
    /// (`EditorService.didRefuseChanges`: Selection shakes them), as they hear a transaction's
    /// refusals. `transactWhole` calls it for work it gave up whole, which no transaction committed
    /// to refuse (a paste a locked frame would take), and a plugin for a change it refuses before any
    /// transaction (a writer that finds the shape locked).
    public func refuseChanges(to ids: Set<ShapeID>) {
        for service in serviceOrder { service.didRefuseChanges(to: ids, in: self) }
    }

    /// The color a shape's symbol has wherever it is listed: the first color a plugin gives it
    /// (`registrar.shapeTints`: Colors', for a shape with a color of its own), else its kind's
    /// (`registry.label(of:).tint`); nil for a shape with neither. Asked per row shown, and once a
    /// shape as a board's preview is built (`boardPreviews`, which draws each shape in it), never per
    /// frame for every shape.
    public func tint(of record: AnyShapeRecord) -> NSColor? {
        ownTint(of: record) ?? registry.kindTint(of: record.kind)
    }

    /// The same for a shape of a known kind.
    public func tint<P: ShapeProps>(of shape: ShapeRecord<P>) -> NSColor? {
        tint(of: AnyShapeRecord(shape))
    }

    /// The color a plugin gives the shape's symbol (`registrar.shapeTints`), the first that has one;
    /// nil for a shape no plugin gives one, which has its kind's (`tint(of:)`). What a list of many
    /// shapes asks, with the kind's tint worked out once a kind.
    public func ownTint(of record: AnyShapeRecord) -> NSColor? {
        for rule in registry.shapeTintRules {
            if let tint = rule(record, self) { return tint }
        }
        return nil
    }

    /// Services hear that shapes' tints changed with no commit to them (the file's colors did): a
    /// plugin that gives tints (`registrar.shapeTints`) calls it, and a service that keeps what
    /// shows one makes it again (`EditorService.shapeTintsDidChange`). Boards' previews are built
    /// again in them as they're next drawn, each drawn as it was until then.
    public func shapeTintsDidChange() {
        boardPreviews.tintsDidChange()
        for service in serviceOrder { service.shapeTintsDidChange(in: self) }
    }

    /// Services hear that the host put back the view values an earlier session saved (`restoreViewValues`).
    func tellViewValuesRestored() {
        for service in serviceOrder { service.viewValuesDidChange(in: self) }
    }

    /// Services hear that a view kept while the view settled moved the camera (`keepViewAfterViewChange`).
    func tellViewKept(from old: Camera, to new: Camera) {
        for service in serviceOrder { service.viewWasKept(from: old, to: new, in: self) }
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
                   canShow: { [unowned self] in Self.canShow($0, in: storedFile, registry: registry) },
                   values: { [unowned self] in storedFile.fileValues },
                   standIns: { [unowned self] in registry.standInLookup?(self, $0) ?? [] },
                   namers: { [unowned self] in registry.namingLookup?(self, $0) ?? [] })
    }

    /// A board of the file: `document` for the one shown, else its shapes as the file has them
    /// (empty for a board with none). Observed through `document`.
    public func contents(of board: BoardID) -> CanvasDocument {
        board == self.board ? document : file[board]
    }

    /// The boards the editor can show, the root first, then down the tree, each once
    /// (`CanvasFile.showableBoards`, with the kinds that own boards): what reads every shape the editor
    /// can show walks, each board's shapes `contents(of:)`'s. `file.everyBoard` is every board, shown or
    /// not. Observed through `document`.
    public var showableBoards: [BoardID] { file.showableBoards(boardOwningKinds: registry.boardOwningKinds) }

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
    /// the new one's; the cameras boards were left with are kept. A menu waiting to be popped up
    /// (`popUpMenu`) is dropped. The file's own values (`FileProperty`) are the new file's, and services
    /// hear which differ (`ChangeSet.fileValues`, `BoardChange.fileValues`).
    @_spi(Host) public func replaceFile(with newFile: CanvasFile, showing requested: BoardID? = nil) {
        precondition(!isTransacting, "a file can't be replaced inside a transaction")
        precondition(delivery == nil, "a file can't be replaced while services hear a change")
        Self.expectAccepted(newFile, by: registry)
        isReplacingFile = true
        defer { isReplacingFile = false }
        dismissPopover()
        closeCard(.board)
        menuWaiting = nil
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
        laidOutSizes.forgetAll()
        let fileValues = newFile.fileValues.keysDiffering(from: storedFile.fileValues)
        if target == board {
            var changes = ChangeSet(from: storedDocument, to: newFile[board])
            changes.elsewhere = newFile.shapesChanged(from: storedFile, except: board)
            changes.fileValues = fileValues
            changes.priors = ChangeSet.Priors(file: storedFile)
            storedFile = newFile
            boardPath = newFile.path(to: board) ?? [.root]
            documentDidChange(to: newFile[board], changes: changes)
        } else {
            switchTool(to: registry.defaultTool)
            storedFile = newFile
            show(target, leaving: left, replacingFile: true, fileValues: fileValues)
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
        precondition(delivery == nil, "a file can't be changed while services hear a change")
        let old = storedFile
        var newFile = old, removed: Set<BoardID> = [], changed: Set<BoardID> = [], added: Set<BoardID> = []
        var fileValues: Set<PropertyKey> = []
        let byBoard = Dictionary(grouping: ids.filter { old.record($0)?.isOpaque == true }) { old.board(containing: $0)! }
        for (board, ids) in byBoard {
            // Refused by nothing: a read-only board's hidden shapes go too. Over the file as the shapes before
            // it left it, so what one's handlers wrote on another board is read by the next.
            var transaction = Transaction(document: newFile[board], board: board, isBoardReadOnly: false, registry: registry, camera: camera,
                                          keys: stackingKeys, file: FileAccess(newFile, boardOwningKinds: registry.boardOwningKinds), layout: nil)
            transaction.discard(Set(ids))
            // The board, and every other board a handler wrote on or brought, as a commit writes them.
            var written = [(board: board, document: transaction.document, changes: transaction.changes)], brought: [ShapeID: CanvasDocument] = [:]
            for (staged, document) in transaction.stagedBoards where staged != board && !transaction.changes.boardsRemoved.contains(staged) {
                if transaction.changes.boardsChanged.contains(staged) {
                    written.append((staged, document, ChangeSet(from: newFile[staged], to: document)))
                    changed.insert(staged)
                } else if let owner = staged.owner {
                    brought[owner] = document
                    added.insert(staged)
                }
            }
            newFile.set(written)
            newFile.insertBoards(brought)
            removed.formUnion(transaction.changes.boardsRemoved)
            // What a `willDelete` handler set of the file's own values.
            if let values = transaction.stagedFileValues {
                for key in transaction.changes.fileValues { newFile.fileValues[key] = values[key] }
                fileValues.formUnion(transaction.changes.fileValues)
            }
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
        changes.priors = ChangeSet.Priors(file: old)
        changes.replacedDocument = false
        changes.boardsRemoved = removed
        changes.boardsChanged = Set(byBoard.keys).union(changed).subtracting(removed).subtracting([board])
        changes.boardsAdded = added.subtracting(removed)
        changes.elsewhere = newFile.shapesChanged(from: old, except: board)
        changes.fileValues = fileValues
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
        writeFileValues(of: transaction)
        // One that only set the file's values wrote no board: none is stamped, and the board shown is as it was.
        guard transaction.didChange else { return documentDidChange(to: storedDocument, changes: changes) }
        changes.priors = priors(of: board, reaching: changes)
        changes.elsewhere = writeBoards(of: transaction, own: (board, transaction.document, changes))
        documentDidChange(to: transaction.document, changes: changes)
    }

    /// Writes the file's own values a transaction set (`setFileValue`) through to the file.
    private func writeFileValues(of transaction: Transaction) {
        guard !transaction.changes.fileValues.isEmpty, let values = transaction.stagedFileValues else { return }
        storedFile.fileValues = values
    }

    /// Writes a transaction on a board that isn't shown (`transact(on:)`) through to the file, and
    /// tells services as a commit that changed that board and those it took, brought or changed (shapes
    /// moved onto them, or settled there): the board shown is as it was.
    private func commit(_ transaction: Transaction, onHidden target: BoardID) {
        let local = transaction.changes
        var changes = ChangeSet()
        changes.byAgent = local.byAgent
        changes.fileValues = local.fileValues
        writeFileValues(of: transaction)
        // One that only set the file's values changed no board, its own included.
        if transaction.didChange {
            changes.priors = priors(of: target, reaching: local)
            changes.boardsChanged = local.boardsChanged.union([target])
            changes.boardsAdded = local.boardsAdded
            changes.boardsRemoved = local.boardsRemoved
            changes.elsewhere = writeBoards(of: transaction, own: (target, transaction.document, local)).union(local.shapeIDs)
        }
        documentDidChange(to: storedDocument, changes: changes)
    }

    /// The boards a commit on `board` changes, as they are before it writes them, for `ChangeSet.before(_:)`:
    /// that one, and those it changes or takes (`boardsChanged`, `boardsRemoved`). Each a value the file lets go
    /// of as it writes, so keeping it copies nothing.
    private func priors(of board: BoardID, reaching changes: ChangeSet) -> ChangeSet.Priors {
        ChangeSet.Priors(boards: [board == self.board ? storedDocument : storedFile[board]]
                         + changes.boardsChanged.union(changes.boardsRemoved).map { storedFile[$0] })
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
    /// of the file (each with a new revision, so nothing kept about one is taken for it), the file's
    /// own values it names go back or come again, and services hear it as a transaction's.
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
        beginDelivery(.commit(changes))
        // Before services hear the commit, which may have locked the board's owner (a commit on the
        // board above, `transact(on:)`) or put another file in place, or turned a kit on or off.
        let becameReadOnly = noteBoardReadOnly()
        let kitWentOff = changes.fileValues.contains(KitsOn.key) && noteKits()
        forgetLaidOutSizes(after: changes)
        shapeIndex.documentDidChange(changes, in: newDocument, registry: registry)
        for id in changes.removed where drawingOffsets[id] != nil { drawingOffsets[id] = nil }
        // A shape gliding that something changes is where it is now.
        if !glides.isEmpty { endGlides(changes.shapeIDs.filter { glides[$0] != nil }) }
        if let shape = shownCard?.shape, changes.removed.contains(shape) { closeCard(.shapeGone) }
        // Services drop what no longer names a shape, as the hint's setter does.
        finishDelivery()
        if !changes.added.isEmpty || !changes.removed.isEmpty {
            delegate?.editorShapesDidComeOrGo(self, added: changes.added, removed: changes.removed)
        }
        hintedShapeID = hintedID
        // A shape that's gone, can no longer change (it, a container it's in, or its board), or is of
        // another kind now (turned, `Transaction.turn`), isn't edited.
        if let editing = editingShapeID,
           document[editing].map({ isBoardReadOnly || registry.isReadOnly($0, in: newDocument) || $0.kind != editedKind }) ?? true {
            endEditing(discarding: false)
        }
        if becameReadOnly || kitWentOff { leaveDisabledTool() }
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
        precondition(delivery == nil, "a board can't be shown while services hear a change")
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
    private func show(_ target: BoardID, leaving left: Camera, replacingFile: Bool = false, fileValues: Set<PropertyKey> = []) {
        // A step is the board's it was made on: the one under way closes here.
        undoHistory.close()
        dismissPopover()
        closeCard(.board)
        leftCameras[board] = left
        leftOrder.removeAll { $0 == board }
        leftOrder.append(board)
        let change = BoardChange(from: board, to: target, leftCamera: left, left: storedDocument, shown: storedFile[target],
                                 isFileReplaced: replacingFile, fileValues: fileValues)
        withMutation(keyPath: \.document) { storedDocument = storedFile[target] }
        cameraBeforeFit = nil
        keptView = nil
        board = target
        boardPath = storedFile.path(to: target) ?? [.root]
        // Whether this board takes shapes, and which kits a file put in place has on, before services hear of it.
        _ = noteBoardReadOnly()
        _ = noteKits()
        shapeIndex = warmIndexes.take(for: target, in: self) ?? ShapeIndex()
        hintedID = nil
        drawingOffsets = [:]
        glides = [:]
        glideFrame?.cancel()
        glideFrame = nil
        // What the board left asked for isn't drawn now; what this one draws asks for its own.
        boardPreviews.stopWaiting()
        revision += 1
        // A first visit's fit lays the board out, asking services for what its shapes are laid out by: each
        // takes the switch in first.
        beginDelivery(.board(change))
        isShowingBoard = true
        camera = arrivalCamera(for: target)
        isShowingBoard = false
        finishDelivery()
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
            let clear = clearView, camera = cameraTarget
            return BoardReading(board: board, document: document, shapes: shapeContext, index: shapeIndex,
                                view: clear.rect.isEmpty ? nil : camera.toWorld(clear.rect), covered: clear.covered.map { camera.toWorld($0) },
                                isBoardReadOnly: isBoardReadOnly)
        }
        guard canShow(target) else { return nil }
        let contents = file[target]
        let arrival = arrivalCamera(for: target) {
            let index = ShapeIndex()
            return index.bounds(in: ShapeContext(document: contents, registry: registry, camera: Camera(), index: index, layout: layoutSource))
        }
        let index = ShapeIndex(), clear = clearView(on: target)
        return BoardReading(board: target, document: contents,
                            shapes: ShapeContext(document: contents, registry: registry, camera: arrival, index: index, layout: layoutSource), index: index,
                            view: clear.rect.isEmpty ? nil : arrival.toWorld(clear.rect), covered: clear.covered.map { arrival.toWorld($0) },
                            isBoardReadOnly: isReadOnly(board: target))
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
        // The shapes waiting to be placed go with their tool.
        if old == .pendingPlacement { pendingPlacement = nil }
        hintedShapeID = nil
        for service in serviceOrder { service.toolDidChange(from: old, to: id, in: self) }
        setNeedsDisplay()
        refreshCursor()
    }

    /// Where place tools (and any plugin with a `Placement`) create shapes: the shape goes in, the
    /// default tool comes back (unless the tool is locked, `isToolLocked`, when it stays), services hear
    /// `didPlace` (the selection selects it), and, while the
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
    /// The insert names its undo step "Add" and the placing tool's label ("Add Note"), which VoiceOver hears.
    public func place(_ placement: Placement, at point: CGPoint) {
        put(placement.shape(at: point), placing: placement, from: undoHistory.isPressHeld && session == nil ? point : nil)
    }

    /// The placing tool's shape put down without the pointer (Return with the Note tool picked, Selection's
    /// key): what the current tool places (`registry.placement(for:)`, the tool's own), centered on the
    /// pointer while it is over the canvas (`isPointerOverCanvas`), else on the middle of the view's clear part
    /// (`unobscuredViewport`), as `place(_:at:)` puts it with no press: settled at once, the default tool back
    /// unless the tool is locked, and an editing placement's shape edited. False, and nothing done, when the
    /// current tool places nothing, a press is under way, a shape is being edited, or the view has no size and
    /// the pointer isn't over it.
    /// With shapes waiting to be placed (`placeLater`), it puts them where they're drawn, as `putPending` does.
    @discardableResult
    public func placeAtKeyboard() -> Bool {
        guard session == nil, editingShapeID == nil else { return false }
        if currentToolID == .pendingPlacement { return putPending() }
        guard let placement = registry.placement(forTool: currentToolID) else { return false }
        let view = unobscuredViewport
        guard isPointerOverCanvas || !view.isEmpty else { return false }
        place(placement, at: isPointerOverCanvas ? pointerWorldLocation : camera.toWorld(CGPoint(x: view.midX, y: view.midY)))
        return true
    }

    /// Puts one down with this frame (world units), where `place(_:at:)` centers one of its size on a
    /// point: what a tool that draws its shape's rect with a drag puts down at the release (the Frame
    /// tool). As `place(_:at:)` with no press under way: it settles at once (into a container, or out,
    /// gliding there), in the step under way, a read-only container or board refusing it (nothing is
    /// placed, and the container, or the board's owner, is heard refused); the default tool comes back
    /// (unless the tool is locked), services hear `didPlace`, and an editing placement's shape is edited.
    /// It never follows the pointer.
    ///
    /// Returns the new shape's id; nil when nothing was put down (a read-only board, or a read-only container
    /// that wouldn't take it).
    @discardableResult
    public func place(_ placement: Placement, in frame: CGRect) -> ShapeID? {
        let record = placement.make(frame)
        put(record, placing: placement, from: nil)
        return document[record.id] != nil ? record.id : nil
    }

    /// Puts a new container down around shapes on the board shown, holding them (Frames' Create
    /// Frame): `shape`, of a `ShapeContaining` kind, its id new to the file, framed around those of
    /// `ids` with a box (and what's bound to them alone among `ids`, an arrow between two of them), grown
    /// by `padding` and to `minimumSize` (world units), in the innermost container they're all in, just
    /// below the lowest of them in the stack (`Transaction.enclose`). They stay where they are; what it
    /// lands on beside them is settled as what a container's drawn over is, gliding there. One step,
    /// named as a placement's ("Add Frame", unless a group it's in names it); the default tool comes
    /// back (unless the tool is locked), and services hear `didPlace` (the selection selects it). All or nothing: if one it would
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
        // Nothing to hold, or a refusal, gives it all up: nothing is put down, no step is left, and the refused shake.
        let placed = transactWhole("Add \(registry.label(of: shape.kind).name)") { transaction -> [ShapeID: CGPoint] in
            guard let nudges = transaction.enclose(ids, in: shape, padding: padding, minimumSize: minimumSize)
            else { throw Transaction.Refused() }
            return nudges
        }
        guard let nudges = placed else { return nil }
        if !isToolLocked { setTool(registry.defaultTool) }
        for service in serviceOrder { service.didPlace([shape.id], in: self) }
        glide(nudges)
        return shape.id
    }

    /// Shows shapes about to be placed together (`PendingPlacement`), on the core's own tool for them
    /// (`ToolID.pendingPlacement`, which no toolbar lists): drawn faint where they'd be put down (the
    /// pointer while it's over the canvas, else their bounds in the middle of the view's clear part), each
    /// where the placement arranges it for the keys held (`modifiersHeld`), so a key held (⌥) may lay them
    /// out another way. A press puts them down there and they follow the pointer while it lasts, settling
    /// on the release, as `place(_:at:)` puts one; Return puts them where they're drawn, settled at once
    /// (`placeAtKeyboard`); either way in one step named by the placement, the default tool back whatever
    /// the tool lock (they're put down once), and services hear `didPlace` with every one (Selection
    /// selects them all). Escape, another tool, another board, editing a shape, an undo or a redo, a card
    /// shown or the board becoming read-only lets them go, nothing placed. False, showing nothing, for no records, a press under way,
    /// or a board that can't change (`isToolEnabled`).
    @discardableResult
    public func placeLater(_ placement: PendingPlacement) -> Bool {
        guard !placement.records.isEmpty, session == nil, isToolEnabled(.pendingPlacement) else { return false }
        endEditing()
        pendingPlacement = placement
        switchTool(to: .pendingPlacement)
        setNeedsDisplay()
        return true
    }

    /// Whether shapes wait to be placed (`placeLater`).
    public var isPlacingLater: Bool { pendingPlacement != nil }

    /// Shapes waiting to be placed go, their tool left for the default one: as a shape is edited, an undo or
    /// a redo changes the board under them, or a card shows (the command bar, a row's card).
    func letWaitingShapesGo() {
        if currentToolID == .pendingPlacement { switchTool(to: registry.defaultTool) }
    }

    /// The shapes waiting to be placed (`placeLater`), their boxes where they'd be put down now, for the
    /// keys held: what a frame draws faint, and the overlays decorate (`OverlayContext.pendingShapes`).
    /// None while none wait, and with the pointer off the canvas and no view to put them in the middle of.
    public var pendingShapes: [AnyShapeRecord] {
        guard let pendingPlacement, let point = pendingPoint(of: pendingPlacement) else { return [] }
        return pendingPlacement.records(at: point, for: modifiersHeld)
    }

    /// Where waiting shapes would be put down now: the pointer while it's over the canvas, else the point
    /// that puts their bounds in the middle of the view's clear part (where Return puts them); nil for
    /// neither.
    private func pendingPoint(of placement: PendingPlacement) -> CGPoint? {
        if isPointerOverCanvas { return pointerWorldLocation }
        let view = unobscuredViewport
        guard !view.isEmpty else { return nil }
        let middle = camera.toWorld(CGPoint(x: view.midX, y: view.midY)), bounds = placement.bounds(for: modifiersHeld)
        guard !bounds.isNull else { return middle }
        return CGPoint(x: middle.x - bounds.midX, y: middle.y - bounds.midY)
    }

    /// Puts the waiting shapes down (`placeLater`), arranged for the keys held: at `press` (world units),
    /// following the pointer while the press lasts, or with none where they're drawn, settled at once (a
    /// refusal there leaves nothing placed and them waiting, the container shaking). False, doing nothing,
    /// with none waiting, nowhere to put them, or the board read-only (its owner heard refused).
    @discardableResult
    func putPending(pressedAt press: CGPoint? = nil) -> Bool {
        guard let placement = pendingPlacement, let point = press ?? pendingPoint(of: placement) else { return false }
        guard !isBoardReadOnly else {
            if let owner = board.owner { refuseChanges(to: [owner]) }
            return false
        }
        let records = placement.records(at: point, for: modifiersHeld), ids = records.map(\.id)
        let follows = press != nil && undoHistory.isPressHeld && session == nil
        let before = follows ? undoHistory.snapshots() : [:]
        var nudges: [ShapeID: CGPoint] = [:]
        if follows || registry.containingKinds.isEmpty {
            transact(placement.stepName) { transaction in
                for record in records { transaction.insert(record) }
            }
        } else {
            guard let landed = transactWhole(placement.stepName, { transaction in
                for record in records { transaction.insert(record) }
                return transaction.settle(ids)
            }) else { return false }
            nudges = landed.nudges
        }
        // Put down once: the default tool back whatever the lock, and the waiting shapes with their tool.
        setTool(registry.defaultTool)
        for service in serviceOrder { service.didPlace(ids, in: self) }
        if let press, follows {
            session = PlacingSession(ids, from: press, edits: false, restoring: before, in: self)
            return true
        }
        glide(nudges)
        return true
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
        let settled = placement.completion == .settled
        let follows = point != nil && !settled
        let before = follows ? undoHistory.snapshots() : [:]
        var nudges: [ShapeID: CGPoint] = [:]
        if follows || registry.containingKinds.isEmpty {
            transact("Add \(label ?? "Shape")") { $0.insert(record) }
        } else {
            // A refusal throws the insert away with it: nothing is placed, and the container shakes.
            guard let landed = transactWhole("Add \(label ?? "Shape")", { transaction in
                transaction.insert(record)
                return transaction.settle([record.id])
            }) else { return }
            nudges = landed.nudges
        }
        // Settled: put down and left at that, the selection, the tool and the keyboard where they are.
        if settled { return glide(nudges) }
        if !isToolLocked { setTool(registry.defaultTool) }
        for service in serviceOrder { service.didPlace([record.id], in: self) }
        // VoiceOver hears the step the Undo menu names ("Add Table", or the group's: "Create Database"), as it hears a row's
        // commit, however it was put down (a tool's click, Insert, ⇧↩); a command's own words, once, are the bar's. A placement
        // settled is part of the step that made it (a line's commit), heard there.
        if document[record.id] != nil, !isSayingStep { announce(undoHistory.undoName ?? "Add \(label ?? "Shape")") }
        let edits = placement.completion == .edit
        if let point, session == nil {
            session = PlacingSession([record.id], from: point, edits: edits, restoring: before, in: self)
            return
        }
        // Its editing view is laid out where it is.
        if edits { nudges[record.id] = nil }
        glide(nudges)
        if edits { beginEditing(record.id) }
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

    // Running a command a plugin declared (`perform`, `canPerform`, `attempt`) is in Commands.swift.

    // MARK: Input, for tools and sessions

    /// World units, through the current camera.
    public var pointerWorldLocation: CGPoint { camera.toWorld(tracker.location) }
    /// Whether the pointer is over the canvas itself, not over the minimap, the editing view or a view the
    /// host puts over it, nor outside the window: whether `pointerWorldLocation` is a place on the board
    /// where the person is pointing. The host tells it (a move, a press or a gesture on the canvas says
    /// yes; the pointer leaving it, no), whatever the tool; false until the pointer has been seen there.
    /// Not observed.
    public var isPointerOverCanvas: Bool { pointerIsOverCanvas }
    /// Whether the canvas view has the keyboard (is its window's first responder), as the host tells it
    /// (`keyboardDidChange`): false while a panel's field, a card or the editing view over a shape has it.
    /// True with no view (a test's editor). Each change asks for a frame, so what is drawn by it (the
    /// selection's outline, quieter without it) follows. Not observed.
    public var hasKeyboard: Bool { canvasHasKeyboard }
    /// View points per millisecond, smoothed.
    public var pointerSpeed: CGFloat { tracker.speed }
    /// View points per millisecond, per axis, smoothed like `pointerSpeed`; reset on every press.
    public var pointerVelocity: CGPoint { tracker.velocity }
    /// Held now, plus any released within `Style.modifierReleaseDelay`.
    public var effectiveModifiers: Modifiers { liveModifiers().union(recentlyReleased) }
    /// The keys held, as the host last heard them: a change anywhere in the canvas's window, whatever
    /// has the keyboard, and every pointer event the canvas hears. Observed, and set only when it
    /// changes, so what shows something while a key is held follows the key with no pointer move
    /// (Neighbors' lights). A key let go is let go at once, unlike `effectiveModifiers`; none while the
    /// window isn't key.
    public internal(set) var modifiersHeld: Modifiers = []

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
        letWaitingShapesGo()
        editingStartPoint = point
        editingStartClickCount = point == nil ? 1 : clickCount
        editingShapeID = id
        // Laid out afresh as editing begins and again as it ends, before its view is made: what lays a shape out may read
        // whether it's the one edited (a typed note keeps a line for its words then, so the caret sits above its rows).
        shapesDidChangeLayout([id])
        undoHistory.editingBegan(stepName: (registry.definition(for: record.kind) as? any Editable)?.editingStepName)
        dismissPopover()
        closeCard(.editing)
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
        // While the editing view still stands, so the keyboard goes back to it, and the host then
        // takes it from there.
        closeCard(.editing)
        let mayDiscard = discarding && !undoHistory.isInAction
        editingShapeID = nil
        editingPart = nil
        editingStartPoint = nil
        editingStartClickCount = 1
        shapesDidChangeLayout([id])
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
    /// too, so that a frame costs what's in view rather than what's on the board. Only those of
    /// `drawnShapes`, when it says some.
    public func paintOrder(in rect: CGRect) -> [AnyShapeRecord] {
        var shown: [AnyShapeRecord] = []
        forEachShape(in: rect) { record, _ in shown.append(record) }
        return shown
    }

    /// The shapes in a world rect that are painted just below their anchor (`PaintOrderAnchored.paintsBelowAnchor`: a key, under
    /// the cards it joins), back to front: nothing, at no cost, on a board with none, and otherwise a look at what is in the rect
    /// for them, never the shapes themselves (what draws over the cards those pass beneath asks this each frame).
    public func shapesPaintedBelowAnchor(in rect: CGRect) -> [AnyShapeRecord] {
        let context = shapeContext
        let below = shapeIndex.belowAnchor(in: context)
        guard !below.isEmpty else { return [] }
        var found: [AnyShapeRecord] = []
        forEachShape(in: rect) { record, _ in if below.contains(record.id) { found.append(record) } }
        return found
    }

    /// `paintOrder(in:)`'s shapes, back to front, each with its kept extent (world units): the one rule for what
    /// may show in a rect, for what reads the extents too (VoiceOver's shapes in view, ranked by their middles).
    func forEachShape(in rect: CGRect, _ body: (AnyShapeRecord, CGRect) -> Void) {
        let context = shapeContext
        // The shapes whose extent meets the rect, found in the cells it covers (`ShapeIndex.positions`), not by going
        // through every shape.
        let positions = shapeIndex.positions(touching: rect, in: context)
        guard !positions.isEmpty else { return }
        let list = shapeIndex.paintList(in: context), shapes = document.shapes, only = drawnShapes, hidden = shapeIndex.hidden
        // The shape being edited, laid out larger than it stores (a line typed longer than it is, its waiting line), is painted
        // after the rest, so what its widening now overlaps (a shape put down beside it) never covers its rows while the caret is
        // in it. Nothing moves: it is back in its place in the order as it stops being larger, or edited.
        let lifted = liftedWhileEdited(in: context)?.id
        var held: (record: AnyShapeRecord, extent: CGRect)?
        for position in positions {
            let record = shapes[list.order[position]]
            if let only, !only.contains(record.id) { continue }
            // Drawn as part of another (`ShapeGeometry.isHidden`: an arrow bundled under its lead): never shown on its own.
            if !hidden.isEmpty, hidden.contains(record.id) { continue }
            if record.id == lifted {
                held = (record, list.extents[position])
                continue
            }
            body(record, list.extents[position])
        }
        if let held { body(held.record, held.extent) }
    }

    /// The shape edited, where it is laid out larger than it is at rest (wider: a line typed longer than it is; taller: its waiting
    /// line) and holds no shapes (a container's would be covered): painted, and hit, above the shapes in its way until it is back
    /// to its size or no longer edited. With the frame it is laid out in and the frame it has at rest: laid out without what is
    /// set for it while it's handled, as `makeRoom()` measures it, never its stored box, whose height a kind laid out by its rows
    /// keeps from when it was made (review R25: a table typed to ten rows stores one).
    func liftedWhileEdited(in context: ShapeContext) -> (id: ShapeID, frame: CGRect, box: CGRect)? {
        guard let id = editingShapeID, let record = document[id], record.box != nil, !registry.isContainer(record),
              let frame = context.frame(of: record), let rest = restingFrame(of: record),
              frame.width > rest.width + Self.liftSlack || frame.height > rest.height + Self.liftSlack else { return nil }
        return (id, frame, rest)
    }

    /// `record`'s frame at rest (`LayoutReading.isResting`, the values set for it while it's handled left out), kept until the
    /// file or the layout changes: what the shape edited is lifted beyond.
    private func restingFrame(of record: AnyShapeRecord) -> CGRect? {
        if let kept = restingEdited, kept.id == record.id, kept.revision == revision, kept.layout == layoutRevision { return kept.frame }
        let editor = layoutSource
        let source = LayoutSource(inputs: layoutInputs, sizes: laidOutSizes, lend: editor.lend, shape: editor.shape, board: editor.board,
                                  fileValues: editor.fileValues, isChanged: { _ in true }, writes: [], run: LayoutSource.nextRun(), isResting: true)
        let frame = ShapeContext(document: document, registry: registry, camera: camera, index: nil, layout: source).frame(of: record)
        restingEdited = frame.map { (record.id, revision, layoutRevision, $0) }
        return frame
    }

    /// The shape edited's frame at rest, as of a revision of the file and of the layout (`restingFrame(of:)`).
    @ObservationIgnored private var restingEdited: (id: ShapeID, revision: Int, layout: Int, frame: CGRect)?

    /// Where the shape edited is laid out beyond the box it stores (its widening, its waiting line's room), world units, and the
    /// shape: nil where it is laid out in its box. A plugin that draws over the shapes (pills, chips) leaves what it draws for
    /// another shape out of these, so what the shape edited draws there is never covered while the caret is in it.
    public var editedShapeOverflow: (id: ShapeID, areas: [CGRect])? {
        guard let lifted = liftedWhileEdited(in: shapeContext) else { return nil }
        var areas: [CGRect] = []
        if lifted.frame.maxX > lifted.box.maxX {
            areas.append(CGRect(x: lifted.box.maxX, y: lifted.frame.minY, width: lifted.frame.maxX - lifted.box.maxX, height: lifted.frame.height))
        }
        if lifted.frame.maxY > lifted.box.maxY {
            areas.append(CGRect(x: lifted.frame.minX, y: lifted.box.maxY, width: lifted.frame.width, height: lifted.frame.maxY - lifted.box.maxY))
        }
        return (lifted.id, areas)
    }

    /// How much wider than it stores an edited shape is laid out before it is painted above the rest, world units.
    private static let liftSlack: CGFloat = 0.5

    /// The shapes of the board shown that are drawn, nil for all of them: a picture of some of a
    /// board's shapes (Edit › Copy as Image, `BoardPicture(file:registry:board:showing:)`), whose
    /// other shapes are there to be read (a type its notes are of, what a mention names) and not drawn.
    /// It goes by `paintOrder(in:)`, and so does everything that draws on the canvas. Not observed.
    @ObservationIgnored @_spi(Host) public var drawnShapes: Set<ShapeID>? {
        didSet { setNeedsDisplay() }
    }

    /// Whether any shape of the board shown is drawn as part of another (`ShapeGeometry.isHidden`: a bundle's member arrow), as far
    /// as the shapes laid out so far say. False where nothing is, so what only matters for such shapes (Selection's taking a hidden
    /// pick with its unit) costs nothing there, and asks no plugin.
    public var hasHiddenShapes: Bool { !shapeIndex.hidden.isEmpty }

    /// The front-most shape under a world point, of those `include` accepts. Only shapes near the
    /// point are asked (see `ShapeDefinition.hitMargin`).
    public func shape(at point: CGPoint, where include: (AnyShapeRecord) -> Bool = { _ in true }) -> ShapeID? {
        let context = shapeContext
        // Front to back, those near enough to be asked (`ShapeIndex.mayHit`), found in the cells round the point.
        let positions = shapeIndex.positions(mayHit: point, zoom: camera.zoom, in: context)
        guard !positions.isEmpty else { return nil }
        let list = shapeIndex.paintList(in: context), shapes = document.shapes, hidden = shapeIndex.hidden
        // The shape edited, painted above what its widening overlaps, is hit first there too.
        if let lifted = liftedWhileEdited(in: context)?.id, let record = document[lifted], let index = document.index(of: lifted),
           positions.contains(list.positions[index]), include(record),
           registry.definition(for: record.kind)?.erasedHitTest(point, on: record, in: context) == true {
            return lifted
        }
        for position in positions {
            let record = shapes[list.order[position]]
            // A shape drawn as part of another is hit as that one (its lead), never itself.
            if !hidden.isEmpty, hidden.contains(record.id) { continue }
            if include(record), registry.definition(for: record.kind)?.erasedHitTest(point, on: record, in: context) == true {
                return record.id
            }
        }
        return nil
    }
}

/// A change every service hears, as the editor delivers it (`beginDelivery`, `finishDelivery`): a commit's change
/// set, or another board shown.
private enum ServiceChange {
    case commit(ChangeSet)
    case board(BoardChange)
}

/// The change being delivered, and whether every service has it and they're settling.
private struct Delivery {
    let change: ServiceChange
    var isSettling = false
}

/// A service taking the change being delivered in: busy until its hook returns, and then what it asked to do once
/// it had the change (`onceHeard`).
private struct Hearing {
    let service: Int
    var isBusy = true
    var then: [@MainActor () -> Void] = []
}
