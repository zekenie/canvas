import AppKit

/// The canvas's standard shape shadow, which `RenderContext.fillWithShadow` draws under a fill, left
/// out wherever the fill hides all of it: an opaque fill whose shape holds everything the context
/// draws into (its clip's box, a device pixel more for the antialiasing of an edge on it), as a
/// shape zoomed in past the view's edges does. The picture is the same without it, and the blur,
/// scaled by the zoom, costs what the shape covers on screen: at 800% a card bigger than the view
/// took some 24 ms of a frame on a 2× bitmap for a shadow nothing showed (on screen the GPU blurs
/// it, and frames held 60 fps; a bitmap, and every window headless, blurs it on the CPU).
@MainActor
final class ShapeShadows {
    #if DEBUG
    /// Every shadow drawn, even one its fill hides (debug builds): the control a test of leaving
    /// them out compares against.
    var alwaysDrawn = false
    /// How many shadows were left out because their fills hid them (debug builds).
    private(set) var skipped = 0
    #endif

    /// Fills `path` with `color`, over the shadow unless the fill hides it. Shadows ignore the
    /// transform, so the blur is scaled by hand; the offset is zero because shadow offsets live in
    /// device space. The fill is taken to paint its color as it is: the context's own alpha and
    /// blend mode the fresh state's (neither can be read back), as every shipped render leaves them.
    func fill(_ path: CGPath, with color: CGColor, zoom: CGFloat, in cg: CGContext) {
        cg.saveGState()
        if !hides(path, color, in: cg) {
            cg.setShadow(offset: .zero, blur: Style.shapeShadowBlur * zoom, color: Style.shapeShadow.cgColor)
        }
        cg.addPath(path)
        cg.setFillColor(color)
        cg.fillPath()
        cg.restoreGState()
    }

    /// Whether `path` filled with `color` hides everything a zero-offset shadow under it could
    /// show in `cg`: every pixel the context can draw into is wholly inside the path, and the fill
    /// is opaque.
    private func hides(_ path: CGPath, _ color: CGColor, in cg: CGContext) -> Bool {
        guard color.alpha == 1, color.pattern == nil else { return false }
        let clip = cg.boundingBoxOfClipPath, bounds = path.boundingBoxOfPath
        // A shape smaller than what's drawn into can't hold it: a comparison of rects, and nothing
        // more, for every shape but one bigger than the view.
        guard !clip.isNull, !clip.isInfinite, bounds.contains(clip) else { return false }
        // A device pixel's box in user space, however the transform turns.
        let pixel = cg.convertToUserSpace(CGRect(x: 0, y: 0, width: 1, height: 1))
        let shown = clip.insetBy(dx: -pixel.width, dy: -pixel.height)
        guard bounds.contains(shown) else { return false }
        #if DEBUG
        if alwaysDrawn { return false }
        #endif
        guard CGPath(rect: shown, transform: nil).subtracting(path).isEmpty else { return false }
        #if DEBUG
        skipped += 1
        #endif
        return true
    }
}
