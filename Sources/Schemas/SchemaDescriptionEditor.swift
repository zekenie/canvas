import AppKit
import Canvas
import DetailPanel
import Observation

/// A text view laid over the card being edited, for its description, as a note's editor is laid
/// over the note: its frame in view points and its bounds in world units, the card's frame at their
/// origin, so AppKit scales it by the zoom and the text lays out exactly as the canvas draws it
/// (`SchemaStyle.textAttributes`). Return says the description is done, as it did in the panel, and
/// ends editing, and so do ⌘↩, Escape and the keyboard going to a view outside the canvas (the
/// panel's JSON: the description syncs before what's typed there); ⇧↩ is a new line. The sync asks
/// for the schema once editing ends, however it ends (`SchemaSync.editingDidEnd`), or after a pause
/// in the typing. The card grows and shrinks with what's typed, in the typing's step.
///
/// While the model writes the description (the answer to an edit of the schema), it's read-only and
/// faint, as the panel's box was, and what lands shows in it: it follows the card's sync status.
final class SchemaDescriptionEditor: NSView, NSTextViewDelegate {
    let textView: SchemaDescriptionView
    private let context: EditContext<SchemaCard>
    private weak var sync: SchemaSync?
    /// The description as this view last wrote or showed it: a card that says otherwise was
    /// written from outside (the model's answer).
    private var known: String
    /// A description written from outside is being shown: its caret moved, not the person's.
    private var isShowing = false

    init(card: ShapeRecord<SchemaCard>, context: EditContext<SchemaCard>) {
        self.context = context
        sync = context.service(SchemaSync.self)
        known = card.props.prompt
        let frame = card.frame
        textView = SchemaDescriptionView(frame: CGRect(origin: .zero, size: frame.size))
        super.init(frame: .zero)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.focusRingType = .none
        // The padding before the inset, as a note's.
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = SchemaStyle.editorInset
        textView.typingAttributes = SchemaStyle.textAttributes
        textView.insertionPointColor = SchemaStyle.text
        textView.textStorage?.setAttributedString(NSAttributedString(string: card.props.prompt, attributes: SchemaStyle.textAttributes))
        textView.delegate = self
        // Return, ⌘↩ and Escape end editing at once. The keyboard leaving ends it a turn later, once
        // it's where it went, and only if that's outside the canvas: a press on the canvas ends
        // editing as the canvas has it (a pan while typing doesn't).
        textView.commitsOnReturn = true
        textView.commitsOnLeaving = false
        textView.onCommit = { [weak self] in self?.context.end() }
        textView.onExit = { [weak self] in self?.context.end() }
        textView.onLeave = { [weak self] in
            Task { @MainActor [weak self] in self?.keyboardLeft() }
        }
        clipsToBounds = true
        addSubview(textView)
        // A card too short for its description (drawn with a `size:`) grows to it as editing
        // begins, as typing would grow it, in the editing's step; never shorter than it is.
        let fitted = SchemaStyle.fittedHeight(of: card.props.prompt, width: frame.width, keeping: frame.height)
        if fitted > frame.height {
            context.update { $0.frame.size.height = max($0.frame.size.height, fitted) }
            textView.setFrameSize(CGSize(width: frame.width, height: fitted))
        }
        // Begun from a press, the caret goes where it was, or for a double-click the word; begun
        // without one (Return, placing a card), where the text view puts it.
        if let start = context.startPoint {
            textView.placeSelection(at: CGPoint(x: start.x - frame.minX, y: start.y - frame.minY), selectingWord: context.startClickCount >= 2)
        }
        follow()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Writes the description only when it differs from the card's (a second report of one change
    /// writes nothing), and fits the card to it in the same write (`setPrompt`), so growing is part
    /// of the typing's step ("Typing", "Add Schema").
    func textDidChange(_ notification: Notification) {
        let text = textView.string
        known = text
        context.update { card in
            guard card.prompt != text else { return }
            card.setPrompt(text)
        }
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

    /// Shows a description written from outside: the text's storage alone, the caret where it was as
    /// far as the text reaches (never inside a character), the camera where it is, and typing's undo
    /// dropped, since it's of text that isn't there.
    private func show(_ prompt: String) {
        isShowing = true
        defer { isShowing = false }
        known = prompt
        let text = prompt as NSString
        var caret = min(textView.selectedRange().location, text.length)
        if caret < text.length { caret = text.rangeOfComposedCharacterSequence(at: caret).location }
        textView.textStorage?.setAttributedString(NSAttributedString(string: prompt, attributes: SchemaStyle.textAttributes))
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        if let undoManager = textView.undoManager {
            if let storage = textView.textStorage { undoManager.removeAllActions(withTarget: storage) }
            undoManager.removeAllActions(withTarget: textView)
        }
    }
}

/// The description's text view, a `DetailTextView` (TextKit 2): a plain text view on the canvas
/// but for what its editor sets. Dimmed as a whole while it can't be written, since its text keeps
/// the card's own gray in both appearances.
final class SchemaDescriptionView: DetailTextView {
    /// The keyboard left it, for anything.
    var onLeave: (@MainActor () -> Void)?

    override func showEnabled(_ isEnabled: Bool) {
        alphaValue = isEnabled ? 1 : SchemaStyle.updatingOpacity
    }

    /// Read-only (the model writing the description), Return and ⌘↩ are done all the same, as
    /// Escape is: nothing was typed to commit.
    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if !isEditable, !hasMarkedText(), event.keyCode == 36 || event.keyCode == 76, modifiers.isEmpty || modifiers == .command, let onExit {
            onExit()
            return
        }
        super.keyDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onLeave?() }
        return resigned
    }

    /// Leaving its window, it takes its steps of undo with it (its text's and its own), as a note's
    /// text does: they'd change a text no one sees, since the window's undo manager outlives the
    /// editor, and a board's window forgets a text's undo only as an editable one loses the keyboard.
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil, let undoManager {
            if let textStorage { undoManager.removeAllActions(withTarget: textStorage) }
            undoManager.removeAllActions(withTarget: self)
        }
        super.viewWillMove(toWindow: newWindow)
    }
}
