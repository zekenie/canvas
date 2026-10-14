import AppKit
import Geometry

/// A shape's outline, in world coordinates.
public struct ShapeGeometry: Sendable {
    /// A closed polygon for shapes with an inside; the path's points otherwise.
    public var outline: [CGPoint]
    public var bounds: CGRect
    /// Whether the shape has an inside. Open shapes are hit near their outline only by their own
    /// `hitTest`, and nothing can be attached inside them.
    public var isClosed: Bool
    /// Where its text label is, for a shape whose text is on part of it (an arrow's, tldraw's
    /// `isLabel` geometry), within `bounds`; nil for none. Kept with the rest, so what's drawn zoomed
    /// out (a skeleton) and what's hit find it without working it out again.
    public var label: CGRect?

    public init(outline: [CGPoint], bounds: CGRect? = nil, isClosed: Bool = true, label: CGRect? = nil) {
        self.outline = outline
        self.bounds = bounds ?? CGRect(enclosing: outline)
        self.isClosed = isClosed
        self.label = label
    }
}

/// Read-only lookups for definitions, overlays and plugins.
///
/// The editor keeps each shape's geometry from frame to frame, until the shape changes or a shape
/// its definition looked up while working it out does. So a definition that looks at other shapes
/// (a connector, at the shapes it joins) does it through `shape(_:)`, `geometry(of:)` and
/// `hitTest(_:shape:)`, which keep track. Reading all of `document`, or `camera`, while working
/// out a geometry ties that geometry to every change of them.
@MainActor
public struct ShapeContext {
    public var document: CanvasDocument {
        currentIndex?.noteReadingDocument()
        return storedDocument
    }
    public let registry: Registry
    public var camera: Camera {
        currentIndex?.noteReadingCamera()
        return storedCamera
    }
    public var zoom: CGFloat { camera.zoom }

    let storedDocument: CanvasDocument
    let storedCamera: Camera
    /// The editor's index, if this context was made from the editor's document and camera; used
    /// while they're still the editor's (`generation`).
    private let index: ShapeIndex?
    private let generation: Int
    /// What shapes are laid out with, if this context is the editor's, a transaction's or a run's
    /// (`layoutInput`).
    let layout: LayoutSource?

    /// Lookups in a document of your own (shapes copied, say), whose geometry is worked out as it's
    /// asked for. The editor's is `editor.shapeContext`, and a transaction's `transaction.shapes`.
    public init(document: CanvasDocument, registry: Registry, camera: Camera = Camera()) {
        self.init(document: document, registry: registry, camera: camera, index: nil)
    }

    init(document: CanvasDocument, registry: Registry, camera: Camera, index: ShapeIndex?, layout: LayoutSource? = nil) {
        self.layout = layout
        storedDocument = document
        self.registry = registry
        storedCamera = camera
        self.index = index
        generation = index?.generation ?? 0
    }

    /// One of the editor's services, if this context is the editor's, a transaction's or a run's: what a maker
    /// that works without a gesture reads besides the shapes (Topology's arrows, say), as the editor holds it
    /// committed, not as a transaction in flight leaves it. Nil if no installed plugin registers it.
    public func service<S: EditorService>(_: S.Type) -> S? { layout?.lend(ObjectIdentifier(S.self)) as? S }

    private var currentIndex: ShapeIndex? {
        guard let index, index.generation == generation else { return nil }
        return index
    }

    /// A geometry being worked out reads more than one shape: it's worked out again on every change
    /// of the board, as one that reads `document` is.
    func currentIndexNotesDocument() { currentIndex?.noteReadingDocument() }

    /// A shape, by id.
    public func shape(_ id: ShapeID) -> AnyShapeRecord? {
        currentIndex?.noteRead(id)
        return storedDocument[id]
    }

    public func geometry(of id: ShapeID) -> ShapeGeometry? {
        if let index = currentIndex { return index.entry(for: id, in: self)?.geometry }
        guard let record = storedDocument[id], let definition = registry.definition(for: record.kind) else { return nil }
        return definition.erasedGeometry(of: record, in: self)
    }

    /// A shape's bounds where it has an inside (its geometry is closed), in world units, if they're
    /// finite and have a width and a height. Nil for a shape that has none: one kept aside
    /// (`isOpaque`), one without an inside (an arrow, a line), one that isn't there, and one whose
    /// bounds are null, not finite or flat. What shapes placed among others keep clear of:
    /// `canvas draw` keeps what it draws clear of every such shape it doesn't move, and moving a
    /// shape near another does the same.
    public func solidBounds(of id: ShapeID) -> CGRect? {
        guard let record = shape(id), !record.isOpaque, let geometry = geometry(of: id), geometry.isClosed else { return nil }
        let bounds = geometry.bounds
        guard !bounds.isNull, bounds.isFinite, bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }

    /// The union of the shapes' geometry bounds, in world units: what boxes a selection, or brings
    /// shapes into view. Shapes with no outline (nothing drawn) don't count; nil if none is left.
    public func bounds(of ids: some Sequence<ShapeID>) -> CGRect? {
        var union: CGRect?
        func add(_ id: ShapeID) {
            if let bounds = outlineBounds(of: id) { union = union?.union(bounds) ?? bounds }
        }
        // An array's ids are read from its storage, with no call through the generic for each (a
        // selection of every shape is thousands).
        if ids.withContiguousStorageIfAvailable({ $0.forEach(add) }) == nil { ids.forEach(add) }
        return union
    }

    /// The bounds of a shape's geometry, nil for one with no outline, or none.
    private func outlineBounds(of id: ShapeID) -> CGRect? {
        if let index = currentIndex { return index.outlineBounds(of: id, in: self) }
        guard let geometry = geometry(of: id), !geometry.outline.isEmpty, !geometry.bounds.isNull else { return nil }
        return geometry.bounds
    }

    /// Whether a world point hits the shape, by its definition's own test.
    public func hitTest(_ point: CGPoint, shape id: ShapeID) -> Bool {
        if let index = currentIndex {
            // Nowhere near it, it's a miss, and there's no need to ask.
            guard let entry = index.entry(for: id, in: self),
                  ShapeIndex.mayHit(point, extent: entry.extent, margin: entry.hitMargin, zoom: storedCamera.zoom) else { return false }
        }
        guard let record = storedDocument[id], let definition = registry.definition(for: record.kind) else { return false }
        return definition.erasedHitTest(point, on: record, in: self)
    }
}

/// How far past its geometry a shape can still be hit (`ShapeDefinition.hitMargin`): world units,
/// plus view points, which are divided by the zoom.
public struct HitMargin: Equatable, Sendable {
    public var world: CGFloat
    public var view: CGFloat
    public init(world: CGFloat = 0, view: CGFloat = 0) {
        self.world = world
        self.view = view
    }
}

/// What a shape draws with. Each render gets a fresh graphics state, and AppKit drawing
/// (`NSAttributedString.draw`, `NSColor.setFill`) goes to the same context.
@MainActor
public struct RenderContext {
    /// The camera transform is applied: draw in world units.
    public let cg: CGContext
    public let shapes: ShapeContext
    /// This shape's editing view is showing.
    public let isEditing: Bool
    public var zoom: CGFloat { shapes.zoom }
    private let boardShapeCount: (ShapeID) -> Int
    private let boardPreview: (ShapeID, CGRect, CGFloat, CGContext) -> Bool
    private let fileShape: (ShapeID) -> AnyShapeRecord?
    private let lend: (ObjectIdentifier) -> (any EditorService)?
    private let shadows: ShapeShadows
    let skeleton: SkeletonInk

    init(cg: CGContext, shapes: ShapeContext, isEditing: Bool, shapeCount: @escaping (ShapeID) -> Int,
         preview: @escaping (ShapeID, CGRect, CGFloat, CGContext) -> Bool, fileShape: @escaping (ShapeID) -> AnyShapeRecord?,
         lend: @escaping (ObjectIdentifier) -> (any EditorService)?, shadows: ShapeShadows, skeleton: SkeletonInk) {
        self.cg = cg
        self.shapes = shapes
        self.isEditing = isEditing
        boardShapeCount = shapeCount
        boardPreview = preview
        self.fileShape = fileShape
        self.lend = lend
        self.shadows = shadows
        self.skeleton = skeleton
    }

    /// A shape on any board of the file the editor can show: one on the board shown as
    /// `shapes.shape(_:)` finds it (tracked), else one on another board, as it is now (nil for one
    /// on a board it can't show, as `CanvasEditor.shape(inFile:)`). What a render that names shapes
    /// (a mention's pill, which shows its shape's name) reads, so a name of a shape on another
    /// board shows as that shape is called. Like `shapeCount(inBoardOwnedBy:)`, it's read as the shape is
    /// drawn, and a write to a board that isn't shown redraws the canvas, so a name drawn is never
    /// stale; nothing but a render can read another board.
    public func shape(inFile id: ShapeID) -> AnyShapeRecord? { shapes.shape(id) ?? fileShape(id) }

    /// One of the file's own values (`FileProperty`: the colors a file names), as the file holds it
    /// now, or the property's default: what a render reads of the file that is no shape's, with no
    /// service. It's read as the shape is drawn, and the commit that changes one redraws the canvas,
    /// so what's drawn from it is never stale; a geometry never reads one here (a layout provider
    /// may, `LayoutReading.fileValue`, and then says when it changes). Read through what the frame's
    /// shapes are laid out with, the editor's file, so a render context costs nothing more for it.
    public func fileValue<P: FileProperty>(_: P.Type) -> P.Value { shapes.layout?.fileValues()[P.self] ?? P.defaultValue }

    /// One of the editor's services, as `EditContext.service(_:)` lends an editing view's: what a
    /// render needs besides its own shape and the file (an answer a service worked out off the main
    /// thread). Nil if no installed plugin registers it. Nothing observes a render, so a lending
    /// service must call `editor.setNeedsDisplay()` when what it lends changes, or what's drawn goes
    /// stale: it's read as the shape is drawn, and a shape not in view, or drawn as a skeleton, isn't.
    public func service<S: EditorService>(_: S.Type) -> S? { lend(ObjectIdentifier(S.self)) as? S }

    /// How many shapes are on the board a shape owns (a `BoardOwning` kind's shape), not counting
    /// those on boards under it: 0 for a board with none, or a shape that owns none. A render may
    /// show it; nothing else can read another board, so a shape's geometry and hit testing never
    /// depend on one. It's read as the shape is drawn, and a write to a board that isn't shown
    /// (`transact(on:)`) redraws the canvas as any commit does, so a count drawn is never stale.
    public func shapeCount(inBoardOwnedBy owner: ShapeID) -> Int { boardShapeCount(owner) }

    /// Draws a rough picture of the board a shape owns into `rect` (world units), fitted: the
    /// board's proportions kept, centered, and no larger than `maxScale` times its own size, so a
    /// board of a few shapes is drawn small in the middle of the rect rather than as big as one of
    /// hundreds (a card's preview at 0.1 shows its board as the canvas does at 10%). Every shape there is a silhouette of its geometry, all in
    /// one muted gray (none of their text or colors; a shape that owns a board is its outline), as
    /// the minimap draws: a picture of 256 pixels at most, and shown larger than that (zoomed in, or
    /// on a sharper screen), the shapes in view as paths, sharp at any size, up to a frame's worth
    /// of them. Returns false, having drawn nothing, while the picture isn't ready, for a
    /// board with nothing to show (none, or empty), and for a rect too small on screen to show one
    /// (under 16 view points either way): draw something else then (a count). A picture
    /// takes a few frames to build (the core builds them within a budget each frame, and redraws
    /// until they're done), and one of a board as it was before an edit or an undo is never drawn.
    public func drawBoardPreview(ofBoardOwnedBy owner: ShapeID, in rect: CGRect, maxScale: CGFloat = .infinity) -> Bool {
        boardPreview(owner, rect, maxScale, cg)
    }

    /// Fills a path over the canvas's standard shape shadow, 6 world units of blur all round on
    /// screen. The shadow is left out where the fill hides it all, an opaque color over everything
    /// the context draws into (a shape zoomed in past the view's edges), so the picture is the same
    /// and a shape bigger than the view costs a fill, not a blur of the view. Call it with the
    /// context's alpha and blend mode as the fresh state has them: the fill is taken to paint its
    /// color as it is.
    public func fillWithShadow(_ path: CGPath, _ color: NSColor) {
        shadows.fill(path, with: color.cgColor, zoom: zoom, in: cg)
    }

    // MARK: Skeletons

    /// The default skeleton (`CustomSkeleton`): a geometry (the shape's, kept:
    /// `shapes.geometry(of:)`) as a rough picture of the board draws it, a closed outline filled
    /// and an open one stroked a view point wide, in one neutral gray unless `color` says
    /// otherwise; no shadow, nothing inside. A shape only a few pixels across is its bounds (a line
    /// from its first point to its last, if it's open), and one under a pixel the whole device
    /// pixel its middle is in, as the minimap's silhouettes are. What the core draws for a kind
    /// without a skeleton of its own, and what one may start from. It paints as `fillPath` does, so
    /// call it with no path of your own under way.
    public func drawSkeleton(of geometry: ShapeGeometry, color: NSColor? = nil) {
        cg.saveGState()
        fillSkeleton(of: geometry, color: color?.cgColor ?? skeleton.fill)
        cg.restoreGState()
    }

    /// Greeked text: bars where a skeleton's text would be (world units; a line's worth each), in
    /// one fill of the canvas's text-bar color, a translucent dark that reads on a shape's light
    /// body, so every kind's greeked text looks alike. The kind works out the bars from what it
    /// knows without laying text out (a line's bar as long as its characters), and may hand them
    /// over as it works them out (a lazy sequence), with no array of its own. It paints as
    /// `fillPath` does.
    public func fillSkeletonText(_ bars: some Sequence<CGRect>) {
        var bars = bars.makeIterator()
        guard let first = bars.next() else { return }
        cg.saveGState()
        cg.addRect(first)
        while let bar = bars.next() { cg.addRect(bar) }
        cg.setFillColor(skeleton.text)
        cg.fillPath()
        cg.restoreGState()
    }

    /// `drawSkeleton(of:color:)` in the graphics state as it is: the core's, for a kind without
    /// a skeleton of its own, in the fresh state each shape draws with.
    func fillSkeleton(of geometry: ShapeGeometry, color: CGColor) {
        let outline = geometry.outline, bounds = geometry.bounds
        guard let first = outline.first, let last = outline.last else { return }
        switch Silhouettes.form(of: bounds, pixel: skeleton.pixel) {
        case .pixel:
            // The device pixel its middle is in, whole, as a picture of the board fills the pixel
            // it's in: a square a pixel wide around the middle would be spread over as many as four
            // at a quarter each, and all but vanish.
            let middle = cg.convertToDeviceSpace(CGPoint(x: bounds.midX, y: bounds.midY))
            cg.setFillColor(color)
            cg.fill(cg.convertToUserSpace(CGRect(x: middle.x.rounded(.down), y: middle.y.rounded(.down), width: 1, height: 1)))
        case .bounds where geometry.isClosed:
            cg.setFillColor(color)
            cg.fill(bounds)
        case .bounds:
            cg.move(to: first)
            cg.addLine(to: last)
            strokeSkeleton(color: color)
        case .outline where geometry.isClosed:
            cg.addLines(between: outline)
            cg.closePath()
            cg.setFillColor(color)
            cg.fillPath()
        case .outline:
            cg.addLines(between: outline)
            strokeSkeleton(color: color)
        }
    }

    /// Strokes the path under way.
    private func strokeSkeleton(color: CGColor) {
        cg.setStrokeColor(color)
        cg.setLineWidth(Style.skeletonLineWidth / zoom)
        cg.setLineCap(.round)
        cg.setLineJoin(.round)
        cg.strokePath()
    }
}

/// What a frame's skeletons draw with, worked out once a frame: their colors, in the appearance
/// the frame draws in, and how big a pixel is.
struct SkeletonInk {
    let fill: CGColor
    let text: CGColor
    /// World units.
    let pixel: CGFloat
}

/// How one kind of shape looks and behaves. Stateless; one per kind, registered by its plugin.
/// What else a kind can do comes from the capability protocols that refine this one.
///
/// `geometry` is the one source of truth: hit testing and the outline follow it unless you
/// override them (for an exact test, say, or a smoother outline). Box kinds get their frame as
/// geometry, so the smallest definition is just `render`. Conform in an extension
/// (`extension MyDefinition: ShapeDefinition { ... }`): only there does Swift flag a member that
/// nearly matches a defaulted requirement, and the build fails on it.
@MainActor
public protocol ShapeDefinition<Props> {
    associatedtype Props: ShapeProps
    func render(_ shape: ShapeRecord<Props>, in context: RenderContext)
    /// Box kinds get their frame by default; any other kind must say.
    func geometry(of shape: ShapeRecord<Props>, in context: ShapeContext) -> ShapeGeometry
    /// Whether a world point is on the shape: for pressing, hovering and attaching to it.
    /// Default: inside a closed outline (an open shape can't be hit unless it says how).
    func hitTest(_ point: CGPoint, on shape: ShapeRecord<Props>, in context: ShapeContext) -> Bool
    /// How far outside its geometry's bounds (and its box) `hitTest` can still say yes. The editor
    /// asks `hitTest` only about points that near, so a kind whose `hitTest` reaches past its
    /// outline (a stroke's width, a few points to make a thin line easy to click) says how far.
    /// Default: nowhere, as the default `hitTest` hits only inside the outline.
    var hitMargin: HitMargin { get }
    /// The outline drawn for it: the target hint, and whatever plugins outline (hover, selection).
    /// The core strokes them all in one pass.
    func indicatorPath(of shape: ShapeRecord<Props>, in context: ShapeContext) -> CGPath
}

extension ShapeDefinition {
    public var hitMargin: HitMargin { HitMargin() }

    public func hitTest(_ point: CGPoint, on shape: ShapeRecord<Props>, in context: ShapeContext) -> Bool {
        let geometry = geometry(of: shape, in: context)
        return geometry.isClosed && polygonContains(geometry.outline, point)
    }

    public func indicatorPath(of shape: ShapeRecord<Props>, in context: ShapeContext) -> CGPath {
        let geometry = geometry(of: shape, in: context)
        let path = CGMutablePath()
        path.addLines(between: geometry.outline)
        if geometry.isClosed { path.closeSubpath() }
        return path
    }
}

extension ShapeDefinition where Props: BoxShapeProps {
    public func geometry(of shape: ShapeRecord<Props>, in context: ShapeContext) -> ShapeGeometry {
        ShapeGeometry(outline: shape.frame.polygon, bounds: shape.frame)
    }
}
