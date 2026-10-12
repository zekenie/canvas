import CoreGraphics

// Where a row's parts are: the one place that says, for the render, the faces and the rows view, from the
// block the rows are drawn in, whether it opens with a lead (the hairline and the gap under it), and how
// wide the name column is. A type's note and a note that is one share it, so a name is cut at the same
// place on both.

extension TypesStyle {
    /// The least width a note with rows reads at.
    public static let rowsMinimumWidth: CGFloat = 320
    /// One row: 22 points, its text 14.
    public static let rowHeight: CGFloat = 22
    public static let rowFontSize: CGFloat = 14
    /// Under the words, the hairline opens the rows and this much space follows it; none without words.
    public static let rowsLead: CGFloat = 8
    /// Between the name column and the value column.
    public static let nameGap: CGFloat = 12
    /// The name column is as wide as the longest name, at most this share of the rows' width.
    public static let nameShare: CGFloat = 0.45
    /// An inherited row's tick: this wide, this far left of the rows, in the padding.
    public static let tickWidth: CGFloat = 2
    public static let tickInset: CGFloat = 8
    /// Between a kind's label, its chip and the `›`.
    public static let partGap: CGFloat = 5
    /// The reading state's bars: this tall, as wide as these shares of the rows.
    public static let spotBarHeight: CGFloat = 6
    public static let spotBarShares: [CGFloat] = [0.56, 0.44, 0.52]
    /// Between a failure's reason and its action's words.
    public static let actionGap: CGFloat = 8
    /// Between the pills of a list of links, and before the `+N` that counts the rest.
    public static let linkGap: CGFloat = 6
}

@MainActor
struct RowGeometry {
    let block: CGRect
    /// Where the first row starts.
    let top: CGFloat
    /// The name column's width: the longest shown name's, at most `nameShare` of the block.
    let nameColumn: CGFloat

    init(block: CGRect, hasLead: Bool, longestName: CGFloat) {
        self.block = block
        top = block.minY + (hasLead ? TypesStyle.rowsLead : 0)
        nameColumn = min(longestName, TypesStyle.nameShare * block.width)
    }

    func rect(_ row: Int) -> CGRect {
        CGRect(x: block.minX, y: top + CGFloat(row) * TypesStyle.rowHeight, width: block.width, height: TypesStyle.rowHeight)
    }

    func nameRect(_ row: Int) -> CGRect {
        let rect = rect(row)
        return CGRect(x: rect.minX, y: rect.minY, width: nameColumn, height: rect.height)
    }

    func valueRect(_ row: Int) -> CGRect {
        let rect = rect(row)
        let start = rect.minX + nameColumn + TypesStyle.nameGap
        return CGRect(x: start, y: rect.minY, width: max(0, rect.maxX - start), height: rect.height)
    }
}
