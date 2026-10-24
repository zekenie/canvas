import AppKit
import TextEditing

/// The command bar's field: one line of the app's text view, typing slash commands for the shapes
/// selected through the `SlashCommandTyping` it hosts, as a note's editor hosts one for its text. It
/// types commands, not prose: one line (a line break pasted is a space; Return and Tab with nothing to
/// pick insert nothing), every substitution off, its spelling unchecked. Its list's keys are every caret
/// list's; Tab with nothing to complete does nothing, ⇧Tab closes the list, and Escape with no list
/// open, the `/` deleted and the keyboard leaving close the bar (`onExit`, `onEmptied`, `onLeave`).
@MainActor
public final class SlashBarTextView: EditingTextView {
    /// The slash commands typed in it, for the shapes the bar was opened on.
    public internal(set) var slashCommands: SlashCommandTyping?
    /// Its text was emptied (the `/` deleted).
    var onEmptied: (@MainActor () -> Void)?
    /// Between `shouldChangeText` and `didChangeText`: the selection moving then is the edit's.
    private var isChangingText = false

    // `init(frame:)` makes the text system and goes through `init(frame:textContainer:)`, which AppKit
    // asks of this class: it's the one that sets the field up.
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure() {
        font = SlashBarStyle.font
        textColor = .labelColor
        isRichText = false
        allowsUndo = true
        SlashBarField.setUp(self)
    }

    public override var caretListWindow: CaretListWindow? { slashCommands?.window }

    // MARK: What it tells the typing

    public override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        let should = super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        if should { isChangingText = true }
        return should
    }

    /// Text pasted in is one line: its line breaks and tabs are spaces. Emptied, the bar closes.
    public override func didChangeText() {
        if string.contains(where: { $0.isNewline || $0 == "\t" }) {
            let range = selectedRange()
            string = String(string.map { $0.isNewline || $0 == "\t" ? " " : $0 })
            setSelectedRange(range)
        }
        isChangingText = false
        super.didChangeText()
        slashCommands?.didChange(isEdit: true)
        if string.isEmpty { onEmptied?() }
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !isChangingText { slashCommands?.didChange(isEdit: false) }
    }

    public override func insertText(_ string: Any, replacementRange: NSRange) {
        let wasComposing = hasMarkedText()
        super.insertText(string, replacementRange: replacementRange)
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        if !wasComposing, !hasMarkedText() { slashCommands?.didType(typed) }
    }

    /// A plain Return is the command's first: it runs or completes the line.
    public override func keyDown(with event: NSEvent) {
        if slashCommands?.takesKey(event) == true { return }
        super.keyDown(with: event)
    }

    // One line: Return and Tab with nothing to pick, and a line break, insert nothing.
    public override func insertNewline(_ sender: Any?) {}
    public override func insertLineBreak(_ sender: Any?) {}
    public override func insertParagraphSeparator(_ sender: Any?) {}
    public override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {}
}

/// What the bar shows: the field at its left, and at its right what it acts on, quieter ("Groceries",
/// "5 shapes").
@MainActor
final class SlashBarView: NSView {
    let field: NSView
    let acting: NSTextField

    init(field: NSView, acting label: String) {
        self.field = field
        acting = NSTextField(labelWithString: label)
        super.init(frame: CGRect(x: 0, y: 0, width: SlashBarStyle.width, height: SlashBarStyle.height))
        acting.font = SlashBarStyle.labelFont
        acting.textColor = .secondaryLabelColor
        acting.alignment = .right
        acting.lineBreakMode = .byTruncatingHead
        acting.setAccessibilityElement(false)
        addSubview(field)
        addSubview(acting)
        layoutParts()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        layoutParts()
    }

    /// The field takes what the label leaves, the label at most `labelShare` of the bar.
    private func layoutParts() {
        let inset = SlashBarStyle.inset
        let room = max(0, bounds.width - inset * 3)
        // The cell's size, its padding with it: the intrinsic width leaves that out, and the label would cut its head off.
        let wanted = ceil(acting.cell?.cellSize.width ?? acting.intrinsicContentSize.width)
        let labelWidth = min(wanted, room * SlashBarStyle.labelShare)
        let labelHeight = ceil(acting.intrinsicContentSize.height)
        acting.frame = CGRect(x: bounds.width - inset - labelWidth, y: ((bounds.height - labelHeight) / 2).rounded(),
                              width: labelWidth, height: labelHeight)
        field.frame = CGRect(x: inset, y: 0, width: max(0, room - labelWidth), height: bounds.height)
    }
}
