import AppKit
import TextEditing

/// The one text editor a form has, over the cell with the caret: a line of text with no autocorrect, no smart
/// quotes or dashes, no spelling marks and no `/` or `@` list. A long value is one line and scrolls sideways
/// under the caret (the form keeps this in a clip view of the cell's size); a line break pasted in is kept in
/// the value and the line shows the first. The form moves it from cell to cell, so what it could undo is
/// forgotten each time. A note's cell has its list of notes at this view's caret, as every list is (`picking`).
@MainActor
public final class FieldCellEditor: EditingTextView {
    public init() {
        super.init(frame: .zero)
    }

    /// What NSTextView's `init(frame:)` calls on itself, so the set-up is here.
    public override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isRichText = false
        drawsBackground = false
        allowsUndo = true
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        CaretListSubstitutions.off.apply(to: self)
        commitsOnLeaving = false
        textContainerInset = .zero
        isHorizontallyResizable = true
        isVerticallyResizable = false
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.maximumNumberOfLines = 1
    }

    /// A key took a line out and the keyboard moved on to this cell: the repeats of that held key are the first press's, so they are
    /// let go until the next press (they would delete what the cell holds, and then the line itself).
    var dropsRepeats = false

    public override func keyDown(with event: NSEvent) {
        if event.isARepeat, dropsRepeats { return }
        if !event.isARepeat { dropsRepeats = false }
        super.keyDown(with: event)
    }

    /// The list of notes a note's cell finds in while it is typed over: the keys are the list's first.
    var picking: (picker: any NotePicking, window: CaretListWindow)?

    public override var caretListWindow: CaretListWindow? { picking?.window }

    /// While a note is picked, the keys are `NotePicking.perform`'s: Return picks and Backspace on nothing closes. Tab and ⇧Tab are never a
    /// pick (`EditingTextView` would hand them to the list): the list closes with nothing stored and the key goes on as it would with
    /// no list, to the form's delegate, which moves to the next cell.
    public override func doCommand(by selector: Selector) {
        if let (picker, window) = picking {
            let (taken, action) = picker.perform(selector)
            if taken {
                switch action {
                case .pick: window.pickHighlighted()
                case .close: window.closeList()
                default: break
                }
                return
            }
            if action == .close { window.closeList() }
        }
        super.doCommand(by: selector)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
