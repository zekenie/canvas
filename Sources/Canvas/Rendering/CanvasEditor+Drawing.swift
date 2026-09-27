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
        // Pad the visible area so shadows of shapes just offscreen still get drawn. Shapes without
        // a box are always drawn.
        let visible = camera.toWorld(bounds).insetBy(dx: -40, dy: -40)
        for record in paintOrder() {
            guard let definition = registry.definition(for: record.kind) else { continue }
            if let box = record.box, !box.intersects(visible) { continue }
            drawIsolated(context) {
                definition.erasedRender(record, in: RenderContext(cg: context, shapes: shapes, isEditing: record.id == editingShapeID))
            }
        }
        drawIndicators(in: context, shapes: shapes)
        let overlayContext = OverlayContext(cg: context, editor: self, shapes: shapes)
        for overlay in registry.overlays where overlay.space == .world {
            drawIsolated(context) { overlay.draw(in: overlayContext) }
        }
        if let brush {
            drawIsolated(context) {
                context.setFillColor(Style.brushFill.cgColor)
                context.fill(brush)
                context.setStrokeColor(Style.brushStroke.cgColor)
                context.setLineWidth(1 / camera.zoom)
                context.stroke(brush)
            }
        }
        context.restoreGState()

        drawIsolated(context) { drawHandles(in: context) }
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

    /// Hover, selection and target outlines, and the box around several selected shapes (tldraw's
    /// selection bounds), in one stroke at a constant screen width.
    private func drawIndicators(in context: CGContext, shapes: ShapeContext) {
        var outlined: [ShapeID] = []
        if currentToolID == .select, session == nil, let hovered, !isSelected(hovered) {
            outlined.append(hovered)
        }
        let showsSelection = !(session?.hidesSelectionIndicator ?? false)
        if showsSelection { outlined += selectedShapeIDs }
        if let hintedShapeID { outlined.append(hintedShapeID) }
        let box = showsSelection && selectedShapeIDs.count > 1 ? selectionBounds : nil
        guard !outlined.isEmpty else { return }
        context.saveGState()
        for id in outlined {
            guard let record = document[id], let path = registry.definition(for: record.kind)?.erasedIndicatorPath(of: record, in: shapes) else { continue }
            context.addPath(path)
        }
        if let box { context.addRect(box) }
        context.setStrokeColor(Style.accent.cgColor)
        context.setLineWidth(Style.indicatorWidth / camera.zoom)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }

    /// The only selected shape's handles, in view points. They show in the select tool, and hide while
    /// anything but a handle press is under way.
    private func drawHandles(in context: CGContext) {
        var pressed: AnyHashable?
        switch session {
        case nil: break
        case let pointing as PointingHandleSession: pressed = pointing.handle
        default: return
        }
        guard currentToolID == .select else { return }
        // Handles shrink once zoomed out past 25%.
        let radius = Style.handleRadius * min(1, camera.zoom / 0.25)
        for (handle, center) in visibleHandles() {
            func circle(_ radius: CGFloat) -> CGRect {
                CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            }
            if handle == hoveredHandle || handle == pressed {
                context.setFillColor(Style.accentFill.cgColor)
                context.fillEllipse(in: circle(Style.handleHitRadius))
            }
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: circle(radius))
            context.setStrokeColor(Style.accent.cgColor)
            context.setLineWidth(Style.indicatorWidth)
            context.strokeEllipse(in: circle(radius))
        }
    }
}
