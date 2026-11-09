import AppKit
import Palette

/// What every kind of the kit shares in how it looks: the paper a table and an enum are drawn on, the rows on it, and
/// the inks and the colors of the marks. World units, the model's, as a note's are. The paper is the same in both
/// appearances, as a note's is, so the inks on it are fixed; the colors of marks and pills are Palette's swatches of
/// the hues the frames drew, which keep each hue and pass the contrast floors (decided 25: the frames' gold key mark
/// measured 2.9 on the paper).
@MainActor
public enum KitStyle {
    /// The paper, #EBEBEB, in both appearances.
    public static let paper = RGB(hex: 0xEBEBEB)
    public static let cornerRadius: CGFloat = 6
    /// Between two rows' tops.
    public static let rowHeight: CGFloat = 24
    /// Above the first row and below the last.
    public static let topInset: CGFloat = 8
    public static let bottomInset: CGFloat = 12
    /// Where a row's name starts, from the paper's left edge: after the gutter its marks are in.
    public static let nameInset: CGFloat = 35
    /// Where the gutter's mark is centered, from the paper's left edge.
    public static let gutterMiddle: CGFloat = 19
    /// Between the paper's right edge and a type's end.
    public static let trailingInset: CGFloat = 14
    /// Between a name and the type after it, at least: a type that would come closer is cut short.
    public static let nameGap: CGFloat = 10
    /// How tall Find's mark over a hit in a row is: the row's text, not the row.
    public static let findHitHeight: CGFloat = 20
    /// What ends a fold's "+N ›" line.
    public static let moreChevron = "›"

    /// A row's name, 15 points, in the paper's ink.
    public static let nameFont = NSFont.systemFont(ofSize: 15)
    /// A type, an enum's value: monospaced, 13 points.
    public static let typeFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    public static let valueFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    /// An API's code (a path, the server, a status): monospaced, 14 points.
    public static let codeFont = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
    /// A method's chip's text: bold caps, 10 points.
    public static let chipFont = NSFont.systemFont(ofSize: 10, weight: .bold)
    /// A line's placeholder (an API's faint "server"): the code's font, slanted.
    public static let placeholderFont = NSFontManager.shared.convert(codeFont, toHaveTrait: .italicFontMask)

    /// The ink names are drawn in: #111113.
    public static let ink = RGB(hex: 0x111113)
    /// The grey a type is drawn in: the frames' #848488 made as dark as text needs to read on the paper.
    public static let secondaryInk = Swatch.reading(RGB(hex: 0x848488), against: [paper], atLeast: Swatch.textContrast)

    /// The hues the frames drew, each made into its roles on the paper (a mark, a pill in a row) or on the canvas (a
    /// title's pill): the key mark's gold, the link's blue, an enum's purple.
    public static let keyGold = RGB(hex: 0xAE8302)
    nonisolated public static let linkBlue = RGB(hex: 0x2C72DB)
    public static let enumPurple = RGB(hex: 0xA23BD0)
    /// A hue's roles drawn on the paper: the paper is the ground and the raised surface both.
    public static func onPaper(_ color: RGB) -> Swatch { Swatch(color, on: Tone(paper), raised: Tone(paper)) }

    /// A key's line, world units: narrower than an arrow's 3.5, as the frames draw keys (arrow-look §0). Lines stay ink.
    public static let keyLineWidth: CGFloat = 2.5

    /// A shape of the kit zoomed out on the light canvas: its paper is ringed in this, so #EBEBEB stays seen on white, as a
    /// type's note is.
    public static let skeletonEdge = NSColor(white: 0, alpha: 0.16)
    /// That ring's width, view points.
    public static let skeletonEdgeWidth: CGFloat = 1

    /// A gutter mark's size (a primary key's key, a unique column's "1").
    public static let markSize: CGFloat = 13
    /// How far round a gutter mark a press drags its row (its lead): a square this wide on the mark's middle, a row tall.
    public static let leadSide: CGFloat = 24

    /// Zoomed out: a bar where a name is, the names' 15-point text greeked (0.52 em a column), each bar where the text's
    /// x-height is, 8 tall.
    public static let skeletonNameColumn: CGFloat = 0.52 * 15
    public static let skeletonBarHeight: CGFloat = 8
    /// The most columns a bar stands for, so a name of hundreds of characters costs what one of twenty does.
    public static let skeletonMostColumns = 40
    /// The least a row is on screen, view points, for a skeleton to draw its bars: under it (about 12%, a row three pixels
    /// tall) the paper and its title bar say it, for every kind written as lines (tables, enums, APIs).
    public static let skeletonLeastRow: CGFloat = 3

    /// The paper's path at `rect`.
    public static func paperPath(_ rect: CGRect) -> CGPath {
        let radius = max(0, min(cornerRadius, rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// How tall a shape of `rows` rows is: the insets and a row each, and room for one when there are none.
    public static func height(rows: Int) -> CGFloat {
        topInset + rowHeight * CGFloat(max(rows, 1)) + bottomInset
    }

    /// The rect of row `index` on paper at `frame`: as wide as the paper, `rowHeight` tall.
    public static func rowRect(_ index: Int, in frame: CGRect) -> CGRect {
        CGRect(x: frame.minX, y: frame.minY + topInset + CGFloat(index) * rowHeight, width: frame.width, height: rowHeight)
    }

    /// The rows of a shape at `frame` that `visible` reaches, as indices into `count`: what a render draws, so a table of
    /// hundreds of rows costs the rows in view.
    public static func rows(_ count: Int, in frame: CGRect, reaching visible: CGRect) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        // Clamped as doubles first: a clip with no bounds (an infinite rect) is every row, never an Int out of range.
        let top = visible.minY - frame.minY - topInset, bottom = visible.maxY - frame.minY - topInset
        let first = Int(max(0, min(Double(count), Double((top / rowHeight).rounded(.down)))))
        let last = Int(max(0, min(Double(count), Double((bottom / rowHeight).rounded(.up)))))
        return first < last ? first..<last : 0..<0
    }
}
