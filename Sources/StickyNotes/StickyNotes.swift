import AppKit
import Canvas
import Keyboard
import Mentions
import Ports
import Selection
import Titles
import Validation

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
    /// No text (a mention is text) and no title.
    var isEmpty: Bool {
        props.text.isBlank && (self[TitleProperty.self] ?? "").allSatisfy(\.isWhitespace)
    }

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
            note.createOnDoubleClick(place)                    // opts into the selection's double-click
            note.validate { shape, _ in                        // opts into the validation horizontal
                shape.isEmpty ? [.warning("This note is empty.")] : []
            }
            note.title()                                       // and titles: a title, its pill, and its row's name
            note.noteHeader()                                  // renamed in the detail panel's header
            note.noteRow()                                     // and the table of contents
            note.noteLinks()                                   // and ports: arrows from a note to a note
            note.mentionText { $0.mentionTexts }               // and mentions: its text shows pills,
            note.mentionable(untitled: { $0.props.text.firstLine })   // and it's called by its title, else its first line
        }
        registrar.channel(NoteLink.self)                       // which this plugin declares
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
}

/// A text view laid over the note being edited. Its frame is in view points and its bounds in
/// world units, the note's frame at its origin, so AppKit scales it by the zoom and the text lays
/// out exactly as the canvas draws it. Its text shows mentions as pills (`MentionTextView`), and
/// begun from a press on a pill, that pill is selected.
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
        textView.delegate = self
        clipsToBounds = true
        addSubview(textView)
        // Begun from a press on a pill, the pill is selected: the view's bounds, and so the text
        // view's, are world units with the note's frame at their origin. Anywhere else, the text
        // view puts the caret where it always has.
        if let start = context.startPoint {
            textView.selectPill(at: CGPoint(x: start.x - frame.minX, y: start.y - frame.minY))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Commits the text only when it differs from the note's: a second report of one change (after
    /// an undo, the text view's own and then the board's window's) writes nothing.
    func textDidChange(_ notification: Notification) {
        let text = textView.mentionText
        context.update { if $0.text != text { $0.text = text } }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(cancelOperation(_:)) else { return false }
        context.end()
        return true
    }
}
