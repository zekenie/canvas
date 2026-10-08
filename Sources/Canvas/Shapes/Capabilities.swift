import AppKit

/// Edited in place: from an editing placement, or by any plugin that calls `editor.beginEditing`
/// (Selection's double-click and Return). The view is laid over the shape's editing frame (a box
/// kind's box; a kind without one says where, an arrow its label's), with bounds in world units
/// so AppKit scales it with the zoom.
public protocol Editable: ShapeDefinition {
    func makeEditingView(for shape: ShapeRecord<Props>, context: EditContext<Props>) -> EditingView
    /// Where the editing view goes while the shape is edited, in world units: looked at again as the
    /// shape or the camera changes, so it may grow with what's typed (an arrow's label). A box kind's
    /// is its box. Nil leaves the view where it was.
    func editingFrame(of shape: ShapeRecord<Props>, in context: ShapeContext) -> CGRect?
    /// Whether a shape whose editing ends with `props` is thrown away (a pill left empty, as a text
    /// shape is in tldraw). Asked by `endEditing` as the session ends by the person's own doing
    /// (Escape, a click elsewhere, another shape edited), after the view has saved what it holds and
    /// before the editing step closes: a true answer deletes the shape inside that step, so a shape
    /// placed and discarded nets to nothing and no step is left. Not asked when an undo, redo, board
    /// switch, command or draw ends the session: that action owns the open step, and an undo may be
    /// taking the shape away itself. Default false.
    func discardsWhenEditingEnds(_ props: Props) -> Bool
    /// What the step an editing session opens is called ("Edit Reference"), as a menu says Undo Edit
    /// Reference. Nil is "Typing". A step an action holds open (a placement's "Add ...") keeps the
    /// action's name.
    var editingStepName: String? { get }
}

extension Editable {
    public func discardsWhenEditingEnds(_ props: Props) -> Bool { false }
    public var editingStepName: String? { nil }
}

extension Editable where Props: BoxShapeProps {
    public func editingFrame(of shape: ShapeRecord<Props>, in context: ShapeContext) -> CGRect? { shape.frame }
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
public struct EditContext<Props: ShapeProps> {
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

    /// Ends this editing session: nothing once it has ended, or another has begun, so a view may
    /// end it a turn later (as the keyboard leaves it).
    public func end() {
        guard let editor, editor.editingShapeID == shapeID else { return }
        editor.endEditing()
    }

    /// The shape as it is now: what something other than typing wrote shows here (a language
    /// model's answer landing). It reads the document, which an observation hears change with
    /// every commit, so a view that waits for one write observes what says it's coming instead.
    /// Nil once it's gone.
    public var shape: ShapeRecord<Props>? { editor?.document[shapeID]?.typed(as: Props.self) }

    /// Where the editing view is laid over the shape now (`Editable.editingFrame`), in world units:
    /// the origin of the view's coordinates. Nil once the shape is gone.
    public var frame: CGRect? { editor?.editingFrame(of: shapeID) }

    /// Brings `rect` into view (a caret's, where text is typed past the window's edge: a note
    /// growing downward with what's typed), moving the camera at once, by as little as it takes, into
    /// the part of the view the host leaves clear, 16 points in from its edges; no zoom, and no undo
    /// step. `rect` is in the editing view's coordinates: world units, with the shape's editing frame
    /// at their origin, as the view's bounds are. Nothing while a press is under way.
    public func keepInView(_ rect: CGRect) { editor?.keepInView(rect, of: shapeID) }

    /// The pointer is on part of the view that has a popover (its anchor in the view's coordinates,
    /// as `keepInView`'s rect is), or on nothing that has one (nil), as `editor.hoverPopover` hears
    /// it from the select tool over the canvas, which doesn't hear the pointer over the editing
    /// view. Nothing once this session has ended.
    public func hoverPopover(_ popover: CanvasPopover?) {
        guard let editor, editor.editingShapeID == shapeID else { return }
        guard let popover, let box = editor.editingFrame(of: shapeID) else {
            editor.hoverPopover(nil)
            return
        }
        var inWorld = popover
        inWorld.anchor = popover.anchor.offsetBy(dx: box.minX, dy: box.minY)
        editor.hoverPopover(inWorld)
    }
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
/// (a schema card's height, which `setPrompt` fits to its description). A shape made from properties
/// written somewhere else, `Registry.shape(_:properties:)`, or given some of its own that way,
/// `shape(_:setting:)` (the command line's `draw`), goes through `derive` before anything else is
/// done with it, so it's in step as the setters would have left it, and so does one handed to
/// `registry.derived(_:)` (`draw`'s width alone, at the new width). A board read doesn't (a shape
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

/// Drawn more simply zoomed out: how a shape shows in place of `render` while the canvas draws
/// skeletons (the camera's zoom under the editor's `skeletonZoom`, 35%, where text no longer
/// reads). A skeleton is what the shape is and where, less than the real view: its fills, and
/// bars where its text would be (`RenderContext.fillSkeletonText`), never text, shadows or images
/// of its own. The shape being edited is never drawn as one (its editing view is over it). A kind
/// without this gets the default, its geometry in one neutral gray
/// (`RenderContext.drawSkeleton(of:color:)`, which a skeleton may draw too, in a color of its own).
///
/// Zoomed out, a frame draws thousands, so keep it cheap: a few fills, costing about the same
/// whatever the shape holds; read the shape, its geometry (kept from frame to frame:
/// `context.shapes.geometry(of:)`), `context.zoom`, and at most what's already kept for it (a
/// board's preview, `drawBoardPreview`; what its plugin keeps of the shape), never anything that parses or
/// lays out text (a line's bar is as long as its text's columns, `SkeletonText`, say, not as its
/// measured width).
/// While skeletons are drawn, its outline (selected, hovered, the hint) is its kept geometry's, in
/// place of `indicatorPath`, which is what the default skeleton fills; a kind whose skeleton isn't
/// that outlines it its own way (`CustomSkeletonOutline`).
public protocol CustomSkeleton: ShapeDefinition {
    func renderSkeleton(_ shape: ShapeRecord<Props>, in context: RenderContext)
}

/// A skeleton outlined its own way while skeletons are drawn (selected, hovered, the hint), in
/// place of its kept geometry's outline: a kind whose skeleton isn't that says how it's outlined
/// (an arrow's arc, where its kept geometry is only three points, its start, middle and end). Found
/// once per kind, so every other kind's shape is outlined without being asked. Not asked for a
/// shape only a few pixels across, outlined by its bounds as the default skeleton is drawn. ⌘A
/// zoomed out outlines every shape in view each frame, so it costs what the skeleton does: made
/// from the shape and its kept geometry (`context.geometry(of:)`), nothing worked out again. And
/// it's stroked, where a rect's outline is filled as a ring for a fraction of that: leave it out
/// for a skeleton that differs from a rect geometry only by corners rounded a pixel or two at
/// these zooms.
public protocol CustomSkeletonOutline: CustomSkeleton {
    /// What `renderSkeleton` draws, so the outline and the skeleton agree; nil for its kept
    /// geometry's outline, as a kind without this has.
    func skeletonIndicatorPath(of shape: ShapeRecord<Props>, in context: ShapeContext) -> CGPath?
}

/// A kind drawn as a line (an arrow), saying how wide: what the core covers a tinted outline
/// (`Outlines.tinted`, a plugin's own colors) of such a shape to. An open shape's outline is a
/// couple of view points along its middle, wider than the line where the line is thin on screen and
/// a stripe down the middle of it where it's thick (an arrow's 3.5 units are 7 view points at 200%).
/// With this the core strokes a tinted outline of an open shape of the kind, drawn in full, as
/// wide as the line is on screen and a point more, round, so it covers the line and what the line
/// is drawn with (an arrow's heads are part of its outline); zoomed out, where shapes are
/// skeletons, it's the plain width. Only tinted outlines cover: the selection's and a hover's stay
/// as thin as they are. Found once per kind (`registry.strokedShapes`), so no other kind's shape is
/// asked.
public protocol StrokedShape: ShapeDefinition {
    /// How wide `render` strokes the shape's line, in world units: what its outline is stroked to
    /// cover, so it follows the shape's own line (an arrow says its stroke width, whatever its
    /// props). Asked each frame of each tinted shape of the kind in view, so read the shape and
    /// nothing worked out again.
    func lineWidth(of shape: ShapeRecord<Props>, in context: ShapeContext) -> CGFloat
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

/// Each shape of this box kind contains shapes on its own board (a frame): a shape it holds names it
/// as its container (`AnyShapeRecord.container`, set in a transaction, `setContainer`), which isn't
/// in any schema. Nothing to implement: the core moves what a container holds with it, paints it
/// above it, holds it read-only while the container is, lets go of it into the container's own
/// container when the container is deleted, and keeps what's put down from sitting across a
/// container's edge (`Transaction.settle`). Only box kinds hold, and are held.
public protocol ShapeContaining: ShapeDefinition where Props: BoxShapeProps {}
