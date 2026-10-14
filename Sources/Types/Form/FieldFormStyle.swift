import AppKit
import DetailPanel

// What the form's look is made of, in view points: a row is 22 tall in a card of 240 to 480, 360 at
// most (the fold's 320), the name at the left, muted, the value after it. Colors come from the system's, so
// they follow the appearance; the needed amber and the wrong red are shared by every surface that marks a
// field.

extension TypesStyle {
    /// A line, in the card and in the panel.
    public static let formRowHeight: CGFloat = 22
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
    /// The panel's JSON box: monospaced, 76 tall at least, growing to twelve lines, then it scrolls.
    public static let formJSONFont = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
    public static let formJSONMinHeight: CGFloat = 76
    public static let formJSONMaxLines = 12
    public static let formJSONPad: CGFloat = 5
    static let formJSONRadius: CGFloat = 5

    // What the rows on a note draw with too (`Rows/`): declared here, under them, since a card and the
    // panel mark a field as its row does and may name nothing of the rows'.

    /// A note's paper is light in both appearances, so the rows' inks are fixed colors, as the highlights
    /// are: the note's ink.
    static let rowInk = NSColor(white: 0.12, alpha: 1)
    /// A needed field's dot: the same amber as a rule's highlight and a warning.
    static let neededInk = NSColor(srgbRed: 0.96, green: 0.62, blue: 0.04, alpha: 1)
    /// A wrong value's red: as dark as it takes to read at 4.5 to 1 on a note's yellow and on white.
    static let wrongInk = NSColor(srgbRed: 0.74, green: 0.10, blue: 0.10, alpha: 1)
    /// A needed field's amber dot: this across, this far after its name.
    public static let neededDotSize: CGFloat = 5
    public static let neededDotGap: CGFloat = 5
    /// A wrong pill's wave starts and ends this far in from its ends, clear of the round corners.
    static let pillWaveInset: CGFloat = 7
}
