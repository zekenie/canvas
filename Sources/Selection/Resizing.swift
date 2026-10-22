import Canvas
import CoreGraphics
import Geometry

/// Which box kinds' shapes are resized with handles, and how small they go: a kind opts in with
/// `x.resizable(minimumSize:)`. The only selected shape of such a kind, unless it's read-only or
/// being edited, has eight handles (`ResizeHandle`), on the corners of its box and the middles of
/// its sides, drawn, hit, hovered and pressed as any handle is, each with the resize cursor for its
/// place; a drag on one resizes the box (`ResizingSession`). At most one per kind, plus one for
/// every kind (`.any`), which a kind's own overrides; a minimum above zero and finite either way.
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
    /// edited, has eight, on the corners of its box and the middles of its sides, and a drag on one
    /// moves that corner or side, the one opposite staying put (⇧ keeps the proportions the box had,
    /// ⌥ keeps its center), never to less than `minimumSize` (world units) either way, as one undo
    /// step, "Resize".
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
}

/// Dragging a resize handle (`ResizeHandle`), past the drag threshold: the box follows the pointer
/// as the handle says (`resizing`), from where it was as the drag began, in a transaction per drag
/// event, the press one undo step, "Resize". ⇧ keeps its proportions and ⌥ its center, taking effect
/// as they're pressed or let go, without the pointer moving; never smaller than its kind's minimum.
/// A shape in a container (a frame) stops `Settlement.gap` inside its edge, so it never grows across
/// it. Nothing snaps. On the release, what the box now reaches or lets go of settles in or out of
/// it, if it's a container (`Transaction.settle(container:)`), gliding there, in the same step.
/// Escape puts the box back as it was, which leaves no step.
@MainActor
final class ResizingSession {
    let shapeID: ShapeID
    let handle: ResizeHandle
    /// Where the handle was pressed, in world units.
    private let origin: CGPoint
    /// The box as the drag began.
    private let start: CGRect
    private let minimum: CGSize
    /// Where the box may reach, for a shape in a container: inside its container's edge, or as far
    /// as the box already did. Nil on its board directly.
    private let room: CGRect?
    /// The last drag event's pointer, to resize again from when held keys change.
    private var last: Pointer?

    /// Nil for a shape that isn't there, has no box, or whose kind isn't resizable.
    init?(shapeID: ShapeID, handle: ResizeHandle, from origin: CGPoint, in editor: CanvasEditor) {
        guard let record = editor.document[shapeID], let box = record.box,
              let minimum = editor.selectionState?.minimumSizes[record.kind] else { return nil }
        self.shapeID = shapeID
        self.handle = handle
        self.origin = origin
        start = box
        self.minimum = minimum
        room = Self.room(for: record, box: box, in: editor)
    }

    /// Where a box may reach as it's resized, for a shape in a container: inside its container's edge, or as far as
    /// `box` already does. Nil on its board directly.
    static func room(for record: AnyShapeRecord, box: CGRect, in editor: CanvasEditor) -> CGRect? {
        let gap = Settlement.gap
        return editor.registry.container(of: record, in: editor.document).flatMap { editor.document[$0]?.box }
            .map { $0.insetBy(dx: gap, dy: gap).union(box) }
    }

    private func resize(to pointer: Pointer, in editor: CanvasEditor) {
        last = pointer
        var box = handle.resizing(start, by: pointer.world - origin, keepingProportions: pointer.modifiers.contains(.shift),
                                  fromCenter: pointer.modifiers.contains(.option), minimum: minimum)
        if let room { box = box.intersection(room) }
        editor.transact("Resize") { $0.update(shapeID) { $0.box = box } }
    }
}

extension ResizingSession: Session {
    func cursor(in editor: CanvasEditor) -> CanvasCursor? { handle.cursor }

    func drag(_ pointer: Pointer, in editor: CanvasEditor) { resize(to: pointer, in: editor) }

    /// ⇧ or ⌥ came or went: the box is resized again where the pointer is, without its moving.
    func modifiersChanged(_ modifiers: Modifiers, in editor: CanvasEditor) {
        guard var pointer = last else { return }
        pointer.world = editor.camera.toWorld(pointer.view)
        pointer.modifiers = modifiers
        resize(to: pointer, in: editor)
    }

    /// The release: the box takes the size the pointer gives it there, and then, for a container,
    /// what it now reaches or lets go of settles in or out of it and glides there, the last of the
    /// press's step.
    func end(_ pointer: Pointer, in editor: CanvasEditor) {
        resize(to: pointer, in: editor)
        editor.glide(editor.transact("Resize") { $0.settle(container: shapeID) })
    }

    /// Escape: the box goes back to where it was as the drag began (only its box, so what else
    /// changed meanwhile stays), and the step comes to nothing.
    func cancel(in editor: CanvasEditor) -> Bool {
        editor.transact("Resize") { $0.update(shapeID) { $0.box = start } }
        return true
    }
}

// MARK: By the keys

/// The open step's key resize, settled as it closes.
private struct KeyResizeSettle: Hashable {}

extension CanvasEditor {
    /// The shape ⌥ and an arrow resize: the only selected one, of a kind that resizes (`ShapeResizing`), with nothing
    /// under way or being edited; nil otherwise, and the key goes on. A read-only one counts: the key is its, and refused.
    var keyResizable: ShapeID? {
        guard session == nil, editingShapeID == nil, let id = selection, let record = document[id], record.box != nil,
              selectionState?.minimumSizes[record.kind] != nil else { return nil }
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
        guard let record = document[id], let box = record.box, let minimum = selectionState?.minimumSizes[record.kind] else { return }
        guard !isReadOnly(id) else { return refuseChanges(to: [id]) }
        var resized = handle.resizing(box, by: delta, keepingProportions: false, fromCenter: false, minimum: minimum)
        if let room = ResizingSession.room(for: record, box: box, in: self) { resized = resized.intersection(room) }
        guard resized != box, !resized.isNull, resized.width > 0, resized.height > 0 else { return }
        undoHistory.group {
            transact("Resize") { $0.update(id) { $0.box = resized } }
            undoHistory.finishing(KeyResizeSettle()) { [weak self] in
                guard let self, document[id] != nil else { return }
                glide(transact("Resize") { $0.settle(container: id) })
            }
        }
    }

    /// The only selected shape's resize handles as parts (`ResizeHandle.parts`): those shown on its box, as
    /// `visibleHandles` shows them; none on a shape not selected alone, a read-only one, or one being edited.
    func resizeHandleParts(of shape: AnyShapeRecord) -> [ShapePart] {
        guard selection == shape.id, editingShapeID != shape.id, !isReadOnly(shape.id), let box = shape.box,
              selectionState?.minimumSizes[shape.kind] != nil else { return [] }
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
