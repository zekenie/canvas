import AppKit
import Canvas
import CanvasRPC
import Draw
import Mentions
import TextEditing

// The rows of the note being edited. The note's editing view covers the whole paper, so a press over the rows
// would land in its text and put the caret at the end of the words. A kind that hosts an editing view over its
// rows lays this one over them: a press in the rows is the rows', whatever the text view under it would do.
// On a type's note it does what a click on the canvas does for the part under the point (Retry, a card, an
// options list) and nothing elsewhere. On a note that is one it is the rows editor: the note's one editing
// session has two places for the caret, the words and a row. A typed value is edited by a one-line field
// (`RowField`) laid over it, each keystroke a commit through the one writer; a box, a choice and a row with more
// in it are focused with this view as the first responder, outlined, and take the keys of the table below.
// A row that names notes is focused the same way: typing on it opens the list of the notes it may name (a field over the
// value takes the characters; nothing is stored until a pick), Space opens the list with nothing typed, and Return ends
// editing. In the list Return or a click picks, and Tab, ⇧Tab and Escape close it with nothing stored (Tab then goes on
// to the next row).
// Every other key stops here: up the responder chain is the canvas's shortcuts, where Backspace deletes the
// selection, which is the note being edited.
//
// | Key         | Typed row                 | Box, choice, row with more, fold, pills              |
// | Tab, ⇧Tab   | next row, previous row    | the same                                             |
// | ↓, ↑        | next row, previous row    | the same                                             |
// | ← →         | the caret                 | a relation row: between its pills                    |
// | Return      | editing ends              | a pill focused: its note; a row with more: its card; |
// |             |                           | a choice: its menu; else editing ends                |
// | Space       | a space                   | a pill focused: its note; a box toggles, a choice    |
// |             |                           | pops, more: its card                                 |
// | ⇧Return     | a new note beside, edited | the same                                             |
// | Backspace   | the text's                | a relation row: its pills, one at a time             |
// | Escape, ⌘↩  | editing ends              | editing ends                                         |
//
// Return, Space and Backspace do once for a press, however long the key is held: what a held key repeats is the moving
// (Tab, the arrows). The keys are read through `KeyMeaning`, as the field's commands are.
// Off the last row, Tab goes on past the shape (the host's: the next note); ↑ and ⇧Tab from the first go back to the words;
// ↓ on the last does nothing. Tab in the words comes to the first row, and ⇧Tab from past the shape to the last.

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
    /// Tab off the last row: the session goes on past the shape, as Tab in its words would with no rows.
    public var tabbedOut: @MainActor () -> Void
    /// ⇧Return in a row: a new note beside the shape, edited, as ⇧Return in its words puts one.
    public var addBeside: @MainActor () -> Void

    public init(origin: @escaping @MainActor () -> CGPoint?, end: @escaping @MainActor () -> Void,
                keepInView: @escaping @MainActor (CGRect) -> Void, focusWords: @escaping @MainActor () -> Void,
                tabbedOut: @escaping @MainActor () -> Void, addBeside: @escaping @MainActor () -> Void) {
        self.origin = origin
        self.end = end
        self.keepInView = keepInView
        self.focusWords = focusWords
        self.tabbedOut = tabbedOut
        self.addBeside = addBeside
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
        case relation(RelationshipRowKey)
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
    /// A row's list is open: the notes it lists and its window, over the value's field. Nothing is written until a pick.
    private var picking: (picker: any NotePicking, window: CaretListWindow)?
    /// The relation row the open list picks for.
    private var pickingRow: RelationshipRow?
    /// The pill of the focused relation row that has the focus (by place among the pills shown): a second Backspace removes it.
    private var pillFocus: Int?
    /// The elements VoiceOver was given for the rows, with what each was made from.
    private var rowElements: [(shown: ShownRow, kind: RowClass, look: RowLook, element: NSAccessibilityElement)?] = []
    /// Moving the focus between this view's own parts: the keyboard leaving one is not the person leaving.
    private var switching = false
    /// A card is being asked for: it takes the keyboard as it opens, before the service has it down as open.
    private var cardOpening = false
    /// A card of this shape is open: the keyboard is the card's, and the row stays focused. The service's word, not
    /// a flag kept here: a card goes down in ways that tell this view nothing (the field left its type, the note
    /// scrolled out of view, the zoom went to skeletons), and a row that thought one still open would never again
    /// let go of its focus.
    private var cardIsOpen: Bool { cardOpening || book?.editor?.fieldCards?.openTarget?.shape == shape }

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
        case .relation(let key): edited.index(ofRelation: key)
        }
    }

    private func focus(of row: Int, in edited: EditedRows) -> Focus? {
        if let key = edited.shown.rows[row].path?.field { return .field(key) }
        if let key = edited.shown.rows[row].relation { return .relation(key) }
        return edited.fold(row).map { Focus.fold(isMore: $0.isMore) }
    }

    /// The focused row's place among the rows as they are now.
    private func focusedIndex(in edited: EditedRows) -> Int? { focus.flatMap { index(of: $0, in: edited) } }

    /// The list a relation row has open, if any (tests read it).
    public var openList: CaretList? { picking?.picker.list }

    /// The pill of the focused relation row that has the focus, by its place among the pills shown (tests read it).
    public var focusedPill: Int? { pillFocus }

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
        case .relation:
            let responder = focusRow(hit.row)
            let session = book.editor?.editingShapeID
            // A press on the `›` opens the card of the relationships; anywhere else on the value, the list.
            let onChevron = book.isChevron(point, row: hit.row, in: edited)
            _ = book.editor?.scheduler.schedule(after: .zero) { [weak self] in
                guard let self, let book = self.book, book.rowsView === self, book.editor?.editingShapeID == session, session == self.shape,
                      let edited = self.rows(), let current = self.focusedIndex(in: edited), current == hit.row, self.picking == nil else { return }
                if onChevron { self.openCard(current) } else { self.startRelating(row: current, typed: "") }
            }
            return responder
        default:
            return nil
        }
    }

    /// ↓ from the words' last line, and Tab in them: the first row takes the caret. False with no row to take it (a type's
    /// note, a note with no rows).
    public func focusFirstRow() -> Bool {
        guard let edited = rows(), edited.count > 0 else { return false }
        return focusRow(0) != nil
    }

    /// ⇧Tab from past the shape (the next note's words): the last row takes the caret or the focus, and is the responder
    /// that does. Nil with no row to take it.
    @discardableResult
    public func focusLastRow() -> NSResponder? {
        guard let edited = rows(), edited.count > 0 else { return nil }
        return focusRow(edited.count - 1)
    }

    /// Gives a row the caret (a typed one: its field, the caret at `point` if given) or the focus (this view).
    @discardableResult
    private func focusRow(_ row: Int, at point: CGPoint? = nil, clickCount: Int = 1) -> NSResponder? {
        guard let edited = rows(), edited.shown.rows.indices.contains(row), let target = focus(of: row, in: edited) else { return nil }
        switching = true
        defer { switching = false }
        host.keepInView(edited.shown.rows[row].rect)
        if focus != target { pillFocus = nil }
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
        announceFocus()
        return responder
    }

    private func makeField(row: Int, key: String, kinds: [PlainKind], in edited: EditedRows) -> RowField {
        let path = FieldPath(field: key)
        let field = RowField()
        field.setAccessibilityLabel(edited.shown.rows[row].name)
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
        if let listed = picking {
            picking = nil
            pickingRow = nil
            book?.picking = nil
            field.picking = nil
            listed.window.dismiss()
            book?.editor?.setNeedsDisplay()
        }
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

    /// Tab off the last row: the rows let go of the focus, and the host goes on past the shape.
    private func leaveForward() {
        focus = nil
        pillFocus = nil
        stopField()
        needsDisplay = true
        host.tabbedOut()
    }

    /// The caret leaves the rows for the words.
    private func leaveToWords() {
        focus = nil
        pillFocus = nil
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
        if field != nil, picking != nil {
            // A relation row's field: its row is still one, else the list goes.
            guard case .relation = edited.classes[row] else {
                stopField()
                window?.makeFirstResponder(self)
                needsDisplay = true
                return
            }
            layoutField()
        } else if field != nil {
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
        if let pill = pillFocus, edited.shown.rows[row].pills.count <= pill { pillFocus = nil }
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
            if row + 1 < edited.count { focusRow(row + 1) } else { leaveForward() }
        case .previous:
            if row > 0 { focusRow(row - 1) } else { leaveToWords() }
        case .down:
            if row + 1 < edited.count { focusRow(row + 1) }
        case .up:
            if row > 0 { focusRow(row - 1) } else { leaveToWords() }
        case .commit:
            if followPill(row, in: edited) {
                return
            } else if case .choice = edited.classes[row] {
                popChoice(row, edited)
            } else if edited.opensCard(row) {
                openCard(row)
            } else if case .relation = edited.classes[row] {
                // Its list, where a list can be made; else editing ends.
                if canRelate { startRelating(row: row, typed: "") } else { host.end() }
            } else {
                host.end()
            }
        case .escape:
            if pillFocus != nil {
                // A pill's focus goes first; a second Escape ends editing.
                pillFocus = nil
                needsDisplay = true
            } else {
                host.end()
            }
        case .addBeside:
            host.addBeside()
        case .space:
            if followPill(row, in: edited) { return }
            switch edited.classes[row] {
            case .box:
                if let key = edited.shown.rows[row].path?.field { book?.toggle(key, of: shape) }
            case .choice:
                popChoice(row, edited)
            case .relation:
                startRelating(row: row, typed: "")
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
        guard let reading = KeyMeaning.Reading(event: event) else { return typeToPick(event, modifiers: modifiers) }
        let plain = reading.modifiers.isEmpty
        // A held key repeats to move, not to do: Return, Space and Backspace are one press whatever the key is held.
        if event.isARepeat, [.activate, .toggle, .delete, .finish].contains(reading.meaning) { return }
        switch reading.meaning {
        case .next where reading.modifiers == .shift: handle(.previous)
        case .next where plain: handle(.next)
        case .previous: handle(.previous)
        case .down where plain: handle(.down)
        case .up where plain: handle(.up)
        case .left where plain: movePillFocus(by: -1)
        case .right where plain: movePillFocus(by: 1)
        case .activate where plain: handle(.commit)
        case .activate where reading.modifiers == .shift: handle(.addBeside)
        case .finish where reading.modifiers == .command: host.end()
        case .toggle where plain: handle(.space)
        case .back: handle(.escape)
        case .delete where plain: deletePill()
        default: typeToPick(event, modifiers: modifiers)
        }
        // No other key goes on: up the chain is the canvas's shortcuts.
    }

    /// Return or Space on a focused pill goes to its note, as a click on it does. False with no pill focused.
    private func followPill(_ row: Int, in edited: EditedRows) -> Bool {
        guard let pill = pillFocus, case .related(let pills, _) = edited.shown.rows[row].content, pills.indices.contains(pill) else { return false }
        if let destination = pills[pill].destination { book?.editor?.mentions?.follow(destination) }
        return true
    }

    // MARK: VoiceOver

    /// One element per row, in the order of the rows: named for its field, with its value, and by what the row is for a role
    /// (a box a check box, a choice a pop-up button, a row with more in it and a fold buttons, a typed row a text field, a relation
    /// row a group of its pills as buttons). A needed or wrong value says so in its help. The row being typed in is its field.
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .group }
    public override func accessibilityLabel() -> String? { TypesStyle.rowsAccessibilityLabel }

    public override func accessibilityChildren() -> [Any]? {
        guard let edited = rows() else { return [] }
        return elements(of: edited)
    }

    /// The element with the keyboard: the field, a focused pill, else the focused row.
    public override var accessibilityFocusedUIElement: Any? {
        // AppKit asks on the main thread; the property is declared without the main actor.
        nonisolated(unsafe) var element: Any?
        MainActor.assumeIsolated { element = focusedElement() }
        return element
    }

    private func focusedElement() -> Any? {
        guard focus != nil, let edited = rows(), let row = focusedIndex(in: edited) else { return nil }
        if let field { return field }
        let element = element(at: row, in: edited, check: book?.check(of: edited.record) ?? .clean)
        if let pillFocus, let pills = (element as? NSAccessibilityElement)?.accessibilityChildren() as? [NSAccessibilityElement],
           pills.indices.contains(pillFocus) { return pills[pillFocus] }
        return element
    }

    private func elements(of edited: EditedRows) -> [Any] {
        let check = book?.check(of: edited.record) ?? .clean
        let all = edited.shown.rows.indices.map { element(at: $0, in: edited, check: check) }
        if rowElements.count > all.count { rowElements.removeLast(rowElements.count - all.count) }
        return all
    }

    /// The element for a row: the field while it is typed in, else the one made for the row as it is now. A row that is as it
    /// was when its element was made keeps it (the frames made again), so the focused element is one of the children by identity.
    private func element(at row: Int, in edited: EditedRows, check: FieldCheck) -> Any {
        let shown = edited.shown.rows[row]
        if row == focusedIndex(in: edited), let field, picking == nil { return field }
        let mark = check.problems.isEmpty ? nil : shown.relation.map { check.mark(at: $0) } ?? edited.shown.marks[row].compactMap { check.mark(at: $0) }.max()
        let look = RowLook.of(content: shown.content, mark: mark)
        let kind = edited.classes[row]
        while rowElements.count <= row { rowElements.append(nil) }
        if let held = rowElements[row], held.shown == shown, held.kind == kind, held.look == look {
            held.element.setAccessibilityFrame(screen(shown.rect))
            if case .related(let pills, _) = shown.content, let parts = held.element.accessibilityChildren() as? [NSAccessibilityElement] {
                for (part, pill) in zip(parts, pills) { part.setAccessibilityFrame(screen(book?.pillRect(pill, in: shown) ?? shown.valueRect)) }
            }
            return held.element
        }
        let made = element(for: shown, class: kind, look: look)
        rowElements[row] = (shown, kind, look, made)
        return made
    }

    private func element(for shown: ShownRow, class kind: RowClass, look: RowLook) -> NSAccessibilityElement {
        let element = NSAccessibilityElement()
        element.setAccessibilityParent(self)
        element.setAccessibilityFrame(screen(shown.rect))
        element.setAccessibilityLabel(shown.name)
        switch look {
        case .needed, .neededInside: element.setAccessibilityHelp(TypesStyle.neededHelp)
        case .wrong: element.setAccessibilityHelp(TypesStyle.wrongHelp)
        case .plain, .empty: break
        }
        switch (kind, shown.content) {
        case (.box, .box(let on)):
            element.setAccessibilityRole(.checkBox)
            element.setAccessibilityValue(on ? 1 : 0)
        case (.choice, .choice(let chosen)):
            element.setAccessibilityRole(.popUpButton)
            element.setAccessibilityValue(chosen ?? "")
        case (.typed, .text(let text)):
            element.setAccessibilityRole(.textField)
            element.setAccessibilityValue(text)
        case (.typed, .empty(let placeholder)):
            element.setAccessibilityRole(.textField)
            element.setAccessibilityValue("")
            element.setAccessibilityPlaceholderValue(placeholder)
        case (.relation, .related(let pills, let more)):
            element.setAccessibilityRole(.group)
            element.setAccessibilityValue(pills.map(\.label).joined(separator: ", ") + (more > 0 ? TypesStyle.moreHelp(more) : ""))
            element.setAccessibilityChildren(pills.map { pill in
                let part = NSAccessibilityElement()
                part.setAccessibilityParent(element)
                part.setAccessibilityRole(.button)
                part.setAccessibilityLabel(pill.label)
                part.setAccessibilityFrame(screen(book?.pillRect(pill, in: shown) ?? shown.valueRect))
                return part
            })
        case (.relation, .empty(let placeholder)):
            element.setAccessibilityRole(.group)
            element.setAccessibilityValue("")
            element.setAccessibilityPlaceholderValue(placeholder)
        case (_, .summary(let text)), (_, .fold(let text)):
            element.setAccessibilityRole(.button)
            element.setAccessibilityValue(text)
        case (.more, _), (.json, _), (.fold, _):
            element.setAccessibilityRole(.button)
            element.setAccessibilityValue("")
        default:
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityValue("")
        }
        return element
    }

    /// A rect of this view, on the screen.
    private func screen(_ rect: CGRect) -> CGRect {
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    /// The keyboard went to another row or pill: VoiceOver says where.
    private func announceFocus() {
        NSAccessibility.post(element: self, notification: .focusedUIElementChanged)
    }

    // MARK: Picking a note

    /// Whether a relation row can open a list: something draws connections.
    private var canRelate: Bool { book?.editor?.registry.drawsConnections ?? false }

    /// Typing on a focused relation row opens its list with the characters typed: any key with no ⌘ or ⌃ that makes a
    /// printable character.
    private func typeToPick(_ event: NSEvent, modifiers: NSEvent.ModifierFlags) {
        guard focus != nil, modifiers.isDisjoint(with: [.command, .control]), let typed = event.characters, !typed.isEmpty,
              typed.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 && !(0xF700...0xF8FF).contains($0.value) }),
              let edited = rows(), let row = focusedIndex(in: edited), case .relation = edited.classes[row] else { return }
        startRelating(row: row, typed: typed)
    }

    /// ← and → move the focus between the pills a focused relation row shows, clamped to them; from none, ← goes to the
    /// last and → to the first.
    private func movePillFocus(by step: Int) {
        guard let edited = rows(), let row = focusedIndex(in: edited), case .relation = edited.classes[row] else { return }
        let count = edited.shown.rows[row].pills.count
        guard count > 0 else { return }
        pillFocus = pillFocus.map { min(max($0 + step, 0), count - 1) } ?? (step < 0 ? count - 1 : 0)
        needsDisplay = true
        announceFocus()
    }

    /// Backspace or Delete on a focused relation row: the first focuses the last pill, so the person sees which relationship
    /// goes (it holds data); the second takes that pill's relationship away.
    private func deletePill() {
        guard let book, let edited = rows(), let row = focusedIndex(in: edited), case .relation = edited.classes[row] else { return }
        let pills = edited.shown.rows[row].pills
        guard !pills.isEmpty else { return }
        guard let pill = pillFocus, pills.indices.contains(pill) else {
            pillFocus = pills.count - 1
            needsDisplay = true
            return
        }
        pillFocus = nil
        book.unrelate(pills[pill].arrow, of: shape)
        needsDisplay = true
    }

    /// Opens the list of the notes a relation row may name under its value, a field over the value taking `typed`. A
    /// read-only note shakes and opens nothing. Nothing is written until a pick.
    private func startRelating(row: Int, typed: String) {
        guard let book, let editor = book.editor, picking == nil, let edited = rows(), edited.shown.rows.indices.contains(row),
              case .relation = edited.classes[row], let relation = edited.relation(row), let key = edited.shown.rows[row].relation, canRelate else { return }
        if editor.isReadOnly(shape) {
            editor.refuseChanges(to: [shape])
            return
        }
        guard let picker = book.makePicker?(shape, relation.row) else { return }
        switching = true
        defer { switching = false }
        stopField()
        focus = .relation(key)
        pillFocus = nil
        host.keepInView(edited.shown.rows[row].rect)
        let field = RowField()
        field.setAccessibilityLabel(edited.shown.rows[row].name)
        field.show(typed)
        field.setSelectedRange(NSRange(location: (field.string as NSString).length, length: 0))
        field.onKey = { [weak self] key in self?.handle(key) }
        field.onChange = { [weak self] in self?.pickQueryChanged() }
        field.onBlur = { [weak self, weak field] in
            guard let self, let field else { return }
            guard !self.switching, !self.cardIsOpen else { return }
            // The keyboard went elsewhere: the list closes with nothing stored, and the row is no longer the focus.
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
        picker.setQuery(typed)
        let listWindow = CaretListWindow(picker.list, accessibilityLabel: TypesStyle.relationPickerAccessibilityLabel, over: field,
                                         anchorRect: { [weak self] in self?.valueScreenRect() },
                                         pick: { [weak self] row in self?.picked(row: row) },
                                         close: { [weak self] in self?.closePicking() })
        picker.list.onChange = { [weak listWindow] in listWindow?.listDidChange() }
        picking = (picker, listWindow)
        pickingRow = relation.row
        field.picking = (picker, listWindow)
        book.picking = (shape, .relation(key))
        layoutField()
        window?.makeFirstResponder(field)
        needsDisplay = true
        editor.setNeedsDisplay()
        listWindow.listDidChange()
    }

    /// Where the value's field is, on the screen: what the list goes under.
    private func valueScreenRect() -> CGRect? {
        guard let window, let clip else { return nil }
        return window.convertToScreen(convert(clip.frame, to: nil))
    }

    private func pickQueryChanged() {
        guard let picking, let field else { return }
        picking.picker.setQuery(field.value)
        layoutField()
        needsDisplay = true
    }

    /// A line of the list picked (Return, or a click): the list and the field go, the row stays focused, and the pick is
    /// written: the relationship (`RowBook.relate`, one step).
    private func picked(row index: Int) {
        guard let picking, case .relation? = focus, let relation = pickingRow, let note = picking.picker.pickNote(row: index) else { return }
        stopField()
        window?.makeFirstResponder(self)
        needsDisplay = true
        book?.relate(note, in: relation, of: shape)
    }

    /// The list closed with nothing picked (Escape, Tab, Backspace on nothing, a click elsewhere): the field and what was
    /// typed go, the value is what it was, and the row stays focused.
    private func closePicking() {
        guard picking != nil else { return }
        stopField()
        window?.makeFirstResponder(self)
        needsDisplay = true
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
                                             closed: { [weak self] in self?.restoreFocus() },
                                             tabbedOut: { [weak self] forward in self?.handle(forward ? .next : .previous) })
        // Before the card is asked for: it takes the keyboard as it opens, and the row stays focused.
        cardOpening = true
        defer { cardOpening = false }
        book.openCard(request)
    }

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
        // A press while a row's list is open closes it with nothing stored, then does what it does.
        if picking != nil { closePicking() }
        if let face = face(at: point) {
            book?.perform(face)
            return
        }
        guard let book, let edited = rows(), let hit = book.target(at: point, in: edited), hit.onValue else { return }
        let row = hit.row
        // A click on a live pill goes to the note it names (ending the editing), whatever the row is.
        if let pointed = book.pill(at: point, row: row, in: edited) {
            book.editor?.mentions?.follow(pointed)
            return
        }
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
        case .relation:
            focusRow(row)
            if book.isChevron(point, row: row, in: edited) { openCard(row) } else { startRelating(row: row, typed: "") }
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
        if field == nil, let pillFocus, shown.pills.indices.contains(pillFocus) {
            book.outline(book.pillRect(shown.pills[pillFocus], in: shown), to: cg)
            return
        }
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

    /// The shape's rows moved or changed: the view over them follows, once every service has settled the change being
    /// delivered, if one is (`onceSettled`: laying the view out lays the note out, which asks the book and the index).
    func rowsChanged() {
        guard rowsView != nil, !repositionAsked else { return }
        repositionAsked = true
        editor?.onceSettled { [weak self] in
            self?.repositionAsked = false
            self?.rowsView?.reposition()
        }
    }
}
