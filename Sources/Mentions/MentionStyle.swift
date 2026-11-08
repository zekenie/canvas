import AppKit
import DetailPanel
import Titles

/// Mentions' UI constants. A pill's metrics are fractions of its text's font size (an em), so a
/// pill fits whatever text it's in: the values in comments are for a note's 16-point text in its
/// fixed 19-point lines, where a 17-point pill leaves every line as tall as it was, in string
/// drawing and in TextKit 2 alike. Other owners add theirs in extensions, in their own files.
@MainActor
enum MentionStyle {
    // MARK: The pill

    /// Its height: 17 points at 16.
    static let pillHeight: CGFloat = 17.0 / 16
    /// How far above the font's descender its bottom is: half a point at 16.
    static let pillBottomAboveDescender: CGFloat = 0.5 / 16
    /// Room at each end: 0.3 em.
    static let pillPadding: CGFloat = 0.3
    /// The kind's symbol, semibold: 0.7 em.
    static let symbolSize: CGFloat = 0.7
    /// The room the symbol is centered in, whatever its kind's: 1 em, as wide as the widest shipped
    /// symbol is at 0.7 (a frame's `rectangle.dashed`, 16 points at 16; a wider one is drawn smaller
    /// to fit). So a live pill is as wide as its label makes it, and text measured from itself alone,
    /// where no shape is looked up, is as wide as it's drawn (`MentionTextStyle.measuredString`).
    static let symbolSlot: CGFloat = 1
    /// Between the symbol and the label: 0.2 em.
    static let symbolGap: CGFloat = 0.2
    /// The label, medium: 0.85 em.
    static let labelSize: CGFloat = 0.85
    /// Its corners: 4 points at 16.
    static let cornerRadius: CGFloat = 4.0 / 16
    /// The widest a pill is, unless its text is narrower: 16 em. A longer label ends in "…".
    static let maxWidth: CGFloat = 16
    /// A row's chip lead in a live pill of a row (an endpoint's method, `PartLead.chip`), in the symbol's place: its word bold
    /// and white at 0.6 em on the chip's color, 0.25 em in, 0.75 em tall, rounded 0.15 em, 0.25 em before the label. Its
    /// colors are the row's, the same on every surface (as the row draws it).
    static let chipLabelSize: CGFloat = 0.6
    static let chipPadding: CGFloat = 0.25
    static let chipHeight: CGFloat = 0.75
    static let chipRadius: CGFloat = 0.15
    static let chipGap: CGFloat = 0.25

    /// On a shape's surface, colors are the text's own at these strengths, since a tint on a
    /// tinted shape (yellow on a yellow note) would vanish.
    static let shapeFill: CGFloat = 0.10
    static let shapeSymbol: CGFloat = 0.65
    /// A pill naming a shape that isn't there, or can't be mentioned: no fill, a dashed stroke at
    /// this strength, 1 point wide, and the label, in italic, at about two thirds: the name it holds
    /// is the only record of what was mentioned, so it reads at 4.6:1 on a note's yellow (half was
    /// 3:1), while the dashes and the italic say it's gone.
    static let missingStroke: CGFloat = 0.35
    static let missingStrokeWidth: CGFloat = 1
    static let missingDash: [CGFloat] = [2, 2]
    static let missingLabel: CGFloat = 0.65

    /// An outlined pill (a value that points at a shape): white, with the text's color at this strength as a
    /// hairline this wide.
    static let outlinedFill = NSColor.white
    static let outlinedStroke: CGFloat = 0.2
    static let outlinedStrokeWidth: CGFloat = 0.5
    /// Its metrics, in ems: taller than a text pill's, ends fully round, the label as large as the text's.
    static let outlinedHeight: CGFloat = 1.2
    static let outlinedPadding: CGFloat = 0.55
    static let outlinedLabelSize: CGFloat = 0.9

    /// Below this many device pixels per point (25% zoom on a 1× screen), a pill draws only its
    /// fill (or its dashed outline): its text couldn't be read there.
    static let minDetailScale: CGFloat = 0.25

    /// What a pill naming a shape that isn't there says, where there's a tooltip, and what it
    /// shows when it holds no name.
    static let missingHelp = "Deleted"
    static let unavailableHelp = "Not available"

    // MARK: The picker

    /// Its size (`pickerMetrics`): its look is every caret list's (DetailPanel's `CaretListWindow`).
    static let pickerWidth: CGFloat = 280
    static let pickerRowHeight: CGFloat = 24
    static let pickerRowsShown = 8
    /// Below the `@`.
    static let pickerOffset: CGFloat = 4
    /// Where the picker looks for the shapes nearest the text's: a square this far out from its
    /// center, then four times as far, this many times or until a square holds as many shapes as
    /// the catalog, before the whole catalog.
    static let nearbySearch: CGFloat = 400
    static let nearbySearchSteps = 5
    /// The longest query: a whole title can be typed, and a character more closes the picker.
    static let queryLimit = TitleProperty.maxLength

    // MARK: In the panel

    /// Mention text in a panel box (`MentionTextArea`): the panel's text, in the label's color, on
    /// a neutral surface, where each pill's symbol takes its target's tint.
    static let panelText = MentionTextStyle(font: DetailStyle.textFont, color: .labelColor, surface: .neutral)
    /// A read-only box's text and pills, dimmed together: about the secondary label's strength.
    static let disabledOpacity: CGFloat = 0.5

    // MARK: What mentions a shape

    /// About how many characters of a mentioner's text a list of what mentions a shape quotes around
    /// its mention.
    static let quoteLength = 60
    /// The symbol of a mentioner whose kind has no placing tool.
    static let unknownSymbol = "square.dashed"
    /// The canvas's context menu item, and a pill's in text.
    static let showWhatMentions = "Show What Mentions"
    /// Go › Go to Mention, which follows the pill on the caret.
    static let goToMention = "Go to Mention"
    static func showWhatMentions(_ label: String) -> String { "Show What Mentions “\(label)”" }
}

extension MentionTextStyle {
    /// Mention text in the panel, as `MentionTextArea` sets it: the panel's font, the label's color, a neutral surface,
    /// so pills are tinted. For another plugin's box over a `MentionTextView` (a rule's).
    @MainActor public static var panel: MentionTextStyle { MentionStyle.panelText }
}
