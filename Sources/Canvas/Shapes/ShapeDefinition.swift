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

    public init(outline: [CGPoint], bounds: CGRect? = nil, isClosed: Bool = true) {
        self.outline = outline
        self.bounds = bounds ?? CGRect(enclosing: outline)
        self.isClosed = isClosed
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

    /// Lookups in a document of your own (shapes copied, say), whose geometry is worked out as it's
    /// asked for. The editor's is `editor.shapeContext`, and a transaction's `transaction.shapes`.
    public init(document: CanvasDocument, registry: Registry, camera: Camera = Camera()) {
        self.init(document: document, registry: registry, camera: camera, index: nil)
    }

    init(document: CanvasDocument, registry: Registry, camera: Camera, index: ShapeIndex?) {
        storedDocument = document
        self.registry = registry
        storedCamera = camera
        self.index = index
        generation = index?.generation ?? 0
    }

    private var currentIndex: ShapeIndex? {
        guard let index, index.generation == generation else { return nil }
        return index
    }

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

    /// The union of the shapes' geometry bounds, in world units: what boxes a selection, or brings
    /// shapes into view. Shapes with no outline (nothing drawn) don't count; nil if none is left.
    public func bounds(of ids: some Sequence<ShapeID>) -> CGRect? {
        var union: CGRect?
        for id in ids {
            guard let geometry = geometry(of: id), !geometry.outline.isEmpty, !geometry.bounds.isNull else { continue }
            union = union?.union(geometry.bounds) ?? geometry.bounds
        }
        return union
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

    init(cg: CGContext, shapes: ShapeContext, isEditing: Bool, shapeCount: @escaping (ShapeID) -> Int,
         preview: @escaping (ShapeID, CGRect, CGFloat, CGContext) -> Bool, fileShape: @escaping (ShapeID) -> AnyShapeRecord?) {
        self.cg = cg
        self.shapes = shapes
        self.isEditing = isEditing
        boardShapeCount = shapeCount
        boardPreview = preview
        self.fileShape = fileShape
    }

    /// A shape on any board of the file the editor can show: one on the board shown as
    /// `shapes.shape(_:)` finds it (tracked), else one on another board, as it is now (nil for one
    /// on a board it can't show, as `CanvasEditor.shape(inFile:)`). What a render that names shapes
    /// (a mention's pill, which shows its shape's name) reads, so a name of a shape on another
    /// board shows as that shape is called. Like `shapeCount(inBoardOwnedBy:)`, it's read as the shape is
    /// drawn, and a write to a board that isn't shown redraws the canvas, so a name drawn is never
    /// stale; nothing but a render can read another board.
    public func shape(inFile id: ShapeID) -> AnyShapeRecord? { shapes.shape(id) ?? fileShape(id) }

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
    /// the minimap draws. Returns false, having drawn nothing, while the picture isn't ready, for a
    /// board with nothing to show (none, or empty), and for a rect too small on screen to show one
    /// (under 16 view points either way): draw something else then (a count). A picture
    /// takes a few frames to build (the core builds them within a budget each frame, and redraws
    /// until they're done), and one of a board as it was before an edit or an undo is never drawn.
    public func drawBoardPreview(ofBoardOwnedBy owner: ShapeID, in rect: CGRect, maxScale: CGFloat = .infinity) -> Bool {
        boardPreview(owner, rect, maxScale, cg)
    }

    /// The canvas's standard shape shadow. Shadows ignore the transform, so the blur is scaled by
    /// hand; the offset is zero because shadow offsets live in device space.
    public func fillWithShadow(_ path: CGPath, _ color: NSColor) {
        cg.saveGState()
        cg.setShadow(offset: .zero, blur: 6 * zoom, color: Style.shapeShadow.cgColor)
        cg.addPath(path)
        cg.setFillColor(color.cgColor)
        cg.fillPath()
        cg.restoreGState()
    }
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
