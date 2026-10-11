import AppKit
import Canvas
import TextEditing

// The rows of the note being edited. The note's editing view covers the whole paper, so a press over the rows
// would land in its text and put the caret at the end of the words. A kind that hosts an editing view over its
// rows lays this one over them: a press in the rows is the rows', whatever the text view under it would do.
// On a type's note it does what a click on the canvas does for the part under the point (Retry, a card, an
// options list) and nothing elsewhere. On a note that is one it is the rows editor: the note's one editing
// session has two places for the caret, the words and a row. A typed value is edited by a one-line field
// (`RowField`) laid over it, each keystroke a commit through the one writer; a box, a choice and a row with more
// in it are focused with this view as the first responder, outlined, and take the keys of the table below.
// Every other key stops here: up the responder chain is the canvas's shortcuts, where Backspace deletes the
// selection, which is the note being edited.
//
// | Key         | Typed row                 | Box, choice, row with more, fold            |
// | Tab, ⇧Tab   | next row, previous row    | the same                                    |
// | ↓, ↑        | next row, previous row    | the same                                    |
// | Return      | editing ends              | a row with more: its card; else editing ends |
// | Space       | a space                   | a box toggles, a choice pops, more: its card |
// | Escape, ⌘↩  | editing ends              | editing ends                                |
//
// Off the last row, Tab ends editing; ↑ and ⇧Tab from the first go back to the words; ↓ on the last does nothing.

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

/// The view over a shape's rows while it is edited.
@MainActor
public final class RowsView: NSView {
    private weak var book: RowBook?
    private let shape: ShapeID
    private let host: RowsHost

    /// The row with the caret or the focus, by what finds it again when the rows change.
    private enum Focus: Equatable {
        case field(String)
        case fold(isMore: Bool)
    }

    private var focus: Focus?
    /// The one-line editor of the focused row, in a view that clips it to the value's column.
    private var field: RowField?
    private var clip: NSView?
    private var fieldKinds: [PlainKind] = []
    /// The path the field told the check it is typing in.
    private var typingPath: FieldPath?
    /// What the field last wrote, or took: a commit to the shape that stores another value was written from
    /// outside, and the field shows it.
    private var written: JSONValue?
    /// How far the field's text is slid left to keep its caret in the clip.
    private var slide: CGFloat = 0
    /// Moving the focus between this view's own parts: the keyboard leaving one is not the person leaving.
    private var switching = false
    /// A card is open for the focused row: the keyboard is the card's, and the row stays focused.
    private var cardIsOpen = false

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
    public override var acceptsFirstResponder: Bool { true }

    /// Puts itself over the shape's rows (`rowsRect` less the host's origin); hidden with none. The rows may
    /// have changed: the focused row is looked for again, its field laid out again, and what something else
    /// wrote shown.
    public func reposition() {
        guard let book, let rect = book.rowsRect(of: shape), let origin = host.origin() else {
            isHidden = true
            return
        }
        let frame = rect.offsetBy(dx: -origin.x, dy: -origin.y)
        if self.frame != frame { self.frame = frame }
        isHidden = false
        refresh()
    }

    // MARK: Where the focus is

    private func rows() -> EditedRows? { book?.editedRows(of: shape) }

    private func index(of focus: Focus, in edited: EditedRows) -> Int? {
        switch focus {
        case .field(let key): edited.index(ofField: key)
        case .fold(let isMore): edited.index(ofFold: isMore)
        }
    }

    private func focus(of row: Int, in edited: EditedRows) -> Focus? {
        if let key = edited.shown.rows[row].path?.field { return .field(key) }
        return edited.fold(row).map { Focus.fold(isMore: $0.isMore) }
    }

    /// The focused row's place among the rows as they are now.
    private func focusedIndex(in edited: EditedRows) -> Int? { focus.flatMap { index(of: $0, in: edited) } }

    /// The name of the row with the caret or the focus; nil with none (tests read it).
    public var focusedRow: String? {
        guard let focus, let edited = rows(), let row = index(of: focus, in: edited) else { return nil }
        return edited.shown.rows[row].name
    }

    // MARK: Taking the focus

    /// The responder that takes the keyboard for a press at `point` (this view's coordinates) that started
    /// the session: a typed value's field, with the caret there; this view, with the row focused, for a row
    /// with more (whose card is then asked for a turn later, when the session is in its window); nil where the
    /// point starts nothing here (a name, the paper, a box, a choice), so the words take it.
    public func begin(at point: CGPoint, clickCount: Int) -> NSResponder? {
        guard let book, let edited = rows(), let hit = book.target(at: point, in: edited), hit.onValue else { return nil }
        switch edited.classes[hit.row] {
        case .typed:
            return focusRow(hit.row, at: point, clickCount: clickCount)
        case .more, .json, .fold:
            let responder = focusRow(hit.row)
            let session = book.editor?.editingShapeID
            _ = book.editor?.scheduler.schedule(after: .zero) { [weak self] in
                guard let self, let book = self.book, book.rowsView === self, book.editor?.editingShapeID == session, session == self.shape,
                      let edited = self.rows(), let current = self.focusedIndex(in: edited), current == hit.row else { return }
                self.openCard(current)
            }
            return responder
        default:
            return nil
        }
    }

    /// ↓ from the words' last line: the first row takes the caret. False with no row to take it (a type's
    /// note, a note with no rows).
    public func focusFirstRow() -> Bool {
        guard let edited = rows(), edited.count > 0 else { return false }
        return focusRow(0) != nil
    }

    /// Gives a row the caret (a typed one: its field, the caret at `point` if given) or the focus (this view).
    @discardableResult
    private func focusRow(_ row: Int, at point: CGPoint? = nil, clickCount: Int = 1) -> NSResponder? {
        guard let edited = rows(), edited.shown.rows.indices.contains(row), let target = focus(of: row, in: edited) else { return nil }
        switching = true
        defer { switching = false }
        host.keepInView(edited.shown.rows[row].rect)
        let responder: NSResponder
        if case .typed(let kinds) = edited.classes[row], case .field(let key) = target {
            if field == nil || focus != target { stopField() }
            focus = target
            let field = field ?? makeField(row: row, key: key, kinds: kinds, in: edited)
            layoutField()
            if let point {
                field.placeSelection(at: field.convert(point, from: self), selectingWord: clickCount >= 2)
                scrollCaret()
            }
            responder = field
        } else {
            stopField()
            focus = target
            responder = self
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
        window?.makeFirstResponder(responder)
        return responder
    }

    private func makeField(row: Int, key: String, kinds: [PlainKind], in edited: EditedRows) -> RowField {
        let path = FieldPath(field: key)
        let field = RowField()
        let stored = edited.record[FieldValuesProperty.self]?.value(at: path)
        written = stored
        fieldKinds = kinds
        field.show(Self.text(of: stored, kinds: kinds))
        field.onKey = { [weak self] key in self?.handle(key) }
        field.onChange = { [weak self] in self?.fieldChanged() }
        field.onCommit = { [weak self] in self?.host.end() }
        typingPath = path
        field.onFocus = { [weak self] in
            guard let self else { return }
            self.book?.setTyping(path, of: self.shape)
        }
        field.onBlur = { [weak self, weak field] in
            guard let self else { return }
            self.book?.clearTyping(path, of: self.shape)
            guard !self.switching, !self.cardIsOpen, let field else { return }
            // The keyboard went elsewhere (the words, a click outside): the row is no longer the focus. The field
            // goes a turn later: it is still being resigned.
            Task { @MainActor [weak self, weak field] in
                guard let self, let field, self.field === field, self.window?.firstResponder !== field else { return }
                self.focus = nil
                self.stopField()
                self.needsDisplay = true
            }
        }
        let clip = NSView()
        clip.clipsToBounds = true
        clip.addSubview(field)
        addSubview(clip)
        self.field = field
        self.clip = clip
        slide = 0
        return field
    }

    /// The field's text for a stored value: a text as it is (its line breaks the field's to keep), a number or a
    /// date as its row shows it.
    static func text(of value: JSONValue?, kinds: [PlainKind]) -> String {
        guard let value else { return "" }
        if case .string(let text) = value, FieldText.date(from: text) == nil || !kinds.contains(where: { $0 == .date || $0 == .dateTime }) { return text }
        return kinds.count == 1 ? FieldText.shown(value, as: kinds[0]) : FieldText.shown(value, asOneOf: kinds)
    }

    /// Takes the field away; the keyboard goes to this view first, so the field resigns as it goes.
    private func stopField() {
        guard let field else { return }
        let wasSwitching = switching
        switching = true
        if window?.firstResponder === field { window?.makeFirstResponder(self) }
        field.onKey = nil
        field.onChange = nil
        field.onFocus = nil
        field.onBlur = nil
        field.onCommit = nil
        clip?.removeFromSuperview()
        self.field = nil
        clip = nil
        // Whoever set it clears it: this field is gone, so the check is no longer told it is typed in.
        if let typingPath { book?.clearTyping(typingPath, of: shape) }
        typingPath = nil
        switching = wasSwitching
    }

    /// The caret leaves the rows for the words.
    private func leaveToWords() {
        focus = nil
        stopField()
        needsDisplay = true
        host.focusWords()
    }

    // MARK: Keeping up with the rows

    private func refresh() {
        guard let focus else { return }
        guard let edited = rows(), let row = index(of: focus, in: edited) else {
            // The row is gone (folded away, its field taken out of the type): the caret goes back to the words.
            if window?.firstResponder === self || field != nil { leaveToWords() } else { self.focus = nil }
            return
        }
        if field != nil {
            guard case .typed(let kinds) = edited.classes[row] else {
                stopField()
                window?.makeFirstResponder(self)
                needsDisplay = true
                return
            }
            let stored = edited.record[FieldValuesProperty.self]?.value(at: FieldPath(field: edited.shown.rows[row].path?.field ?? ""))
            fieldKinds = kinds
            if stored != written, let field {
                // Something else wrote the value (an agent's draw, an undo): the row takes what was written.
                written = stored
                field.show(Self.text(of: stored, kinds: kinds))
            }
            layoutField()
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// The field over its value: in a clip as wide as the text hugs it (at least `fieldFocusMinimum`, at most the
    /// value's column), slid so the caret stays in it.
    private func layoutField() {
        guard let field, let clip, let edited = rows(), let row = focusedIndex(in: edited) else { return }
        let shown = edited.shown.rows[row]
        let outset = TypesStyle.fieldFocusOutset
        let textWidth = textWidth(of: field)
        let width = min(max(textWidth + 2 * outset, TypesStyle.fieldFocusMinimum), shown.valueRect.width + 2 * outset)
        let frame = CGRect(x: shown.valueRect.minX - outset, y: shown.rect.minY + 1, width: width, height: shown.rect.height - 2)
        if clip.frame != frame { clip.frame = frame }
        let fieldFrame = CGRect(x: -slide, y: TypesStyle.fieldLift, width: max(textWidth + 2 * outset + 2, frame.width + slide), height: frame.height)
        if field.frame != fieldFrame { field.frame = fieldFrame }
        scrollCaret()
    }

    private func textWidth(of field: RowField) -> CGFloat {
        guard let layout = field.textLayoutManager else { return 0 }
        layout.ensureLayout(for: layout.documentRange)
        return layout.usageBoundsForTextContainer.width
    }

    /// Slides the text so the caret is in the clip.
    private func scrollCaret() {
        guard let field, let clip, let caret = field.caretFrame else { return }
        let outset = TypesStyle.fieldFocusOutset
        // The caret in the text's own coordinates, whatever the slide.
        let at = caret.offsetBy(dx: slide, dy: 0)
        let limit = clip.frame.width - 1
        var next = slide
        if at.maxX - next > limit { next = at.maxX - limit }
        if at.minX - next < outset { next = max(0, at.minX - outset) }
        guard next != slide else { return }
        slide = next
        field.frame.origin.x = -slide
    }

    private func fieldChanged() {
        guard let book, let field, case .field(let key)? = focus else { return }
        // What it writes is what the commit's notice will find stored, so the field does not take it back.
        written = book.stored(field.value, kinds: fieldKinds)
        book.write(field.value, key: key, of: shape, kinds: fieldKinds)
        layoutField()
        needsDisplay = true
    }

    // MARK: Keys

    private func handle(_ key: RowKey) {
        guard let edited = rows(), let row = focusedIndex(in: edited) else { return }
        switch key {
        case .next:
            if row + 1 < edited.count { focusRow(row + 1) } else { host.end() }
        case .previous:
            if row > 0 { focusRow(row - 1) } else { leaveToWords() }
        case .down:
            if row + 1 < edited.count { focusRow(row + 1) }
        case .up:
            if row > 0 { focusRow(row - 1) } else { leaveToWords() }
        case .commit:
            if edited.classes[row].opensCard { openCard(row) } else { host.end() }
        case .escape:
            host.end()
        case .space:
            switch edited.classes[row] {
            case .box:
                if let key = edited.shown.rows[row].path?.field { book?.toggle(key, of: shape) }
            case .choice:
                popChoice(row, edited)
            case let kind where kind.opensCard:
                openCard(row)
            default:
                break
            }
        }
    }

    public override func keyDown(with event: NSEvent) {
        guard focus != nil else { return }
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.keyCode {
        case 48 where modifiers.isEmpty: handle(.next)
        case 48 where modifiers == .shift: handle(.previous)
        case 125 where modifiers.isEmpty: handle(.down)
        case 126 where modifiers.isEmpty: handle(.up)
        case 36 where modifiers.isEmpty, 76 where modifiers.isEmpty: handle(.commit)
        case 36 where modifiers == .command, 76 where modifiers == .command: host.end()
        case 49 where modifiers.isEmpty: handle(.space)
        case 53: handle(.escape)
        default: break
        }
        // No other key goes on: up the chain is the canvas's shortcuts.
    }

    private func popChoice(_ row: Int, _ edited: EditedRows) {
        book?.popChoiceMenu(row: row, of: edited) { [weak self] in self?.restoreFocus() }
    }

    /// The row has the keyboard again (a menu closed, a card closed).
    private func restoreFocus() {
        guard let edited = rows(), let row = focusedIndex(in: edited) else { return }
        focusRow(row)
    }

    // MARK: The card

    private func openCard(_ row: Int) {
        guard let book, let edited = rows() else { return }
        let request = book.valuesCardRequest(row: row, of: edited,
                                             closed: { [weak self] in self?.cardEnded(); self?.restoreFocus() },
                                             tabbedOut: { [weak self] forward in self?.cardEnded(); self?.handle(forward ? .next : .previous) })
        // Before the card is asked for: it takes the keyboard as it opens, and the row stays focused.
        cardIsOpen = true
        if !book.openCard(request) { cardIsOpen = false }
    }

    private func cardEnded() { cardIsOpen = false }

    // MARK: The pointer

    /// The row part under a point of this view, if any (a type's note).
    private func face(at point: CGPoint) -> RowFace? {
        guard let book, let origin = host.origin() else { return nil }
        let inEditor = convert(point, to: superview)
        return book.editedFace(at: CGPoint(x: inEditor.x + origin.x, y: inEditor.y + origin.y), on: shape)
    }

    /// A press in the rows is the rows': on a typed value it puts the caret there, on a box it toggles it, on a
    /// choice it pops its menu, on a row with more it asks for its card; each focuses the row. On a name, the
    /// lead or the paper between it does nothing, and the caret stays where it was.
    public override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if let face = face(at: point) {
            book?.perform(face)
            return
        }
        guard let book, let edited = rows(), let hit = book.target(at: point, in: edited), hit.onValue else { return }
        let row = hit.row
        switch edited.classes[row] {
        case .typed:
            focusRow(row, at: point, clickCount: event.clickCount)
        case .box:
            focusRow(row)
            if let key = edited.shown.rows[row].path?.field { book.toggle(key, of: shape) }
        case .choice:
            focusRow(row)
            popChoice(row, edited)
        case .more, .json, .fold:
            focusRow(row)
            openCard(row)
        case .still:
            focusRow(row)
        }
    }

    /// The I-beam over a typed value, the arrow over the rest: the words' I-beam stops where the rows begin.
    public override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
        guard let edited = rows() else { return }
        for (row, kind) in edited.classes.enumerated() {
            if case .typed = kind { addCursorRect(edited.shown.rows[row].valueRect, cursor: .iBeam) }
        }
    }

    public override func layout() {
        super.layout()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Drawing and leaving

    /// The outline of the focused row, and a focused choice's `▾`. Everything else is the render's, under it.
    public override func draw(_ dirtyRect: NSRect) {
        guard let book, let focus, let cg = NSGraphicsContext.current?.cgContext, let edited = rows(), let row = index(of: focus, in: edited) else { return }
        let shown = edited.shown.rows[row]
        let rect = field != nil ? clip?.frame ?? .zero : book.focusRect(of: shown, class: edited.classes[row])
        book.drawFocus(rect, of: shown, class: edited.classes[row], to: cg)
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned, !switching, !cardIsOpen, field == nil, focus != nil {
            focus = nil
            needsDisplay = true
        }
        return resigned
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        // Out of its window (editing ended): nothing is typed in.
        if window == nil {
            focus = nil
            stopField()
        }
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
