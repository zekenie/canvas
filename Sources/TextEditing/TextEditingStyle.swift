import AppKit

/// The metrics of the text view and the caret list. Points.
@MainActor
enum TextEditingStyle {
    /// The font a view's placeholder is drawn in when the view has none of its own: the system's, 11 points.
    static let placeholderFont = NSFont.systemFont(ofSize: 11)

    // MARK: Highlights (`EditingTextView.highlights`)

    /// A highlight is a mention's pill drawn behind text, so its metrics are the pill's, as fractions
    /// of the text's font size (an em): 17 points tall at 16, its corners 4.
    static let highlightHeight: CGFloat = 17.0 / 16
    static let highlightCornerRadius: CGFloat = 4.0 / 16
    /// How far it reaches past the text at each end, in points.
    static let highlightPadding: CGFloat = 2

    // MARK: Caret lists (`CaretListWindow`)

    /// Between the window's edge and its first and last rows.
    static let caretListInset: CGFloat = 5
    /// Between the window's sides and a row's highlight.
    static let caretListRowInset: CGFloat = 5
    /// Between a row's highlight and its symbol (or its title), and its detail.
    static let caretListTextInset: CGFloat = 7
    static let caretListSymbolWidth: CGFloat = 16
    static let caretListGap: CGFloat = 6
    static let caretListHighlightRadius: CGFloat = 4
    static let caretListCornerRadius: CGFloat = 8
    static let caretListLabelSize: CGFloat = 13
    static let caretListDetailSize: CGFloat = 11
    static let caretListHeaderSize: CGFloat = 11
    /// What of a row its detail keeps however long the title: the title comes first, and the
    /// detail takes the rest of the row, or this share of it, whichever is more.
    static let caretListDetailShare: CGFloat = 0.4
}
