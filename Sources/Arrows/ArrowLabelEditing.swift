import AppKit
import Canvas
import DetailPanel
import Geometry
import Selection

/// An arrow's label is edited in place (tldraw's): a double-click on the arrow, Return with it
/// selected, or a click on the label of the only selected arrow, which puts the caret where it's
/// clicked (the rest select all its text). The editing view is laid over the label, which grows
/// with what's typed, an empty one as wide as an "i", at halfway (tldraw's `onEditStart`), where
/// the first text typed puts it.
extension ArrowDefinition: Editable {
    func makeEditingView(for shape: ShapeRecord<Arrow>, context: EditContext<Arrow>) -> EditingView {
        let editor = ArrowLabelEditor(arrow: shape, context: context)
        return EditingView(view: editor, firstResponder: editor.textView)
    }

    func editingFrame(of shape: ShapeRecord<Arrow>, in context: ShapeContext) -> CGRect? {
        ArrowLabels.frame(of: shape.props, on: arrowGeometry(shape.props, in: context), editing: true)
    }
}

/// A click edits an arrow only on its label, and a drag from its label slides the label along the
/// body (tldraw's PointingArrowLabel), not the arrow.
extension ArrowDefinition: LabeledShape {
    func labelDragSession(of shape: ShapeRecord<Arrow>, from origin: CGPoint, in editor: CanvasEditor) -> (any Session)? {
        guard let label = labelFrame(of: shape, in: editor.shapeContext) else { return nil }
        return ArrowLabelDragSession(arrowID: shape.id, grabOffset: label.center - origin, before: shape.props.labelPosition)
    }
}

/// Dragging an arrow's label: its center follows the pointer (as it was grabbed) to the nearest
/// point of the body, and snaps to halfway within `ArrowStyle.labelSnapDistance` view points of it.
/// One step, "Move Label"; Escape puts it back.
@MainActor
final class ArrowLabelDragSession {
    let arrowID: ShapeID
    let grabOffset: CGPoint
    let before: CGFloat

    init(arrowID: ShapeID, grabOffset: CGPoint, before: CGFloat) {
        self.arrowID = arrowID
        self.grabOffset = grabOffset
        self.before = before
    }
}

extension ArrowLabelDragSession: Session {
    func cursor(in editor: CanvasEditor) -> CanvasCursor? { .closedHand }

    func drag(_ pointer: Pointer, in editor: CanvasEditor) {
        guard let body = editor.arrowGeometry(of: arrowID)?.body, body.length > 0 else { return }
        var position = body.fraction(nearest: pointer.world + grabOffset)
        let halfway = ArrowLabelLayout.defaultPosition
        if body.point(at: position).distance(to: body.point(at: halfway)) <= ArrowStyle.labelSnapDistance / editor.camera.zoom {
            position = halfway
        }
        move(to: position, in: editor)
    }

    func cancel(in editor: CanvasEditor) -> Bool {
        move(to: before, in: editor)
        return true
    }

    private func move(to position: CGFloat, in editor: CanvasEditor) {
        guard editor.document[arrowID]?.typed(as: Arrow.self)?.props.labelPosition != position else { return }
        editor.transact("Move Label") { $0.update(arrowID, as: Arrow.self) { $0.props.labelPosition = position } }
    }
}

/// A text view laid over the label being edited: its frame in view points and its bounds in world
/// units, the label's frame at their origin, so AppKit scales it by the zoom and the text lays out
/// as the canvas draws it (`ArrowStyle.labelAttributes`, centered), its padding in from the label's
/// edges. Each change is written to the arrow, which the label grows with, and the canvas lays the
/// view over the label again. Escape and ⌘↩ end editing; Return is a new line, as in tldraw.
final class ArrowLabelEditor: NSView, NSTextViewDelegate {
    let textView: DetailTextView
    private let context: EditContext<Arrow>

    init(arrow: ShapeRecord<Arrow>, context: EditContext<Arrow>) {
        self.context = context
        let frame = context.frame ?? .zero
        textView = DetailTextView(frame: CGRect(origin: .zero, size: frame.size))
        super.init(frame: .zero)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.focusRingType = .none
        textView.textContainer?.lineFragmentPadding = 0
        // TextKit 2 sets a line's glyphs a point lower in it than string drawing does, so the text
        // starts a point higher than the render's, as a note's editor does.
        textView.textContainerInset = NSSize(width: ArrowStyle.labelPadding, height: ArrowStyle.labelPadding - 1)
        textView.typingAttributes = ArrowStyle.labelAttributes
        textView.textStorage?.setAttributedString(NSAttributedString(string: arrow.props.text, attributes: ArrowStyle.labelAttributes))
        textView.insertionPointColor = ArrowStyle.color
        textView.delegate = self
        textView.commitsOnLeaving = false
        textView.onCommit = { [weak self] in self?.context.end() }
        clipsToBounds = true
        addSubview(textView)
        // Begun from a press on the label, the caret goes where it was (a double-click's word);
        // begun anywhere else (the body, Return), all its text is selected, as tldraw's.
        if let start = context.startPoint, frame.contains(start) {
            textView.placeSelection(at: CGPoint(x: start.x - frame.minX, y: start.y - frame.minY), selectingWord: context.startClickCount >= 2)
        } else {
            textView.selectAll(nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Writes the text only when it differs from the arrow's: a second report of one change (after
    /// an undo) writes nothing. A label that said nothing starts halfway, where it's shown while it's
    /// empty (tldraw's onEditStart, which writes it as editing begins: here an edit that types
    /// nothing changes nothing, and leaves no step to undo).
    func textDidChange(_ notification: Notification) {
        let text = textView.string
        context.update { arrow in
            guard arrow.text != text else { return }
            if !arrow.hasText { arrow.labelPosition = ArrowLabelLayout.defaultPosition }
            arrow.text = text
        }
        keepCaretInView()
    }

    func textViewDidChangeSelection(_ notification: Notification) { keepCaretInView() }

    private func keepCaretInView() {
        guard window != nil, let caret = textView.caretFrame else { return }
        context.keepInView(convert(caret, from: textView))
    }

    /// The canvas lays the editor over the label, its bounds the label's size, which changes with
    /// what's typed: the text view takes it.
    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        if textView.frame.size != newSize { textView.setFrameSize(newSize) }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(cancelOperation(_:)) else { return false }
        context.end()
        return true
    }
}
