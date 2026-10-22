import CoreGraphics

// Where a row's parts are: the one place that says, for the render, the faces and the rows view, from the
// block the rows are drawn in, whether it opens with a lead (the hairline and the gap under it), and how
// wide the name column is. A type's note and a note that is one share it, so a name is cut at the same
// place on both.

extension TypesStyle {
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
    /// Between a row's pills, and before the `+N` that counts the rest.
    public static let pillGap: CGFloat = 6
    /// The dashed line between a note's fields and its relation rows takes this much room, and is drawn with this
    /// dash (on, off) at this strength of black: fixed, since the paper is light in both appearances.
    public static let relationRuleHeight: CGFloat = 8
    static let relationRuleDash: [CGFloat] = [3, 3]
    static let relationRuleAlpha: CGFloat = 0.25
}

@MainActor
struct RowGeometry {
    let block: CGRect
    /// Where the first row starts.
    let top: CGFloat
    /// The name column's width: the longest shown name's, at most `nameShare` of the block.
    let nameColumn: CGFloat
    /// The row the dashed line comes before: the first relation row, when a field or a fold is above it; nil with
    /// no line. Every row from it down is `relationRuleHeight` lower.
    private let ruleBefore: Int?

    /// The geometry of a template's rows in `block`: the template carries the dashed line's place, so no site that
    /// places a row can forget it.
    init(block: CGRect, hasLead: Bool, template: RowTemplate) {
        self.block = block
        top = block.minY + (hasLead ? TypesStyle.rowsLead : 0)
        nameColumn = min(template.nameColumn, TypesStyle.nameShare * block.width)
        ruleBefore = template.hasRule ? template.relationStart : nil
    }

    func rect(_ row: Int) -> CGRect {
        CGRect(x: block.minX, y: top + CGFloat(row) * TypesStyle.rowHeight + offset(of: row), width: block.width, height: TypesStyle.rowHeight)
    }

    /// How far the dashed line pushes a row down.
    private func offset(of row: Int) -> CGFloat {
        if let ruleBefore, row >= ruleBefore { TypesStyle.relationRuleHeight } else { 0 }
    }

    /// The row at a height (an index that may be past the rows there are), nil above the first row and on the dashed
    /// line: the inverse of `rect(_:)`.
    func row(at y: CGFloat) -> Int? {
        let down = y - top
        guard down >= 0 else { return nil }
        guard let ruleBefore else { return Int((down / TypesStyle.rowHeight).rounded(.down)) }
        let ruleTop = CGFloat(ruleBefore) * TypesStyle.rowHeight
        if down < ruleTop { return Int((down / TypesStyle.rowHeight).rounded(.down)) }
        if down < ruleTop + TypesStyle.relationRuleHeight { return nil }
        return ruleBefore + Int(((down - ruleTop - TypesStyle.relationRuleHeight) / TypesStyle.rowHeight).rounded(.down))
    }

    /// Where the dashed line goes (its middle), when there is one.
    var ruleY: CGFloat? {
        ruleBefore.map { top + CGFloat($0) * TypesStyle.rowHeight + TypesStyle.relationRuleHeight / 2 }
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
