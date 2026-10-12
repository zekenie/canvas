import AppKit
import TextEditing

/// The text editor of the panel's JSON box, over the box of the focused `Other` field: monospaced, with every
/// substitution off, no spelling and no list. ⌘↩ and the keyboard leaving are its commit (`EditingTextView`'s);
/// Esc is the panel's (it sets no `onExit`), and Tab goes on to the form's next stop.
@MainActor
public final class FieldJSONEditor: EditingTextView {
    public init() {
        super.init(frame: .zero)
    }

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
        font = TypesStyle.formJSONFont
        textContainerInset = NSSize(width: TypesStyle.formJSONPad, height: TypesStyle.formJSONPad)
        isHorizontallyResizable = false
        isVerticallyResizable = true
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
