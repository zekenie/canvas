import Canvas
import CoreGraphics
import Geometry

// Going to shapes, one way for every plugin that brings shapes into view: the table of contents
// (a row's click), and whatever links to a shape (a mention in text). data-canvas's navigateToShape.
extension CanvasEditor {
    /// Brings the shapes into view: centers their bounds (`shapeContext.bounds(of:)`), zoomed to fit
    /// with 100 points of margin in all but no closer than 120%, and moves the camera there over
    /// 200 ms (`animateCamera`), as data-canvas's table of contents does (tldraw's zoomToBounds). What
    /// selecting rows of the table of contents does. Only on the board shown (`goTo` goes to shapes
    /// on another). Does nothing before the view has a size, or when none of the shapes has bounds
    /// (none is on the board shown).
    public func reveal(_ ids: [ShapeID]) {
        guard let bounds = shapeContext.bounds(of: ids), let target = revealCamera(fitting: bounds) else { return }
        animateCamera(to: target, duration: SelectionStyle.revealDuration)
    }

    /// Goes to the shapes, as following a link to them does: ends editing, selects those that can
    /// be selected, and brings them into view (`reveal`) unless they're all in view already at a
    /// readable zoom. Selecting them is a step back (`goBack`, ⌘[ returns, camera and all) when it
    /// changes the selection; going to what's selected already, or to shapes none of which can be
    /// selected, leaves the selection as it is and takes no step, so it only moves the camera.
    /// "Readable" is 70% or closer (where a note's text reads at about 11 points), or, for
    /// shapes too big to show whole at that, as close as fitting them would bring them. The camera
    /// is judged where it's headed, if it's gliding.
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
    /// through. A shape that doesn't open (`canOpen`) is only gone to. Does nothing mid-gesture, or
    /// when the shape isn't on a board it can show.
    public func goInto(_ id: ShapeID) {
        guard session == nil else { return }
        let go = { [self] in
            goTo([id])
            if canOpen(id) { open(id) }
        }
        if let selectionState { selectionState.asOneStep(go) } else { go() }
    }

    /// Where `reveal` takes the camera to show `bounds`; nil before the view has a size.
    private func revealCamera(fitting bounds: CGRect) -> Camera? {
        let size = viewportSize
        guard size.width > 0, size.height > 0 else { return nil }
        return Camera(fitting: bounds, in: size, inset: SelectionStyle.revealInset, maxZoom: SelectionStyle.revealMaxZoom)
    }

    /// Whether the shapes' bounds are all in view, where the camera is headed, at a zoom they read
    /// at: `SelectionStyle.readableZoom` or closer, or as close as `reveal` would bring them.
    private func isReadablyInView(_ ids: [ShapeID]) -> Bool {
        guard let bounds = shapeContext.bounds(of: ids), let fitted = revealCamera(fitting: bounds) else { return false }
        let camera = cameraTarget
        let visible = camera.toWorld(CGRect(origin: .zero, size: viewportSize))
        return visible.contains(bounds) && camera.zoom >= min(SelectionStyle.readableZoom, fitted.zoom)
    }
}
