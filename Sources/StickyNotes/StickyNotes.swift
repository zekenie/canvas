import AppKit
import Canvas
import Colors
import Connections
import Keyboard
import LanguageRules
import Mentions
import Observation
import Palette
import Selection
import SlashCommands
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
        // It keeps a height it's given (a resize, `canvas draw`'s `size:`) as the least it is: a member that's new,
        // so a note saved before it is never shorter than a new one, as it was.
        PropsMigration("givenHeight"),
    ]
    public static let properties = Properties<StickyNote>(title: "Sticky note") {
        Property("frame", \.frame).required()
        Property("text", \.text).description("What the note says.")
        Property("givenHeight", \.givenHeight).unlisted()
    }
    public var frame: CGRect
    /// What it says, with mentions of other shapes.
    public var text: MentionText
    /// The height it was last given (a resize that moves its top or bottom, `canvas draw`'s `size:`), which it keeps
    /// as the least it is: it grows past it with its words and comes back to it as they go. Nil for a note never
    /// given one, whose least is a new note's height. Its own to keep, so no attribute of a script's: `size:` sets it.
    public var givenHeight: CGFloat?
    public init(frame: CGRect = .zero, text: MentionText = "", givenHeight: CGFloat? = nil) {
        self.frame = frame
        self.text = text
        self.givenHeight = givenHeight
    }
    public init() { self.init(frame: .zero) }
    /// A new note, typed or not: one width, wide enough for a type's rows to read (a field's name and a
    /// short value), since rows never widen a note.
    public static let defaultSize = CGSize(width: 260, height: 200)
    /// The smallest a note is resized to by hand: a few letters a line, and the padding round one line
    /// (`NoteStyle.padding`, `lineHeight`). Not its placement's, so `canvas draw` still draws one smaller (a badge).
    public static let minimumSize = CGSize(width: 80, height: 52)
    /// The least it's as tall as, whatever its words: the height it was given, else a new note's.
    var leastHeight: CGFloat { givenHeight ?? Self.defaultSize.height }
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

public struct StickyNotesPlugin: ListedPlugin {
    public init() {}
    public var id: PluginID { .stickyNotes }
    public func register(into registrar: inout PluginRegistrar) {
        // What a note's editor answers (`NoteEditor`), for the Keyboard Shortcuts window.
        registrar.keyHint("⌘↩ or ⎋", "Finish Editing", while: .text)
        registrar.keyHint("⇧↩ in a Note", "New Note Beside It", while: .text)
        registrar.keyHint("⇥ or ⇧⇥ in a Note", "Next or Previous Note", while: .text)
        registrar.service { NoteHops(editor: $0) }
        // ⇧↩ on the canvas is Insert › Note: a new note beside the selection (any shape's side, the right first), or with
        // none somewhere clear in the middle of the view, edited, as ⇧↩ in a note's words puts one beside that note.
        registrar.shortcut(KeyChord(KeyChord.return.key, .shift), forCommand: .insert(ToolID(placing: StickyNote.kind)))
        registrar.shape(StickyNoteDefinition()) { note in
            let place = note.editingPlacement(size: NoteStyle.size) { StickyNote() }
            note.tool(label: "Note", systemImage: "note.text", shortcut: "n", placing: place)
            note.madeBeside { made, neighbor in                // a note put beside a shape takes its color, as tldraw's adjacent notes do
                var made = made
                if let color = neighbor[ColorProperty.self] { made[ColorProperty.self] = color }
                return made
            }
            note.colorable(default: .yellow)                   // a note has a color: its paper, yellow without one
            note.checkedByRules()                              // a note of a type is checked against the type's rules
            note.tint(NoteStyle.tint)                          // its yellow, wherever it's listed by its kind
            note.createOnDoubleClick(place)                    // opts into the selection's double-click
            note.resizable(minimumSize: StickyNote.minimumSize) // and its handles, on the paper as it's laid out
            note.title(coverSurface: NoteStyle.color)          // and titles: a title, its pill, its cover, and its row's name
            note.titlePillLook { shape, _ in                   // a type's note is white paper, so its cover's ink is chosen for that
                shape[TypeSchemaProperty.self] != nil ? TitlePillLook(coverSurface: NoteStyle.typePaper) : nil
            }
            note.titleCoverSurface { shape, context in        // and any other note's is its own paper, its color's
                context.service(ColorBook.self)?.color(\.paper, of: shape)
            }
            note.noteHeader()                                  // renamed in the detail panel's header
            note.noteRow()                                     // and the table of contents
            note.noteLinks()                                   // and ports: arrows from a note to a note
            note.mentionText { $0.mentionTexts(in: $1) }          // and mentions: its text shows pills,
            note.mentionable(untitled: { $0.props.text.firstLine ?? FieldValues.name(of: $0) })   // called by its title, else its first line, else its values
            note.typeWords(\.text, drawnIn: { $0.mentionTexts(in: $1).first }, fitting: { StickyNoteDefinition().derive(&$0) })   // and types: its text says what one holds,
            note.canBeType()                                   // and `/is-a type` makes it one
            note.canBeRelationshipType()                       // and a type may be marked as one that relates,
            note.definitionWalk { editor, id in                 // its pill's card, off its last stop, going on to the next note
                editor.service(NoteHops.self)?.editNote(.next, from: id) ?? false
            }
            note.typeable()                                    // and `/is-a` makes it an instance of one
            note.typeRows(drawnIn: { NoteLayout($0, in: $1).block })   // and a type's rows go under its words
            note.noteAccessibility()                           // VoiceOver reads its words as its value
        }
        registrar.channel(NoteLink.self)                       // which this plugin declares
        // `/bulk-create A, B, C` in the command bar with nothing selected: a note titled with each, waiting on the
        // pointer to be put down together, in a column, or in a row while ⌥ is held (a click, or Selection's ⌥↩).
        registrar.selectionSlashCommand(BulkCreate.command)
        registrar.keyHint("⌥ Click or ⌥↩", BulkCreateStyle.inRow, while: .pointer)
    }
}

struct StickyNoteDefinition {}

extension StickyNoteDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<StickyNote>, in context: RenderContext) {
        let layout = NoteLayout(shape, in: context.shapes)
        // A relationship type is a pill: a capsule in its color with its name, and nothing of a note.
        if let pill = layout.pill {
            renderPill(pill, of: shape, in: layout.frame, context)
            return
        }
        // A type's note is white paper, its highlights behind its words, under its editor too, whose text
        // lays out as this does (a note that isn't a type costs one lookup). Any other note is its color's paper.
        let isType = shape[TypeSchemaProperty.self] != nil
        let paper = isType ? NoteStyle.typePaper : context.colors(of: shape).flatMap { NSColor(cgColor: $0.paper) } ?? NoteStyle.color
        context.fillWithShadow(NoteStyle.path(layout.frame), paper)
        let placements = shape.mentionTexts(placedIn: layout.words)
        if isType, let words = placements.first { context.fillTypeHighlights(of: shape, in: words) }
        // Its rows, if it has any (a plain note has no block), under the editor too.
        if let block = layout.block { context.drawTypeRows(of: shape, in: block) }
        // While editing, the editing view draws the text instead.
        guard !context.isEditing else { return }
        for placement in placements { context.drawMentionText(placement) }
    }

    func indicatorPath(of shape: ShapeRecord<StickyNote>, in context: ShapeContext) -> CGPath {
        let frame = context.frame(of: shape)
        return NoteLayout.pill(shape, in: context) == nil ? NoteStyle.path(frame) : NoteStyle.capsule(frame)
    }
}

/// A note is laid out by its words and what goes under them (`NoteLayout`): as big as it stores
/// while it has no rows, and, with them, as wide as it stores and tall enough for the words and the
/// rows. That height is never stored; the stored box is the note as it is with no rows.
extension StickyNoteDefinition: LaidOutBox {
    func laidOutSize(of shape: ShapeRecord<StickyNote>, in context: ShapeContext) -> CGSize {
        let rows = context.layoutInput(TypeRows.extent, of: shape)
        if rows == nil, let pill = NoteLayout.pill(shape, in: context) { return pill.size }
        return NoteLayout.size(of: shape.props, rows: rows)
    }

    /// A relationship type's pill is about the middle of the box it stores; a note is from its top-left.
    func laidOutAnchor(of shape: ShapeRecord<StickyNote>, in context: ShapeContext) -> CGPoint {
        context.layoutInput(TypeRows.extent, of: shape) == nil && NoteLayout.pill(shape, in: context) != nil ? CGPoint(x: 0.5, y: 0.5) : .zero
    }
}

/// A note is as tall as its text, and no shorter than the height it was given, else a new one's: typing
/// fits it (`NoteEditor`), and so does a note made or given text from properties (the command line's
/// `draw`), each mention measured as a live pill by the name it holds (`measuredString`), as the pure
/// function of its props this is: as tall as typing it would make it while its shapes are called that.
extension StickyNoteDefinition: DerivedProps {
    func derive(_ note: inout StickyNote) {
        let string = NoteStyle.text.measuredString(note.text, width: note.frame.width - NoteStyle.padding * 2)
        note.frame.size.height = NoteStyle.fittedHeight(of: string, width: note.frame.width, least: note.leastHeight, keeping: note.frame.height)
    }
}

/// A note given a frame (a resize, `canvas draw`'s `size:`) takes its place and its width, keeps a height
/// it's given as the least it is (`givenHeight`), and is as tall as its words need past it (`derive`): a
/// resize stops at its words, and typing never takes it under the height it was given. A relationship type's
/// pill is as big as its name, so it isn't resized, and the box it stores is what it's given, as any box's.
extension StickyNoteDefinition: CustomSizing {
    func size(_ shape: inout ShapeRecord<StickyNote>, to frame: CGRect, giving axes: SizeAxes, in context: ShapeContext) {
        guard isResizable(shape, in: context) else { return shape.props.frame = frame }
        shape.props.frame.origin = frame.origin
        if axes.contains(.width) { shape.props.frame.size.width = frame.width }
        if axes.contains(.height) {
            shape.props.givenHeight = frame.height
            shape.props.frame.size.height = frame.height     // what it keeps where its width leaves its words no room
        }
        derive(&shape.props)
    }

    func isResizable(_ shape: ShapeRecord<StickyNote>, in context: ShapeContext) -> Bool {
        NoteLayout.pill(shape, in: context) == nil
    }
}

extension StickyNoteDefinition: Editable {
    /// The paper as it is laid out; a relationship type's, the capsule.
    func editingFrame(of shape: ShapeRecord<StickyNote>, in context: ShapeContext) -> CGRect? {
        context.frame(of: shape)
    }

    func makeEditingView(for shape: ShapeRecord<StickyNote>, context: EditContext<StickyNote>) -> EditingView {
        // A relationship type is edited in its pill: its name, one line over the capsule.
        if let editor = pillEditor(for: shape, context: context) { return EditingView(view: editor, firstResponder: editor.field) }
        let editor = NoteEditor(text: shape.props.text, stored: shape.frame, least: shape.props.leastHeight,
                                frame: context.frame ?? shape.frame, context: context)
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
    static let typePaper = NSColor(name: nil) { $0.isDark ? typePaperDark : .white }
    static let typePaperDark = NSColor(white: 0.92, alpha: 1)

    /// The paper and its skeleton's edge (`typeSkeletonEdge`, nil where it's clear) as the appearance
    /// being drawn resolves them, for a skeleton, which draws thousands a frame: a dynamic color costs
    /// half a microsecond to resolve, so they're resolved once for the appearance last drawn in (a
    /// frame in the other appearance resolves them again, and so does one whose appearance is
    /// another object).
    static var typeSkeleton: (paper: CGColor, edge: CGColor?) {
        let appearance = NSAppearance.currentDrawing()
        if appearance !== resolvedAppearance {
            let edge = typeSkeletonEdge.cgColor
            resolvedSkeleton = (typePaper.cgColor, edge.alpha > 0 ? edge : nil)
            resolvedAppearance = appearance
        }
        return resolvedSkeleton
    }
    private static var resolvedAppearance: NSAppearance?
    private static var resolvedSkeleton: (paper: CGColor, edge: CGColor?) = (CGColor(gray: 1, alpha: 1), nil)
    /// Every line of a note's text is this tall, in the render and the editor alike. It's string
    /// drawing's own pitch for the font, so the render is as it was; TextKit 2, which lays out the
    /// editor, would set lines a point closer, so the text moved when editing started.
    static let lineHeight: CGFloat = 19
    /// Shared by the renderer and the editor so text, and its pills, don't shift when editing starts.
    static let text = MentionTextStyle(font: .systemFont(ofSize: 16), color: NSColor(white: 0.12, alpha: 1), lineHeight: lineHeight)
    /// The text's attributes: its font, its color and its fixed lines.
    static var textAttributes: [NSAttributedString.Key: Any] { text.attributes }
    /// How tall one line of words is, as `linesHeight` measures it: the room an edited note's words keep over its rows
    /// while they are empty, so the first letter typed moves nothing.
    static let oneLineHeight = linesHeight(of: NSAttributedString(string: " ", attributes: textAttributes), inner: .greatestFiniteMagnitude)
    /// Where the editor's text starts in the note. At the same line height, TextKit 2 sets a line's
    /// glyphs a point lower in it than string drawing does, so the editor's text starts a point
    /// higher than the render's and its lines fall exactly on the render's.
    static let editorInset = NSSize(width: padding, height: padding - 1)
    static func path(_ frame: CGRect) -> CGPath {
        CGPath(roundedRect: frame, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
    }
    /// A relationship type's pill: its frame with its ends round, which is also how it is outlined.
    static func capsule(_ frame: CGRect) -> CGPath {
        CGPath(roundedRect: frame, cornerWidth: frame.height / 2, cornerHeight: frame.height / 2, transform: nil)
    }
    /// What a pill is filled with when nothing says its type's color (a list without Types' index): a gray.
    static let pillFallback = NSColor(white: 0.45, alpha: 1)

    /// How tall a note `width` wide is to show all of `text` (as it's drawn: `NoteStyle.text`, with
    /// its pills): its lines (the empty one after a last Return too, where the caret is; none for no
    /// text, as `NoteWords` measures it), and the padding above and below, with half a point spare so
    /// string drawing never cuts the last line;
    /// never shorter than `least`, the note's least height (`StickyNote.leastHeight`: the height it was
    /// given, else a new note's; tldraw's note grows the same way). `height`, a note's own, is kept when
    /// the width leaves no room for text to measure.
    static func fittedHeight(of text: NSAttributedString, width: CGFloat, least: CGFloat, keeping height: CGFloat) -> CGFloat {
        let inner = width - padding * 2
        guard inner > 0 else { return height }
        // An empty string has no attributes, so it would measure as a line of AppKit's default font.
        guard text.length > 0 else { return max(least, padding * 2) }
        return max(least, linesHeight(of: text, inner: inner) + padding * 2)
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
    /// it has rows), `least` its least height (`StickyNote.leastHeight`): the text view is as big as the
    /// paper, so its text wraps where the render's does, while the note is fitted to its words as it
    /// stores it, at the width it stores.
    init(text: MentionText, stored: CGRect, least: CGFloat, frame: CGRect, context: EditContext<StickyNote>) {
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
        textView.onKeyDown = { [weak self] event in self?.hop(on: event) ?? false }
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
                            focusWords: { [weak self] in self?.focusWords() },
                            tabbedOut: { [weak self] in self?.tabbedOut() },
                            addBeside: { [weak self] in self?.addNoteBeside() })
        if let view = context.service(RowBook.self)?.makeRowsView(for: context.shapeID, host: host) {
            rows = view
            addSubview(view)
        }
        // A note too short for its text (saved before notes grew with it, or drawn with a `size:`)
        // grows to it as editing begins, as typing would grow it, so what was cut off can be read and
        // edited; the write joins the editing session's step. Never shorter than it is: a note drawn
        // taller keeps its height until it's typed into.
        let fitted = NoteStyle.fittedHeight(of: textView.attributedString(), width: stored.width, least: least, keeping: stored.height)
        if fitted > stored.height {
            context.update { $0.frame.size.height = max($0.frame.size.height, fitted) }
            textView.setFrameSize(CGSize(width: frame.width, height: max(fitted, frame.height)))
        }
        // Begun from a press, the selection goes where it was, as a click in the text puts it: on a
        // pill, the pill; elsewhere the caret, or for a double-click the word. The view's bounds,
        // and so the text view's, are world units with the note's frame at their origin. Begun
        // without one (Return, placing a note), the text view puts the caret where it always has.
        // A press on a row's value begins in that row (Types' rows view says: a typed value's field, a row with
        // more in it focused); anywhere else the words take it. ⇧Tab from the next note begins at the last row.
        if let start = context.startPoint {
            var inEditor = CGPoint(x: start.x - frame.minX, y: start.y - frame.minY)
            if let rows, !rows.isHidden { inEditor.y += movedByEditing(text, width: frame.width, below: inEditor.y, rows: rows) }
            if let rows, !rows.isHidden, rows.frame.contains(inEditor),
               let responder = rows.begin(at: CGPoint(x: inEditor.x - rows.frame.minX, y: inEditor.y - rows.frame.minY), clickCount: context.startClickCount) {
                first = responder
            } else {
                textView.placeSelection(at: inEditor, selectingWord: context.startClickCount >= 2)
            }
        } else if let rows, context.service(NoteHops.self)?.startsAtLastRow(context.shapeID) == true {
            first = rows.focusLastRow()
        }
        follow()
    }

    /// How far a press at `y` (this view's coordinates) moved as editing began. The press was on the note as drawn at rest;
    /// edited, its words keep a line however empty they are and its rows have their lead under them
    /// (`RowsExtent.wordsLine`), so what was under the words moved down with the rows: how far the rows' top is lower in the
    /// layout edited than in the layout at rest, both from `NoteLayout`.
    private func movedByEditing(_ text: MentionText, width: CGFloat, below y: CGFloat, rows: RowsView) -> CGFloat {
        let p = NoteStyle.padding
        guard let book = context.service(RowBook.self), let rest = book.extent(ofShape: context.shapeID, edited: false),
              let edited = book.extent(ofShape: context.shapeID, edited: true) else { return 0 }
        guard y > p + NoteWords.height(of: text, width: width - p * 2) else { return 0 }
        return NoteLayout.blockTop(of: text, width: width - p * 2, rows: edited) - NoteLayout.blockTop(of: text, width: width - p * 2, rows: rest)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Commits the text only when it differs from the note's: a second report of one change (after
    /// an undo, the text view's own and then the board's window's) writes nothing. The note is fitted
    /// to it in the same write, never under the height it was given, so growing and shrinking back are
    /// part of the typing's step ("Typing", "Add Note").
    func textDidChange(_ notification: Notification) {
        let text = textView.mentionText
        let shown = textView.attributedString()
        known = text
        context.update { note in
            guard note.text != text else { return }
            note.text = text
            note.frame.size.height = NoteStyle.fittedHeight(of: shown, width: note.frame.width, least: note.leastHeight, keeping: note.frame.height)
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

    /// Tab off the last row: the next note, as Tab in the words goes on from a note with no rows; with no other note,
    /// back round to the words.
    private func tabbedOut() {
        guard context.service(NoteHops.self)?.editNote(.next, from: context.shapeID) == true else { return focusWords() }
    }

    /// A new note beside this one, edited; editing ends here (⇧↩ in the words or in a row).
    private func addNoteBeside() {
        let id = context.shapeID
        guard let hops = context.service(NoteHops.self), !hops.refusesThroughStandIn() else { return }
        context.end()
        hops.addNote(beside: id)
    }

    /// ⇧↩ goes on to a new note beside this one, as tldraw's adjacent notes do (↩ alone is a new line).
    /// Tab goes to the first row, if the note has rows, else on to the next note; ⇧Tab to the previous note,
    /// starting at its last row, or round to this note's last row when there's no other. Editing ends here
    /// and begins on that note (`NoteHops`). A list open at the caret (@'s, /'s) holds the keys first (`holdsKeys`).
    private func hop(on event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
        guard modifiers.isSubset(of: .shift), let hops = context.service(NoteHops.self) else { return false }
        let id = context.shapeID
        switch event.keyCode {
        case 36, 76:
            guard modifiers == .shift else { return false }
            // Held, ⇧↩ makes one note: its repeats reach the new note's editor and are kept from it.
            if event.isARepeat { return true }
            addNoteBeside()
        case 48 where modifiers.isEmpty:
            if rows?.focusFirstRow() == true { return true }
            hops.editNote(.next, from: id)
        case 48:
            if !hops.editNote(.previous, from: id) { rows?.focusLastRow() }
        default:
            return false
        }
        return true
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
