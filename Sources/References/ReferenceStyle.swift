import AppKit
import Chrome
import Palette
import TextEditing

/// The pill's look. World units, so at 100% they are view points. Its colors are semantic or
/// dynamic, resolved as it's drawn, so the dark appearance follows by itself.
@MainActor
enum ReferenceStyle {
    // MARK: The capsule

    /// The pill's height, and so its corners' radius: a capsule. Tall enough for the place over the name.
    static let height: CGFloat = 40
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
    /// What surrounds the room a pill's text has: the leading pad, the symbol, the gap and the trailing pad. A pill's
    /// width is this and the wider of its name (and what trails it) and its place's line.
    static let padding: CGFloat = leadingPad + symbolBox + gap + trailingPad
    /// The room a place's line is folded in when a pill is fitted: the widest a pill is, less the padding.
    static let placeRoomMost: CGFloat = maxWidth - padding
    /// A direct pill reserves room for what may come to trail it (the eye of a shape gone private, a
    /// channel's warning): the gap and the glyph, so neither cuts a short name short.
    static let glyphRoom: CGFloat = gap + eyeSize
    // MARK: The count

    /// The count a pill that stands for every match trails ("12", "1.2k"), and the "0" of one that
    /// found none: a capsule 18 tall, its digits 11 semibold, 6 either side, on the label's color at 8%.
    static let badgeHeight: CGFloat = 18
    static let badgePad: CGFloat = 6
    static let badgeFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
    static let badgeFill = NSColor.labelColor.fading(to: 0.08)
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
    /// The face the leading symbol's button has around the symbol, in view points: the box and this
    /// margin all round (divided by the zoom, in world units).
    static let goMargin: CGFloat = 4

    // MARK: Type and symbols

    static let labelFont = NSFont.systemFont(ofSize: 14, weight: .medium)
    /// A row's lead drawn as its chip (an endpoint's method): bold small text, white on the chip, 16 tall, 5 in, rounded 3, and
    /// the gap before the rest of the name.
    static let chipFont = NSFont.systemFont(ofSize: 10, weight: .bold)
    static let chipHeight: CGFloat = 16
    static let chipPadding: CGFloat = 5
    static let chipRadius: CGFloat = 3
    static let chipGap: CGFloat = 6
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
    /// In light the system orange reads 1.7:1 on a wash, so it is `#B96B00` there (3:1 on every wash); the dark keeps the system's.
    static let warningTint = NSColor(light: RGB(hex: 0xB96B00), dark: RGB(hex: 0xFF9F0A))
    /// Where a pill's original is, when that isn't where the pill is (its place, "Alpha › Beta", the board it is on
    /// leading when no step opens one): the fold of its steps (Chrome's `PlaceFold`) in the pill's room, set in SF 11
    /// regular over the name, a board's name semibold.
    static let placeFont = NSFont.systemFont(ofSize: 11, weight: .regular)
    static let placeBoardFont = NSFont.systemFont(ofSize: 11, weight: .semibold)
    /// The width of text in the place's line, to a whole point, a board's name in its own weight: what `PlaceFold` is given.
    static func placeWidth(_ text: String, isBoard: Bool) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: isBoard ? placeBoardFont : placeFont]).size().width)
    }
    /// A place's steps folded in `room` points, in the pill's fonts: the line a pill is fitted for (the fold in the most room a
    /// pill has, `placeRoomMost`) wherever that fits in `room`, so a pill fitted to its place draws the very line its width was
    /// made for (a fold in exactly the width the line came to can cut a name shorter, since a cut backs up to a word); else
    /// the fold in `room`.
    static func placeLine(_ steps: [PlaceStep], room: CGFloat) -> PlaceLine {
        func fold(_ room: CGFloat) -> PlaceLine { PlaceFold.line(for: steps, room: room) { placeWidth($0, isBoard: $1) } }
        guard room >= PlaceFold.leastRoom, room < placeRoomMost else { return fold(room) }
        let fitted = fold(placeRoomMost)
        return fitted.width <= room ? fitted : fold(room)
    }
    /// The place line's text: the label's color at 60%; the `›` and `…` between and an untitled container's name at 30%.
    static let placeColor = NSColor.labelColor.fading(to: 0.6)
    static let placeFaintColor = NSColor.labelColor.fading(to: 0.3)
    /// From this zoom up the pill has both lines; under it (down to the skeleton's) the name alone, centered.
    static let placeZoom: CGFloat = 0.6
    static func showsPlace(atZoom zoom: CGFloat) -> Bool { zoom >= placeZoom - 0.0005 }
    /// Where the lines' baselines are in the pill's 40: the place's, and the name's under it. Strings and the editor both
    /// set a baseline the ascender, rounded up, below a line's top (`lineTop`).
    static let placeBaseline: CGFloat = 16
    static let nameBaseline: CGFloat = 31
    static let placeTop = placeBaseline - ceil(placeFont.ascender)
    static let nameTop = nameBaseline - ceil(labelFont.ascender)
    static let placeLineHeight = ceil(placeBoardFont.ascender - placeBoardFont.descender)
    /// A line the label sits on as the render and the editing view lay it out: its font's, rounded up.
    static let lineHeight = ceil(labelFont.ascender - labelFont.descender)
    /// On two lines, a row's chip starts this far down the pill at the least: a point below the place line's descenders.
    static let chipBelowPlace = placeBaseline + ceil(-placeFont.descender) + 1

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
    /// The table of contents' row its rows gather under at each level (`ContentsSections`), so a frame's
    /// many pills don't crowd out what it holds.
    static let sectionTitle = "References"

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
    /// The edge and the dashes of a pill wearing no color: the label's color at 45% (3:1 and better on either canvas).
    static let neutralStrength: CGFloat = 0.45
    static let dashStrength: CGFloat = neutralStrength
    /// The count's capsule on a colored pill: its color's `solid` at 30%. A block zoomed out is `solid` at 50% over the canvas,
    /// and a pill that stands for nothing, zoomed out, a lighter one still.
    static let badgeStrength: CGFloat = 0.3
    /// A pill for every match wears the color they share, looked for among this many matches at most (past it, gray): a scan of
    /// 2,000 costs some 2 ms, once an answer.
    static let sharedColorMost = 2_000
    static let skeletonStrength: CGFloat = 0.5

    // MARK: Colors

    static let fill = NSColor(name: nil) {
        $0.isDark ? NSColor(srgbRed: 0x2C / 255, green: 0x2C / 255, blue: 0x2E / 255, alpha: 1) : .white
    }
    /// The dashes of a pill that stands for nothing, and the edge of one wearing no color: the label's color at 45%.
    static let dash = NSColor.labelColor.fading(to: dashStrength)
    static let border = NSColor.labelColor.fading(to: neutralStrength)
    static let label = NSColor.labelColor
    static let secondary = NSColor.secondaryLabelColor
    static let placeholderColor = NSColor.placeholderTextColor

    /// Under the pointer on the leading symbol: the accent, and a step darker while it's pressed.
    static let goColor = NSColor.controlAccentColor
    static let goPressedColor = NSColor(name: nil) { appearance in
        NSColor.resolved(in: appearance) { NSColor.controlAccentColor.blended(withFraction: 0.25, of: .black) ?? .controlAccentColor }
    }

    /// The pill's fill and border as the appearance being drawn in has them, worked out once for each
    /// appearance: a dynamic color asked its `cgColor` runs its provider, and a frame draws a thousand.
    struct Surface {
        let fill: CGColor
        let border: CGColor
        let dash: CGColor
        let badge: CGColor
        /// Whether the appearance is dark: asked once an appearance, not once a pill.
        let dark: Bool
    }

    private static var surfaces: [NSAppearance.Name: Surface] = [:]

    static var surface: Surface {
        let appearance = NSAppearance.currentDrawing()
        if let found = surfaces[appearance.name] { return found }
        let made = Surface(fill: fill.cgColor, border: border.cgColor, dash: dash.cgColor, badge: badgeFill.cgColor, dark: appearance.isDark)
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
    /// What VoiceOver calls the list (its words row is Mentions', `MentionPicker.wordsItem`).
    static let pickerAccessibilityLabel = "References"

    // MARK: Copy

    /// What the pointer resting on a pill that stands for nothing says.
    static let helpFont = NSFont.systemFont(ofSize: 11)
    static let helpNameFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let deletedHelp = "Deleted"
    static let unavailableHelp = "Not available"
    static let privateHelp = "Not public"

    /// What a status line calls a shape with no name.
    static let unnamed = "Shape"
    /// The line of a pill that stands for shapes that don't take an attached arrow's channel:
    /// `“Order” doesn’t take note links.`
    static func mismatchLine(name: String, channels: String) -> String { "“\(name)” doesn’t take \(channels)." }

    /// Menu items and the panel's button.

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
    /// What a query found that isn't public, so the reference doesn't stand for it, and the step that
    /// makes it public (the words of Publishing's own).
    static func notPublic(_ count: Int) -> String { "\(count) not public" }
    static let makePublic = "Make Public"
    /// Turning words into a query: the button that starts it, its symbol, and the undo step it lands
    /// as (what's said while it's under way, and of its failures, is every host's: `InterpretationWords`).
    static let interpret = "Interpret"
    static let interpretSymbol = "sparkles"
    static let interpretStep = "Interpret"
    static let noMatches = "No matches"
    /// The Query section's rows apart (its query box and the rows of what it found are QueryTranslation's:
    /// `InterpretationStyle`).
    static let panelSpacing: CGFloat = 8

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

    // MARK: Mirrors

    /// The pill sits this far in from the mat's left edge, as a tab sits on a folder; the frame is at least the pill and
    /// this either side wide.
    static let mirrorPillInset: CGFloat = 16
    /// The body's room inside the mat, at its sides and under it.
    static let mirrorPadding: CGFloat = 10
    /// Between the pill's bottom and the body's top.
    static let mirrorGap: CGFloat = 8
    /// The mat's corners.
    static let mirrorRadius: CGFloat = 12
    /// A mirror made by Expand draws its original at its own size, or smaller so its body fits this.
    static let mirrorFirstFit = CGSize(width: 480, height: 360)
    /// How small and how large a mirror's scale goes, its handles' and a script's.
    nonisolated static let mirrorScales: ClosedRange<CGFloat> = 0.1...4
    /// The smallest a mirror's handles make its frame: the pill and its insets across.
    static let mirrorMinimumSize = CGSize(width: 96, height: 72)
    /// The quieting: the body's colors pulled toward gray to this saturation, then this far toward the canvas.
    static let mirrorSaturation: CGFloat = 0.45
    static let mirrorTowardCanvas: CGFloat = 0.12
    /// What the menus and the command bar call it, and its undo steps.
    static let expand = "Expand"
    static let collapse = "Collapse"
    static let expandStep = "Expand Reference"
    static let collapseStep = "Collapse Reference"
    /// What VoiceOver calls a reference shown as a mirror, where a pill is "Reference".
    static let mirrorKind = "Mirror"

    // MARK: Shapes

    static func capsule(_ rect: CGRect) -> CGPath {
        let radius = min(rect.height, rect.width) / 2
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
