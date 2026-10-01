import AppKit
import Canvas
import Geometry

/// What pressing a handle did.
public enum HandlePress: Sendable {
    /// Wait for a drag: past the drag threshold, `dragSession` takes over.
    case drag
    /// The press did something on its own (a double-click toggle, say), so there's no drag.
    case consumed
}

/// Draggable handles on the only selected shape, unless it's read-only. The select tool finds,
/// draws and hit-tests them (in view points, `SelectionStyle.handleRadius` / `handleHitRadius`)
/// and applies the drag threshold; the definition decides what they do.
public protocol HandleProviding: ShapeDefinition {
    associatedtype Handle: Hashable & Sendable
    /// Visible handles, front to back, in world coordinates.
    func handles(of shape: ShapeRecord<Props>, in context: ShapeContext) -> [HandleLocation<Handle>]
    func pressHandle(_ handle: Handle, of shape: ShapeRecord<Props>, at pointer: Pointer, in editor: CanvasEditor) -> HandlePress
    /// Called once the pointer passes the drag threshold; `origin` is where it was pressed (world).
    func dragSession(for handle: Handle, of shape: ShapeRecord<Props>, from origin: CGPoint, in editor: CanvasEditor) -> any Session
}

public struct HandleLocation<Handle: Hashable & Sendable>: Sendable {
    public var handle: Handle
    public var point: CGPoint
    public init(_ handle: Handle, at point: CGPoint) {
        self.handle = handle
        self.point = point
    }
}

// Callable on `any HandleProviding`: the signatures don't mention `Props`.
extension HandleProviding {
    func erasedHandles(of record: AnyShapeRecord, in context: ShapeContext) -> [(handle: AnyHashable, point: CGPoint)] {
        guard let shape = record.typed(as: Props.self) else { return [] }
        return handles(of: shape, in: context).map { (AnyHashable($0.handle), $0.point) }
    }
    func erasedPressHandle(_ handle: AnyHashable, of record: AnyShapeRecord, at pointer: Pointer, in editor: CanvasEditor) -> HandlePress {
        guard let handle = handle.base as? Handle, let shape = record.typed(as: Props.self) else { return .consumed }
        return pressHandle(handle, of: shape, at: pointer, in: editor)
    }
    func erasedDragSession(for handle: AnyHashable, of record: AnyShapeRecord, from origin: CGPoint, in editor: CanvasEditor) -> (any Session)? {
        guard let handle = handle.base as? Handle, let shape = record.typed(as: Props.self) else { return nil }
        return dragSession(for: handle, of: shape, from: origin, in: editor)
    }
}

extension CanvasEditor {
    /// The only selected shape's handles, in view space, front to back: its kind's own
    /// (`HandleProviding`), then, for a resizable kind (`ShapeResizing`), those of its box's corners
    /// and sides that show there (`ResizeHandle`). A read-only shape (`registrar.readOnlyShapes`)
    /// has none: a press there is a press on the shape. Nor does the shape being edited (an arrow's
    /// label), as in tldraw: its editing view is over them.
    func visibleHandles() -> [(handle: AnyHashable, point: CGPoint)] {
        guard let id = selection, id != editingShapeID, let record = document[id], !isReadOnly(id) else { return [] }
        var handles: [(handle: AnyHashable, point: CGPoint)] = []
        if let definition = registry.definition(for: record.kind) as? any HandleProviding {
            handles = definition.erasedHandles(of: record, in: shapeContext).map { ($0.handle, camera.toView($0.point)) }
        }
        if let box = record.box, selectionState?.minimumSizes[record.kind] != nil {
            let view = camera.toView(box)
            handles += ResizeHandle.shown(on: view).map { (AnyHashable($0), $0.point(on: view)) }
        }
        return handles
    }

    /// The only selected shape's handle under a view point: the nearest within
    /// `SelectionStyle.handleHitRadius`.
    public func handle(atViewPoint viewPoint: CGPoint) -> AnyHashable? {
        visibleHandles()
            .map { ($0.handle, $0.point.distance(to: viewPoint)) }
            .filter { $0.1 <= SelectionStyle.handleHitRadius }
            .min { $0.1 < $1.1 }?
            .0
    }

    /// A press on one of the only selected shape's handles: a resize handle's waits for a drag; one
    /// of its kind's own, as its definition says.
    func pressHandle(_ handle: AnyHashable, with pointer: Pointer) {
        guard let id = selection, let record = document[id] else { return }
        if handle.base is ResizeHandle {
            session = PointingHandleSession(shapeID: id, handle: handle, origin: pointer.view)
            return
        }
        guard let definition = registry.definition(for: record.kind) as? any HandleProviding else { return }
        if definition.erasedPressHandle(handle, of: record, at: pointer, in: self) == .drag {
            session = PointingHandleSession(shapeID: id, handle: handle, origin: pointer.view)
        }
    }
}

/// A handle was pressed; past the drag threshold, a resize takes over for a resize handle
/// (`ResizingSession`), else the definition's drag session.
@MainActor
final class PointingHandleSession {
    let shapeID: ShapeID
    let handle: AnyHashable
    let origin: CGPoint
    init(shapeID: ShapeID, handle: AnyHashable, origin: CGPoint) {
        self.shapeID = shapeID
        self.handle = handle
        self.origin = origin
    }
}

extension PointingHandleSession: Session {
    /// A resize handle's resize cursor, else the closed hand.
    func cursor(in editor: CanvasEditor) -> CanvasCursor? { (handle.base as? ResizeHandle)?.cursor ?? .closedHand }

    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        guard pointer.view.distance(to: origin) > Style.dragThreshold, let next = dragSession(in: editor) else { return }
        editor.hoveredHandle = nil
        editor.session = next
        next.drag(pointer, in: editor)
    }

    /// What takes the drag over: a resize, for a resize handle; else the definition's session.
    private func dragSession(in editor: CanvasEditor) -> (any Session)? {
        let from = editor.camera.toWorld(origin)
        if let resize = handle.base as? ResizeHandle { return ResizingSession(shapeID: shapeID, handle: resize, from: from, in: editor) }
        guard let record = editor.document[shapeID],
              let definition = editor.registry.definition(for: record.kind) as? any HandleProviding else { return nil }
        return definition.erasedDragSession(for: handle, of: record, from: from, in: editor)
    }

    /// Released without a drag: drop any hint the press showed.
    func end(_ pointer: Pointer, in editor: CanvasEditor) {
        editor.hintedShapeID = nil
    }
}

/// The only selected shape's handles, in view points. They show in the select tool, and hide while
/// anything but a handle's or a canvas button's press, or a resize, is under way: a resize's follow
/// the box, the one dragged pressed.
struct HandlesOverlay: CanvasOverlay {
    var space: OverlaySpace { .view }

    func draw(in overlay: OverlayContext) {
        let editor = overlay.editor, context = overlay.cg
        var pressed: AnyHashable?
        switch editor.session {
        case nil, is PressingButtonSession: break
        case let pointing as PointingHandleSession: pressed = pointing.handle
        case let resizing as ResizingSession: pressed = AnyHashable(resizing.handle)
        default: return
        }
        guard editor.currentToolID == .select else { return }
        let radius = SelectionStyle.handleRadius * min(1, overlay.zoom / SelectionStyle.handleFullSizeZoom)
        for (handle, center) in editor.visibleHandles() {
            func circle(_ radius: CGFloat) -> CGRect {
                CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            }
            if handle == editor.hoveredHandle || handle == pressed {
                context.setFillColor(SelectionStyle.accentFill.cgColor)
                context.fillEllipse(in: circle(SelectionStyle.handleHitRadius))
            }
            context.setFillColor(NSColor.white.cgColor)
            context.fillEllipse(in: circle(radius))
            context.setStrokeColor(SelectionStyle.accent.cgColor)
            context.setLineWidth(SelectionStyle.handleStrokeWidth)
            context.strokeEllipse(in: circle(radius))
        }
    }
}
