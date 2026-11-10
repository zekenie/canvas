import Canvas
import CoreGraphics
import Geometry

/// The zoom a kind's shapes read at, where its text is set smaller than a note's 16 points (11
/// points reads at 100%): going to one (`goTo`) brings it at least that close. A kind that says
/// nothing reads at `SelectionStyle.readableZoom`, 70%. At most one per kind, plus one for every
/// kind (`.any`), which a kind's own overrides; each above zero and at most `maximum`, 120%, as close
/// as going to a shape brings it (`reveal`'s closest).
public enum ReadableZoom {
    /// The closest going to shapes brings them (`reveal`, data-canvas's and tldraw's 120%), and so
    /// the closest a kind can say it reads at.
    public static let maximum: CGFloat = 1.2
}

extension ReadableZoom: KeyedExtensionPoint {
    public typealias Contribution = CGFloat
    public static var owner: PluginID { .selection }
    public static func uniqueKeys(of _: CGFloat, for target: ShapeTarget) -> [AnyHashable] { [target] }

    public static func check(_ registry: Registry) throws(RegistryError) {
        for zoom in registry.contributions(to: ReadableZoom.self) {
            guard zoom.value > 0, zoom.value.isFinite else {
                throw .invalid(point: "ReadableZoom", reason: "\(zoom.pluginID) says \(zoom.target) reads at \(zoom.value), which isn't a zoom")
            }
            guard zoom.value <= maximum else {
                throw .invalid(point: "ReadableZoom",
                               reason: "\(zoom.pluginID) says \(zoom.target) reads at \(zoom.value), closer than going to a shape brings it (\(maximum))")
            }
        }
    }
}

extension ShapeRegistrar {
    /// Its shapes read at `zoom` or closer (1 is 100%; at most 120%, `ReadableZoom.maximum`): going
    /// to one (`goTo`) brings it at least that close, where one of a kind that says nothing is left
    /// at 70%. For a kind whose text is set smaller than a note's: 11-point text reads at 100%.
    public mutating func readableZoom(_ zoom: CGFloat) {
        contribute(zoom, to: ReadableZoom.self)
    }
}

extension PluginRegistrar {
    /// The zoom a kind another plugin registers reads at, as `readableZoom` on a kind's
    /// own registrar.
    public mutating func readableZoom<P: ShapeProps>(_: P.Type, _ zoom: CGFloat) {
        contribute(zoom, to: ReadableZoom.self, for: .kind(P.kind))
    }
}

/// Where the editor was as a way around that spans many calls began (`editor.navigationStart`):
/// what Back returns to after it (`editor.navigate(from:_:)`).
public struct NavigationStart: Equatable, Sendable {
    public let board: BoardID
    public let selection: [ShapeID]
    public let camera: Camera
    /// Which start this is, a new one each time one is taken: the step back the way around puts on the
    /// history carries it, so a later call finds that step, never an older place that looks the same.
    let serial: Int
}

// Going to shapes, one way for every plugin that brings shapes into view: the table of contents
// (a row's click), and whatever links to a shape (a mention in text). data-canvas's navigateToShape.
extension CanvasEditor {
    /// Brings the shapes into view: centers their bounds (`shapeContext.bounds(of:)`) in the part of
    /// the view the host leaves clear (`unobscuredViewport`: below the path over a subboard's canvas),
    /// zoomed to fit with 100 points of margin in all but no closer than 120%, and moves the camera
    /// there over 200 ms, as data-canvas's table of contents does (tldraw's zoomToBounds); a fit kept
    /// while the view settles (`animateCamera(toFit:…)`), so the inspector the selection shows,
    /// sliding in beside the canvas, leaves them fitted in what's left. What selecting rows of the
    /// table of contents does, and Zoom to Selection. Only on the board shown (`goTo` goes to shapes
    /// on another). Does nothing before the view has a size, or when none of the shapes has bounds
    /// (none is on the board shown). The person is where it takes them, as Back judges it (`settle`).
    public func reveal(_ ids: [ShapeID]) {
        guard let bounds = shapeContext.bounds(of: ids) else { return }
        animateCamera(toFit: bounds, inset: SelectionStyle.revealInset, maxZoom: SelectionStyle.revealMaxZoom,
                      duration: SelectionStyle.revealDuration)
        settleIfSelected(ids)
    }

    /// The person is where bringing `ids` into view took them, as Back judges it (`settle`), when what
    /// it brought is selected: shapes revealed that aren't (a Find hit) move the camera alone, as a pan.
    private func settleIfSelected(_ ids: [ShapeID]) {
        guard let state = selectionState, ids.contains(where: state.selectedSet.contains) else { return }
        state.settle()
    }

    /// Brings the shapes into view only if they are not all in it (tldraw's `zoomToSelectionIfOffscreen`,
    /// what stepping from shape to shape does): in what the host leaves clear of the view as it is headed (the
    /// inspector the selection shows counted before it has slid in, and the minimap's corner left out: `clearView`), where the camera is headed, with the row
    /// above their top (a title's pill) counted as theirs, the camera stays. Otherwise it moves over 200 ms by
    /// the least pan that brings them in, `SelectionStyle.revealMargin` in from the edges, at the zoom it has
    /// (`animateCamera(toShow:…)`), never centering them, so what was beside them in view stays there; and
    /// `keeping` (the shape a new one was put down beside), when the two fit in view together, is kept in view
    /// with them; failing that, `orKeeping` (a part of it: the row a card hangs from) where that fits. Shapes too big to fit at that zoom are fitted, farther out (never closer, which `reveal`
    /// brings small shapes to); with `zoomingOut` false they are panned to, their top-left in view, and the
    /// zoom kept. With `zoomingIn`, a view so far out the canvas draws skeletons (`drawsSkeletons`), where what was brought
    /// would land as a sketch nobody reads (a paste after an undo left the view at 10%: UX walk 5 paste-5-2), is zoomed in to
    /// fit them (with `keeping` where that is closer than the view is now), no closer than 100% (`SelectionStyle.readableFitMaxZoom`), in view or
    /// not, never farther out than the view is (a fit that is, is the ordinary reveal). Does nothing before the view has a
    /// size, or when none of the shapes has bounds.
    public func revealIfOffscreen(_ ids: [ShapeID], keeping: [ShapeID] = [], orKeeping second: CGRect? = nil, zoomingOut: Bool = true,
                                  zoomingIn: Bool = false) {
        guard let bounds = shapeContext.bounds(of: ids) else { return }
        if zoomingIn, drawsSkeletons, !unobscuredViewport.isEmpty {
            // Fitted with what it was put beside (`keeping`) where that is closer than the view is now, else alone; a fit no closer
            // than the camera's own leaves the view as it is for the ordinary reveal below (a block in view stays where it is).
            let view = unobscuredViewport, zoom = cameraTarget.zoom
            let candidates = [keeping.isEmpty ? nil : shapeContext.bounds(of: keeping).map { $0.union(bounds) }, bounds].compactMap { $0 }
            if let rect = candidates.first(where: {
                Camera(fitting: $0, in: view, inset: SelectionStyle.revealInset, maxZoom: SelectionStyle.readableFitMaxZoom).zoom > zoom
            }) {
                animateCamera(toFit: rect, inset: SelectionStyle.revealInset, maxZoom: SelectionStyle.readableFitMaxZoom,
                              duration: SelectionStyle.revealDuration)
                settleIfSelected(ids)
                return
            }
        }
        guard revealIfOffscreen(rect: bounds, keeping: [shapeContext.bounds(of: keeping), second].compactMap { $0 }, withRowAbove: true,
                                zoomingOut: zoomingOut, settling: false)
        else { return }
        settleIfSelected(ids)
    }

    /// The same, keeping in view with them the first of `alternatives` (world units) that fits in view with them: what a type
    /// made for an API keeps, the API and the types it names where they all fit, else the API alone, else the row a card hangs
    /// from (UX walk 5 apis-5-1). At the zoom it has: shapes too big to fit are fitted, farther out.
    public func revealIfOffscreen(_ ids: [ShapeID], keepingFirstOf alternatives: [CGRect]) {
        guard let bounds = shapeContext.bounds(of: ids),
              revealIfOffscreen(rect: bounds, keeping: alternatives, withRowAbove: true, settling: false) else { return }
        settleIfSelected(ids)
    }

    /// How many of `kept` (world units: what the person works with), of those wholly in the clear view where the camera is headed,
    /// the least pan `revealIfOffscreen(_:keepingFirstOf:)` would make to bring a box of `bounds` into view (keeping the first of
    /// `alternatives` that fits with it) takes out of it: 0 for a box in view already; nil for one too big to show at this zoom,
    /// which would be fitted farther out, or before the view has a size. What a caller weighs spots by before putting a shape
    /// down (a new type: a pan that takes out of view what the person works with ranks last, U11's rule for a put).
    public func revealTakesAway(_ kept: [CGRect], bringing bounds: CGRect, keepingFirstOf alternatives: [CGRect] = []) -> Int? {
        guard let pan = revealPan(bringing: bounds, keepingFirstOf: alternatives) else { return nil }
        guard pan != .zero else { return 0 }
        let camera = cameraTarget, clear = clearView
        return kept.map { camera.toView($0) }.filter { clear.contains($0) && !clear.contains($0.offsetBy(dx: pan.width, dy: pan.height)) }.count
    }

    /// The least pan, in view points, `revealIfOffscreen(_:keepingFirstOf:)` would make for a box of `bounds` (with the row
    /// above its top) where the camera is headed: zero for one in view already; nil for one too big to show at this zoom, or
    /// before the view has a size.
    private func revealPan(bringing bounds: CGRect, keepingFirstOf alternatives: [CGRect]) -> CGSize? {
        guard let shown = revealedRect(bounds, keeping: alternatives, withRowAbove: true) else { return nil }
        guard !clearView.contains(cameraTarget.toView(shown.bounds)) else { return .zero }
        guard let together = shown.together else { return nil }
        return clearView.insetBy(SelectionStyle.revealMargin).shift(bringing: cameraTarget.toView(together))
    }

    /// What a reveal of `bounds` shows: the box with the row above it (`bounds`), and what the least pan brings in (`together`:
    /// with the first of `keeping` that fits with it, else alone; nil for a box too big to fit at the zoom the camera is headed
    /// for). Nil before the view has a size, or for a box that is no box.
    private func revealedRect(_ bounds: CGRect, keeping: [CGRect], withRowAbove: Bool) -> (bounds: CGRect, together: CGRect?)? {
        let view = unobscuredViewport, camera = cameraTarget
        guard !view.isEmpty, !bounds.isNull, bounds.isFinite else { return nil }
        let above = withRowAbove ? SelectionStyle.revealRowAbove / camera.zoom : 0
        func withRow(_ rect: CGRect) -> CGRect { CGRect(x: rect.minX, y: rect.minY - above, width: rect.width, height: rect.height + above) }
        let shown = withRow(bounds)
        let margin = SelectionStyle.revealMargin
        let room = view.insetBy(dx: margin, dy: margin)
        func fits(_ rect: CGRect) -> Bool { rect.width * camera.zoom <= room.width && rect.height * camera.zoom <= room.height }
        guard fits(shown) else { return (shown, nil) }
        let together = keeping.lazy.map { withRow($0.union(bounds)) }.first(where: fits)
        return (shown, together ?? shown)
    }

    /// The same for a rect in world units (a part of the selected shape, `ShapeParts`, where the person
    /// then is, `settling`), answering whether it moved the camera; the row above it counted only `withRowAbove`
    /// (a shape's, never a part's), and the first of `keeping` that fits in view with it kept there too.
    @discardableResult
    func revealIfOffscreen(rect bounds: CGRect, keeping: [CGRect] = [], withRowAbove: Bool = false,
                           zoomingOut: Bool = true, settling: Bool = true) -> Bool {
        guard let (shown, together) = revealedRect(bounds, keeping: keeping, withRowAbove: withRowAbove) else { return false }
        // In view: in the clear part and out of the corner the minimap covers, as the least pan below brings it.
        guard !clearView.contains(cameraTarget.toView(shown)) else { return false }
        let margin = SelectionStyle.revealMargin
        if let together {
            animateCamera(toShow: together, margin: margin, duration: SelectionStyle.revealDuration)
        } else if zoomingOut {
            animateCamera(toFit: bounds, inset: SelectionStyle.revealInset, maxZoom: cameraTarget.zoom, duration: SelectionStyle.revealDuration)
        } else {
            animateCamera(toShow: shown, margin: margin, duration: SelectionStyle.revealDuration)
        }
        if settling { selectionState?.settle() }
        return true
    }

    /// Brings what the selection climbed to (a group, or the container it is in: Escape, ⌘↑) into view only if none
    /// of it is in view: a database the table just left is in shows partly at least, and the camera stays; one wholly
    /// out of view is panned to (its top-left in view when it is bigger than the view), never zoomed out to, so the
    /// shapes the person was at keep their size.
    func revealEnclosure(_ ids: [ShapeID]) {
        guard let bounds = shapeContext.bounds(of: ids), !unobscuredViewport.isEmpty,
              !cameraTarget.toWorld(unobscuredViewport).intersects(bounds) else { return }
        revealIfOffscreen(ids, zoomingOut: false)
    }

    /// Goes to the shapes, as following a link to them does: ends editing, selects those that can
    /// be selected, and brings them into view (`reveal`) unless they're all in view already at a
    /// readable zoom. Selecting them is a step back (`goBack`, ⌘[ and ⌃- return, camera and all) when it
    /// changes the selection, however near they are (VS Code's jump: a place of its own, as one step,
    /// `asOneStep`); going to what's selected already, or to shapes none of which can be
    /// selected, leaves the selection as it is and takes no step, so it only moves the camera.
    /// "Readable" is 70% or closer (where a note's text reads at about 11 points), or closer for a
    /// kind whose text is smaller (`ReadableZoom`: 11-point text's, 100%), the closest of the
    /// shapes' kinds; or, for shapes too big to show whole at that, as close as fitting them would
    /// bring them. The camera is judged where it's headed, if it's gliding.
    ///
    /// The shapes may be anywhere in the file (a mention names a shape on any board). It goes to the
    /// board of the first of them that's on a board it can show (`canShow`), and to those of them on
    /// that board, leaving the rest. On another board, it shows that board and selects them there as
    /// one step back (`showBoard(_:selecting:)`: Back returns to the board left, with its
    /// selection), then brings them into view from the camera the board was left with (or its
    /// first visit's). Does nothing mid-gesture, or when none of the shapes is on a board it can
    /// show. Without the Selection plugin, nothing is selectable: it ends editing, shows their
    /// board, and brings them into view.
    public func goTo(_ ids: [ShapeID]) {
        let file = file
        guard session == nil, let target = ids.lazy.compactMap({ file.board(containing: $0) }).first(where: canShow) else { return }
        let here = ids.filter { file.board(containing: $0) == target }
        endEditing()
        navigate { [self] in
            if target == board {
                let selectable = here.filter(isSelectable)
                if !selectable.isEmpty, Set(selectable) != Set(selectedShapeIDs) { selectedShapeIDs = selectable }
            } else {
                guard showBoard(target, selecting: here) else { return }
            }
            if !isReadablyInView(here) { reveal(here) }
        }
    }

    /// Goes into a shape, as following a link to a shape that's opened rather than looked at does (a
    /// mention of a subboard enters its board): goes to it (`goTo`), then opens it there (`open`),
    /// as one step back, to the board and selection it was followed from, whatever boards it went
    /// through. A shape that doesn't open (`canOpen`) is only gone to. Does nothing mid-gesture,
    /// when the shape isn't on a board it can show, or when its own board is the one shown (a
    /// subboard's mention followed from inside it): it's gone into already.
    public func goInto(_ id: ShapeID) {
        guard session == nil, board != BoardID(owner: id) else { return }
        navigate { [self] in
            goTo([id])
            if canOpen(id) { open(id) }
        }
    }

    /// Runs `body` (showing a board, selecting shapes, bringing them into view) as going somewhere, as
    /// following a link does: one step back, to the board, the selection and the camera before it,
    /// however near what it selects is (VS Code's jump, where a selection is judged by the view the
    /// person had), and none if it leaves the board and the selection as they were; nothing inside
    /// records a step of its own. What `goTo` and `goInto` are made of, and how a row of the table of
    /// contents is picked. Without the Selection plugin it only runs `body`.
    public func navigate(_ body: () -> Void) {
        if let selectionState { selectionState.asOneStep(body) } else { body() }
    }

    /// Where the editor is now (its board, selection and camera, where it's headed), for a way
    /// around that spans many calls (Find's stepping through its hits, board to board) to come back
    /// to as one step back (`navigate(from:_:)`). Nil without the Selection plugin.
    public var navigationStart: NavigationStart? {
        selectionState.map { NavigationStart(board: board, selection: selectedShapeIDs, camera: cameraTarget, serial: $0.takeStart()) }
    }

    /// Runs `body` (showing boards, revealing shapes) as part of one step back to `start`, however
    /// many calls make it up: nothing `body` does records a step of its own, and the first call
    /// that moves the board, the selection or the camera puts `start` on the history as the step
    /// back, once (a later call finds it there and adds none, whatever the person did between; a place
    /// left earlier that looks the same is another step, so it never stands in for this one). As
    /// `asOneStep`, but for a way around the person takes a step at a time: Back after it returns to
    /// where it began.
    public func navigate(from start: NavigationStart, _ body: () -> Void) {
        guard let state = selectionState else { return body() }
        state.asOneStep(from: SelectionHistory.Entry(board: start.board, selection: start.selection, camera: start.camera, start: start.serial), body)
    }

    /// A trackpad's smart zoom (a two-finger double-tap, `.smartMagnify`), as Safari's and Preview's:
    /// brings the shape under the pointer into view, as `reveal` does; the next, while the camera is
    /// still where that one took it, eases it back to where it was. Nothing under the pointer, and
    /// nothing to go back to: nothing. Nothing mid-gesture.
    public func smartMagnify() {
        guard session == nil, let state = selectionState else { return }
        if let zoom = state.smartZoom, zoom.shown == cameraTarget {
            state.smartZoom = nil
            animateCamera(to: zoom.before, duration: SelectionStyle.revealDuration)
            return
        }
        state.smartZoom = nil
        guard let id = selectableShape(at: pointerWorldLocation), let bounds = shapeContext.bounds(of: [id]),
              let target = revealCamera(fitting: bounds) else { return }
        state.smartZoom = (before: cameraTarget, shown: target)
        animateCamera(to: target, duration: SelectionStyle.revealDuration)
    }

    /// Where `reveal` takes the camera to show `bounds`; nil before the view has a size.
    private func revealCamera(fitting bounds: CGRect) -> Camera? {
        let view = unobscuredViewport
        guard !view.isEmpty else { return nil }
        return Camera(fitting: bounds, in: view, inset: SelectionStyle.revealInset, maxZoom: SelectionStyle.revealMaxZoom)
    }

    /// Whether the shapes' bounds are all in view (in what the host leaves clear of it), where the
    /// camera is headed, at a zoom they read at: the closest any of their kinds reads at
    /// (`readableZoom(of:)`) or closer, or as close as `reveal` would bring them.
    private func isReadablyInView(_ ids: [ShapeID]) -> Bool {
        guard let bounds = shapeContext.bounds(of: ids), let fitted = revealCamera(fitting: bounds) else { return false }
        let camera = cameraTarget
        let visible = camera.toWorld(unobscuredViewport)
        let readable = ids.compactMap { document[$0] }.map(readableZoom(of:)).max() ?? SelectionStyle.readableZoom
        return visible.contains(bounds) && camera.zoom >= min(readable, fitted.zoom)
    }

    /// The zoom a shape reads at: its kind's (`ReadableZoom`), else 70%, where a note's 16-point
    /// text is 11.2 points on screen (`SelectionStyle.readableZoom`).
    public func readableZoom(of shape: AnyShapeRecord) -> CGFloat {
        selectionState?.readableZooms[shape.kind] ?? SelectionStyle.readableZoom
    }
}
