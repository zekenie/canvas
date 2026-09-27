import AppKit
import Geometry

extension CanvasEditor {
    /// Draws the whole canvas into `context` (the view's, or an offscreen one). `bounds` is the
    /// view's bounds in view points. Every shape and overlay draws with a fresh graphics state, so
    /// one plugin's leftover alpha or dash can't leak into another's.
    @_spi(Host) public func draw(in context: CGContext, bounds: CGRect, dirtyRect: CGRect) {
        // AppKit drawing (fills, text) goes to the current NSGraphicsContext: make it this one.
        let installsContext = NSGraphicsContext.current?.cgContext !== context
        if installsContext {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        }
        defer { if installsContext { NSGraphicsContext.restoreGraphicsState() } }

        Style.canvasBackground.setFill()
        dirtyRect.fill()
        drawGrid(in: context, bounds: bounds)

        let shapes = shapeContext
        context.saveGState()
        context.scaleBy(x: camera.zoom, y: camera.zoom)
        context.translateBy(x: -camera.origin.x, y: -camera.origin.y)
        // Pad the visible area so shadows of shapes just offscreen still get drawn.
        let world = camera.toWorld(bounds)
        for record in paintOrder(in: world.insetBy(dx: -40, dy: -40)) {
            guard let definition = registry.definition(for: record.kind) else { continue }
            drawIsolated(context) {
                definition.erasedRender(record, in: RenderContext(cg: context, shapes: shapes, isEditing: record.id == editingShapeID))
            }
        }
        drawOutlines(in: context, shapes: shapes)
        let overlayContext = OverlayContext(cg: context, editor: self, shapes: shapes, visibleRect: world)
        for overlay in registry.overlays where overlay.space == .world {
            drawIsolated(context) { overlay.draw(in: overlayContext) }
        }
        if let session {
            drawIsolated(context) { session.draw(in: overlayContext) }
        }
        context.restoreGState()

        for overlay in registry.overlays where overlay.space == .view {
            drawIsolated(context) { overlay.draw(in: overlayContext) }
        }
    }

    // MARK: Pictures of the board
    //
    // What a view that shows the board away from the canvas (the minimap) goes by. Such a picture is
    // kept from frame to frame and redrawn only where shapes moved or changed shape: `damage(since:)`
    // says where. It shows where shapes are, not which is on top: the paint order isn't damage.

    /// What the canvas outlines now: every plugin's outlines (none while the session hides them),
    /// with the hint among the shapes; a shape outlined in full isn't among the faint ones too. A
    /// picture of the board marks the same shapes.
    @_spi(Host) public var outlines: Outlines {
        var outlines = Outlines()
        if session?.hidesOutlines != true {
            for source in registry.outlineSources {
                let more = source(self)
                outlines.shapes += more.shapes
                outlines.faintShapes += more.faintShapes
                outlines.rects += more.rects
            }
        }
        if let hintedShapeID { outlines.shapes.append(hintedShapeID) }
        let full = Set(outlines.shapes)
        outlines.faintShapes.removeAll { full.contains($0) }
        return outlines
    }

    /// The bounds of every shape on the board, in world units: what a picture of all of it shows.
    /// Shapes that could be anywhere (no outline, and no box) and shapes kept aside don't count;
    /// null with none. Kept as shapes change, so asking costs what changed.
    @_spi(Host) public var shapeBounds: CGRect { shapeIndex.bounds(in: shapeContext) }

    /// Now, for `damage(since:)`: a picture brought up to date keeps it.
    @_spi(Host) public var damageMark: Int { shapeIndex.mark(in: shapeContext) }

    /// Where shapes may be other than they were at `mark`, in world units: every shape a commit
    /// since then changed, added or removed, where it was and where it is, with every shape whose
    /// geometry follows one of them (an arrow, its ends' shapes) or the camera. A picture drawn at
    /// `mark` is up to date once it draws there again, grown by however far past its shapes it draws.
    /// Not the paint order: a restack names the shapes it moved in the stack, but not one it carried
    /// along above its anchor. Null when nothing moved; infinite when the editor no longer knows (too
    /// long ago), or a shape that could be anywhere changed.
    @_spi(Host) public func damage(since mark: Int) -> CGRect { shapeIndex.damage(since: mark, in: shapeContext) }

    /// A fresh graphics state and an empty path (the current path isn't part of the graphics
    /// state), so nothing one plugin leaves behind reaches the next.
    private func drawIsolated(_ context: CGContext, _ draw: () -> Void) {
        context.saveGState()
        context.beginPath()
        draw()
        context.beginPath()
        context.restoreGState()
    }

    private func drawGrid(in context: CGContext, bounds: CGRect) {
        var spacing = Style.gridSpacing
        while spacing * camera.zoom < Style.minGridSpacingOnScreen {
            spacing *= 2
        }
        // Dots are placed in view space so they stay the same size at every zoom level.
        let step = spacing * camera.zoom
        let startX = (floor(camera.origin.x / spacing) * spacing - camera.origin.x) * camera.zoom
        let startY = (floor(camera.origin.y / spacing) * spacing - camera.origin.y) * camera.zoom
        let diameter = Style.gridDotDiameter
        var y = startY
        while y < bounds.maxY + diameter {
            var x = startX
            while x < bounds.maxX + diameter {
                context.addEllipse(in: CGRect(x: x - diameter / 2, y: y - diameter / 2, width: diameter, height: diameter))
                x += step
            }
            y += step
        }
        context.setFillColor(Style.gridDot.cgColor)
        context.fillPath()
    }

    /// Every plugin's outlines (unless the session hides them), then the hint, in one stroke at a
    /// constant screen width; under them, in a wider, lighter stroke of their own, the faint ones.
    private func drawOutlines(in context: CGContext, shapes: ShapeContext) {
        let outlines = self.outlines
        strokeOutlines(of: outlines.faintShapes, rects: [], in: Style.accent.withAlphaComponent(Style.faintIndicatorOpacity),
                       width: Style.faintIndicatorWidth, context: context, shapes: shapes)
        strokeOutlines(of: outlines.shapes, rects: outlines.rects, in: Style.accent, width: Style.indicatorWidth, context: context, shapes: shapes)
    }

    /// `width` is in view points.
    private func strokeOutlines(of ids: [ShapeID], rects: [CGRect], in color: NSColor, width: CGFloat, context: CGContext, shapes: ShapeContext) {
        guard !ids.isEmpty || !rects.isEmpty else { return }
        context.saveGState()
        for id in ids {
            guard let record = document[id], let path = registry.definition(for: record.kind)?.erasedIndicatorPath(of: record, in: shapes) else { continue }
            context.addPath(path)
        }
        for rect in rects { context.addRect(rect) }
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(width / camera.zoom)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }
}
