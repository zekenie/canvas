import Canvas
import CoreGraphics
import Geometry

// Going to shapes, one way for every plugin that brings shapes into view: the table of contents
// (a row's click), and whatever links to a shape (a mention in text). data-canvas's navigateToShape.
extension CanvasEditor {
    /// Brings the shapes into view: centers their bounds (`shapeContext.bounds(of:)`), zoomed to fit
    /// with 100 points of margin in all but no closer than 120%, and moves the camera there over
    /// 200 ms (`animateCamera`), as data-canvas's table of contents does (tldraw's zoomToBounds). What
    /// selecting rows of the table of contents does. Does nothing before the view has a size, or when none of the
    /// shapes has bounds (none is on the board).
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
    /// is judged where it's headed, if it's gliding. Does nothing mid-gesture, or when none of the
    /// shapes is on the board. Without the Selection plugin, nothing is selectable: it ends editing
    /// and brings them into view.
    public func goTo(_ ids: [ShapeID]) {
        guard session == nil, ids.contains(where: { document[$0] != nil }) else { return }
        endEditing()
        let selectable = ids.filter(isSelectable)
        if !selectable.isEmpty, Set(selectable) != Set(selectedShapeIDs) { selectedShapeIDs = selectable }
        if !isReadablyInView(ids) { reveal(ids) }
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
