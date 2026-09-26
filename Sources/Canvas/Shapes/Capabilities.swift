import AppKit

/// Edited in place: double-click, Return, or an editing placement. The view is laid over the
/// shape's box, with bounds in world units so AppKit scales it with the zoom.
public protocol Editable: ShapeDefinition where Props: BoxShapeProps {
    func makeEditingView(for shape: ShapeRecord<Props>, context: EditContext<Props>) -> EditingView
}

@MainActor
public struct EditingView {
    public let view: NSView
    public let firstResponder: NSResponder
    public init(view: NSView, firstResponder: NSResponder) {
        self.view = view
        self.firstResponder = firstResponder
    }
}

/// An editing view's way back into the document.
@MainActor
public struct EditContext<Props: BoxShapeProps> {
    public let shapeID: ShapeID
    weak var editor: CanvasEditor?

    init(shapeID: ShapeID, editor: CanvasEditor) {
        self.shapeID = shapeID
        self.editor = editor
    }

    /// Changes the shape in a transaction. Does nothing once the shape is gone.
    public func update(_ change: (inout Props) -> Void) {
        editor?.transact { $0.update(shapeID, as: Props.self) { change(&$0.props) } }
    }

    public func end() { editor?.endEditing() }
}

/// What pressing a handle did.
public enum HandlePress: Sendable {
    /// Wait for a drag: past the drag threshold, `dragSession` takes over.
    case drag
    /// The press did something on its own (a double-click toggle, say), so there's no drag.
    case consumed
}

/// Draggable handles on the selected shape. The core finds, draws and hit-tests them (in view
/// points, `Style.handleRadius` / `handleHitRadius`) and applies the drag threshold; the
/// definition decides what they do.
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

/// Pressed in the select tool, these start their own session instead of following the pointer
/// by their box. A kind without a box needs this to be movable at all.
public protocol CustomTranslation: ShapeDefinition {
    func translationSession(for shape: ShapeRecord<Props>, at pointer: Pointer, in editor: CanvasEditor) -> any Session
}

/// Painted relative to another shape instead of by document order, and never brought to front
/// when pressed. (A connector stays just above the shapes it joins; a label, above its host.)
public protocol PaintOrderAnchored: ShapeDefinition {
    /// Paint just above this shape; nil (or a shape that isn't there) paints above everything.
    func paintAnchor(of shape: ShapeRecord<Props>, in document: CanvasDocument) -> ShapeID?
}
