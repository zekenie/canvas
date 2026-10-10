import AppKit
import Canvas

// The rows of the note being edited. The note's editing view covers the whole paper, so a press over the rows
// would land in its text and put the caret at the end of the words. A kind that hosts an editing view over its
// rows lays this one over them: a press in the rows is the rows', whatever the text view under it would do.
// Here it does what a click on the canvas does for the part under the point (Retry, a card, an options list)
// and nothing elsewhere.

/// What the kind's editing view lends the rows view of its session.
@MainActor
public struct RowsHost {
    /// The editing view's origin, world units: the view's coordinates are the shape's laid-out frame at zero.
    public var origin: @MainActor () -> CGPoint?
    /// Ends the editing session.
    public var end: @MainActor () -> Void
    /// Brings a rect in the rows view's coordinates into view.
    public var keepInView: @MainActor (CGRect) -> Void
    /// Puts the caret back in the words, at their end.
    public var focusWords: @MainActor () -> Void

    public init(origin: @escaping @MainActor () -> CGPoint?, end: @escaping @MainActor () -> Void,
                keepInView: @escaping @MainActor (CGRect) -> Void, focusWords: @escaping @MainActor () -> Void) {
        self.origin = origin
        self.end = end
        self.keepInView = keepInView
        self.focusWords = focusWords
    }
}

/// The view over a shape's rows while it is edited. It draws nothing (the render under it draws the rows, and
/// the editing view has no background) and never takes the keyboard in this slice.
@MainActor
public final class RowsView: NSView {
    private weak var book: RowBook?
    private let shape: ShapeID
    private let host: RowsHost

    init(shape: ShapeID, book: RowBook, host: RowsHost) {
        self.shape = shape
        self.book = book
        self.host = host
        super.init(frame: .zero)
        isHidden = true
        reposition()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Its coordinates are the editing view's: world units, the shape's frame at their origin.
    public override var isFlipped: Bool { true }
    public override var acceptsFirstResponder: Bool { false }

    /// Puts itself over the shape's rows (`rowsRect` less the host's origin); hidden with none.
    public func reposition() {
        guard let book, let rect = book.rowsRect(of: shape), let origin = host.origin() else {
            isHidden = true
            return
        }
        let frame = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        if self.frame != frame { self.frame = frame }
        isHidden = false
    }

    /// The row part under a point of this view, if any.
    private func face(at point: CGPoint) -> RowFace? {
        guard let book, let origin = host.origin() else { return nil }
        let inEditor = convert(point, to: superview)
        return book.editedFace(at: CGPoint(x: inEditor.x + origin.x, y: inEditor.y + origin.y), on: shape)
    }

    public override func mouseDown(with event: NSEvent) {
        guard let face = face(at: convert(event.locationInWindow, from: nil)) else { return }
        book?.perform(face)
    }

    /// The arrow over all of it: the words' I-beam stops where the rows begin.
    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }

    public override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }
}

extension RowBook {
    /// The view that takes the clicks on the rows of a shape while its words are edited, laid over them by
    /// the kind's editing view (it calls `reposition()` as the editing view changes size). Nil for a kind
    /// that shows no rows. The book keeps one: the session's.
    public func makeRowsView(for shape: ShapeID, host: RowsHost) -> RowsView? {
        guard let record = editor?.document[shape], kinds.contains(record.kind) else { return nil }
        let view = RowsView(shape: shape, book: self, host: host)
        rowsView = view
        return view
    }

    /// The shape's rows moved or changed: the view over them follows.
    func rowsChanged() {
        rowsView?.reposition()
    }
}
