import AppKit
import Palette
import TextEditing

/// The pill's look. World units, so at 100% they are view points. Its colors are semantic or
/// dynamic, resolved as it's drawn, so the dark appearance follows by itself.
@MainActor
enum ReferenceStyle {
    // MARK: The capsule

    /// The pill's height, and so its corners' radius: a capsule.
    static let height: CGFloat = 32
    static let radius: CGFloat = height / 2
    /// What a click with the Reference tool puts down, and what an empty pill is.
    static let defaultWidth: CGFloat = 120
    /// A pill is never narrower or wider than this, whatever its label: a longer one ends in "…".
    static let minWidth: CGFloat = 64
    static let maxWidth: CGFloat = 280

    /// Left of the symbol (or of the label, with none), and right of the label's room.
    static let leadingPad: CGFloat = 10
    static let trailingPad: CGFloat = 14
    /// The symbol's box, and the gap between it and the label.
    static let symbolBox: CGFloat = 16
    static let gap: CGFloat = 6
    /// A dynamic pill always reserves room for its widest badge, "9.9k" (some 37 points, its pads in):
    /// the gap and the badge. A count of 100,000 or a million ("120k", "1.2M") reaches a point or three
    /// into the gap.
    static let badgeRoom: CGFloat = 6 + 37
    /// A direct pill reserves room for what may come to trail it (the eye of a shape gone private, a
    /// channel's warning): the gap and the glyph, so neither cuts a short name short.
    static let glyphRoom: CGFloat = gap + eyeSize
    // MARK: The count

    /// The count a pill that stands for every match trails ("12", "1.2k"), and the "0" of one that
    /// found none: a capsule 18 tall, its digits 11 semibold, 6 either side, on the label's color at 8%.
    static let badgeHeight: CGFloat = 18
    static let badgePad: CGFloat = 6
    static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    static let badgeFill = fading(NSColor.labelColor, to: 0.08)
    /// What a count reads in its capsule: as it is below a thousand, then in thousands with a tenth
    /// below ten thousand ("1.2k", "9.9k") and whole above ("12k", "999k"), then in millions alike
    /// ("1.2M", "12M"); cut down, never rounded up, so it never says more than were found. The panel
    /// says the count whole.
    static func badge(_ count: Int) -> String {
        func cut(_ count: Int, _ unit: Int, _ suffix: String) -> String {
            guard count < unit * 10 else { return "\(count / unit)\(suffix)" }
            let tenths = count / (unit / 10)
            return tenths % 10 == 0 ? "\(tenths / 10)\(suffix)" : "\(tenths / 10).\(tenths % 10)\(suffix)"
        }
        if count < 1_000 { return "\(count)" }
        return count < 1_000_000 ? cut(count, 1_000, "k") : cut(count, 1_000_000, "M")
    }
    /// The first match's kind symbol, trailing a pill that stands for it alone.
    static let firstSize: CGFloat = 13

    // MARK: Finding

    /// How long a pill's answers wait for quiet after a commit (each commit waits again), how long an
    /// answer is out before it's said to be looked for ("Finding…"), how many matches a first-match
    /// pill is given (the first, and what All would add, for the panel; an All one is given every
    /// match), how many answers each keeps for its undo and redo, and for how many references answers
    /// are kept at all, deleted ones' too, and how many shapes all the answers kept may name between
    /// them (16 MB of ids), however many a query finds: the least recently landed or used let go
    /// first, never the one just landed.
    static let settle: Duration = .milliseconds(250)
    static let findingDelay: Duration = .milliseconds(250)
    static let firstFetched = 8
    static let answersKept = 4
    static let memosKept = 256
    static let memoIDsKept = 1_000_000
    /// How long the words a person types rest, with nothing public to pick, before they're turned
    /// into a query (and each keystroke starts the wait again).
    static let interpretDelay: Duration = .milliseconds(600)

    /// The face the leading symbol's button has around the symbol, in view points: the box and this
    /// margin all round (divided by the zoom, in world units).
    static let goMargin: CGFloat = 4

    // MARK: Type and symbols

    static let labelFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    /// What a pill that stands for nothing says, in italic.
    static let missingFont: NSFont = {
        let descriptor = labelFont.fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: labelFont.pointSize) ?? labelFont
    }()
    static let symbolSize: CGFloat = 13
    static let symbolWeight = NSFont.Weight.medium
    /// The trailing eye of a pill whose target went private.
    static let eyeSize: CGFloat = 11
    static let eyeSymbol = "eye.slash"
    /// The eye is the label's color a little softened, not the secondary: on the dashed pill's
    /// dimmed text a secondary eye all but vanishes in light mode.
    static let eyeColor = NSColor.labelColor
    static let eyeStrength: CGFloat = 0.7
    /// What trails a pill that stands for shapes that don't take the channel of an arrow attached
    /// to it, and a translation that failed: a warning, always its own orange.
    static let warningSymbol = "exclamationmark.triangle.fill"
    static let warningSize: CGFloat = 11
    static let warningTint = NSColor.systemOrange
    /// Where a pill's note is, when that isn't where the pill is (its path, "Alpha › Beta", or the name of its board):
    /// gray, after the note's name, a gap from it, in what room the pill's width leaves (cut at its end, and left out when
    /// less than `boardRoomLeast` remains). A pick from the list fits the pill's width to it too.
    static let boardFont = NSFont.systemFont(ofSize: 14, weight: .regular)
    static let boardGap: CGFloat = 6
    static let boardRoomLeast: CGFloat = 24
    static let boardColor = NSColor.tertiaryLabelColor
    /// A line the label sits on as the render and the editing view lay it out: its font's, rounded up.
    static let lineHeight = ceil(labelFont.ascender - labelFont.descender)

    /// Where a line of `font` starts in a box `height` tall: its capitals centered, as the symbols
    /// beside them are, on a whole point. String drawing and the editor both set the baseline the
    /// ascender, rounded up, below the line's top. Centering the whole line, descender and all, sets
    /// the letters a point low.
    static func lineTop(of font: NSFont, in height: CGFloat) -> CGFloat {
        ((height + font.capHeight) / 2 - ceil(font.ascender)).rounded()
    }

    /// The kind's symbol: its tool, its row (while it names nothing), its panel (an empty pill).
    static let systemImage = "arrow.turn.up.right"
    /// What a pill that stands for what a query finds leads with, however many it finds.
    static let dynamicSymbol = "magnifyingglass"
    /// The magnifier's color and strength: the label's color at 70%.
    static let dynamicTint = NSColor.labelColor
    static let dynamicStrength: CGFloat = 0.7
    /// What a pill that stands for something that isn't there leads with.
    static let missingSymbol = "square.dashed"
    /// What the leading symbol turns into under the pointer, which clicking goes to the original by.
    static let goSymbol = "arrow.up.forward.circle.fill"

    /// What an empty pill says, dimmed.
    static let placeholder = "Reference"

    // MARK: Strengths

    /// The kind's tint is blended this far toward the label's color, so a symbol is the kind's and
    /// reads on the pill's surface.
    static let tintBlend: CGFloat = 0.4
    /// A pill that stands for nothing: its label and symbol at this strength, italic, in a dashed
    /// border with no fill.
    static let missingStrength: CGFloat = 0.65
    /// A pill whose words are being interpreted or searched for stands for nothing yet: solid, its
    /// words at this strength.
    static let findingStrength: CGFloat = 0.5
    static let borderWidth: CGFloat = 1
    static let dashPattern: [CGFloat] = [2, 2]
    static let dashStrength: CGFloat = 0.35

    // MARK: Colors

    static let fill = NSColor(name: nil) {
        $0.isDark ? NSColor(srgbRed: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255, alpha: 1) : .white
    }
    /// The dashes of a pill that stands for nothing: the label's color at a third.
    static let dash = fading(NSColor.labelColor, to: dashStrength)
    static let border = NSColor(name: nil) { $0.isDark ? NSColor.white.withAlphaComponent(0.16) : NSColor.black.withAlphaComponent(0.14) }
    static let label = NSColor.labelColor
    static let secondary = NSColor.secondaryLabelColor
    static let placeholderColor = NSColor.placeholderTextColor

    /// Under the pointer on the leading symbol: the accent, and a step darker while it's pressed.
    static let goColor = NSColor.controlAccentColor
    static let goPressedColor = NSColor(name: nil) { appearance in
        resolved(in: appearance) { NSColor.controlAccentColor.blended(withFraction: 0.25, of: .black) ?? .controlAccentColor }
    }

    /// The pill's fill and border as the appearance being drawn in has them, worked out once for each
    /// appearance: a dynamic color asked its `cgColor` runs its provider, and a frame draws a thousand.
    struct Surface {
        let fill: CGColor
        let border: CGColor
        let dash: CGColor
    }

    private static var surfaces: [NSAppearance.Name: Surface] = [:]

    static var surface: Surface {
        let appearance = NSAppearance.currentDrawing()
        if let found = surfaces[appearance.name] { return found }
        let made = Surface(fill: fill.cgColor, border: border.cgColor, dash: dash.cgColor)
        surfaces[appearance.name] = made
        return made
    }

    // MARK: Zoomed out

    /// A skeleton's one square fill, and the lighter one for a pill that stands for nothing.
    static let skeletonFill = NSColor(name: nil) {
        $0.isDark ? NSColor(srgbRed: 0x4A / 255, green: 0x4A / 255, blue: 0x4E / 255, alpha: 1)
            : NSColor(srgbRed: 0xD8 / 255, green: 0xD8 / 255, blue: 0xDD / 255, alpha: 1)
    }
    static let skeletonMissingFill = NSColor(name: nil) {
        $0.isDark ? NSColor(srgbRed: 0x3A / 255, green: 0x3A / 255, blue: 0x3C / 255, alpha: 1)
            : NSColor(srgbRed: 0xEC / 255, green: 0xEC / 255, blue: 0xEF / 255, alpha: 1)
    }

    // MARK: Typing

    /// The most characters a pill's text takes.
    static let textLimit = 200
    /// The list over the field: its size is Mentions' `@` picker's, its look every caret list's.
    static let pickerWidth: CGFloat = 280
    static let pickerRowHeight: CGFloat = 24
    static let pickerRowsShown = 8
    static let pickerOffset: CGFloat = 4
    static let pickerMetrics = CaretListMetrics(width: pickerWidth, rowHeight: pickerRowHeight, rowsShown: pickerRowsShown, offset: pickerOffset)
    /// The most shapes the list shows when it has no typed text to rank by and none is near or recent.
    static let pickerRest = 50
    /// What the list says with no public shape in the file and nothing typed: dimmed, the one row.
    static let noPublicShapes = "No public shapes"
    /// What VoiceOver calls the list, and says of its last row.
    static let pickerAccessibilityLabel = "References"
    static let wordsSpoken = "Words"

    // MARK: Copy

    /// What the pointer resting on a pill that stands for nothing says.
    static let helpFont = NSFont.systemFont(ofSize: 11)
    static let deletedHelp = "Deleted"
    static let unavailableHelp = "Not available"
    static let privateHelp = "Not public"

    /// What a status line calls a shape with no name.
    static let unnamed = "Shape"
    /// The line of a pill that stands for shapes that don't take an attached arrow's channel:
    /// `“Order” doesn’t take note links.`
    static func mismatchLine(name: String, channels: String) -> String { "“\(name)” doesn’t take \(channels)." }

    /// Menu items and the panel's button.
    /// What the root board is called where a line names a shape's board (the pill, the header, a
    /// match's row): no owner gives it a name. Any other board is what Boards calls it.
    static let rootBoardName = "Board"

    static let goToOriginal = "Go to Original"
    static let showMatches = "Show Matches"
    static let matchAll = "Match All"
    static let matchFirst = "Match First"

    // MARK: The panel

    static let querySection = "Query"
    static let matchesSection = "Matches"
    static let matchLabel = "Match"
    static let allTitle = "All"
    static let finding = "Finding…"
    static let tooSlow = "Too slow"
    static let retry = "Retry"
    static let cantFind = "Unavailable"
    /// What a query found that isn't public, so the reference doesn't stand for it, and the step that
    /// makes it public (the words of Publishing's own).
    static func notPublic(_ count: Int) -> String { "\(count) not public" }
    static let makePublic = "Make Public"
    /// Turning words into a query: the status while it's under way, the button that starts it, its
    /// symbol, and the undo step it lands as; and what a failure of it says (a model's own failures
    /// say theirs).
    static let interpreting = "Interpreting…"
    static let interpret = "Interpret"
    static let interpretSymbol = "sparkles"
    static let interpretStep = "Interpret"
    static let notSignedIn = "Not signed in"
    static let keyRejected = "Key rejected"
    static let noQuery = "No query for these words"
    static let unusable = "Unusable answer"
    static let openSettings = "Open Settings…"
    static let noMatches = "No matches"
    /// The Query section's rows apart, its query box's least height, and the "and 42 more" under the
    /// matches: caption-sized, under their names (past the symbol's column and its gap).
    static let panelSpacing: CGFloat = 8
    static let queryBoxHeight: CGFloat = 20
    static let captionSize: CGFloat = 10
    static let moreIndent: CGFloat = 16 + 4
    /// The most matches the panel lists; past it, how many more there are.
    static let matchRows = 8
    static func more(_ count: Int) -> String { "and \(count) more" }

    /// The header's line under a dynamic reference that found shapes: "First of 7", "12 matches",
    /// "1,284 matches" (the count whole, as the locale writes it).
    static func matchesLine(_ found: ReferenceFound) -> String {
        if found.count == 1 { return "1 match" }
        return found.all ? "\(found.count.formatted()) matches" : "First of \(found.count.formatted())"
    }

    // MARK: The memo

    /// How many labels and symbols are kept built: more than a frame draws, so a frame builds none
    /// of them again; past it, they're let go of all at once.
    static let memoCapacity = 4096
    /// The device pixels to a point a symbol's bitmap is kept at: a frame draws from the next size up.
    static let rasterScales = [1, 2, 4, 8]

    // MARK: Shapes

    static func capsule(_ rect: CGRect) -> CGPath {
        let radius = min(rect.height, rect.width) / 2
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}

/// `color` at `strength` of its opacity, still following the appearance: a system color's
/// `withAlphaComponent` is fixed to the appearance it was made in.
func fading(_ color: NSColor, to strength: CGFloat) -> NSColor {
    NSColor(name: nil) { appearance in resolved(in: appearance) { color.withAlphaComponent(strength) } }
}

/// A color made as it is in `appearance`: the system's colors change with it.
func resolved(in appearance: NSAppearance, _ make: () -> NSColor) -> NSColor {
    var color = NSColor.clear
    appearance.performAsCurrentDrawingAppearance { color = make() }
    return color
}
