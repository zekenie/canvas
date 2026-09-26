import AppKit

/// A text view laid over the note being edited.
///
/// The editor's frame is in canvas view points but its bounds are in world units, so AppKit
/// scales the text view by the current zoom. That keeps the text laid out exactly as the canvas
/// draws it when not editing.
final class NoteEditor: NSView {
    let noteID: StickyNote.ID
    let textView: NSTextView

    init(note: StickyNote) {
        noteID = note.id
        textView = NSTextView(frame: CGRect(origin: .zero, size: note.frame.size))
        super.init(frame: .zero)

        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.focusRingType = .none
        textView.textContainerInset = NSSize(width: Style.notePadding, height: Style.notePadding)
        textView.textContainer?.lineFragmentPadding = 0
        textView.typingAttributes = Style.noteTextAttributes
        textView.textStorage?.setAttributedString(NSAttributedString(string: note.text, attributes: Style.noteTextAttributes))
        textView.insertionPointColor = Style.noteTextAttributes[.foregroundColor] as? NSColor ?? .black

        clipsToBounds = true
        addSubview(textView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
}
