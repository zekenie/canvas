import AppKit
import TextEditing

/// The one text editor a form has, over the cell with the caret: a line of text with no autocorrect, no smart
/// quotes or dashes, no spelling marks and no `/` or `@` list. A long value is one line and scrolls sideways
/// under the caret (the form keeps this in a clip view of the cell's size); a line break pasted in is kept in
/// the value and the line shows the first. The form moves it from cell to cell, so what it could undo is
/// forgotten each time. A caret list in a cell (slice 14's picker) would be this view's, as every list is.
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

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
