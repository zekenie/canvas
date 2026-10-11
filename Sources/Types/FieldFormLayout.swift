import AppKit
import Canvas

// Where everything of a form is: the header above the lines (the line back, the type's chip, an either's branch
// names, a table's names: they stay put while the lines scroll), the lines under it in a scroll view, and
// how big the card wants to be. Sizes are asked of the sheet, never of the views, and kept until the sheet
// changes, since the canvas asks for the card's size at every frame.

struct FormMetrics {
    var width: CGFloat = 0
    var headerHeight: CGFloat = 0
    var back: CGRect?
    var chip: CGRect?
    var branches: CGRect?
    var names: CGRect?
    var nameWidth: CGFloat = 0
    var gridWidth: CGFloat = 0
    var linesHeight: CGFloat = 0
    var bottomPad: CGFloat = 0
    /// Where each line starts and, last, where the lines end: only while a line holds a JSON box, which is
    /// taller than a row; empty otherwise, and a line is a row.
    var offsets: [CGFloat] = []
}

extension FieldFormView {
    // MARK: Sizes

    /// The header's height, from what the sheet has: the line back, the chip, the branch names, a table's names.
    private var headerHeightOfSheet: CGFloat {
        let row = TypesStyle.formRowHeight
        var height: CGFloat = presentation == .card ? TypesStyle.formPadY : 0
        if sheet.back != nil { height += row }
        if sheet.chip != nil { height += row }
        if !sheet.branches.isEmpty { height += row }
        if case .table = sheet.layout { height += TypesStyle.formNamesHeight }
        return height
    }

    /// What the lines take, as `computeMetrics` last worked it out.
    private var linesHeightOfSheet: CGFloat { metrics.linesHeight }

    private var bottomPadOfSheet: CGFloat { presentation == .card ? TypesStyle.formPadY : 0 }

    /// How wide the lines are: wider than the form when a table has more columns than the card shows (it scrolls sideways).
    public var gridWidth: CGFloat { metrics.gridWidth }

    /// What stays put above the lines: the line back, the chip, the branch names, a table's names.
    public var headerHeight: CGFloat { headerHeightOfSheet }

    /// How tall the panel's form is: the host sets its height to it.
    public var contentHeight: CGFloat { headerHeightOfSheet + linesHeightOfSheet + bottomPadOfSheet }

    /// A table past four columns is 72 wider for each, uncapped: what its grid is, and the card up to 480.
    private var tableWidth: CGFloat {
        guard case .table(let names) = sheet.layout, names.count > TypesStyle.formFreeColumns else { return 0 }
        return TypesStyle.formMinWidth + TypesStyle.formWidthPerColumn * CGFloat(names.count - TypesStyle.formFreeColumns)
    }

    /// The width the sheet wants: its names and its widest values, 240 at least, 480 at most. A table past four
    /// columns is wider for each. Kept until the sheet changes.
    func preferredWidth() -> CGFloat {
        if let kept = preferredWidthKept { return kept }
        var need = TypesStyle.formMinWidth
        let lines = sheet.lines.prefix(TypesStyle.formMeasuredLines)
        switch sheet.layout {
        case .table:
            need = max(need, tableWidth)
        case .rows:
            let names = lines.map { textWidth($0.name ?? "", in: font) + ($0.isNeeded ? TypesStyle.formDot + 6 : 0) + ($0.chip == nil ? 0 : chipWidth($0.chip!) + 6) }
            let values = lines.map { cellContentWidth($0.cells.first) }
            need = max(need, 2 * TypesStyle.formPadX + (names.max() ?? 0) + TypesStyle.formGap + (values.max() ?? 0))
        case .column, .checks:
            need = max(need, 2 * TypesStyle.formPadX + TypesStyle.formCheckWidth + (lines.map { cellContentWidth($0.cells.first) }.max() ?? 0))
        case .pairs:
            let widest = lines.map { $0.cells.map(cellContentWidth).max() ?? 0 }.max() ?? 0
            need = max(need, 2 * TypesStyle.formPadX + 2 * widest + TypesStyle.formGap)
        }
        let kept = min(max(need, TypesStyle.formMinWidth), TypesStyle.formMaxWidth)
        preferredWidthKept = kept
        return kept
    }

    /// What a card would be, no wider than the room and no taller than its cap, then its lines scroll.
    /// The row it hangs from sets no width: it is as wide as its rows need.
    public func fittingSize(anchorWidth: CGFloat, room: CGSize) -> CGSize {
        let width = min(preferredWidth(), room.width)
        let cap = isFold ? TypesStyle.formFoldMaxHeight : TypesStyle.formMaxHeight
        let height = min(headerHeightOfSheet + linesHeightOfSheet + bottomPadOfSheet, cap, room.height)
        return CGSize(width: max(width, 0), height: max(height, 0))
    }

    func computeMetrics(width: CGFloat) -> FormMetrics {
        let width = presentation == .panel ? max(width, TypesStyle.formPanelMinWidth) : width
        let row = TypesStyle.formRowHeight, pad = TypesStyle.formPadX
        var metrics = FormMetrics(width: width)
        var y: CGFloat = presentation == .card ? TypesStyle.formPadY : 0
        if sheet.back != nil { metrics.back = CGRect(x: pad, y: y, width: width - 2 * pad, height: row); y += row }
        if sheet.chip != nil { metrics.chip = CGRect(x: pad, y: y, width: width - 2 * pad, height: row); y += row }
        if !sheet.branches.isEmpty { metrics.branches = CGRect(x: pad, y: y, width: width - 2 * pad, height: row); y += row }
        if case .table = sheet.layout {
            metrics.names = CGRect(x: pad, y: y, width: width - 2 * pad, height: TypesStyle.formNamesHeight)
            y += TypesStyle.formNamesHeight
        }
        metrics.headerHeight = y
        metrics.bottomPad = bottomPadOfSheet
        if sheet.lines.contains(where: { jsonCell(of: $0) != nil }) {
            var offsets: [CGFloat] = [0]
            offsets.reserveCapacity(sheet.lines.count + 1)
            for held in sheet.lines { offsets.append(offsets[offsets.count - 1] + height(of: held)) }
            metrics.offsets = offsets
            metrics.linesHeight = offsets[offsets.count - 1]
        } else {
            metrics.linesHeight = CGFloat(sheet.lines.isEmpty && presentation == .card ? 1 : sheet.lines.count) * TypesStyle.formRowHeight
        }
        metrics.gridWidth = max(width, tableWidth)
        metrics.nameWidth = nameColumn(width: width)
        return metrics
    }

    /// A rows sheet's name column: as wide as its longest name (with a needed dot and a chip after it), up to 45% of the card.
    private func nameColumn(width: CGFloat) -> CGFloat {
        guard sheet.layout == .rows else { return 0 }
        if let kept = nameColumnKept { return min(kept, TypesStyle.formNameShare * (width - 2 * TypesStyle.formPadX)) }
        let widest = sheet.lines.prefix(TypesStyle.formMeasuredLines).map { line -> CGFloat in
            textWidth(line.name ?? "", in: font) + (line.isNeeded ? TypesStyle.formDot + 6 : 0) + (line.chip == nil ? 0 : chipWidth(line.chip!) + 6)
        }.max() ?? 0
        nameColumnKept = widest
        return min(widest, TypesStyle.formNameShare * (width - 2 * TypesStyle.formPadX))
    }

    func textWidth(_ text: String, in font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width)
    }

    /// What a cell takes of a line, cut at a third of the widest card.
    private func cellContentWidth(_ cell: FieldCell?) -> CGFloat {
        guard let cell else { return 0 }
        let words = cell.shown.isEmpty ? cell.placeholder : cell.shown
        var width = textWidth(String(words.prefix(60)), in: font)
        switch cell.control {
        case .more: width += 14
        case .choice: width += 14
        case .yesNo: width = TypesStyle.formBoxSize
        default: break
        }
        return min(width, TypesStyle.formMaxWidth / 2)
    }

    func chipWidth(_ type: ShapeID) -> CGFloat {
        textWidth(chipName(type).text, in: TypesStyle.formChipFont) + 2 * TypesStyle.formChipPad
    }

    // MARK: Layout

    public override func layout() {
        super.layout()
        metrics = computeMetrics(width: bounds.width)
        let headerHeight = metrics.headerHeight
        header.frame = NSRect(x: 0, y: 0, width: bounds.width, height: headerHeight)
        let room = max(bounds.height - headerHeight - metrics.bottomPad, 0)
        scroll.frame = NSRect(x: 0, y: headerHeight, width: bounds.width, height: room)
        let height = max(metrics.linesHeight, room)
        grid.setFrameSize(NSSize(width: metrics.gridWidth, height: height))
        scroll.hasHorizontalScroller = false
        header.needsDisplay = true
    }

    /// The panel: the form is as tall as what it holds, and as wide as its host makes it. Clearing what was kept
    /// for sizes happens as the sheet changes.
    func clearSizes() {
        preferredWidthKept = nil
        nameColumnKept = nil
    }

    // MARK: Lines of different heights

    /// The JSON box a line holds, if it does: the panel's `Other`.
    func jsonCell(of held: FieldLine) -> FieldCell? {
        guard let cell = held.cells.first, case .json = cell.control else { return nil }
        return cell
    }

    /// What a JSON box shows: what is typed in it, kept until it is committed, else the stored value as JSON.
    func jsonText(of cell: FieldCell) -> String { jsonDrafts[cell.path] ?? cell.shown }

    /// A box for `text`: 76 tall, growing to twelve lines.
    func boxHeight(for text: String) -> CGFloat {
        let lines = min(max(text.split(separator: "\n", omittingEmptySubsequences: false).count, 1), TypesStyle.formJSONMaxLines)
        return max(TypesStyle.formJSONMinHeight, CGFloat(lines) * TypesStyle.formJSONLineHeight + 2 * TypesStyle.formJSONPad)
    }

    /// A line is a row, but for a JSON box: its name's row (if it has one), the box, and a row under it saying `Not JSON`.
    func height(of held: FieldLine) -> CGFloat {
        guard let cell = jsonCell(of: held) else { return TypesStyle.formRowHeight }
        return (held.name == nil ? 0 : TypesStyle.formRowHeight) + boxHeight(for: jsonText(of: cell)) + (jsonErrors.contains(cell.path) ? TypesStyle.formRowHeight : 0)
    }

    func top(ofLine line: Int) -> CGFloat {
        metrics.offsets.isEmpty ? CGFloat(line) * TypesStyle.formRowHeight : metrics.offsets[line]
    }

    func height(ofLine line: Int) -> CGFloat {
        metrics.offsets.isEmpty ? TypesStyle.formRowHeight : metrics.offsets[line + 1] - metrics.offsets[line]
    }

    /// The line a y of the grid is in: a division, or a search of the tops while a box makes them uneven.
    func line(atY y: CGFloat) -> Int {
        guard !metrics.offsets.isEmpty else { return Int(floor(y / TypesStyle.formRowHeight)) }
        var low = 0, high = metrics.offsets.count - 2
        while low < high {
            let middle = (low + high + 1) / 2
            if metrics.offsets[middle] <= y { low = middle } else { high = middle - 1 }
        }
        return y < 0 ? -1 : low
    }

    // MARK: Hit testing

    /// The stop a point of the grid (its coordinates) lands on: a cell, else its line; nil for nothing.
    func stop(atGrid point: CGPoint) -> FieldStop? {
        let place = line(atY: point.y)
        guard point.y >= 0, sheet.lines.indices.contains(place) else { return nil }
        let held = sheet.lines[place]
        if held.disclosure != nil { return FieldStop(line: place, column: -1) }
        for column in held.cells.indices where grid.cellRect(line: place, column: column).insetBy(dx: -2, dy: 0).contains(point) {
            return stopOfCell(line: place, column: column)
        }
        return held.cells.count == 1 ? stopOfCell(line: place, column: 0) : nil
    }

    /// The stop a cell is, if it takes the keyboard: its own, or its line's.
    func stopOfCell(line: Int, column: Int) -> FieldStop? {
        let own = FieldStop(line: line, column: column), whole = FieldStop(line: line, column: -1)
        if sheet.stops.contains(own) { return own }
        return sheet.stops.contains(whole) ? whole : nil
    }
}

extension TypesStyle {
    /// A table's names, above its lines.
    static let formNamesHeight: CGFloat = 20
    static let formNamesFont = NSFont.systemFont(ofSize: 11)
    /// A line of the JSON box.
    public static let formJSONLineHeight: CGFloat = ceil(NSLayoutManager().defaultLineHeight(for: formJSONFont))
}
