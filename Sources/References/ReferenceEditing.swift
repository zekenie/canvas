import AppKit
import Canvas
import Mentions
import Queries
import TextEditing

/// The text view of a pill's field: one line, whose list of public shapes (`ReferencePicker`) shows
/// in a `CaretListWindow` under it while it's open, as every `EditingTextView`'s list does (the keys
/// that move through it, pick and close it are the base class's). What's left to the field is when the list
/// opens (as the view comes into a window, and again whenever something is typed), what a pick does,
/// and the keys no other list has: ⌥Return commits the words as typed, ⇧Return does nothing.
@MainActor
final class ReferenceTextView: EditingTextView {
    /// What the list shows; nil: no list.
    var picker: ReferencePicker?
    /// A row of the list was picked, by a key or a click.
    var onPick: (@MainActor (ReferencePickerRow) -> Void)?
    /// ⌥Return: the words as typed, whatever the list holds.
    var onCommitWords: (@MainActor () -> Void)?
    private var listWindow: CaretListWindow?

    override var caretListWindow: CaretListWindow? { listWindow }

    // MARK: The list

    /// Shows the list under the text, if there's one to show and it isn't already: the first time the
    /// view is in a window (which it follows from then on), and whenever something is typed after
    /// Escape closed it.
    func openList() {
        guard listWindow == nil, let picker, isEditable else { return }
        let window = CaretListWindow(picker.list, accessibilityLabel: ReferenceStyle.pickerAccessibilityLabel, over: self,
                                     anchor: { [weak self] in self?.anchor },
                                     pick: { [weak self] row in self?.pick(row: row) },
                                     close: { [weak self] in self?.listWindow = nil })
        listWindow = window
        window.listDidChange()
    }

    /// The rows or the highlight changed: the window shows them.
    func listDidChange() { listWindow?.listDidChange() }

    /// The whole text, which the list sits under the start of.
    private var anchor: NSRange { NSRange(location: 0, length: (string as NSString).length) }

    private func pick(row index: Int) {
        guard let picker, picker.rows.indices.contains(index) else { return }
        onPick?(picker.rows[index])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { openList() }
    }

    // MARK: Keys

    /// ⌥Return commits the words as typed, and ⇧Return is nothing: a pill's text is one line.
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, !hasMarkedText() {
            switch event.modifierFlags.intersection([.command, .shift, .option, .control]) {
            case .shift: return
            case .option:
                onCommitWords?()
                return
            default: break
            }
        }
        super.keyDown(with: event)
    }
}

/// A field laid over the pill being edited, on one line: its frame in view points and its bounds in
/// world units, the pill's frame at their origin, so AppKit scales it by the zoom and the text sits
/// where the render's label does (`ReferenceStyle`'s font and pads). It starts with what the pill says
/// (the name of what it stands for, or its words), all selected, so typing replaces it, and the list
/// of public shapes under it opens on that text.
///
/// Each change is written to the reference as words (`ReferenceEdits.find`), which refits the pill's
/// width as it goes, and the list is ranked again; a text that's back to what the field opened with, or
/// blank, puts the pill back as it was. Nothing is picked implicitly: a pick is Return or Tab on a
/// shape's row, or a click on it, and writes its name (`ReferenceEdits.pick`) and ends editing. Return
/// on the words row, ⌥Return and ⌘Return commit the words as typed; Return with the list closed (Escape
/// closed it), and a second Escape, leave the field, and the text typed, which is already the
/// pill's words, stays. Newlines pasted in are spaces, and the text is at most 200 characters. A new pill
/// left empty is discarded (`discardsWhenEditingEnds`).
final class ReferenceEditor: NSView, NSTextViewDelegate {
    let textView = ReferenceTextView(frame: .zero)
    /// Clips the text to the label's room, so text past it (200 characters in a pill at most 280 wide)
    /// scrolls as it's typed, its caret kept in view.
    private let clip = NSView()
    private let context: EditContext<Reference>
    /// What the pill held when editing began, for putting it back.
    private let original: Reference
    /// What the field started with: text that's back to it is what the pill said.
    private let openingText: String
    private let picker: ReferencePicker?
    /// Whether the list has only the words row left.
    private var handsOff = false

    init(reference: ShapeRecord<Reference>, context: EditContext<Reference>) {
        self.context = context
        original = reference.props
        let state = context.service(ReferenceState.self)
        let opening = Self.text(of: reference.props, shown: state?.state(of: reference.props) ?? .empty)
        openingText = opening
        picker = state.map { ReferencePicker(state: $0, owner: reference.id, text: opening, current: reference.props.target.map { ($0.id, opening) }) }
        // Whatever was asked of its words before is let go of: a call out is cancelled.
        state?.editingBegan(reference.id)
        let size = (context.frame ?? reference.frame).size
        super.init(frame: CGRect(origin: .zero, size: size))
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.focusRingType = .none
        textView.font = ReferenceStyle.labelFont
        textView.textColor = ReferenceStyle.label
        textView.typingAttributes = [.font: ReferenceStyle.labelFont, .foregroundColor: ReferenceStyle.label]
        textView.placeholder = ReferenceStyle.placeholder
        // Words are typed as they are: a quote stays straight, a dash a hyphen.
        CaretListSubstitutions.off.apply(to: textView)
        textView.isContinuousSpellCheckingEnabled = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = false
        textView.insertionPointColor = ReferenceStyle.label
        textView.delegate = self
        textView.commitsOnReturn = true
        textView.commitsOnLeaving = false
        textView.onCommit = { [weak self] in self?.leave() }
        textView.onLeave = { [weak self] in self?.settleWords() }
        textView.onCommitWords = { [weak self] in self?.commitWords() }
        textView.onPick = { [weak self] row in self?.pick(row) }
        textView.picker = picker
        textView.string = openingText
        clipsToBounds = true
        clip.clipsToBounds = true
        addSubview(clip)
        clip.addSubview(textView)
        picker?.onChange = { [weak self] in self?.pickerDidChange() }
        updateHandoff()
        placeText()
        textView.selectAll(nil)
        layoutText()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// What the field starts with: what a direct reference stands for is called, as its pill says; a
    /// dynamic one's words (or its query's text); nothing for an empty pill.
    private static func text(of props: Reference, shown: ReferenceCondition) -> String {
        switch props.mode {
        case .empty: ""
        case .dynamic: props.text
        case .direct:
            switch shown {
            case .live(let appearance), .notPublic(let appearance): appearance.label
            default: props.target?.label ?? ""
            }
        }
    }

    // MARK: Where the text is

    /// Where the text starts: the pill's label's place (the render's: its capitals centered in the pill),
    /// which follows whether the pill leads with a symbol (what it stands for; the magnifier once the
    /// list has only the words row left). TextKit 2 sets this font's line where string drawing does.
    private func placeText() {
        let props = context.shape?.props ?? original
        let condition = context.service(ReferenceState.self)?.state(of: props) ?? .empty
        let look = ReferenceLook(editing: condition, handsOff: handsOff)
        let x = ReferenceStyle.leadingPad + (look.leading == nil ? 0 : ReferenceStyle.symbolBox + ReferenceStyle.gap)
        let top = ReferenceStyle.lineTop(of: ReferenceStyle.labelFont, in: ReferenceStyle.height)
        textView.textContainerInset = NSSize(width: x, height: top)
    }

    /// The text is clipped to the label's room (the pill, less its trailing pad and, for words, the
    /// room a count takes) and scrolled so the caret is in it: text longer than the pill is wide is
    /// seen where it's being typed.
    private func layoutText() {
        let size = bounds.size
        let props = context.shape?.props ?? original
        let right = max(0, size.width - ReferenceStyle.trailingPad - (props.mode == .dynamic ? ReferenceStyle.badgeRoom : 0))
        clip.frame = CGRect(x: 0, y: 0, width: right, height: size.height)
        clip.bounds = CGRect(origin: .zero, size: clip.frame.size)
        let caret = textView.caretFrame?.maxX ?? 0
        let scroll = max(0, caret - right)
        let frame = CGRect(x: -scroll, y: 0, width: max(size.width + scroll, caret + 1), height: size.height)
        if textView.frame != frame { textView.frame = frame }
    }

    /// The canvas lays the editor over the pill, whose width changes with what's typed.
    override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        layoutText()
    }

    override var bounds: NSRect {
        didSet { if bounds.size != oldValue.size { layoutText() } }
    }

    // MARK: Typing

    func textDidChange(_ notification: Notification) {
        let text = textView.string
        let putBack = text == openingText || ReferenceEdits.isBlank(text)
        context.update { props in
            if putBack {
                props.target = original.target
                props.words = original.words
                props.query = original.query
                ReferenceEdits.fit(&props)
            } else {
                ReferenceEdits.find(&props, words: text)
            }
        }
        picker?.setText(text)
        placeText()
        layoutText()
        textView.openList()
        // The words rest, and are interpreted, once only the words row is left (any keystroke starts
        // again).
        context.service(ReferenceState.self)?.typed(putBack ? "" : text, in: context.shapeID, interprets: picker?.isHandoff ?? false)
    }

    func textViewDidChangeSelection(_ notification: Notification) { layoutText() }

    /// At most 200 characters, and no line breaks or tabs: pasted ones are spaces.
    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        guard let replacement = replacementString else { return true }
        var text = replacement.map { $0.isNewline || $0 == "\t" ? " " : $0 }
        let room = ReferenceStyle.textLimit - ((textView.string as NSString).length - range.length)
        if text.count > max(room, 0) { text = Array(text.prefix(max(room, 0))) }
        let fitted = String(text)
        guard fitted != replacement else { return true }
        if !fitted.isEmpty || range.length > 0 { textView.insertText(fitted, replacementRange: range) }
        return false
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.cancelOperation(_:)),
             #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)), #selector(NSResponder.insertParagraphSeparator(_:)):
            // The list, if it was open, took these first: Escape with it closed leaves the field, as
            // Return does; the text is already the pill's words.
            leave()
            return true
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            return true
        default:
            return false
        }
    }

    // MARK: Committing

    /// What a row of the list does: a shape's names it, and the words row's commits the words.
    private func pick(_ row: ReferencePickerRow) {
        switch row {
        case .shape(let choice): pickTarget(choice.candidate)
        case .words: commitWords()
        case .empty: break
        }
    }

    /// The pill stands for the shape, named as a mention of it shows it: one write, the words and query
    /// let go of, the width refit to its name; and editing ends.
    private func pickTarget(_ candidate: MentionCandidate) {
        context.update { ReferenceEdits.pick(&$0, ReferenceTarget(id: candidate.id, label: candidate.appearance.label)) }
        context.service(MentionState.self)?.didPick(candidate.id)
        context.end()
    }

    /// The pill stands for the words as typed, shapes matching them or not (the words row, ⌥Return):
    /// what it says already, unless the field is as it opened and the pill a picked shape's, and ends
    /// editing. Words that read as a query (`queries.check` takes them) are that query, canonical, in
    /// this step: no model is asked.
    private func commitWords() {
        let words = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !words.isEmpty {
            let query = query(for: words)
            context.update { props in
                if props.mode == .dynamic, props.text == words, props.query != nil || query == nil { return }
                ReferenceEdits.find(&props, words: words, query: query)
            }
            // Words no query was found for are interpreted when editing ends, though the list had shapes for them.
            context.service(ReferenceState.self)?.committed(words: words, of: context.shapeID)
        }
        context.end()
    }

    /// Leaves the field (Return with the list closed, a second Escape, ⌘Return): the words settled,
    /// then editing ends.
    private func leave() {
        settleWords()
        context.end()
    }

    /// Leaving the field, whatever for (and the keyboard leaving, as editing ends): the words are
    /// written already, so what's left is the white space at their ends, which isn't part of what the
    /// pill finds, and, for text that changed, the query the words are when they read as one (as
    /// committing them does).
    private func settleWords() {
        guard textView.string != openingText, let props = context.shape?.props, props.mode == .dynamic, props.target == nil,
              props.words == textView.string else { return }
        let words = props.words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        let query = props.query ?? query(for: words)
        guard words != props.words || query != props.query else { return }
        context.update { ReferenceEdits.find(&$0, words: words, query: query) }
    }

    /// The query `words` are, canonical, if they read as one; nil if they don't (they're words for the
    /// model), or there's no engine.
    private func query(for words: String) -> String? {
        if let query = try? context.service(QueryState.self)?.check(words).canonical { return query }
        // Else the query the model wrote for exactly these words while they rested, if it came.
        return context.service(ReferenceState.self)?.draftQuery(for: context.shapeID, words: words)
    }

    // MARK: The list's state

    private func pickerDidChange() {
        textView.listDidChange()
        updateHandoff()
    }

    /// Once the list has only the words row left, the pill leads with the magnifier (its text moves
    /// over for it), and the canvas draws it so.
    private func updateHandoff() {
        let now = picker?.isHandoff ?? false
        guard now != handsOff else { return }
        handsOff = now
        context.service(ReferenceState.self)?.setHandingOff(now, for: context.shapeID)
        placeText()
    }
}
