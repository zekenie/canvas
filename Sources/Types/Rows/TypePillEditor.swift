import AppKit
import TextEditing

// The view laid over a relationship type's pill while its name is edited: one line of text in the pill's font and ink, the
// caret in it, over the capsule the canvas draws. It edits the title, never the words (a name typed as a note's words would
// be the type's words, and wake the model). The kind's editing view hosts it and writes what is typed; its bounds are the
// pill's, world units, as every editing view's are.

/// The line a pill's name is typed in: a text view with no autocorrect, quotes, dashes or lists, that hands each change
/// and the key that ends it to its host.
@MainActor
public final class TypePillEditor: NSView, NSTextViewDelegate {
    /// How editing ended: Return, Escape or Tab. Each keeps what was typed; Tab also asks for the card that defines the type.
    public enum Ending: Sendable { case done, escape, tab }

    public let field = FieldCellEditor()
    /// The name as typed, after each change.
    public var typed: ((String) -> Void)?
    /// Return, Escape or Tab.
    public var finished: ((Ending) -> Void)?

    public init(title: String?, ink: NSColor) {
        super.init(frame: .zero)
        let resolved = NSColor(cgColor: ink.cgColor) ?? ink
        field.font = TypePills.font
        field.textColor = resolved
        field.insertionPointColor = resolved
        field.typingAttributes = [.font: TypePills.font, .foregroundColor: resolved]
        field.string = title ?? ""
        field.setSelectedRange(NSRange(location: (title ?? "").utf16.count, length: 0))
        field.delegate = self
        field.setAccessibilityLabel(TypesStyle.nameRelationshipType)
        addSubview(field)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        placeField()
    }

    public override func layout() {
        super.layout()
        placeField()
    }

    /// The text's line, from the padding in and centered across the pill, as the canvas draws the pill's text.
    private func placeField() {
        let font = TypePills.font
        let line = ceil(font.ascender - font.descender + font.leading)
        let frame = CGRect(x: TypesStyle.pillPadding, y: ((bounds.height - line) / 2).rounded(),
                           width: max(0, bounds.width - 2 * TypesStyle.pillPadding), height: line)
        if field.frame != frame { field.frame = frame }
    }

    public func textDidChange(_ notification: Notification) {
        typed?(field.string)
    }

    public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            finished?(.done)
        case #selector(NSResponder.cancelOperation(_:)):
            finished?(.escape)
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertBacktab(_:)):
            finished?(.tab)
        default:
            return false
        }
        return true
    }
}
