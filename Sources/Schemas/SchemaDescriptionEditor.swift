import AppKit
import Canvas
import DetailPanel
import Mentions
import Observation

/// A text view laid over the card being edited, for its description, as a note's editor is laid
/// over the note: its frame in view points and its bounds in world units, the card's frame at their
/// origin, so AppKit scales it by the zoom and the text lays out exactly as the canvas draws it
/// (`SchemaStyle.text`), pills and all. It's a `MentionTextView` that mentions only schema cards:
/// `@` where a word starts lists the file's other cards, and a pick is a pill, which the sync writes
/// as a `$ref` to the card's schema (`SchemaReferences`). Return is a new line, as in a note; ⌘↩ says
/// the description is done and ends editing, and so do Escape and the keyboard going to a view
/// outside the canvas (the panel's JSON: the description syncs before what's typed there). The sync
/// asks for the schema once editing ends, however it ends (`SchemaSync.editingDidEnd`), or after a
/// pause in the typing. The card grows and shrinks with what's typed, in the typing's step.
///
/// The card's highlights show behind its words, where the canvas draws them under the view, as they
/// are for the text being typed (words kept keep theirs), and resting the pointer on one shows its
/// part of the schema in a popover, as on the canvas (`SchemaHighlightPopovers`), until something's
/// typed.
///
/// While the model writes the description (the answer to an edit of the schema), it's read-only and
/// faint, as the panel's box was, and what lands shows in it: it follows the card's sync status.
final class SchemaDescriptionEditor: NSView, NSTextViewDelegate {
    let textView: MentionTextView<Only<SchemaCard>>
    private let context: EditContext<SchemaCard>
    private weak var sync: SchemaSync?
    private weak var mentions: MentionState?
    /// The description as this view last wrote or showed it: a card that says otherwise was
    /// written from outside (the model's answer).
    private var known: SchemaPromptText
    /// A description written from outside is being shown: its caret moved, not the person's.
    private var isShowing = false

    init(card: ShapeRecord<SchemaCard>, context: EditContext<SchemaCard>) {
        self.context = context
        sync = context.service(SchemaSync.self)
        mentions = context.service(MentionState.self)
        known = card.props.prompt
        let frame = card.frame
        textView = MentionTextView(frame: CGRect(origin: .zero, size: frame.size), text: card.props.prompt, style: SchemaStyle.text,
                                   owner: context.shapeID, mentions: mentions)
        super.init(frame: .zero)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.focusRingType = .none
        // The padding before the inset, as a note's: setting the inset fits the pills to the line.
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = SchemaStyle.editorInset
        textView.typingAttributes = SchemaStyle.textAttributes
        textView.insertionPointColor = SchemaStyle.textColor
        textView.delegate = self
        // ⌘↩ and Escape end editing at once, ⌘↩ while the model writes the description too; Return
        // is the text's. The keyboard leaving ends it a turn later, once it's where it went, and only
        // if that's outside the canvas: a press on the canvas ends editing as the canvas has it (a
        // pan while typing doesn't).
        textView.commitsOnReturn = false
        textView.commitsOnLeaving = false
        textView.commitsWhileReadOnly = true
        textView.onCommit = { [weak self] in self?.context.end() }
        textView.onExit = { [weak self] in self?.context.end() }
        textView.onLeave = {
            Task { @MainActor [weak self] in self?.keyboardLeft() }
        }
        textView.onPointer = { [weak self] point in self?.hover(at: point) }
        clipsToBounds = true
        addSubview(textView)
        // A card too short for its description (drawn with a `size:`) grows to it as editing
        // begins, as typing would grow it, in the editing's step; never shorter than it is.
        let fitted = SchemaStyle.fittedHeight(of: textView.attributedString(), width: frame.width, keeping: frame.height)
        if fitted > frame.height {
            context.update { $0.frame.size.height = max($0.frame.size.height, fitted) }
            textView.setFrameSize(CGSize(width: frame.width, height: fitted))
        }
        // Begun from a press, the selection goes where it was, as a click in the text puts it: on a
        // pill, the pill; elsewhere the caret, or for a double-click the word. Begun without one
        // (Return, placing a card), where the text view puts it.
        if let start = context.startPoint {
            textView.placeSelection(at: CGPoint(x: start.x - frame.minX, y: start.y - frame.minY), selectingWord: context.startClickCount >= 2)
        }
        follow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Writes the description only when it differs from the card's (a second report of one change
    /// writes nothing), and fits the card to it as it's shown, pills as their cards are called now,
    /// in the same write (`setPrompt`), so growing is part of the typing's step ("Typing", "Add
    /// Schema").
    func textDidChange(_ notification: Notification) {
        let text = textView.mentionText
        let shown = textView.attributedString()
        known = text
        context.update { card in
            guard card.prompt != text else { return }
            card.setPrompt(text, shown: shown)
        }
        context.hoverPopover(nil)
        keepCaretInView()
    }

    /// The caret moved (an arrow key, a click): it's kept in view too. Not for a description shown
    /// from outside, which moves no one's caret.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isShowing else { return }
        keepCaretInView()
    }

    /// A card grows downward with its description, past the window's bottom if it's near it, and
    /// the camera follows the caret, as a note's editor has it (`EditContext.keepInView`).
    private func keepCaretInView() {
        guard window != nil, let caret = textView.caretFrame else { return }
        // In this view's coordinates: world units, the card's frame at their origin.
        context.keepInView(convert(caret, from: textView))
    }

    /// The canvas lays the editor over the card, its bounds the card's size: as the card grows with
    /// its description, the text view grows with it.
    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        if textView.frame.size != newSize { textView.setFrameSize(newSize) }
    }

    /// The keyboard went elsewhere: to a view outside the canvas (the panel's JSON, a field), the
    /// description is done, so editing ends there, the keyboard staying where it went. On the
    /// canvas itself (a press there), what the press does decides.
    private func keyboardLeft() {
        guard let canvas = superview, let window = canvas.window else { return }
        if let responder = window.firstResponder as? NSView, responder === canvas || responder.isDescendant(of: canvas) { return }
        context.end()
    }

    /// Read-only and faint while the model writes the description; and the description the card
    /// has, shown in place of the text's, when something other than this view wrote it (the
    /// model's answer landing). Looked at again as the card's sync status changes: only the sync
    /// writes the description while it's typed into (undo, a draw and a file put in place end
    /// editing first), and its answer is written before the status moves on, so it's there to read
    /// (unobserved: every commit would wake an observation of the document).
    private func follow() {
        let id = context.shapeID
        let isUpdating = withObservationTracking {
            sync?.status(of: id) == .updating(.prompt)
        } onChange: { [weak self] in
            // Heard as it's about to change: looked at once it has.
            Task { @MainActor [weak self] in self?.follow() }
        }
        if textView.isEditable == isUpdating {
            textView.isEditable = !isUpdating
            textView.showEnabled(!isUpdating)
        }
        if let prompt = context.shape?.props.prompt, prompt != known { show(prompt) }
    }

    /// The pointer over the text (a point in the text view's coordinates, which are this view's: the
    /// card's, its frame at their origin), or gone from it: on a highlight's words where the canvas
    /// draws them (the text lays out as the canvas draws it), their popover, beside the line it's on.
    private func hover(at point: CGPoint?) {
        guard let point, let card = context.shape else { return context.hoverPopover(nil) }
        let placed = SchemaHighlightAnswers.placed(for: card)
        guard !placed.isEmpty else { return context.hoverPopover(nil) }
        let origin = card.frame.origin, inWorld = CGPoint(x: point.x + origin.x, y: point.y + origin.y)
        let lines = SchemaHighlightAnswers.lines(of: card) { [mentions] in mentions?.resolve($0) ?? .missing }
        for (highlight, lines) in zip(placed, lines) {
            guard let line = lines.first(where: { $0.contains(inWorld) }) else { continue }
            let anchor = line.offsetBy(dx: -origin.x, dy: -origin.y)
            context.hoverPopover(SchemaHighlightPopovers.popover(of: highlight, in: card, anchor: anchor) { [sync] in sync?.shape(inFile: $0) })
            return
        }
        context.hoverPopover(nil)
    }

    /// Shows a description written from outside: the text's storage alone (`MentionTextView.show`,
    /// the caret where it was as far as the text reaches), the camera where it is, and typing's undo
    /// dropped, since it's of text that isn't there.
    private func show(_ prompt: SchemaPromptText) {
        isShowing = true
        defer { isShowing = false }
        known = prompt
        textView.show(prompt)
        if let undoManager = textView.undoManager {
            if let storage = textView.textStorage { undoManager.removeAllActions(withTarget: storage) }
            undoManager.removeAllActions(withTarget: textView)
        }
    }
}
