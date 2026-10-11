import AppKit
import Canvas
import Connections
import Keyboard
import Mentions
import Observation
import Selection
import TextEditing
import Titles
import Types

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
    /// Where the note draws its text: in the box its layout gives its words (its frame, inset by the
    /// padding, while it has no rows). The render draws exactly this, and Mentions finds the note's
    /// pills through it.
    @MainActor func mentionTexts(in context: ShapeContext) -> [MentionTextPlacement] {
        mentionTexts(placedIn: NoteLayout(self, in: context).words)
    }

    @MainActor func mentionTexts(placedIn words: CGRect) -> [MentionTextPlacement] {
        [MentionTextPlacement(props.text, in: words, style: NoteStyle.text)]
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
            note.titlePillLook { shape, _ in                   // a type's note is white paper, so its cover's ink is chosen for that
                shape[TypeSchemaProperty.self] != nil ? TitlePillLook(coverSurface: NoteStyle.typePaper) : nil
            }
            note.noteHeader()                                  // renamed in the detail panel's header
            note.noteRow()                                     // and the table of contents
            note.noteLinks()                                   // and ports: arrows from a note to a note
            note.mentionText { $0.mentionTexts(in: $1) }          // and mentions: its text shows pills,
            note.mentionable(untitled: { $0.props.text.firstLine })   // called by its title, else its first line
            note.typeWords(\.text, drawnIn: { $0.mentionTexts(in: $1).first }, fitting: { StickyNoteDefinition().derive(&$0) })   // and types: its text says what one holds,
            note.canBeType()                                   // and `/is-a type` makes it one
            note.typeable()                                    // and `/is-a` makes it an instance of one
            note.typeRows(drawnIn: { NoteLayout($0, in: $1).block })   // and a type's rows go under its words
        }
        registrar.channel(NoteLink.self)                       // which this plugin declares
    }
}

struct StickyNoteDefinition {}

extension StickyNoteDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<StickyNote>, in context: RenderContext) {
        let layout = NoteLayout(shape, in: context.shapes)
        // A type's note is white paper, its highlights behind its words, under its editor too, whose text
        // lays out as this does (a note that isn't a type costs one lookup).
        let isType = shape[TypeSchemaProperty.self] != nil
        context.fillWithShadow(NoteStyle.path(layout.frame), isType ? NoteStyle.typePaper : NoteStyle.color)
        let placements = shape.mentionTexts(placedIn: layout.words)
        if isType, let words = placements.first { context.fillTypeHighlights(of: shape, in: words) }
        // Its rows, if it has any (a plain note has no block), under the editor too.
        if let block = layout.block { context.drawTypeRows(of: shape, in: block) }
        // While editing, the editing view draws the text instead.
        guard !context.isEditing else { return }
        for placement in placements { context.drawMentionText(placement) }
    }

    func indicatorPath(of shape: ShapeRecord<StickyNote>, in context: ShapeContext) -> CGPath {
        NoteStyle.path(context.frame(of: shape))
    }
}

/// A note is laid out by its words and what goes under them (`NoteLayout`): as big as it stores
/// while it has no rows, and, with them, wide enough to read them and tall enough for the words and
/// the rows. The size is never stored; the stored box is the note as it is with no rows.
extension StickyNoteDefinition: LaidOutBox {
    func laidOutSize(of shape: ShapeRecord<StickyNote>, in context: ShapeContext) -> CGSize {
        NoteLayout.size(of: shape.props, rows: context.layoutInput(TypeRows.extent, of: shape))
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
        let editor = NoteEditor(text: shape.props.text, stored: shape.frame, frame: context.frame ?? shape.frame, context: context)
        return EditingView(view: editor, firstResponder: editor.first ?? editor.textView)
    }
}

@MainActor
enum NoteStyle {
    static let size = StickyNote.defaultSize
    static let cornerRadius: CGFloat = 4
    static let padding: CGFloat = 16
    /// Between a note's words and the rows under them, when it has words.
    static let blockGap: CGFloat = 12
    /// How many heights of words `NoteWords` keeps; past it the lot is let go.
    static let wordsCacheCapacity = 16_384
    static let color = NSColor(srgbRed: 1.0, green: 0.87, blue: 0.45, alpha: 1)
    /// A type's note is paper, not yellow: white, and in the dark appearance a light paper (0.92), not
    /// the canvas's color, as the yellow note stays yellow there. Its text is the note's ink on both.
    static let typePaper = NSColor(name: nil) { $0.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? typePaperDark : .white }
    static let typePaperDark = NSColor(white: 0.92, alpha: 1)

    /// The paper as the appearance being drawn resolves it, for a skeleton, which draws thousands a
    /// frame: a dynamic color costs half a microsecond to resolve, so it's resolved once for the
    /// appearance last drawn in (a frame in the other appearance resolves it again, and so does one
    /// whose appearance is another object).
    static var typePaperCG: CGColor {
        let appearance = NSAppearance.currentDrawing()
        if appearance !== resolvedAppearance {
            resolvedPaper = typePaper.cgColor
            resolvedAppearance = appearance
        }
        return resolvedPaper
    }
    private static var resolvedAppearance: NSAppearance?
    private static var resolvedPaper = CGColor(gray: 1, alpha: 1)
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
        return max(size.height, linesHeight(of: text, inner: inner) + padding * 2)
    }

    /// How tall `text`'s lines are `inner` wide, with half a point spare so string drawing never cuts
    /// the last line: a note's words, and what `fittedHeight` fits it to.
    static func linesHeight(of text: NSAttributedString, inner: CGFloat) -> CGFloat {
        let lines = text.boundingRect(with: CGSize(width: inner, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin]).height
        return (lines + 0.5).rounded(.up)
    }
}

/// A text view laid over the note being edited. Its frame is in view points and its bounds in
/// world units, the note's frame at its origin, so AppKit scales it by the zoom and the text lays
/// out exactly as the canvas draws it. Its text shows mentions as pills (`MentionTextView`), and
/// begun from a press on a pill, that pill is selected. Escape and ⌘↩ end editing.
///
/// A type's words: its highlights show behind them, where the canvas draws them under the view, and
/// resting the pointer on one shows its part of the schema in a popover, as on the canvas
/// (`TypeIndex.popover(at:on:)`), until something's typed. While the model writes them (the answer
/// to an edit of the schema) they're read-only and faint, as the panel's JSON is while it's written,
/// and what lands shows in the view: it follows the type's sync status.
final class NoteEditor: NSView, NSTextViewDelegate {
    let textView: MentionTextView<AnyMentionable>
    private let context: EditContext<StickyNote>
    private weak var sync: TypeSync<TypeSchemaProperty>?
    private weak var types: TypeIndex?
    /// Over the note's rows: a press there is the rows', not the text's (Types'), and a row is a second place for
    /// the caret.
    private var rows: RowsView?
    /// What takes the keyboard when editing begins, if not the words: a row, where the press that began it was on one.
    private(set) var first: NSResponder?
    /// The text as this view last wrote or showed it: a note that says otherwise was written from
    /// outside (the model's answer).
    private var known: MentionText
    /// Text written from outside is being shown: its caret moved, not the person's.
    private var isShowing = false

    /// `stored` is the note's frame as it is kept, `frame` the one it is laid out in (the same, until
    /// it has rows): the text view is as big as the paper, so its text wraps where the render's does,
    /// while the note is fitted to its words as it stores it, at the width it stores.
    init(text: MentionText, stored: CGRect, frame: CGRect, context: EditContext<StickyNote>) {
        self.context = context
        sync = context.service(TypeSync<TypeSchemaProperty>.self)
        types = context.service(TypeIndex.self)
        known = text
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
        // ⌘↩ ends editing while the model writes the text too.
        textView.commitsWhileReadOnly = true
        textView.onCommit = { [weak self] in self?.context.end() }
        textView.onPointer = { [weak self] point in self?.hover(at: point) }
        clipsToBounds = true
        addSubview(textView)
        // The rows, if the note has any, are under the words and over the text view: a press on them is theirs.
        let context = self.context
        let host = RowsHost(origin: { context.frame?.origin }, end: { context.end() },
                            keepInView: { [weak self] rect in
                                guard let self, let rows = self.rows else { return }
                                context.keepInView(self.convert(rect, from: rows))
                            },
                            focusWords: { [weak self] in self?.focusWords() })
        if let view = context.service(RowBook.self)?.makeRowsView(for: context.shapeID, host: host) {
            rows = view
            addSubview(view)
        }
        // A note too short for its text (saved before notes grew with it, or drawn with a `size:`)
        // grows to it as editing begins, as typing would grow it, so what was cut off can be read and
        // edited; the write joins the editing session's step. Never shorter than it is: a note drawn
        // taller keeps its height until it's typed into.
        let fitted = NoteStyle.fittedHeight(of: textView.attributedString(), width: stored.width, keeping: stored.height)
        if fitted > stored.height {
            context.update { $0.frame.size.height = max($0.frame.size.height, fitted) }
            textView.setFrameSize(CGSize(width: frame.width, height: max(fitted, frame.height)))
        }
        // Begun from a press, the selection goes where it was, as a click in the text puts it: on a
        // pill, the pill; elsewhere the caret, or for a double-click the word. The view's bounds,
        // and so the text view's, are world units with the note's frame at their origin. Begun
        // without one (Return, placing a note), the text view puts the caret where it always has.
        // A press on a row's value begins in that row (Types' rows view says: a typed value's field, a row with
        // more in it focused); anywhere else the words take it.
        if let start = context.startPoint {
            let inEditor = CGPoint(x: start.x - frame.minX, y: start.y - frame.minY)
            if let rows, !rows.isHidden, rows.frame.contains(inEditor),
               let responder = rows.begin(at: CGPoint(x: inEditor.x - rows.frame.minX, y: inEditor.y - rows.frame.minY), clickCount: context.startClickCount) {
                first = responder
            } else {
                textView.placeSelection(at: inEditor, selectingWord: context.startClickCount >= 2)
            }
        }
        follow()
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
        known = text
        context.update { note in
            guard note.text != text else { return }
            note.text = text
            note.frame.size.height = NoteStyle.fittedHeight(of: shown, width: note.frame.width, keeping: note.frame.height)
        }
        rows?.reposition()
        context.hoverPopover(nil)
        keepCaretInView()
    }

    /// The caret moved (an arrow key, Return, a click): it's kept in view too. Not for text shown
    /// from outside, which moves no one's caret.
    func textViewDidChangeSelection(_ notification: Notification) {
        guard !isShowing else { return }
        keepCaretInView()
    }

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
        rows?.reposition()
    }

    /// The caret back in the words, at their end.
    private func focusWords() {
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: textView.textStorage?.length ?? 0, length: 0))
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.moveDown(_:)), let rows, self.textView.selectedRange().length == 0 {
            // ↓ from the last line goes to the first row: the caret first moves as it always has, and if it stayed
            // on its line there was no line below.
            let selection = self.textView.selectedRange(), line = self.textView.caretFrame?.minY
            self.textView.moveDown(nil)
            if self.textView.caretFrame?.minY == line {
                self.textView.setSelectedRange(selection)
                if !rows.focusFirstRow() { self.textView.moveDown(nil) }
            }
            return true
        }
        guard commandSelector == #selector(cancelOperation(_:)) else { return false }
        context.end()
        return true
    }

    /// Read-only and faint while the model writes a type's words; and the text the note has, shown
    /// in place of the view's, when something other than this view wrote it (the model's answer
    /// landing). Looked at again as the note's sync status changes: only the sync writes the text
    /// while it's typed into (undo, a draw and a file put in place end editing first), and its
    /// answer is written before the status moves on, so it's there to read (unobserved: every
    /// commit would wake an observation of the document).
    private func follow() {
        let id = context.shapeID
        let isUpdating = withObservationTracking {
            sync?.status(of: id) == .updating(.words)
        } onChange: { [weak self] in
            // Heard as it's about to change: looked at once it has.
            Task { @MainActor [weak self] in self?.follow() }
        }
        if textView.isEditable == isUpdating {
            textView.isEditable = !isUpdating
            textView.showEnabled(!isUpdating)
        }
        if let text = context.shape?.props.text, text != known { show(text) }
    }

    /// The pointer over the text (a point in the text view's coordinates, which are this view's: the
    /// note's, its frame at their origin), or gone from it: on a highlight's words where the canvas
    /// draws them (the text lays out as the canvas draws it), their popover, beside the line it's on.
    private func hover(at point: CGPoint?) {
        guard let point, let origin = context.shape?.frame.origin else { return context.hoverPopover(nil) }
        context.hoverPopover(types?.popover(at: point, on: context.shapeID, origin: origin))
    }

    /// Shows text written from outside: the text's storage alone (`MentionTextView.show`, the caret
    /// where it was as far as the text reaches), the camera where it is, and typing's undo dropped,
    /// since it's of text that isn't there.
    private func show(_ text: MentionText) {
        isShowing = true
        defer { isShowing = false }
        known = text
        textView.show(text)
        if let undoManager = textView.undoManager {
            if let storage = textView.textStorage { undoManager.removeAllActions(withTarget: storage) }
            undoManager.removeAllActions(withTarget: textView)
        }
    }
}
