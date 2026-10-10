import AppKit
import Canvas
import Connections
import HostSlots
import Keyboard
import Mentions
import Selection
import TextEditing
import Titles

public struct StickyNote: BoxShapeProps {
    public static let kind: ShapeKind = "sticky-note"
    /// Append only. The count is the version boards record.
    public static let migrations = [
        // The note no longer keeps a checklist. (This step handed it over to Checklists' added
        // property, since removed.)
        PropsMigration("checklist becomes the checklist property") { $0["checklist"] = nil },
        // Titles adds the title to every kind that opts in, once someone names the shape; the
        // note no longer keeps one.
        PropsMigration.handOver("title", to: TitleProperty.self),
        // Its text may mention shapes: text that would now read as a mention (or an escaped one)
        // is escaped, so it stays the text it was.
        PropsMigration("text may mention shapes") { props in MentionTextFormat.escapeLookalikesV1(in: &props, "text") },
    ]
    public static let properties = Properties<StickyNote>(title: "Sticky note") {
        Property("frame", \.frame).required()
        Property("text", \.text).description("What the note says.")
    }
    public var frame: CGRect
    /// What it says, with mentions of other shapes.
    public var text: MentionText
    public init(frame: CGRect = .zero, text: MentionText = "") {
        self.frame = frame
        self.text = text
    }
    public init() { self.init(frame: .zero) }
    public static let defaultSize = CGSize(width: 200, height: 200)
}

extension ShapeRecord where Props == StickyNote {
    /// Where the note draws its text: in its frame, inset by the padding. The render draws exactly
    /// this, and Mentions finds the note's pills through it.
    @MainActor var mentionTexts: [MentionTextPlacement] {
        [MentionTextPlacement(props.text, in: props.frame.insetBy(dx: NoteStyle.padding, dy: NoteStyle.padding), style: NoteStyle.text)]
    }
}

extension PluginID {
    public static let stickyNotes: PluginID = "sticky-notes"
}

public struct StickyNotesPlugin: CanvasPlugin {
    public init() {}
    public var id: PluginID { .stickyNotes }
    public func register(into registrar: inout PluginRegistrar) {
        registrar.shape(StickyNoteDefinition()) { note in
            let place = note.editingPlacement(size: NoteStyle.size) { StickyNote() }
            note.tool(label: "Note", systemImage: "note.text", shortcut: "n", placing: place)
            note.tint(NoteStyle.tint)                          // its yellow, wherever it's listed by its kind
            note.createOnDoubleClick(place)                    // opts into the selection's double-click
            note.title(coverSurface: NoteStyle.color)          // and titles: a title, its pill, its cover, and its row's name
            note.noteHeader()                                  // renamed in the detail panel's header
            note.noteRow()                                     // and the table of contents
            note.noteLinks()                                   // and ports: arrows from a note to a note
            note.mentionText { $0.mentionTexts }               // and mentions: its text shows pills,
            note.mentionable(untitled: { $0.props.text.firstLine })   // called by its title, else its first line
        }
        registrar.channel(NoteLink.self)                       // which this plugin declares
        // Six notes on how to use them, for the app's first board: linked where the list draws arrows.
        registrar.welcomeBoard { registry in WelcomeBoard.document(linked: registry.kinds.contains(Arrow.kind)) }
    }
}

struct StickyNoteDefinition {}

extension StickyNoteDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<StickyNote>, in context: RenderContext) {
        context.fillWithShadow(NoteStyle.path(shape.frame), NoteStyle.color)
        // While editing, the editing view draws the text instead.
        guard !context.isEditing else { return }
        for placement in shape.mentionTexts { context.drawMentionText(placement) }
    }

    func indicatorPath(of shape: ShapeRecord<StickyNote>, in context: ShapeContext) -> CGPath {
        NoteStyle.path(shape.frame)
    }
}

/// A note is as tall as its text, and no shorter than a new one: typing fits it (`NoteEditor`), and
/// so does a note made or given text from properties (the command line's `draw`), each mention
/// measured as a live pill by the name it holds (`measuredString`), as the pure function of its
/// props this is: as tall as typing it would make it while its shapes are called that.
extension StickyNoteDefinition: DerivedProps {
    func derive(_ note: inout StickyNote) {
        let string = NoteStyle.text.measuredString(note.text, width: note.frame.width - NoteStyle.padding * 2)
        note.frame.size.height = NoteStyle.fittedHeight(of: string, width: note.frame.width, keeping: note.frame.height)
    }
}

extension StickyNoteDefinition: Editable {
    func makeEditingView(for shape: ShapeRecord<StickyNote>, context: EditContext<StickyNote>) -> EditingView {
        let editor = NoteEditor(text: shape.props.text, frame: shape.frame, context: context)
        return EditingView(view: editor, firstResponder: editor.textView)
    }
}

@MainActor
enum NoteStyle {
    static let size = StickyNote.defaultSize
    static let cornerRadius: CGFloat = 4
    static let padding: CGFloat = 16
    static let color = NSColor(srgbRed: 1.0, green: 0.87, blue: 0.45, alpha: 1)
    /// Every line of a note's text is this tall, in the render and the editor alike. It's string
    /// drawing's own pitch for the font, so the render is as it was; TextKit 2, which lays out the
    /// editor, would set lines a point closer, so the text moved when editing started.
    static let lineHeight: CGFloat = 19
    /// Shared by the renderer and the editor so text, and its pills, don't shift when editing starts.
    static let text = MentionTextStyle(font: .systemFont(ofSize: 16), color: NSColor(white: 0.12, alpha: 1), lineHeight: lineHeight)
    /// The text's attributes: its font, its color and its fixed lines.
    static var textAttributes: [NSAttributedString.Key: Any] { text.attributes }
    /// Where the editor's text starts in the note. At the same line height, TextKit 2 sets a line's
    /// glyphs a point lower in it than string drawing does, so the editor's text starts a point
    /// higher than the render's and its lines fall exactly on the render's.
    static let editorInset = NSSize(width: padding, height: padding - 1)
    static func path(_ frame: CGRect) -> CGPath {
        CGPath(roundedRect: frame, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }

    /// How tall a note `width` wide is to show all of `text` (as it's drawn: `NoteStyle.text`, with
    /// its pills): its lines (the empty one after a last Return too, where the caret is), and the
    /// padding above and below, with half a point spare so string drawing never cuts the last line;
    /// never shorter than a new note (tldraw's note grows the same way). `height`, a note's own, is
    /// kept when the width leaves no room for text to measure.
    static func fittedHeight(of text: NSAttributedString, width: CGFloat, keeping height: CGFloat) -> CGFloat {
        let inner = width - padding * 2
        guard inner > 0 else { return height }
        let lines = text.boundingRect(with: CGSize(width: inner, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height
        return max(size.height, (lines + 0.5).rounded(.up) + padding * 2)
    }
}

/// A text view laid over the note being edited. Its frame is in view points and its bounds in
/// world units, the note's frame at its origin, so AppKit scales it by the zoom and the text lays
/// out exactly as the canvas draws it. Its text shows mentions as pills (`MentionTextView`), and
/// begun from a press on a pill, that pill is selected. Escape and ⌘↩ end editing.
final class NoteEditor: NSView, NSTextViewDelegate {
    let textView: MentionTextView<AnyMentionable>
    private let context: EditContext<StickyNote>

    init(text: MentionText, frame: CGRect, context: EditContext<StickyNote>) {
        self.context = context
        textView = MentionTextView(frame: CGRect(origin: .zero, size: frame.size), text: text, style: NoteStyle.text,
                                   owner: context.shapeID, mentions: context.service(MentionState.self))
        super.init(frame: .zero)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.focusRingType = .none
        // The padding before the inset: setting the inset fits the pills to the line.
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainerInset = NoteStyle.editorInset
        textView.typingAttributes = NoteStyle.textAttributes
        textView.insertionPointColor = NoteStyle.text.color
        textView.spelling = .app
        textView.delegate = self
        // ⌘↩ says the text is done, as in the panel's boxes: editing ends. The keyboard leaving
        // isn't that here: the canvas ends editing itself.
        textView.commitsOnLeaving = false
        textView.onCommit = { [weak self] in self?.context.end() }
        clipsToBounds = true
        addSubview(textView)
        // A note too short for its text (saved before notes grew with it, or drawn with a `size:`)
        // grows to it as editing begins, as typing would grow it, so what was cut off can be read and
        // edited; the write joins the editing session's step. Never shorter than it is: a note drawn
        // taller keeps its height until it's typed into.
        let fitted = NoteStyle.fittedHeight(of: textView.attributedString(), width: frame.width, keeping: frame.height)
        if fitted > frame.height {
            context.update { $0.frame.size.height = max($0.frame.size.height, fitted) }
            textView.setFrameSize(CGSize(width: frame.width, height: fitted))
        }
        // Begun from a press, the selection goes where it was, as a click in the text puts it: on a
        // pill, the pill; elsewhere the caret, or for a double-click the word. The view's bounds,
        // and so the text view's, are world units with the note's frame at their origin. Begun
        // without one (Return, placing a note), the text view puts the caret where it always has.
        if let start = context.startPoint {
            textView.placeSelection(at: CGPoint(x: start.x - frame.minX, y: start.y - frame.minY), selectingWord: context.startClickCount >= 2)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Commits the text only when it differs from the note's: a second report of one change (after
    /// an undo, the text view's own and then the board's window's) writes nothing. The note is fitted
    /// to it in the same write, so growing is part of the typing's step ("Typing", "Add Note").
    func textDidChange(_ notification: Notification) {
        let text = textView.mentionText
        let shown = textView.attributedString()
        context.update { note in
            guard note.text != text else { return }
            note.text = text
            note.frame.size.height = NoteStyle.fittedHeight(of: shown, width: note.frame.width, keeping: note.frame.height)
        }
        keepCaretInView()
    }

    /// The caret moved (an arrow key, Return, a click): it's kept in view too.
    func textViewDidChangeSelection(_ notification: Notification) { keepCaretInView() }

    /// A note grows downward with its text, past the window's bottom if it's near it, and the canvas
    /// scrolls no text of its own: the camera follows the caret instead, so what's typed is never
    /// typed blind (`EditContext.keepInView`).
    private func keepCaretInView() {
        guard window != nil, let caret = textView.caretFrame else { return }
        // In this view's coordinates: world units, the note's frame at their origin.
        context.keepInView(convert(caret, from: textView))
    }

    /// The canvas lays the editor over the note, its bounds the note's size: as the note grows with
    /// its text, the text view grows with it, so the text past the note's first height shows.
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
