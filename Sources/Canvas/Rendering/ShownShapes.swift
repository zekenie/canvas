import AppKit
import Geometry

// Shapes shown in another shape's place (a stand-in that shows its original, a mirror: `ShowingShapes`): the core draws
// one there as its own kind draws it (`RenderContext.drawShape(inFile:through:standingIn:)`), finds it under a point
// (`shownShape(at:in:)`) and edits it there (`beginEditing(_:through:at:clickCount:)`), on whichever board it is. It
// names no kind: the stand-in's kind says what it shows and where (`shownShape`, `shownTransform`).

/// What a frame draws every shape with, which a shape drawn in another's place is drawn with too: made once a frame.
@MainActor
struct ShownFrame {
    /// The canvas draws skeletons this frame.
    let skeletons: Bool
    let ink: SkeletonInk
    let shapeCount: (ShapeID) -> Int
    /// The board previews' drawing, for a shape drawn at a zoom (a preview too small on screen draws none).
    let preview: (CGFloat) -> (ShapeID, CGRect, CGFloat, CGContext) -> Bool
    let fileShape: (ShapeID) -> AnyShapeRecord?
    let lend: (ObjectIdentifier) -> (any EditorService)?
}

/// What the editor keeps to draw containers shown in another shape's place: for each board one was drawn from lately but
/// the board shown (whose own index it reads), an index of its shapes (their paint order and extents, for culling), and
/// what each container drawn holds, each kept while its board is as it was, so a mirror of a frame of hundreds costs a
/// frame what's in view, not the board. A shape that holds nothing needs none of it.
@MainActor
final class ShownBoards {
    private struct Kept {
        let revision: Int
        let index: ShapeIndex
    }
    /// How many boards it keeps an index of, and how many containers what they hold.
    static let limit = 8
    static let heldLimit = 64
    private var kept: [BoardID: Kept] = [:]
    /// The boards kept, the one drawn from longest ago first.
    private var order: [BoardID] = []
    private var held: [ShapeID: (board: BoardID, revision: Int, held: Set<ShapeID>)] = [:]

    /// The index of a board other than the one shown, as the file has it at `revision`: kept, or made afresh for a
    /// board that changed since (built as it's first asked).
    func index(of board: BoardID, revision: Int) -> ShapeIndex {
        order.removeAll { $0 == board }
        order.append(board)
        if let entry = kept[board], entry.revision == revision { return entry.index }
        let entry = Kept(revision: revision, index: ShapeIndex())
        kept[board] = entry
        while order.count > Self.limit { kept[order.removeFirst()] = nil }
        return entry.index
    }

    /// Every shape `container` holds on `board`, at any depth, as the board is at `revision`.
    func held(by container: ShapeID, on board: BoardID, revision: Int, in document: CanvasDocument, kinds: Set<ShapeKind>) -> Set<ShapeID> {
        if let entry = held[container], entry.board == board, entry.revision == revision { return entry.held }
        let found = Set(document.descendants(of: container, containingKinds: kinds))
        if held.count >= Self.heldLimit { held.removeAll() }
        held[container] = (board, revision, found)
        return found
    }

    /// Shapes laid out again with no commit (`shapesDidChangeLayout`): their kept geometry goes.
    func layoutDidChange(_ ids: Set<ShapeID>) {
        for entry in kept.values { entry.index.layoutDidChange(ids) }
    }

    /// Another file put in place: nothing kept is of it.
    func removeAll() {
        kept.removeAll()
        order.removeAll()
        held.removeAll()
    }
}

extension CanvasEditor {
    // MARK: Drawing

    /// `RenderContext.drawShape(inFile:through:standingIn:)` for a frame being drawn into `cg`.
    func drawShown(_ id: ShapeID, through transform: CGAffineTransform, standingIn standIn: ShapeID, in cg: CGContext,
                   with frame: ShownFrame) -> Bool {
        guard let board = storedFile.board(containing: id), Self.canShow(board, in: storedFile, registry: registry) else { return false }
        let contents = board == self.board ? storedDocument : storedFile[board]
        guard let record = contents[id], !record.isOpaque, registry.definition(for: record.kind) != nil else { return false }
        let scale = Self.scale(of: transform)
        guard scale.isFinite, scale > 0, transform.tx.isFinite, transform.ty.isFinite else { return false }
        let zoom = camera.zoom * scale
        // Lookups as the shapes' own board has them, at the zoom they're drawn at; never the board's kept index, which is
        // kept for the camera it's seen with (a geometry may read the zoom).
        let shapes = ShapeContext(document: contents, registry: registry, camera: Camera(zoom: zoom), index: nil, layout: layoutSource)
        let edited = editingStandIn == standIn ? editingShapeID : nil
        let skeletons = frame.skeletons || zoom < skeletonZoom
        let ink = SkeletonInk(fill: frame.ink.fill, text: frame.ink.text, pixel: frame.ink.pixel / scale)
        let preview = frame.preview(zoom), customSkeletons = registry.customSkeletons
        cg.saveGState()
        cg.concatenate(transform)
        func draw(_ shown: AnyShapeRecord) {
            guard let definition = registry.definition(for: shown.kind) else { return }
            cg.saveGState()
            cg.beginPath()
            let render = RenderContext(cg: cg, shapes: shapes, isEditing: shown.id == edited, shownThrough: standIn,
                                       shapeCount: frame.shapeCount, preview: preview, fileShape: frame.fileShape, lend: frame.lend,
                                       shadows: shapeShadows, skeleton: ink, shown: { _, _, _ in false })
            render.drawAsFrameDoes(shown, by: definition, skeleton: skeletons && shown.id != edited, customSkeletons: customSkeletons)
            cg.beginPath()
            cg.restoreGState()
        }
        if registry.isContainer(record) {
            // What the clip shows, in the shapes' own units, and what may draw into it from just past it (a shadow).
            let visible = cg.boundingBoxOfClipPath.insetBy(dx: -Style.drawingPad, dy: -Style.drawingPad)
            let held = shownHeld(by: record, on: board, in: contents)
            var bound: Set<ShapeID>?
            for shown in shownPaintOrder(on: board, contents: contents, touching: visible)
            where isHeld(shown, by: id, holding: held, bound: &bound, in: shapes) {
                draw(shown)
            }
        } else {
            draw(record)
        }
        cg.restoreGState()
        return true
    }

    /// The shapes of a board whose extent touches `rect`, back to front: the board shown's by its own index, another's by
    /// one kept for it.
    private func shownPaintOrder(on board: BoardID, contents: CanvasDocument, touching rect: CGRect) -> [AnyShapeRecord] {
        let (index, context) = shownIndex(of: board, contents: contents)
        let list = index.paintList(in: context), all = contents.shapes
        return index.positions(touching: rect, in: context).map { all[list.order[$0]] }
    }

    /// An index over a board's shapes, for their paint order and extents, with the context it's read in.
    private func shownIndex(of board: BoardID, contents: CanvasDocument) -> (ShapeIndex, ShapeContext) {
        if board == self.board { return (shapeIndex, shapeContext) }
        let index = shownBoards.index(of: board, revision: storedFile.revision(of: board))
        return (index, ShapeContext(document: contents, registry: registry, camera: Camera(), index: index, layout: layoutSource))
    }

    /// Every shape a container holds, at any depth.
    private func shownHeld(by container: AnyShapeRecord, on board: BoardID, in contents: CanvasDocument) -> Set<ShapeID> {
        shownBoards.held(by: container.id, on: board, revision: storedFile.revision(of: board), in: contents, kinds: registry.containingKinds)
    }

    /// How much a transform that scales and moves scales: its first column's length.
    static func scale(of transform: CGAffineTransform) -> CGFloat { hypot(transform.a, transform.b) }

    // MARK: Where a stand-in shows a shape

    /// What a stand-in on the board shown shows now and how (`ShowingShapes`): the shape, and the transform from its world
    /// units into the board shown's. Nil for a shape that isn't on the board shown, kept aside, of a kind that shows none,
    /// or showing none now, and for a shown shape on no board the editor can show.
    public func shown(through standIn: ShapeID) -> (id: ShapeID, transform: CGAffineTransform)? {
        guard let record = document[standIn], !record.isOpaque, let showing = registry.showingShapes[record.kind],
              let id = showing.erasedShownShape(of: record, in: shapeContext), shape(inFile: id) != nil,
              let transform = showing.erasedShownTransform(of: record, in: shapeContext) else { return nil }
        let scale = Self.scale(of: transform)
        guard scale.isFinite, scale > 0 else { return nil }
        return (id, transform)
    }

    /// Where a stand-in on the board shown shows `id` now: the transform from `id`'s world units into the board shown's,
    /// for the shape it shows and, if that holds shapes, what it holds and what's bound only to those, which are drawn
    /// there with it. Nil for any other shape.
    public func placement(of id: ShapeID, through standIn: ShapeID) -> CGAffineTransform? {
        guard let (shown, transform) = shown(through: standIn) else { return nil }
        if shown == id { return transform }
        guard let board = file.board(containing: shown) else { return nil }
        let shapes = contents(of: board)
        guard let root = shapes[shown], registry.isContainer(root), let record = shapes[id], !record.isOpaque else { return nil }
        let context = ShapeContext(document: shapes, registry: registry, camera: camera, index: nil, layout: layoutSource)
        var bound: Set<ShapeID>?
        return isHeld(record, by: shown, holding: shownHeld(by: root, on: board, in: shapes), bound: &bound, in: context) ? transform : nil
    }

    /// What a stand-in on the board shown shows under a world point of the board shown, front-most first: the shape it
    /// shows, or for a container the shape it holds (or what's bound only to those) under the point, else the container;
    /// with the point in that shape's own world units. Nil where it shows nothing there.
    public func shownShape(at point: CGPoint, in standIn: ShapeID) -> (id: ShapeID, point: CGPoint)? {
        guard let (shown, transform) = shown(through: standIn), let board = file.board(containing: shown) else { return nil }
        let shapes = contents(of: board), local = point.applying(transform.inverted())
        guard let root = shapes[shown] else { return nil }
        let zoom = camera.zoom * Self.scale(of: transform)
        let context = ShapeContext(document: shapes, registry: registry, camera: Camera(zoom: zoom), index: nil, layout: layoutSource)
        guard registry.isContainer(root) else { return context.hitTest(local, shape: shown) ? (shown, local) : nil }
        // Every shape that may be hit there: those whose extent is near the point, with room for any kind's hit margin.
        let reach = Style.drawingPad + 1 / max(zoom, .leastNormalMagnitude)
        let near = CGRect(x: local.x - reach, y: local.y - reach, width: reach * 2, height: reach * 2)
        let held = shownHeld(by: root, on: board, in: shapes)
        var bound: Set<ShapeID>?
        for record in shownPaintOrder(on: board, contents: shapes, touching: near).reversed()
        where isHeld(record, by: shown, holding: held, bound: &bound, in: context) && context.hitTest(local, shape: record.id) {
            return (record.id, local)
        }
        return nil
    }

    /// Whether a shape on a container's board is drawn with it where a stand-in shows the container: the container, one it
    /// holds (`held`, at any depth), or one bound only to those and the container (an arrow between two of its notes).
    /// `bound` is `held` and the container, made the first time a shape is asked about that needs it, and kept by the caller
    /// across the shapes it asks about.
    private func isHeld(_ record: AnyShapeRecord, by container: ShapeID, holding held: Set<ShapeID>, bound: inout Set<ShapeID>?,
                        in context: ShapeContext) -> Bool {
        if record.id == container || held.contains(record.id) { return true }
        guard record.box == nil, !record.isOpaque, registry.referencingKinds.contains(record.kind) else { return false }
        if bound == nil { bound = held.union([container]) }
        return record.isBound(onlyTo: bound!, in: context)
    }

    // MARK: Editing through a stand-in

    /// Whether the shape edited through a stand-in can go on being edited there after a commit: the stand-in still on the
    /// board shown and showing it, neither read-only, and the shape still of the kind it was.
    func editingThroughStandInHolds() -> Bool {
        guard let id = editingShapeID, let standIn = editingStandIn else { return true }
        guard let record = shape(inFile: id), record.kind == editingThroughKind, !record.isOpaque, document[standIn] != nil,
              !isReadOnly(standIn), !isReadOnly(inFile: id), placement(of: id, through: standIn) != nil else { return false }
        return true
    }

    /// A rect in the world units of the shape being edited, where the board shown has it: through the stand-in it's edited
    /// through (`beginEditing(_:through:)`), else as it is.
    func shownOnBoard(_ rect: CGRect) -> CGRect {
        guard let id = editingShapeID, let standIn = editingStandIn, let transform = placement(of: id, through: standIn) else { return rect }
        return rect.applying(transform)
    }
}
