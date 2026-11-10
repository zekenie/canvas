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
        let previews = boardPreviews, zoom = camera.zoom
        if previews.isPending { previews.build(in: file, until: .now + previews.frameBudget) }
        /// The previews drawn by a shape drawn at `zoom` (its own, or through a stand-in that scales it).
        func previewAt(_ zoom: CGFloat) -> (ShapeID, CGRect, CGFloat, CGContext) -> Bool {
            { (owner: ShapeID, rect: CGRect, maxScale: CGFloat, cg: CGContext) in
                // Too small on screen to show anything (zoomed out, or no room): nothing asked for.
                guard min(rect.width, rect.height) * zoom >= Style.previewSmallestSide else { return false }
                guard let built = previews.preview(of: BoardID(owner: owner), in: file) else { return false }
                return previews.draw(built, in: cg, fitting: rect, maxScale: maxScale)
            }
        }
        let preview = previewAt(zoom)
        // Skeletons or not, decided once for the frame; the shape being edited is drawn in full, and so is the stand-in it's
        // edited through.
        let skeletons = drawsSkeletons, editing = editingShapeID, standIn = editingStandIn, customSkeletons = registry.customSkeletons
        let deviceScale = context.userSpaceToDeviceSpaceTransform
        let ink = SkeletonInk(fill: Style.skeleton.cgColor, text: Style.skeletonText.cgColor,
                              pixel: 1 / max(hypot(deviceScale.a, deviceScale.b), .leastNormalMagnitude))
        // What a shape drawn in another's place draws with (`RenderContext.drawShape(inFile:through:standingIn:)`).
        let shownFrame = ShownFrame(skeletons: skeletons, ink: ink, shapeCount: shapeCount, preview: previewAt, fileShape: fileShape, lend: lend)
        let shown = { [unowned self] (id: ShapeID, transform: CGAffineTransform, standIn: ShapeID) in
            drawShown(id, through: transform, standingIn: standIn, in: context, with: shownFrame)
        }
        /// A shape as the frame draws it: its skeleton zoomed out (but the one being edited), else its render.
        func drawShape(_ record: AnyShapeRecord, in shapes: ShapeContext) {
            guard let definition = registry.definition(for: record.kind) else { return }
            drawIsolated(context) {
                if !offsets.isEmpty, let offset = offsets[record.id] {
                    context.translateBy(x: offset.x / zoom, y: offset.y / zoom)
                }
                let render = RenderContext(cg: context, shapes: shapes, isEditing: record.id == editing, isEditedThrough: record.id == standIn,
                                           shapeCount: shapeCount, preview: preview, fileShape: fileShape, lend: lend, shadows: shapeShadows,
                                           skeleton: ink, shown: shown)
                render.drawAsFrameDoes(record, by: definition, skeleton: skeletons && record.id != editing && record.id != standIn,
                                       customSkeletons: customSkeletons)
            }
        }
        for record in paintOrder(in: drawn) { drawShape(record, in: shapes) }
        previews.endFrame()
        if previews.isPending, nextPreviewFrame == nil {
            nextPreviewFrame = scheduler.schedule(after: .zero) { [weak self] in
                self?.nextPreviewFrame = nil
                self?.setNeedsDisplay()
            }
        }
        let (outlines, hint) = outlinesAndHint
        let tinted = outlines.tinted.isEmpty ? nil : TintedRings(outlines, hint: hint, members: outlineMembers)
        drawOutlines(outlines, hint: hint, tinted: tinted, in: context, shapes: shapes, around: drawn, skeletonPixel: skeletons ? ink.pixel : nil)
        // The shapes waiting to be placed (`placeLater`), faint, over the board's and its outlines, under what
        // overlays draw (which decorate them too): a context over them alone, so each has its geometry, laid out
        // as shapes of the file where they'd land.
        let pending = pendingShapes
        let pendingContext = pending.isEmpty ? shapes : shapes.layingOut(with: pending).over(CanvasDocument(shapes: pending))
        if !pending.isEmpty {
            Self.drawingPending(in: context) {
                for record in pending { drawShape(record, in: pendingContext) }
            }
        }
        let overlayContext = OverlayContext(cg: context, editor: self, shapes: shapes, visibleRect: world, drawsSkeletons: skeletons,
                                            tintedRings: tinted, pendingShapes: pending, pendingContext: pendingContext)
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

    /// How many shapes' shadows were left out because their fills hid them (debug builds):
    /// `RenderContext.fillWithShadow` on a shape holding everything the context draws into.
    @_spi(Host) public var shadowsSkipped: Int { shapeShadows.skipped }

    /// Whether every shape's shadow is drawn, even one its fill hides (debug builds): the control
    /// a test of leaving them out compares against.
    @_spi(Host) public var shadowsAlwaysDrawn: Bool {
        get { shapeShadows.alwaysDrawn }
        set { shapeShadows.alwaysDrawn = newValue }
    }

    /// Whether finding the shapes in a rect (`paintOrder(in:)`) and under a point (`shape(at:where:)`) goes through every
    /// shape's extent instead of the cells that cover them, and outlining a long list of shapes goes through each of the list
    /// instead of the shapes in view (debug builds): the control a test of the grid and the outlines compares against.
    /// The board shown now; another board shown has its own.
    @_spi(Host) public var scansEveryShape: Bool {
        get { shapeIndex.scansEveryExtent }
        set { shapeIndex.scansEveryExtent = newValue }
    }

    /// How many grids over the paint list's extents the board shown has made, and how many times its paint list was
    /// built (debug builds): a commit that adds shapes at the top of the stack makes neither again.
    @_spi(Host) public var spatialGridsMade: Int { shapeIndex.gridsMade }
    @_spi(Host) public var paintListsBuilt: Int { shapeIndex.paintListsBuilt }

    /// How many sets of the shapes in a list outlined have been made (debug builds): one for a list, kept while it is the same.
    @_spi(Host) public var outlineSetsMade: Int { outlineMembers.made }
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
    public func drawsSkeleton(of id: ShapeID) -> Bool { drawsSkeletons && id != editingShapeID && id != editingStandIn }

    // MARK: Pictures of the board
    //
    // What a view that shows the board away from the canvas (the minimap) goes by. Such a picture is
    // kept from frame to frame and redrawn only where shapes moved or changed shape: `damage(since:)`
    // says where. It shows where shapes are, not which is on top: the paint order isn't damage.

    /// What the canvas outlines now: every plugin's outlines (none while the session hides them),
    /// with the hint among the shapes; a shape outlined in full isn't among the faint ones too, and
    /// every plugin's tinted groups are kept as they come, in plugin order; the color is the one every
    /// plugin with full outlines names, else none (the accent). A picture of the board marks the same
    /// shapes.
    @_spi(Host) public var outlines: Outlines {
        var (outlines, hint) = outlinesAndHint
        if let hint { outlines.shapes.append(hint) }
        return outlines
    }

    /// `outlines` less the hint, which is not appended to `shapes`: a selection of every shape would be copied to add it.
    /// The faint shapes leave out the hint too, as they do the shapes.
    private var outlinesAndHint: (outlines: Outlines, hint: ShapeID?) {
        var outlines = Outlines()
        if session?.hidesOutlines != true {
            // The color the full outlines are named in, while every plugin with some names the same.
            var named: NSColor??
            for source in registry.outlineSources {
                let more = source(self)
                if !more.shapes.isEmpty || !more.rects.isEmpty {
                    if let first = named { if first != more.color { named = .some(nil) } } else { named = .some(more.color) }
                }
                // The first list of shapes is taken as it is, not copied (⌘A's is every shape).
                if outlines.shapes.isEmpty { outlines.shapes = more.shapes } else if !more.shapes.isEmpty { outlines.shapes += more.shapes }
                if !more.faintShapes.isEmpty { outlines.faintShapes += more.faintShapes }
                if !more.rects.isEmpty { outlines.rects += more.rects }
                if !more.tinted.isEmpty { outlines.tinted += more.tinted }
            }
            outlines.color = named ?? nil
        }
        let hint = hintedShapeID
        if !outlines.faintShapes.isEmpty, !outlines.shapes.isEmpty || hint != nil {
            outlines.faintShapes = Self.faint(outlines.faintShapes, leavingOut: outlines.shapes, and: hint)
        }
        return (outlines, hint)
    }

    /// The faint outlines less those outlined in full (and the hint, which is), with no set of all of those (⌘A's is every
    /// shape): each of a few (a hover) is looked for among them, which compares ids, cheaper than
    /// hashing them; more, in one pass over them.
    private static func faint(_ faint: [ShapeID], leavingOut full: [ShapeID], and hint: ShapeID?) -> [ShapeID] {
        guard faint.count > 8 else { return faint.filter { $0 != hint && !full.contains($0) } }
        var unfound = Set(faint)
        let count = unfound.count
        if let hint { unfound.remove(hint) }
        for id in full {
            unfound.remove(id)
            if unfound.isEmpty { return [] }
        }
        return unfound.count == count ? faint : faint.filter(unfound.contains)
    }

    /// Whether any shape's geometry, as the editor keeps it, was worked out from the camera (its kind's geometry read the
    /// camera or the zoom): if none was, a pan or a zoom changes no shape's geometry, so what a plugin keeps that is worked
    /// out from geometries (the selection's bounds) is still right after one.
    public var geometriesReadCamera: Bool { shapeIndex.readsCamera }

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

    /// Draws as shapes waiting to be placed are drawn: at `Style.pendingOpacity`, as one layer, so
    /// what overlaps within it (a shape and its shadow) isn't darkened twice.
    static func drawingPending(in context: CGContext, _ draw: () -> Void) {
        context.saveGState()
        context.setAlpha(Style.pendingOpacity)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        draw()
        context.endTransparencyLayer()
        context.restoreGState()
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

    /// Every plugin's outlines (unless the session hides them), then the hint, in one pass at a
    /// constant screen width; under them, in a wider, lighter pass of their own, the faint ones, and
    /// under those the tinted groups, one pass each in its color, in the order they came: a group's
    /// ring stands off a line and a gap (`Style.tintedIndicatorWidth`, `tintedRingGap`) further out
    /// for each ring it's past the first, so a shape in two groups shows both, and a shape outlined
    /// in full too has its tint one ring further out, clear of the selection's line. The faint ones
    /// are the shape the groups are about, and are stronger beside them.
    /// Only what meets `area` (world units, what the shapes were drawn for, and in full grown by what
    /// an outline stands off by) is asked for its path and stroked: a shape outlined out of view costs
    /// nothing, however it's outlined, when many shapes are and few are in view (`strokeOutlines`), else a
    /// look at its kept extent. `skeletonPixel` is how big a pixel is (world units)
    /// while shapes are drawn as skeletons, nil while they aren't.
    private func drawOutlines(_ outlines: Outlines, hint: ShapeID?, tinted: TintedRings?, in context: CGContext, shapes: ShapeContext,
                              around area: CGRect, skeletonPixel: CGFloat?) {
        for group in outlines.tinted {
            let outset = CGFloat(max(group.ring, 0)) * Style.tintedRingPitch
            strokeOutlines(of: group.shapes, rects: [], in: group.color, width: Style.tintedIndicatorWidth, outset: outset, around: area,
                           skeletonPixel: skeletonPixel, context: context, shapes: shapes, tinted: tinted)
        }
        let faint = outlines.tinted.isEmpty ? Style.faintIndicatorOpacity : Style.tintedFaintIndicatorOpacity
        strokeOutlines(of: outlines.faintShapes, rects: [], in: Style.accent.withAlphaComponent(faint),
                       width: Style.faintIndicatorWidth, around: area, skeletonPixel: skeletonPixel, context: context, shapes: shapes)
        strokeOutlines(of: outlines.shapes, plus: hint, rects: outlines.rects, in: outlines.color ?? Style.accent, width: Style.indicatorWidth,
                       around: area, skeletonPixel: skeletonPixel, context: context, shapes: shapes)
    }

    /// How many shapes a list may have to be looked up one by one whatever is in view.
    private static let outlinesLookedUp = 32

    /// `width` and `outset` are in view points; `outset` is how much further out than the others a
    /// tinted ring stands (zero for every other outline): a closed shape's outline, drawn in full,
    /// stands off its edge by the standoff and the outset, and zoomed out its ring on the frame is
    /// grown by the outset; an open shape's is on its own path whatever the outset. A shape drawn
    /// away from where it is has its outline there too.
    ///
    /// `tinted` is given for a tinted group's pass, and says two things that are the groups' alone.
    /// A shape that's outlined in full too stands one ring further out, clear of the selection's
    /// line, which lies over most of ring 0 (looked up only for the shapes that meet `area`, a few
    /// outlined in full compared one by one, many through one set). And an open shape of a kind
    /// drawn as a line (`StrokedShape`), in full, is covered: stroked as wide as its line is on
    /// screen and `Style.tintedCoverPad` more, round, never narrower than `width`, so its own line
    /// and its heads don't show along the middle of the outline; zoomed out, where its skeleton is
    /// a line a view point wide, it's the outline's own width.
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
    ///
    /// `extra` is one shape more than `ids` has (the hint). A few shapes, or a list most of whose shapes are in
    /// view, are each looked up for their kept extent; a longer list with few in view (⌘A on a board of thousands)
    /// costs the shapes in view, each asked whether it is in the list (`outlineMembers`, a set kept while the list is the
    /// same), so a shape out of view costs nothing, selected or not.
    private func strokeOutlines(of ids: [ShapeID], plus extra: ShapeID? = nil, rects: [CGRect], in color: NSColor, width: CGFloat, outset: CGFloat = 0,
                                around area: CGRect, skeletonPixel: CGFloat?, context: CGContext, shapes: ShapeContext, tinted: TintedRings? = nil) {
        guard !ids.isEmpty || extra != nil || !rects.isEmpty else { return }
        let zoom = camera.zoom, line = width / zoom
        // How far a ring stands out past the others', in world units: its ring on a skeleton's frame
        // is grown by it, and it's part of what a closed shape's outline drawn in full stands off its
        // edge by, which the area reaches too, but not zoomed out, where only a ring's outset stands
        // off (but the shape being edited, drawn in full, keeps its own). A shape outlined in full
        // too is one ring further out than that.
        let away = outset / zoom
        let gap = outlineStandoff / zoom + away
        let lifts = tinted?.hasOutlinedInFull == true
        let liftedAway = away + Style.tintedRingPitch / zoom, liftedGap = gap + Style.tintedRingPitch / zoom
        let reach = line + (skeletonPixel == nil ? (lifts ? liftedGap : gap) : (lifts ? liftedAway : away))
        let area = area.insetBy(dx: -reach, dy: -reach)
        let skeletonOutlines = registry.skeletonOutlines, editing = editingShapeID, standIn = editingStandIn
        let strokedShapes = tinted == nil ? [:] : registry.strokedShapes
        let strokes = CGMutablePath(), rings = CGMutablePath()
        // What covers a line drawn as wide as its kind says, for each width.
        var covers: [CGFloat: CGMutablePath] = [:]
        /// Adds the outline of a shape whose extent meets the area.
        func outline(_ id: ShapeID, _ entry: ShapeIndex.Entry) {
            let offset = drawingOffsets[id].map { CGPoint(x: $0.x / zoom, y: $0.y / zoom) } ?? .zero
            let shift = CGAffineTransform(translationX: offset.x, y: offset.y)
            let lifted = lifts && tinted?.isOutlinedInFull(id) == true
            let shapeAway = lifted ? liftedAway : away, shapeGap = lifted ? liftedGap : gap
            if let pixel = skeletonPixel, id != editing, id != standIn {
                let geometry = entry.geometry.flatMap { $0.outline.isEmpty ? nil : $0 }
                let bounds = geometry.map { $0.bounds.offsetBy(dx: offset.x, dy: offset.y) }
                if let geometry, let bounds, Silhouettes.form(of: geometry.bounds, pixel: pixel) != .outline {
                    if geometry.isClosed {
                        Self.addRing(around: bounds.insetBy(dx: -shapeAway, dy: -shapeAway), line: line, to: rings)
                    } else {
                        strokes.move(to: geometry.outline[0], transform: shift)
                        strokes.addLine(to: geometry.outline[geometry.outline.count - 1], transform: shift)
                    }
                    return
                }
                if !skeletonOutlines.isEmpty, let record = shapes.storedDocument[id],
                   let own = skeletonOutlines[record.kind]?.erasedSkeletonIndicatorPath(of: record, in: shapes) {
                    strokes.addPath(own, transform: shift)
                    return
                }
                if let geometry, let bounds {
                    // A ring past the first is on the frame, grown, whatever the outline: there's no
                    // growing an outline that isn't a rect, which costs far more than a ring.
                    if geometry.isClosed, shapeAway > 0 || Self.isRect(geometry.outline, bounds: geometry.bounds) {
                        Self.addRing(around: bounds.insetBy(dx: -shapeAway, dy: -shapeAway), line: line, to: rings)
                    } else {
                        strokes.addLines(between: geometry.outline, transform: shift)
                        if geometry.isClosed { strokes.closeSubpath() }
                    }
                    return
                }
            }
            if let record = shapes.storedDocument[id],
               let indicator = registry.definition(for: record.kind)?.erasedIndicatorPath(of: record, in: shapes) {
                if !strokedShapes.isEmpty, entry.geometry?.isClosed == false,
                   let lineWidth = strokedShapes[record.kind]?.erasedLineWidth(of: record, in: shapes) {
                    let coverWidth = max(line, lineWidth + Style.tintedCoverPad / zoom)
                    let cover = covers[coverWidth] ?? CGMutablePath()
                    cover.addPath(indicator, transform: shift)
                    covers[coverWidth] = cover
                } else {
                    addOutline(of: indicator, geometry: entry.geometry, standingOff: shapeGap, to: strokes, transform: shift)
                }
            }
        }
        // Few shapes, or most of a long list in view: each looked up for its extent. A long list with few in view: the shapes
        // in view, each asked whether it is in the list.
        var inView: [Int]?
        if ids.count > Self.outlinesLookedUp, !shapeIndex.scansEveryExtent {
            let found = shapeIndex.positions(touching: area, in: shapes)
            if found.count * 2 < ids.count { inView = found }
        }
        if let inView {
            let members = outlineMembers.members(of: ids)
            let list = shapeIndex.paintList(in: shapes), all = shapes.storedDocument.shapes
            for position in inView {
                let id = all[list.order[position]].id
                guard members.contains(id) || id == extra, let entry = shapeIndex.entry(for: id, in: shapes) else { continue }
                outline(id, entry)
            }
        } else {
            for id in ids {
                guard shapeIndex.extent(of: id, in: shapes)?.touches(area) == true, let entry = shapeIndex.entry(for: id, in: shapes) else { continue }
                outline(id, entry)
            }
            if let extra, shapeIndex.extent(of: extra, in: shapes)?.touches(area) == true, let entry = shapeIndex.entry(for: extra, in: shapes) {
                outline(extra, entry)
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
        guard !strokes.isEmpty || !rings.isEmpty || !covers.isEmpty else { return }
        context.saveGState()
        // A translucent color painted twice where a ring, a stroke and a cover meet would be darker
        // there: painted opaque into a layer, which takes the color's alpha as a whole.
        var ink = color.cgColor
        let layered = ink.alpha < 1 && (rings.isEmpty ? 0 : 1) + (strokes.isEmpty ? 0 : 1) + (covers.isEmpty ? 0 : 1) > 1
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
        if !strokes.isEmpty || !covers.isEmpty {
            context.setStrokeColor(ink)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            if !strokes.isEmpty {
                context.addPath(strokes)
                context.setLineWidth(line)
                context.strokePath()
            }
            for (coverWidth, cover) in covers {
                context.addPath(cover)
                context.setLineWidth(coverWidth)
                context.strokePath()
            }
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

extension RenderContext {
    /// A shape as a frame draws it with this context: as a skeleton (`skeleton`: its kind's own, else the default one in the
    /// skeleton ink's fill), else by its kind's render. The board's frame draws each shape so, and so does a shape drawn in
    /// another's place (`drawShape(inFile:through:standingIn:)`).
    func drawAsFrameDoes(_ record: AnyShapeRecord, by definition: any ShapeDefinition, skeleton: Bool,
                         customSkeletons: [ShapeKind: any CustomSkeleton]) {
        guard skeleton else { return definition.erasedRender(record, in: self) }
        if let custom = customSkeletons[record.kind] {
            custom.erasedRenderSkeleton(record, in: self)
        } else if let geometry = shapes.geometry(of: record.id) {
            fillSkeleton(of: geometry, color: self.skeleton.fill)
        }
    }
}
