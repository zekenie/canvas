import AppKit
import Chrome
import SwiftUI

/// Find's look and its budgets.
@MainActor
public enum FindStyle {
    // MARK: Highlights

    /// A hit, as a highlighter marks it: an orange, multiplied over the shape, which reads on a
    /// note's yellow (a browser's yellow there would vanish) and a card's white alike, in either
    /// appearance (both surfaces are the same in dark mode), the text over it as dark as it was.
    static let hit = CGColor(srgbRed: 1, green: 0.66, blue: 0.24, alpha: 1)
    /// The current hit: a deeper orange, and a thin line round it.
    static let current = CGColor(srgbRed: 1, green: 0.46, blue: 0.06, alpha: 1)
    static let currentLine = CGColor(srgbRed: 0.85, green: 0.3, blue: 0, alpha: 1)
    /// View points.
    static let currentLineWidth: CGFloat = 1.5
    /// A hit over the canvas (an arrow's label), whose color follows the appearance: a wash.
    static let washHit = CGColor(srgbRed: 1, green: 0.6, blue: 0.1, alpha: 0.4)
    static let washCurrent = CGColor(srgbRed: 1, green: 0.5, blue: 0.05, alpha: 0.7)
    /// A hit on a dark badge (a title's pill): a ring, view points out from it and wide.
    static let ringWidth: CGFloat = 2
    static let ringCurrentWidth: CGFloat = 3
    static let ringGap: CGFloat = 1
    /// How far a hit's highlight reaches past its glyphs, each side, view points: a little, as a
    /// pen's would.
    static let pad: CGFloat = 1.5
    static let corner: CGFloat = 2.5
    /// Zoomed out, where shapes are skeletons with no text: a shape with hits washed lightly, so a
    /// title said on it still reads, and the current one lined round in `currentLine` (view points
    /// wide, and out from its edge), never washed deeper.
    static let zoomedOutHit = CGColor(srgbRed: 1, green: 0.58, blue: 0.12, alpha: 0.35)
    static let zoomedOutLineWidth: CGFloat = 2
    static let zoomedOutLineGap: CGFloat = 2
    /// A shape this many device pixels across or less is tinted as its bounds, under one its pixel
    /// (`Silhouettes.form`'s rule).
    static let pixelForm: CGFloat = 1
    /// A shape's label frame is the same place when it has moved less than this, world units: what
    /// a move's arithmetic loses.
    static let labelTolerance: CGFloat = 0.001

    // MARK: Budgets

    /// A frame lays out hits for this long at most; the shapes it had no time for are tinted as
    /// zoomed out, and the next frame goes on.
    static let layoutBudget: Duration = .milliseconds(2)
    /// The index builds a slice of the main actor this long at a time.
    static let buildSlice: Duration = .milliseconds(2)
    /// Typing's current hit: this many results on the board shown are asked their bounds before the
    /// shapes in view are looked up among the results instead.
    static let landingProbe = 64
    /// At most this much of what's selected is what's typed.
    static let longestSeed = 200

    // MARK: The panel

    /// Rows listed at once, around the current one: a lazy list of thousands still costs each row's
    /// identity on every change.
    static let rowWindow = 200
    /// Page Up and Page Down in the field move this many results.
    static let pageRows = 8
    static let rowHeight: CGFloat = 36
    static let rowSpacing: CGFloat = 2
    static let rowSymbolWidth: CGFloat = 16
    static let rowCorner = ChromeStyle.itemCorner
    static let rowSelected = Color.accentColor.opacity(0.18)
    static let headerHeight: CGFloat = 24
    static let fieldSpacing: CGFloat = 6
    static let buttonSpacing: CGFloat = 2
    static let snippetBefore = 24
    static let snippetLength = 120
    static let count = Font.system(size: 11).monospacedDigit()
    static let snippet = Font.system(size: 11)
    static let snippetHit = Font.system(size: 11, weight: .semibold)
    /// A titled shape's name, leading its row before the snippet of a hit elsewhere in it, and what comes between them.
    static let rowName = Font.system(size: 11, weight: .medium)
    /// The same as an AppKit font, to measure a name against `rowNameMost`.
    static let rowNameFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let nameGap = "  "
    /// The same between a row's name and its snippet, as two texts in the row.
    static let nameSpacing: CGFloat = 6
    /// How wide a shape's name in its row is at most, whole up to it, before the hit's words after it are cut: about half
    /// the panel's row, so "orders API" reads before "POST /orders/{id}/refunds".
    public static let rowNameMost: CGFloat = 150

    /// The width a name is given in its row: its own, up to `rowNameMost`. Set outright, so the text is asked to fit it and
    /// cuts itself in the middle; a frame that only caps a text taking its ideal width would let it run on past the cap.
    public static func rowNameWidth(_ name: String) -> CGFloat {
        min(ceil(NSAttributedString(string: name, attributes: [.font: rowNameFont]).size().width) + 1, rowNameMost)
    }
    static let boardTitle = Font.system(size: 11, weight: .semibold)
    static let tally = Font.system(size: 10).monospacedDigit()
    static let noMatchesFont = Font.system(size: 13)
    /// What the list says when nothing matches, as Jump To's and the @ picker's do.
    static let noMatches = "No matches"
    /// The field's well.
    static let fieldFill = Color.primary.opacity(0.06)
}

extension Duration {
    /// As whole nanoseconds, for comparing with a thread's clock.
    var nanoseconds: UInt64 {
        let (seconds, attoseconds) = components
        return UInt64(max(0, seconds)) * 1_000_000_000 + UInt64(max(0, attoseconds) / 1_000_000_000)
    }
}
