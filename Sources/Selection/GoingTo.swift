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
}

// Going to shapes, one way for every plugin that brings shapes into view: the table of contents
// (a row's click), and whatever links to a shape (a mention in text). data-canvas's navigateToShape.
extension CanvasEditor {
    /// Brings the shapes into view: centers their bounds (`shapeContext.bounds(of:)`) in the part of
    /// the view the host leaves clear (`unobscuredViewport`: below the path over a subboard's canvas),
    /// zoomed to fit with 100 points of margin in all but no closer than 120%, and moves the camera
    /// there over 200 ms (`animateCamera`), as data-canvas's table of contents does (tldraw's
    /// zoomToBounds). What selecting rows of the table of contents does, and Zoom to Selection. Only
    /// on the board shown (`goTo` goes to shapes on another). Does nothing before the view has a
    /// size, or when none of the shapes has bounds (none is on the board shown).
    public func reveal(_ ids: [ShapeID]) {
        guard let bounds = shapeContext.bounds(of: ids), let target = revealCamera(fitting: bounds) else { return }
        animateCamera(to: target, duration: SelectionStyle.revealDuration)
    }

    /// Brings the shapes into view only if they are not all in it (tldraw's `zoomToSelectionIfOffscreen`,
    /// what stepping from shape to shape does): in what the host leaves clear of the view, where the
    /// camera is headed, the camera stays. Otherwise it moves over 200 ms to center their bounds with 100
    /// points of margin, at the zoom it has, or farther out where they do not fit (never closer, which
    /// `reveal` brings small shapes to). Does nothing before the view has a size, or when none of the
    /// shapes has bounds.
    public func revealIfOffscreen(_ ids: [ShapeID]) {
        let view = unobscuredViewport, camera = cameraTarget
        guard !view.isEmpty, let bounds = shapeContext.bounds(of: ids), !camera.toWorld(view).contains(bounds) else { return }
        animateCamera(to: Camera(fitting: bounds, in: view, inset: SelectionStyle.revealInset, maxZoom: camera.zoom),
                      duration: SelectionStyle.revealDuration)
    }

    /// Goes to the shapes, as following a link to them does: ends editing, selects those that can
    /// be selected, and brings them into view (`reveal`) unless they're all in view already at a
    /// readable zoom. Selecting them is a step back (`goBack`, ⌘[ returns, camera and all) when it
    /// changes the selection; going to what's selected already, or to shapes none of which can be
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
        if target == board {
            let selectable = here.filter(isSelectable)
            if !selectable.isEmpty, Set(selectable) != Set(selectedShapeIDs) { selectedShapeIDs = selectable }
        } else {
            guard showBoard(target, selecting: here) else { return }
        }
        if !isReadablyInView(here) { reveal(here) }
    }

    /// Goes into a shape, as following a link to a shape that's opened rather than looked at does (a
    /// mention of a subboard enters its board): goes to it (`goTo`), then opens it there (`open`),
    /// as one step back, to the board and selection it was followed from, whatever boards it went
    /// through. A shape that doesn't open (`canOpen`) is only gone to. Does nothing mid-gesture,
    /// when the shape isn't on a board it can show, or when its own board is the one shown (a
    /// subboard's mention followed from inside it): it's gone into already.
    public func goInto(_ id: ShapeID) {
        guard session == nil, board != BoardID(owner: id) else { return }
        let go = { [self] in
            goTo([id])
            if canOpen(id) { open(id) }
        }
        if let selectionState { selectionState.asOneStep(go) } else { go() }
    }

    /// Where the editor is now (its board, selection and camera, where it's headed), for a way
    /// around that spans many calls (Find's stepping through its hits, board to board) to come back
    /// to as one step back (`navigate(from:_:)`). Nil without the Selection plugin.
    public var navigationStart: NavigationStart? {
        selectionState.map { _ in NavigationStart(board: board, selection: selectedShapeIDs, camera: cameraTarget) }
    }

    /// Runs `body` (showing boards, revealing shapes) as part of one step back to `start`, however
    /// many calls make it up: nothing `body` does records a step of its own, and the first call
    /// that moves the board, the selection or the camera puts `start` on the history as the step
    /// back, once (a later call finds it there and adds none, whatever the person did between). As `asOneStep`, but
    /// for a way around the person takes a step at a time: Back after it returns to where it began.
    public func navigate(from start: NavigationStart, _ body: () -> Void) {
        guard let state = selectionState else { return body() }
        state.asOneStep(from: SelectionHistory.Entry(board: start.board, selection: start.selection, camera: start.camera), body)
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
