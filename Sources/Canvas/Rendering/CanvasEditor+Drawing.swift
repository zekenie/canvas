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
        var outlined: [ShapeID] = []
        var faint: [ShapeID] = []
        var rects: [CGRect] = []
        if session?.hidesOutlines != true {
            for source in registry.outlineSources {
                let outlines = source(self)
                outlined += outlines.shapes
                faint += outlines.faintShapes
                rects += outlines.rects
            }
        }
        if let hintedShapeID { outlined.append(hintedShapeID) }
        let full = Set(outlined)
        strokeOutlines(of: faint.filter { !full.contains($0) }, rects: [], in: Style.accent.withAlphaComponent(Style.faintIndicatorOpacity),
                       width: Style.faintIndicatorWidth, context: context, shapes: shapes)
        strokeOutlines(of: outlined, rects: rects, in: Style.accent, width: Style.indicatorWidth, context: context, shapes: shapes)
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
