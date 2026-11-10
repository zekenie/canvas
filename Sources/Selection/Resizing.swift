import Canvas
import CoreGraphics
import Geometry

/// Which box kinds' shapes are resized with handles, and how small they go: a kind opts in with
/// `x.resizable(minimumSize:)`. The only selected shape of such a kind, unless it's read-only or
/// being edited, has eight handles (`ResizeHandle`), on the corners of its frame and the middles of
/// its sides, drawn, hit, hovered and pressed as any handle is, each with the resize cursor for its
/// place, a side's pressed from anywhere along it too (`ResizeHandle.side`); a drag on one resizes
/// it (`ResizingSession`). The frame is the one the shape is laid out in (`context.frame(of:)`), its
/// box for most kinds; a kind laid out past its box (`LaidOutBox`) resizes only if it takes a frame
/// its own way (`CustomSizing`: a note), and then only the shapes it says (`isResizable`). At most
/// one per kind, plus one for every kind (`.any`), which a kind's own overrides; a minimum above
/// zero and finite either way.
public enum ShapeResizing {}

extension ShapeResizing: KeyedExtensionPoint {
    /// The smallest a shape of the kind is resized to, in world units.
    public typealias Contribution = CGSize
    public static var owner: PluginID { .selection }
    public static func uniqueKeys(of _: CGSize, for target: ShapeTarget) -> [AnyHashable] { [target] }

    public static func check(_ registry: Registry) throws(RegistryError) {
        for minimum in registry.contributions(to: ShapeResizing.self) {
            let size = minimum.value
            guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
                throw .invalid(point: "ShapeResizing",
                               reason: "\(minimum.pluginID) says \(minimum.target) is never smaller than \(size.width) by \(size.height), which isn't a size")
            }
        }
    }
}

// Sugar, so opting in is one line and never names the extension point.
extension ShapeRegistrar where Definition.Props: BoxShapeProps {
    /// Its shapes are resized with handles: the only selected one, unless it's read-only or being
    /// edited, has eight, on the corners of its frame and the middles of its sides, and a drag on one
    /// (a side's from anywhere along it) moves that corner or side, the one opposite staying put (⇧
    /// keeps the proportions the frame had, ⌥ keeps its center), never to less than `minimumSize`
    /// (world units) either way, as one undo step, "Resize". The shape takes each frame as its kind
    /// takes one (`CustomSizing`), else as its box.
    public mutating func resizable(minimumSize: CGSize) {
        contribute(minimumSize, to: ShapeResizing.self)
        contribute(ResizeHandle.parts, to: ShapeParts.self)
    }
}

extension PluginRegistrar {
    /// The shapes of a box kind another plugin registers are resized with handles, as
    /// `resizable` on a kind's own registrar.
    public mutating func resizable<P: BoxShapeProps>(_: P.Type, minimumSize: CGSize) {
        contribute(minimumSize, to: ShapeResizing.self, for: .kind(P.kind))
        contribute(ResizeHandle.parts, to: ShapeParts.self, for: .kind(P.kind))
    }
}

/// A resize handle (`ShapeResizing`), named for where it is on its shape's box: a corner, or the
/// middle of a side. What `editor.hoveredHandle` holds while the pointer's on one.
public enum ResizeHandle: CaseIterable, Hashable, Sendable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left

    /// Which side of the box it moves along x: −1 the left, 1 the right, 0 neither.
    var x: CGFloat {
        switch self {
        case .topLeft, .left, .bottomLeft: -1
        case .top, .bottom: 0
        case .topRight, .right, .bottomRight: 1
        }
    }

    /// Which side it moves along y (down the canvas): −1 the top, 1 the bottom, 0 neither.
    var y: CGFloat {
        switch self {
        case .topLeft, .top, .topRight: -1
        case .left, .right: 0
        case .bottomLeft, .bottom, .bottomRight: 1
        }
    }

    /// What VoiceOver calls it, as a part of its shape (⌥Tab).
    var title: String {
        switch self {
        case .topLeft: "Top Left Corner"
        case .top: "Top Edge"
        case .topRight: "Top Right Corner"
        case .right: "Right Edge"
        case .bottomRight: "Bottom Right Corner"
        case .bottom: "Bottom Edge"
        case .bottomLeft: "Bottom Left Corner"
        case .left: "Left Edge"
        }
    }

    /// The resize handles as parts of their shape (`ShapeParts`, contributed for a kind as it opts in): each shown,
    /// a `.handle` the arrow keys move as its drag does, a unit, ten with ⇧ (`CanvasEditor.resize`); an arrow
    /// across the way it moves goes on to the nudge. Pressing one does nothing, as a click on one doesn't.
    @MainActor static var parts: ShapePartSource {
        ShapePartSource(order: 0, name: "resize handles") { editor, shape in editor.resizeHandleParts(of: shape) }
    }

    /// Where it is on a box.
    func point(on box: CGRect) -> CGPoint {
        CGPoint(x: x < 0 ? box.minX : x > 0 ? box.maxX : box.midX, y: y < 0 ? box.minY : y > 0 ? box.maxY : box.midY)
    }

    /// The side of a box, in view points, a press at `point` takes, as tldraw's edges do: one whose handle shows
    /// (`shown`), with the point between its ends, from `SelectionStyle.resizeSideReach` inside it to as far past
    /// the outline drawn `outline` off it, the nearer of two; nil off every side.
    @MainActor
    static func side(of box: CGRect, at point: CGPoint, outline: CGFloat) -> ResizeHandle? {
        let reach = SelectionStyle.resizeSideReach
        return shown(on: box).filter { $0.x == 0 || $0.y == 0 }.compactMap { side -> (side: ResizeHandle, off: CGFloat)? in
            let edge = side.point(on: box)
            // How far out past the side the point is (inside, below zero), and whether it's between the side's ends.
            let out = side.x != 0 ? (point.x - edge.x) * side.x : (point.y - edge.y) * side.y
            let along = side.x != 0 ? (box.minY...box.maxY).contains(point.y) : (box.minX...box.maxX).contains(point.x)
            guard along, out >= -reach, out <= outline + reach else { return nil }
            return (side, abs(out - outline / 2))
        }.min { $0.off < $1.off }?.side
    }

    /// The cursor over it, and while it's dragged: the frame-resize cursor for its place.
    var cursor: CanvasCursor {
        switch self {
        case .topLeft: .resize(.topLeft)
        case .top: .resize(.top)
        case .topRight: .resize(.topRight)
        case .right: .resize(.right)
        case .bottomRight: .resize(.bottomRight)
        case .bottom: .resize(.bottom)
        case .bottomLeft: .resize(.bottomLeft)
        case .left: .resize(.left)
        }
    }

    /// The handles that show on a box, in view points: none on a box under
    /// `SelectionStyle.resizeHandleRoom` either way, whose corners' handles would leave none of it
    /// to press, and a side's only on a side at least twice that long, clear of the corners'.
    @MainActor
    static func shown(on box: CGRect) -> [ResizeHandle] {
        let room = SelectionStyle.resizeHandleRoom
        guard box.width >= room, box.height >= room else { return [] }
        return allCases.filter { handle in
            if handle.x == 0 { return box.width >= 2 * room }       // the top's and the bottom's
            if handle.y == 0 { return box.height >= 2 * room }      // the left's and the right's
            return true
        }
    }

    /// `box` as a drag of this handle by `delta` (world units, from where it was pressed) leaves it:
    /// the sides the handle is on follow the pointer, and the others stay. With `fromCenter` (⌥) the
    /// sides opposite move the other way, so the center stays. With `keepingProportions` (⇧) the box
    /// keeps the ratio of its width to its height: a corner's by the side that grows the most, so the
    /// box takes in the pointer, a side's across it about the middle (a box without area resizes
    /// freely). Never less than `minimum` along a side the handle moves, and keeping proportions,
    /// either way: a side dragged past the one opposite stops there, and never turns the box inside
    /// out. Along an axis whose length stays, nothing moves.
    func resizing(_ box: CGRect, by delta: CGPoint, keepingProportions: Bool, fromCenter: Bool, minimum: CGSize) -> CGRect {
        let reach: CGFloat = fromCenter ? 2 : 1
        var width = box.width + x * delta.x * reach
        var height = box.height + y * delta.y * reach
        if keepingProportions, box.width > 0, box.height > 0 {
            let scale: CGFloat
            if x == 0 {
                scale = height / box.height                                 // the top or the bottom
            } else if y == 0 {
                scale = width / box.width                                   // the left or the right
            } else {
                scale = max(width / box.width, height / box.height)         // a corner
            }
            let fitted = max(scale, minimum.width / box.width, minimum.height / box.height)
            width = max(box.width * fitted, minimum.width)
            height = max(box.height * fitted, minimum.height)
        } else {
            if x != 0 { width = max(width, minimum.width) }
            if y != 0 { height = max(height, minimum.height) }
        }
        return CGRect(x: Self.start(box.minX, box.maxX, length: box.width, resized: width, side: x, fromCenter: fromCenter),
                      y: Self.start(box.minY, box.maxY, length: box.height, resized: height, side: y, fromCenter: fromCenter),
                      width: width, height: height)
    }

    /// Where a box resized to `resized` along one axis starts on it, from `low` to `high` as it was:
    /// where it did while its length stays; else past the side that stays put, `high` for a handle
    /// on the low side (−1), `low` for one on the high side (1), or about the middle, from the center
    /// or for a side the handle isn't on (resized to keep proportions).
    private static func start(_ low: CGFloat, _ high: CGFloat, length: CGFloat, resized: CGFloat, side: CGFloat, fromCenter: Bool) -> CGFloat {
        if resized == length { return low }
        if fromCenter || side == 0 { return (low + high) / 2 - resized / 2 }
        return side < 0 ? high - resized : low
    }

    /// How a drag of this handle resizes `box`, as `resizing` does (`ResizeScaling`, what a resize
    /// adjuster keeps to): about the corner or side opposite, or about the middle from the center
    /// (`fromCenter`) and across a side kept in proportion; along the ways the handle moves, and both
    /// ways while it keeps proportions (`keepingProportions`, of a box with area).
    func scaling(of box: CGRect, keepingProportions: Bool, fromCenter: Bool) -> ResizeScaling {
        let together = keepingProportions && box.width > 0 && box.height > 0
        func anchor(_ low: CGFloat, _ high: CGFloat, side: CGFloat) -> CGFloat {
            if fromCenter || side == 0 { return (low + high) / 2 }
            return side < 0 ? high : low
        }
        return ResizeScaling(anchor: CGPoint(x: anchor(box.minX, box.maxX, side: x), y: anchor(box.minY, box.maxY, side: y)),
                             changesWidth: x != 0 || together, changesHeight: y != 0 || together, keepsProportions: together)
    }
}

/// Dragging a resize handle (`ResizeHandle`), past the drag threshold: the frame follows the pointer
/// as the handle says (`resizing`), from where it was as the drag began, in a transaction per drag
/// event, the press one undo step, "Resize". ⇧ keeps its proportions and ⌥ its center, taking effect
/// as they're pressed or let go, without the pointer moving; never smaller than its kind's minimum.
/// The shape takes each frame as its kind takes one (`Transaction.resize`), so a note too short for
/// its words stops there, the side opposite the handle staying put.
/// A shape in a container (a frame) stops `Settlement.gap` inside its edge, so it never grows across
/// it. Where the pointer puts the box is the resize adjuster's to change, if a plugin claims it
/// (`registrar.resizeAdjuster`: Snapping's snaps the sides that move to other shapes), and it draws
/// what it shows with the session. On the release, what the box now reaches or lets go of settles in
/// or out of it, if it's a container (`Transaction.settle(container:)`), gliding there, in the same
/// step. Escape puts the box back as it was, which leaves no step.
@MainActor
final class ResizingSession {
    let shapeID: ShapeID
    let handle: ResizeHandle
    /// Where the handle was pressed, in world units.
    private let origin: CGPoint
    /// The frame as the drag began: the one the shape is laid out in (`resizeFrame(of:)`).
    private let start: CGRect
    /// The shape as the drag began, which Escape puts back.
    private let before: AnyShapeRecord
    /// The shape as the drag last left it: while it's still that, nothing else has written it since.
    private var written: AnyShapeRecord?
    private let minimum: CGSize
    /// Where the box may reach, for a shape in a container: inside its container's edge, or as far
    /// as the box already did. Nil on its board directly.
    private let room: CGRect?
    /// What changes the box the pointer gives (`registrar.resizeAdjuster`), asked as the drag began.
    private let adjuster: (any ResizeAdjuster)?
    /// The last drag event's pointer, to resize again from when held keys change.
    private var last: Pointer?

    /// Nil for a shape that isn't there, has no box, or isn't resized (`resizeFrame(of:)`). The
    /// resize adjuster, if a plugin claims it, is asked now.
    init?(shapeID: ShapeID, handle: ResizeHandle, from origin: CGPoint, in editor: CanvasEditor) {
        guard let record = editor.document[shapeID], let box = editor.resizeFrame(of: record),
              let minimum = editor.selectionState?.minimumSizes[record.kind] else { return nil }
        let room = ResizingSession.room(for: record, box: box, in: editor)
        self.shapeID = shapeID
        self.handle = handle
        self.origin = origin
        start = box
        before = record
        self.minimum = minimum
        self.room = room
        adjuster = editor.resizeAdjuster(for: ResizeStart(id: shapeID, box: box, minimum: minimum, room: room))
    }

    /// Where a box may reach as it's resized, for a shape in a container: inside its container's edge, or as far as
    /// `box` already does. Nil on its board directly.
    static func room(for record: AnyShapeRecord, box: CGRect, in editor: CanvasEditor) -> CGRect? {
        let gap = Settlement.gap
        return editor.registry.container(of: record, in: editor.document).flatMap { editor.document[$0]?.box }
            .map { $0.insetBy(dx: gap, dy: gap).union(box) }
    }

    /// The frame where the pointer puts it, then where the adjuster puts that, if there is one (kept in
    /// the room whatever it says), as the shape takes it.
    private func resize(to pointer: Pointer, in editor: CanvasEditor) {
        last = pointer
        let keepingProportions = pointer.modifiers.contains(.shift), fromCenter = pointer.modifiers.contains(.option)
        var box = handle.resizing(start, by: pointer.world - origin, keepingProportions: keepingProportions,
                                  fromCenter: fromCenter, minimum: minimum)
        if let room { box = box.intersection(room) }
        let scaling = handle.scaling(of: start, keepingProportions: keepingProportions, fromCenter: fromCenter)
        if let adjuster {
            box = adjuster.adjust(box, scaling: scaling, for: pointer, in: editor)
            if let room { box = box.intersection(room) }
        }
        let registry = editor.registry, id = shapeID
        editor.transact("Resize") { $0.resize(id, to: box, scaling: scaling, in: registry) }
        written = editor.document[id]
    }
}

extension ResizingSession: Session {
    func cursor(in editor: CanvasEditor) -> CanvasCursor? { handle.cursor }

    func drag(_ pointer: Pointer, in editor: CanvasEditor) { resize(to: pointer, in: editor) }

    /// Held keys changed (⇧ or ⌥, or a key the adjuster reads: Snapping's ⌘ and ⌃): the box is resized
    /// again where the pointer is, without its moving.
    func modifiersChanged(_ modifiers: Modifiers, in editor: CanvasEditor) {
        guard var pointer = last else { return }
        pointer.world = editor.camera.toWorld(pointer.view)
        pointer.modifiers = modifiers
        resize(to: pointer, in: editor)
    }

    /// The release: the box takes the size the pointer gives it there (as the adjuster puts it), and
    /// then, for a container, what it now reaches or lets go of settles in or out of it and glides
    /// there, the last of the press's step.
    func end(_ pointer: Pointer, in editor: CanvasEditor) {
        resize(to: pointer, in: editor)
        editor.glide(editor.transact("Resize") { $0.settle(container: shapeID) })
    }

    /// Escape: the shape goes back to its size as the drag began (its box, so what else changed
    /// meanwhile stays; for a kind that takes a frame its own way, which keeps its size in its props
    /// as it likes, the shape as it was, unless something else wrote it during the drag, a model's
    /// answer landing, which stays, and then its box), and the step comes to nothing.
    func cancel(in editor: CanvasEditor) -> Bool {
        let before = before, whole = editor.registry.takesFramesItsOwnWay(before.kind) && editor.document[shapeID] == written
        editor.transact("Resize") {
            $0.update(shapeID) { record in
                if whole { record = before } else { record.box = before.box }
            }
        }
        return true
    }

    /// What the resize adjuster shows (Snapping's guides).
    func draw(in context: OverlayContext) { adjuster?.draw(in: context) }
}

// MARK: By the keys

/// The open step's key resize, settled as it closes.
private struct KeyResizeSettle: Hashable {}

/// A key resize that left the frame as it was.
private struct KeyResizeUnchanged: Error {}

extension CanvasEditor {
    /// The shape ⌥ and an arrow resize: the only selected one, of a kind that resizes (`ShapeResizing`), with nothing
    /// under way or being edited; nil otherwise, and the key goes on. A read-only one counts: the key is its, and refused.
    var keyResizable: ShapeID? {
        guard session == nil, editingShapeID == nil, let id = selection, let record = document[id], resizeFrame(of: record) != nil else { return nil }
        return id
    }

    /// ⌥ and an arrow: the only selected shape resized from its top left, → and ↓ growing it a world unit, ← and ↑
    /// shrinking it, ten with ⇧ (`resize`), brought into view first if it isn't.
    func resizeSelection(_ direction: CGPoint, large: Bool) {
        guard let id = keyResizable else { return }
        revealIfOffscreen([id])
        resize(id, moving: direction.x != 0 ? .right : .bottom, by: PartStep(direction: direction, isLarge: large).offset)
    }

    /// `handle` of shape `id` moved by `delta` (world units) from where it is, as a drag of it that far moves it
    /// (`ResizeHandle.resizing`): never below the kind's minimum, and a shape in a container never across its edge.
    /// One "Resize" in the step under way, so a held key's repeats are one step; as that step closes, a container
    /// settles what it now reaches or lets go of (`settle(container:)`, the drag's release), gliding there. A
    /// read-only shape is refused, and shakes; at the minimum nothing changes.
    func resize(_ id: ShapeID, moving handle: ResizeHandle, by delta: CGPoint) {
        guard let record = document[id], let box = resizeFrame(of: record), let minimum = selectionState?.minimumSizes[record.kind] else { return }
        guard !isReadOnly(id) else { return refuseChanges(to: [id]) }
        var resized = handle.resizing(box, by: delta, keepingProportions: false, fromCenter: false, minimum: minimum)
        if let room = ResizingSession.room(for: record, box: box, in: self) { resized = resized.intersection(room) }
        guard resized != box, !resized.isNull, resized.width > 0, resized.height > 0 else { return }
        let registry = registry, scaling = handle.scaling(of: box, keepingProportions: false, fromCenter: false)
        undoHistory.group {
            // A shape its kind keeps as it is (a note at its words' height) changes nothing that shows: no step.
            do {
                try transact("Resize") { transaction in
                    transaction.resize(id, to: resized, scaling: scaling, in: registry)
                    if transaction.shapes.frame(of: id) == box { throw KeyResizeUnchanged() }
                }
            } catch {
                return
            }
            undoHistory.finishing(KeyResizeSettle()) { [weak self] in
                guard let self, document[id] != nil else { return }
                glide(transact("Resize") { $0.settle(container: id) })
            }
        }
    }

    /// The side of the only selected shape's box a press at a view point takes, as a drag of that side's handle:
    /// anywhere along a side whose handle shows, from just inside it to just past the outline drawn off it
    /// (`ResizeHandle.side`). Nil off them, and where the shape has no resize handles (`visibleHandles`).
    func resizeSide(atViewPoint point: CGPoint) -> ResizeHandle? {
        guard let id = selection, id != editingShapeID, id != editingStandIn, let record = document[id], let box = resizeFrame(of: record),
              !isReadOnly(id) else { return nil }
        return ResizeHandle.side(of: camera.toView(box), at: point, outline: outlineGap)
    }

    /// The only selected shape's resize handles as parts (`ResizeHandle.parts`): those shown on its frame, as
    /// `visibleHandles` shows them; none on a shape not selected alone, a read-only one, or one being edited.
    func resizeHandleParts(of shape: AnyShapeRecord) -> [ShapePart] {
        guard selection == shape.id, editingShapeID != shape.id, editingStandIn != shape.id, !isReadOnly(shape.id), let box = resizeFrame(of: shape) else { return [] }
        let id = shape.id, radius = SelectionStyle.handleRadius / camera.zoom
        return ResizeHandle.shown(on: camera.toView(box)).map { handle in
            let point = handle.point(on: box)
            return ShapePart(id: handle, title: handle.title, role: .handle,
                             rect: CGRect(x: point.x - radius, y: point.y - radius, width: 2 * radius, height: 2 * radius),
                             press: { _ in }, adjust: { editor, step in
                                 // An arrow along a way the handle moves; ⌥⌘ and one across it go on.
                                 guard !step.toNearest, step.direction.x * handle.x != 0 || step.direction.y * handle.y != 0 else { return false }
                                 editor.resize(id, moving: handle, by: step.offset)
                                 return true
                             })
        }
    }
}

extension CanvasEditor {
    /// The frame a shape is resized on, in world units: the one it's laid out in (`context.frame(of:)`, its box for a
    /// kind laid out as it stores), for a shape of a kind that resizes (`ShapeResizing`, a kind laid out past its box
    /// only if it takes a frame its own way) that its kind lets resize (`registry.isResizable`: not a relationship
    /// type's pill). Nil for any other.
    func resizeFrame(of record: AnyShapeRecord) -> CGRect? {
        guard record.box != nil, selectionState?.minimumSizes[record.kind] != nil, registry.isResizable(record, in: shapeContext) else { return nil }
        return shapeContext.frame(of: record)
    }
}

extension Transaction {
    /// Shape `id` given `frame`, the frame it's to be laid out in, by a drag or a key that scales it as `scaling` says:
    /// as its kind takes a frame (`registry.sized`, giving the ways that change), then, where the kind lays it out at
    /// another size than that (a note its words keep taller), moved along each way that changes so that what stays put
    /// stays put: the anchor, at the same place across the frame it's laid out in as across `frame` (the side opposite
    /// the handle, or the middle). Along a way that doesn't change, it grows as its kind lays it out (a note narrowed by
    /// its side, down from its top).
    mutating func resize(_ id: ShapeID, to frame: CGRect, scaling: ResizeScaling, in registry: Registry) {
        var axes: SizeAxes = []
        if scaling.changesWidth { axes.insert(.width) }
        if scaling.changesHeight { axes.insert(.height) }
        guard let record = document[id] else { return }
        let sized = registry.sized(record, to: frame, giving: axes, in: shapes)
        update(id) { $0 = sized }
        guard let laid = shapes.frame(of: id), laid.size != frame.size else { return }
        // Where a frame `length` long from `low` starts so that a frame `laid` long keeps the anchor at the same place
        // across it, from 0 at its start to 1 at its end.
        func start(_ low: CGFloat, _ length: CGFloat, _ laid: CGFloat, _ anchor: CGFloat) -> CGFloat {
            let across = length > 0 ? min(max((anchor - low) / length, 0), 1) : 0.5
            return low + across * (length - laid)
        }
        let shift = CGPoint(x: scaling.changesWidth ? start(frame.minX, frame.width, laid.width, scaling.anchor.x) - laid.minX : 0,
                            y: scaling.changesHeight ? start(frame.minY, frame.height, laid.height, scaling.anchor.y) - laid.minY : 0)
        guard shift != .zero else { return }
        update(id) { record in record.box = record.box.map { $0.offsetBy(dx: shift.x, dy: shift.y) } }
    }
}
