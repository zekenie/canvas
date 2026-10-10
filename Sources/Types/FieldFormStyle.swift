import AppKit
import DetailPanel

// What the form's look is made of, in view points: a row is 22 tall in a card of 240 to 480, 360 at
// most (the fold's 320), the name at the left, muted, the value after it. Colors come from the system's, so
// they follow the appearance; the needed amber and the wrong red are shared by every surface that marks a
// field.

extension TypesStyle {
    /// A line, in the card and in the panel.
    static let formRowHeight: CGFloat = 22
    /// The card's padding above and below the lines, and at the sides.
    static let formPadY: CGFloat = 6
    static let formPadX: CGFloat = 10
    /// A card is at least this wide, at most `formMaxWidth`, and 72 wider for each column of a table past four.
    public static let formMinWidth: CGFloat = 240
    public static let formMaxWidth: CGFloat = 480
    public static let formFreeColumns = 4
    public static let formWidthPerColumn: CGFloat = 72
    /// A card is at most this tall, and the fold's card this; then the lines scroll.
    public static let formMaxHeight: CGFloat = 360
    public static let formFoldMaxHeight: CGFloat = 320
    /// The most of the width a name takes.
    static let formNameShare: CGFloat = 0.45
    /// The panel's form works from this wide, and indents each level by `formIndent`.
    public static let formPanelMinWidth: CGFloat = 140
    static let formIndent: CGFloat = 12
    /// Between a name and its value, and between the cells of a table.
    static let formGap: CGFloat = 8
    /// The triangle's place before a line that opens, and the check's before a check line.
    static let formTriangleWidth: CGFloat = 14
    static let formCheckWidth: CGFloat = 18
    static let formBoxSize: CGFloat = 14
    /// The most of a long cell a table's measure looks at: sizes read the first lines only.
    static let formMeasuredLines = 200

    static let formCardFont = NSFont.systemFont(ofSize: 13)
    static var formPanelFont: NSFont { DetailStyle.textFont }
    static let formNameInk = NSColor.secondaryLabelColor
    static let formValueInk = NSColor.labelColor
    static let formFaintInk = NSColor.tertiaryLabelColor
    /// A needed field with nothing in it, and a value that breaks a rule: shared by rows, card and panel.
    public static let neededInk = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 1.0, green: 0.72, blue: 0.25, alpha: 1) : NSColor(srgbRed: 0.72, green: 0.42, blue: 0.0, alpha: 1)
    }
    public static let wrongInk = NSColor.systemRed

    /// The chip: its height, its text, its padding, and a dashed one's (a type that is gone).
    static let formChipHeight: CGFloat = 18
    static let formChipFont = NSFont.systemFont(ofSize: 11)
    static let formChipPad: CGFloat = 7
    static let formChipFill: CGFloat = 0.14
    static let formChipStroke: CGFloat = 0.45
    /// The needed dot after a name on a type's note.
    static let formDot: CGFloat = 5
    /// The check, the wavy underline's wave.
    static let formWaveStep: CGFloat = 2.5
    static let formWaveHeight: CGFloat = 1.5
    /// The focus's outline around a cell.
    static let formFocusWidth: CGFloat = 1.5
    static let formFocusRadius: CGFloat = 4
    static let formDimmed: CGFloat = 0.45
}
