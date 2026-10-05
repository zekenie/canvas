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
        dotGrid.draw(in: context, bounds: bounds, camera: camera)

        let shapes = shapeContext
        context.saveGState()
        context.scaleBy(x: camera.zoom, y: camera.zoom)
        context.translateBy(x: -camera.origin.x, y: -camera.origin.y)
        let world = camera.toWorld(bounds)
        // Grown so shadows of shapes just offscreen still get drawn, and shapes shaken into view.
        let pad = Style.drawingPad + worldDrawingReach, drawn = world.insetBy(dx: -pad, dy: -pad)
        let offsets = drawingOffsets
        let file = storedFile
        let shapeCount = { (owner: ShapeID) in file.children[owner]?.shapes.count ?? 0 }
        let registry = registry
        let fileShape = { (id: ShapeID) in Self.shape(id, inFile: file, registry: registry) }
        let lend = { [unowned self] (id: ObjectIdentifier) in resolveService(id) }
        // Previews asked for in earlier frames first, so one finished now is drawn now.
        let previews = boardPreviews, previewColor = Style.boardPreview.cgColor, zoom = camera.zoom
        if previews.isPending { previews.build(in: file, until: .now + previews.frameBudget) }
        let preview = { (owner: ShapeID, rect: CGRect, maxScale: CGFloat, cg: CGContext) in
            // Too small on screen to show anything (zoomed out, or no room): nothing asked for.
            guard min(rect.width, rect.height) * zoom >= Style.previewSmallestSide else { return false }
            return previews.preview(of: BoardID(owner: owner), in: file)?.draw(in: cg, fitting: rect, maxScale: maxScale, color: previewColor) ?? false
        }
        // Skeletons or not, decided once for the frame; the shape being edited is drawn in full.
        let skeletons = drawsSkeletons, editing = editingShapeID, customSkeletons = registry.customSkeletons
        let deviceScale = context.userSpaceToDeviceSpaceTransform
        let ink = SkeletonInk(fill: Style.skeleton.cgColor, text: Style.skeletonText.cgColor,
                              pixel: 1 / max(hypot(deviceScale.a, deviceScale.b), .leastNormalMagnitude))
        for record in paintOrder(in: drawn) {
            guard let definition = registry.definition(for: record.kind) else { continue }
            drawIsolated(context) {
                if !offsets.isEmpty, let offset = offsets[record.id] {
                    context.translateBy(x: offset.x / zoom, y: offset.y / zoom)
                }
                let render = RenderContext(cg: context, shapes: shapes, isEditing: record.id == editing, shapeCount: shapeCount,
                                           preview: preview, fileShape: fileShape, lend: lend, skeleton: ink)
                if skeletons, record.id != editing {
                    if let custom = customSkeletons[record.kind] {
                        custom.erasedRenderSkeleton(record, in: render)
                    } else if let geometry = shapes.geometry(of: record.id) {
                        render.fillSkeleton(of: geometry, color: ink.fill)
                    }
                } else {
                    definition.erasedRender(record, in: render)
                }
            }
        }
        previews.endFrame()
        if previews.isPending, nextPreviewFrame == nil {
            nextPreviewFrame = scheduler.schedule(after: .zero) { [weak self] in
                self?.nextPreviewFrame = nil
                self?.setNeedsDisplay()
            }
        }
        drawOutlines(in: context, shapes: shapes, around: drawn, skeletonPixel: skeletons ? ink.pixel : nil)
        let overlayContext = OverlayContext(cg: context, editor: self, shapes: shapes, visibleRect: world, drawsSkeletons: skeletons)
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

    #if DEBUG
    /// How many tiles the dot grid has made (debug builds): a frame the camera didn't move makes none.
    @_spi(Host) public var gridTilesMade: Int { dotGrid.tilesMade }

    /// How many frames drew the dot grid's copies through the clip of the pixels their dots touch,
    /// and how many without it (debug builds): a bitmap's are clipped, and no other context's.
    @_spi(Host) public var gridFramesClipped: Int { dotGrid.framesClipped }
    @_spi(Host) public var gridFramesUnclipped: Int { dotGrid.framesUnclipped }

    /// Whether the dot grid clips its copies whatever the context is (debug builds): nil, the
    /// default, leaves it to the context; a test that draws a bitmap unclipped sets false.
    @_spi(Host) public var gridClipOverride: Bool? {
        get { dotGrid.clipOverride }
        set { dotGrid.clipOverride = newValue }
    }
    #endif

    // MARK: Drawing a shape away from where it is

    /// Draws a shape `offset` view points away from where it is, until it's set back to zero: for
    /// an animation that moves how a shape looks without changing it (Selection's refusal shake). Its outline
    /// goes with it, and so do the overlays that decorate it (a title's pill, a lock),
    /// through `OverlayContext.worldDrawingOffset(of:)`. Everything else goes by where it is: hit
    /// testing, handles, arrows bound to it, pictures of the board. A shape that's deleted loses its
    /// offset.
    public func setDrawingOffset(_ offset: CGPoint, for id: ShapeID) {
        let kept: CGPoint? = offset == .zero || document[id] == nil ? nil : offset
        guard drawingOffsets[id] != kept else { return }
        drawingOffsets[id] = kept
        setNeedsDisplay()
    }

    /// How far from where it is the shape is drawn, in view points (`setDrawingOffset`): zero for
    /// most shapes.
    public func drawingOffset(of id: ShapeID) -> CGPoint { drawingOffsets[id] ?? .zero }

    /// The farthest any shape is drawn from where it is, along either axis, in world units: zero
    /// unless a drawing offset is set (`OverlayContext.worldDrawingReach`).
    var worldDrawingReach: CGFloat {
        drawingOffsets.isEmpty ? 0 : drawingOffsets.values.reduce(0) { max($0, abs($1.x), abs($1.y)) } / camera.zoom
    }

    // MARK: Skeletons

    /// Whether the canvas draws shapes as skeletons now (`CustomSkeleton`): the camera's zoom is
    /// under `skeletonZoom` (35%), where their text no longer reads. Every shape but the one being
    /// edited (`drawsSkeleton(of:)`). What overlays and hit testing that mirror what a shape draws
    /// go by (a face on its text, an adornment's label), so what shows and what answers the pointer
    /// agree; `OverlayContext.drawsSkeletons` is the frame's, and services hear it change
    /// (`EditorService.drawsSkeletonsDidChange`). A shape's geometry isn't told it (`ShapeContext`
    /// has no `drawsSkeletons`, and `skeletonZoom` is host API), so hit testing, the marquee,
    /// arrows' ends, snapping and the minimap go by each shape as they always did.
    public var drawsSkeletons: Bool { camera.zoom < skeletonZoom }

    /// Whether the shape draws as a skeleton now: `drawsSkeletons`, unless it's the shape being
    /// edited, which draws in full under its editing view.
    public func drawsSkeleton(of id: ShapeID) -> Bool { drawsSkeletons && id != editingShapeID }

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
                // The first list of shapes is taken as it is, not copied (⌘A's is every shape).
                if outlines.shapes.isEmpty { outlines.shapes = more.shapes } else if !more.shapes.isEmpty { outlines.shapes += more.shapes }
                if !more.faintShapes.isEmpty { outlines.faintShapes += more.faintShapes }
                if !more.rects.isEmpty { outlines.rects += more.rects }
            }
        }
        if let hintedShapeID { outlines.shapes.append(hintedShapeID) }
        if !outlines.faintShapes.isEmpty, !outlines.shapes.isEmpty {
            outlines.faintShapes = Self.faint(outlines.faintShapes, leavingOut: outlines.shapes)
        }
        return outlines
    }

    /// The faint outlines less those outlined in full, with no set of all of those (⌘A's is every
    /// shape): each of a few (a hover) is looked for among them, which compares ids, cheaper than
    /// hashing them; more, in one pass over them.
    private static func faint(_ faint: [ShapeID], leavingOut full: [ShapeID]) -> [ShapeID] {
        guard faint.count > 8 else { return faint.filter { !full.contains($0) } }
        var unfound = Set(faint)
        let count = unfound.count
        for id in full {
            unfound.remove(id)
            if unfound.isEmpty { return [] }
        }
        return unfound.count == count ? faint : faint.filter(unfound.contains)
    }

    /// The bounds of every shape on the board, in world units: what a picture of all of it shows.
    /// Shapes that could be anywhere (no outline, and no box) and shapes kept aside don't count;
    /// null with none. Kept as shapes change, so asking costs what changed.
    @_spi(Host) public var shapeBounds: CGRect { shapeIndex.bounds(in: shapeContext) }

    /// Now, for `damage(since:)`: a picture brought up to date keeps it. It's the shown board's: a
    /// picture of another board (kept for when it's shown again) goes by `isCurrent`.
    @_spi(Host) public var damageMark: DamageMark { shapeIndex.mark(in: shapeContext) }

    /// Whether a mark was taken on what the editor keeps of the board shown now: a picture of this
    /// board kept while another was shown is up to date as of it (and `damage(since:)` says what
    /// changed since). False for a mark from another board, or from this board before the editor
    /// last worked it out afresh (it wasn't kept warm, or the file was replaced).
    @_spi(Host) public func isCurrent(_ mark: DamageMark) -> Bool { shapeIndex.isCurrent(mark) }

    /// Where shapes may be other than they were at `mark`, in world units: every shape a commit
    /// since then changed, added or removed, where it was and where it is, with every shape whose
    /// geometry follows one of them (an arrow, its ends' shapes) or the camera. A picture drawn at
    /// `mark` is up to date once it draws there again, grown by however far past its shapes it draws.
    /// Not the paint order: a restack names the shapes it moved in the stack, but not one it carried
    /// along above its anchor. Null when nothing moved; infinite when the editor no longer knows (too
    /// long ago, or a mark that isn't current), or a shape that could be anywhere changed.
    @_spi(Host) public func damage(since mark: DamageMark) -> CGRect { shapeIndex.damage(since: mark, in: shapeContext) }

    /// A fresh graphics state and an empty path (the current path isn't part of the graphics
    /// state), so nothing one plugin leaves behind reaches the next.
    private func drawIsolated(_ context: CGContext, _ draw: () -> Void) {
        context.saveGState()
        context.beginPath()
        draw()
        context.beginPath()
        context.restoreGState()
    }

    /// Every plugin's outlines (unless the session hides them), then the hint, in one pass at a
    /// constant screen width; under them, in a wider, lighter pass of their own, the faint ones.
    /// Only what meets `area` (world units, what the shapes were drawn for, and in full grown by what
    /// an outline stands off by) is asked for its path and stroked: a shape outlined out of view costs
    /// a look at its kept extent, however it's outlined. `skeletonPixel` is how big a pixel is (world units)
    /// while shapes are drawn as skeletons, nil while they aren't.
    private func drawOutlines(in context: CGContext, shapes: ShapeContext, around area: CGRect, skeletonPixel: CGFloat?) {
        let outlines = self.outlines
        strokeOutlines(of: outlines.faintShapes, rects: [], in: Style.accent.withAlphaComponent(Style.faintIndicatorOpacity),
                       width: Style.faintIndicatorWidth, around: area, skeletonPixel: skeletonPixel, context: context, shapes: shapes)
        strokeOutlines(of: outlines.shapes, rects: outlines.rects, in: Style.accent, width: Style.indicatorWidth,
                       around: area, skeletonPixel: skeletonPixel, context: context, shapes: shapes)
    }

    /// `width` is in view points. A shape drawn away from where it is has its outline there too.
    ///
    /// Drawn in full, a closed shape's outline stands off its edge, `outlineStandoff` view points
    /// (`Style.outlineStandoff`) all the way round, the same for every kind: its kind's
    /// `indicatorPath` grown outward (`addOutline`: a rect and a rounded rect, which every box kind's
    /// is, are built grown directly, corners concentric, so a shape costs what it did; any other
    /// closed outline is grown by path arithmetic), and the box around several shapes (`rects`) the
    /// same, so it holds the shapes' own. An open shape's (an arrow's) is stroked on its own path,
    /// as it has no inside to stand off from, and a closed shape's is on its edge with a standoff
    /// of zero, as the proof of concept drew it.
    ///
    /// Drawn as a skeleton, a shape's outline is its skeleton's rather than its `indicatorPath`: its
    /// kind's own (`CustomSkeletonOutline`), else its kept geometry's, as the default skeleton fills
    /// it, and a shape only a few pixels across is outlined by its bounds (a line from its first
    /// point to its last, if it's open), as its default skeleton is drawn; the shape being edited,
    /// drawn in full, keeps its own. ⌘A zoomed out outlines every shape in view, and stroking a
    /// path costs far more than filling one, so there a rect (most shapes' geometry, and a plugin's
    /// rects) isn't stroked but filled as a ring, the rect grown by half the line less the rect
    /// shrunk by as much: what the stroke paints, but that its corners are square. Nothing here
    /// makes an array per shape.
    private func strokeOutlines(of ids: [ShapeID], rects: [CGRect], in color: NSColor, width: CGFloat, around area: CGRect,
                                skeletonPixel: CGFloat?, context: CGContext, shapes: ShapeContext) {
        guard !ids.isEmpty || !rects.isEmpty else { return }
        let zoom = camera.zoom, line = width / zoom
        // What a closed shape's outline drawn in full stands off its edge by, in world units; the area
        // reaches that far too, but not zoomed out, where nothing stands off (but the shape being edited).
        let gap = outlineStandoff / zoom
        let reach = line + (skeletonPixel == nil ? gap : 0)
        let area = area.insetBy(dx: -reach, dy: -reach)
        let skeletonOutlines = registry.skeletonOutlines, editing = editingShapeID
        let strokes = CGMutablePath(), rings = CGMutablePath()
        for id in ids {
            guard shapeIndex.extent(of: id, in: shapes)?.touches(area) == true, let entry = shapeIndex.entry(for: id, in: shapes) else { continue }
            let offset = drawingOffsets[id].map { CGPoint(x: $0.x / zoom, y: $0.y / zoom) } ?? .zero
            let shift = CGAffineTransform(translationX: offset.x, y: offset.y)
            if let pixel = skeletonPixel, id != editing {
                let geometry = entry.geometry.flatMap { $0.outline.isEmpty ? nil : $0 }
                let bounds = geometry.map { $0.bounds.offsetBy(dx: offset.x, dy: offset.y) }
                if let geometry, let bounds, Silhouettes.form(of: geometry.bounds, pixel: pixel) != .outline {
                    if geometry.isClosed {
                        Self.addRing(around: bounds, line: line, to: rings)
                    } else {
                        strokes.move(to: geometry.outline[0], transform: shift)
                        strokes.addLine(to: geometry.outline[geometry.outline.count - 1], transform: shift)
                    }
                    continue
                }
                if !skeletonOutlines.isEmpty, let record = shapes.storedDocument[id],
                   let own = skeletonOutlines[record.kind]?.erasedSkeletonIndicatorPath(of: record, in: shapes) {
                    strokes.addPath(own, transform: shift)
                    continue
                }
                if let geometry, let bounds {
                    if geometry.isClosed, Self.isRect(geometry.outline, bounds: geometry.bounds) {
                        Self.addRing(around: bounds, line: line, to: rings)
                    } else {
                        strokes.addLines(between: geometry.outline, transform: shift)
                        if geometry.isClosed { strokes.closeSubpath() }
                    }
                    continue
                }
            }
            if let record = shapes.storedDocument[id],
               let indicator = registry.definition(for: record.kind)?.erasedIndicatorPath(of: record, in: shapes) {
                addOutline(of: indicator, geometry: entry.geometry, standingOff: gap, to: strokes, transform: shift)
            }
        }
        for rect in rects where rect.touches(area) {
            if skeletonPixel != nil {
                Self.addRing(around: rect, line: line, to: rings)
            } else if gap > 0 {
                strokes.addRoundedRect(in: rect.insetBy(dx: -gap, dy: -gap), cornerWidth: gap, cornerHeight: gap)
            } else {
                strokes.addRect(rect)
            }
        }
        guard !strokes.isEmpty || !rings.isEmpty else { return }
        context.saveGState()
        // A translucent color painted twice where a ring and a stroke meet would be darker there:
        // painted opaque into a layer, which takes the color's alpha as a whole.
        var ink = color.cgColor
        let layered = ink.alpha < 1 && !strokes.isEmpty && !rings.isEmpty
        if layered {
            context.setAlpha(ink.alpha)
            context.beginTransparencyLayer(auxiliaryInfo: nil)
            ink = ink.copy(alpha: 1) ?? ink
        }
        if !rings.isEmpty {
            context.addPath(rings)
            context.setFillColor(ink)
            context.fillPath()
        }
        if !strokes.isEmpty {
            context.addPath(strokes)
            context.setStrokeColor(ink)
            context.setLineWidth(line)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.strokePath()
        }
        if layered { context.endTransparencyLayer() }
        context.restoreGState()
    }

    /// Whether a closed outline is its bounds: four corners of them, one after another around it.
    private static func isRect(_ outline: [CGPoint], bounds: CGRect) -> Bool {
        outline.count == 4 && (0..<4).allSatisfy { i in
            let a = outline[i], b = outline[(i + 1) % 4]
            return (a.x == bounds.minX || a.x == bounds.maxX) && (a.y == bounds.minY || a.y == bounds.maxY) && (a.x == b.x) != (a.y == b.y)
        }
    }

    /// What stroking a rect `line` wide paints, with square corners, as a fill: the rect grown by
    /// half the line, less (wound the other way, so rings filled together with the nonzero rule
    /// make their union) the rect shrunk by as much, if anything's left of it.
    private static func addRing(around rect: CGRect, line: CGFloat, to path: CGMutablePath) {
        path.addRect(rect.insetBy(dx: -line / 2, dy: -line / 2))
        let inner = rect.insetBy(dx: line / 2, dy: line / 2)
        guard inner.width > 0, inner.height > 0 else { return }
        path.move(to: CGPoint(x: inner.minX, y: inner.minY))
        path.addLine(to: CGPoint(x: inner.minX, y: inner.maxY))
        path.addLine(to: CGPoint(x: inner.maxX, y: inner.maxY))
        path.addLine(to: CGPoint(x: inner.maxX, y: inner.minY))
        path.closeSubpath()
    }
}
