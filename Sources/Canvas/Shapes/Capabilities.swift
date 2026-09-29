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
    /// Where editing began, in world units: the press `editor.beginEditing(_:at:)` was given, so a
    /// view can put its selection there (the character pressed). Nil when what began it didn't say
    /// (Return, a placement): the view chooses, as it always has.
    public let startPoint: CGPoint?
    /// How many clicks that press was: 2 for a double-click (Selection's), where a text view selects
    /// the word pressed; else 1.
    public let startClickCount: Int
    weak var editor: CanvasEditor?

    init(shapeID: ShapeID, startPoint: CGPoint?, startClickCount: Int, editor: CanvasEditor) {
        self.shapeID = shapeID
        self.startPoint = startPoint
        self.startClickCount = startClickCount
        self.editor = editor
    }

    /// Changes the shape in a transaction. Does nothing once the shape is gone. While the shape is
    /// being edited, what it commits is the editing session's undo step ("Typing").
    public func update(_ change: (inout Props) -> Void) {
        editor?.transact(nil, coalescing: nil, origin: .editing) { $0.update(shapeID, as: Props.self) { change(&$0.props) } }
    }

    public func end() { editor?.endEditing() }

    /// Brings `rect` into view (a caret's, where text is typed past the window's edge: a note
    /// growing downward with what's typed), moving the camera at once, by as little as it takes, into
    /// the part of the view the host leaves clear, 16 points in from its edges; no zoom, and no undo
    /// step. `rect` is in the editing view's coordinates: world units, with the shape's box at their
    /// origin, as the view's bounds are. Nothing while a press is under way.
    public func keepInView(_ rect: CGRect) { editor?.keepInView(rect, of: shapeID) }
}

extension EditContext {
    /// One of the editor's services, as the detail panel's, the table of contents' and adornments'
    /// contexts lend them: what an editing view needs besides its own shape (a completion list's
    /// candidates). Nil if no installed plugin registers it, or the editor is gone.
    public func service<S: EditorService>(_: S.Type) -> S? { editor?.service(S.self) }
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

/// Props that hold something following from the rest, which the kind's own setters keep in step
/// (a schema card's height, which `setSchema` fits to its schema). A shape made from properties
/// written somewhere else, `Registry.shape(_:properties:)`, or given some of its own that way,
/// `shape(_:setting:)` (the command line's `draw`), goes through `derive` before anything else is
/// done with it, so it's in step as the setters would have left it. A board read doesn't (a shape
/// is as it was saved), nor does a paste, nor anything a person does.
public protocol DerivedProps: ShapeDefinition {
    func derive(_ props: inout Props)
}

/// Painted relative to another shape instead of by document order, so bringing it to front means
/// nothing. A connector stays just above the shapes it joins; a label, above its host.
public protocol PaintOrderAnchored: ShapeDefinition {
    /// Paint just above this shape; nil (or a shape that isn't there) paints above everything.
    /// It must follow from the shape's own props and the document's order (which shapes there
    /// are, and where), not other shapes' props: the editor works the paint order out again only
    /// when the stack, or this shape, changes.
    func paintAnchor(of shape: ShapeRecord<Props>, in document: CanvasDocument) -> ShapeID?
}

/// Props bound to other shapes (a connector's ends, a label's host). Every kind whose props are
/// bound to a shape adopts it, since the core and plugins keep those bindings right through it:
/// deleting a shape lets go of it in every shape bound to it, and a copy is bound to the copies of
/// the shapes its original was bound to and lets go of the rest (pasting). A binding's shape must
/// be on the board. A name that may outlive its shape (a mention in text) is a value instead,
/// `ShapeNaming`, which a copy renames and a deletion never looks for; a kind whose props only
/// name shapes doesn't adopt this. A kind that holds shapes' ids with neither goes on holding one
/// once its shape is gone, and a copy goes on holding the original's. A kind whose props hold no
/// shape's id needs nothing.
public protocol ShapeReferencing: ShapeDefinition {
    /// The props, with every shape they're bound to passed through `map`: bound to the shape `map`
    /// returns instead, or, where it returns nil, let go of as though that shape were being deleted
    /// (an arrow's end stays where it's drawn: where it is in `context`, which still has the shape).
    /// Nil when it can't let go of one: a shape `context` doesn't have, which it can't tell how to
    /// do without (an arrow can't tell where that end is drawn). A deletion then leaves the props
    /// as they were, and a copy leaves the shape out.
    func remappingReferences(of shape: ShapeRecord<Props>, _ map: (ShapeID) -> ShapeID?, in context: ShapeContext) -> Props?
}

/// Each shape of this kind owns a board, one under the board it's on: kept in the file under its id
/// (`BoardID(owner:)`, `CanvasFile.children`), not in its props. The core keeps a board with the
/// shape whose id keys it, whatever that shape's kind; this says which kinds' shapes own theirs, so
/// which boards are there to show. Its schema says so (`x-canvas-board`).
public protocol BoardOwning: ShapeDefinition {}
