import AppKit

/// Edited in place: from an editing placement, or by any plugin that calls `editor.beginEditing`
/// (Selection's double-click and Return). The view is laid over the shape's box, with bounds in
/// world units so AppKit scales it with the zoom.
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

/// Moved by its own rules instead of by its frame when a `TranslatingSession` moves it (a kind
/// without a box needs this to move at all; one with both uses this). When the drag starts, the
/// core calls `beginTranslation` once for each such shape, all in one transaction that commits
/// before the first move. On every drag event it then runs the returned translation, inside that
/// event's single transaction, after every moving box has moved. Escape puts every moved shape
/// back as it was before `beginTranslation`.
public protocol CustomTranslation: ShapeDefinition {
    /// `moving` is every shape being moved, this one included. A change made in `transaction`
    /// (arrows make bound ends precise) commits on its own, before anything moves.
    func beginTranslation(of shape: ShapeRecord<Props>, movingWith moving: Set<ShapeID>,
                          in transaction: inout Transaction) -> ShapeTranslation<Props>
}

/// One shape's part in one translation: `move(delta, &shape, shapes)` runs on every drag event.
/// - `delta`: world units the pointer has moved since the press;
/// - `shape`: the record as it is now (after `beginTranslation` and earlier moves);
/// - `shapes`: the document mid-transaction, with this event's boxes already moved.
@MainActor
public struct ShapeTranslation<Props: ShapeProps> {
    let move: @MainActor (CGPoint, inout ShapeRecord<Props>, ShapeContext) -> Void
    public init(_ move: @escaping @MainActor (_ delta: CGPoint, _ shape: inout ShapeRecord<Props>, _ shapes: ShapeContext) -> Void) {
        self.move = move
    }
}

/// Painted relative to another shape instead of by document order, so bringing it to front means
/// nothing. A connector stays just above the shapes it joins; a label, above its host.
public protocol PaintOrderAnchored: ShapeDefinition {
    /// Paint just above this shape; nil (or a shape that isn't there) paints above everything.
    func paintAnchor(of shape: ShapeRecord<Props>, in document: CanvasDocument) -> ShapeID?
}
