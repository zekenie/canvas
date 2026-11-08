import Adornments
import AppKit
import Canvas
import CoreText
import LineRows
import Palette

// Drawing a kit shape's rows on its paper: a row's name, its type, its marks and its pill, in world units, the rows in view
// only. A line of text is set once by what it says and how (`RowText`) and drawn from that each frame, never typeset
// again, so a table's frame costs a few draws a row in view; the paper is the same in both appearances, so its inks are
// fixed and a line is set once for both.

/// The lines a kit shape draws, kept by text and role.
@MainActor
enum RowText {
    /// How a line is set: a row's name, a type, a nullable's `?`, an enum's value, a fold's "+N ›"; an API's code (a path, a
    /// header's prefix), its faint code (the server, a status, a count), a method's chip's text, and code in a color of its own
    /// (a path's parameter in its method's, by its RGB's hex).
    enum Role: Hashable {
        case name, type, null, value, more
        case code, faintCode, chip, placeholder
        case coloredCode(UInt32)

        @MainActor var font: NSFont {
            switch self {
            case .name, .null, .more: KitStyle.nameFont
            case .type: KitStyle.typeFont
            case .value: KitStyle.valueFont
            case .code, .faintCode, .coloredCode: KitStyle.codeFont
            case .chip: KitStyle.chipFont
            case .placeholder: KitStyle.placeholderFont
            }
        }

        @MainActor var ink: CGColor {
            switch self {
            case .name, .null, .value, .code: KitStyle.ink.cgColor
            case .type, .more, .faintCode, .placeholder: KitStyle.secondaryInk.cgColor
            case .chip: CGColor(gray: 1, alpha: 1)
            case .coloredCode(let hex): RGB(hex: hex).cgColor
            }
        }
    }

    /// A line set: the line, how wide it is and how far its baseline is from its middle (world units).
    struct Line {
        let line: CTLine
        let role: Role
        let width: CGFloat
        /// Down from the row's middle to the baseline, so the text's middle is the row's.
        let baselineDrop: CGFloat
    }

    private struct Key: Hashable {
        let text: String
        let role: Role
    }

    /// How many lines are kept; past it the lot is let go.
    static let capacity = 8192
    private static var kept: [Key: Line] = [:]

    static func line(_ text: String, _ role: Role) -> Line {
        let key = Key(text: text, role: role)
        if let line = kept[key] { return line }
        if kept.count >= capacity { kept.removeAll(keepingCapacity: true) }
        let string = NSAttributedString(string: text, attributes: [.font: role.font, NSAttributedString.Key(kCTForegroundColorAttributeName as String): role.ink])
        let line = CTLineCreateWithAttributedString(string)
        var ascent: CGFloat = 0, descent: CGFloat = 0
        let width = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, nil))
        let set = Line(line: line, role: role, width: width, baselineDrop: (ascent - descent) / 2)
        kept[key] = set
        return set
    }

    /// Draws `line` from `x`, its middle at `middle`, cut short with an ellipsis where it's wider than `room`.
    static func draw(_ line: Line, at x: CGFloat, middle: CGFloat, room: CGFloat = .greatestFiniteMagnitude, in cg: CGContext) {
        var drawn = line.line
        if line.width > room {
            guard room > 0 else { return }
            guard let cut = CTLineCreateTruncatedLine(line.line, Double(room), .end, Self.line("…", line.role).line) else { return }
            drawn = cut
        }
        cg.saveGState()
        cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        cg.textPosition = CGPoint(x: x, y: middle + line.baselineDrop)
        CTLineDraw(drawn, cg)
        cg.restoreGState()
    }
}

/// The gutter's marks, SF Symbols in their colors, made once each.
@MainActor
enum RowMarks {
    private static var images: [String: NSImage] = [:]

    static func image(_ name: String, color: RGB, size: CGFloat = KitStyle.markSize) -> NSImage? {
        let key = "\(name) \(color.hexString) \(size)"
        if let image = images[key] { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(color)]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
        images[key] = image
        return image
    }

    /// Draws a mark centered at `middle`, as big as its symbol is set (world units).
    static func draw(_ name: String, color: RGB, size: CGFloat = KitStyle.markSize, centeredAt middle: CGPoint) {
        guard let image = image(name, color: color, size: size) else { return }
        let size = image.size
        image.draw(in: CGRect(x: middle.x - size.width / 2, y: middle.y - size.height / 2, width: size.width, height: size.height),
                   from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }
}

/// A kit shape's paper and the edge its skeleton keeps on the light canvas.
@MainActor
enum KitPaper {
    static let color = NSColor(KitStyle.paper)
    static let cgColor = KitStyle.paper.cgColor

    /// The paper with the note's shadow, rounded.
    static func draw(_ frame: CGRect, in context: RenderContext) {
        context.fillWithShadow(KitStyle.paperPath(frame), color)
    }

    /// Zoomed out: the paper, square, and on the light canvas a ring as wide on screen at every zoom (a shape too small
    /// for one is all ring), so it stays seen on white, where in full its shadow does that.
    static func drawSkeleton(_ frame: CGRect, in context: RenderContext) {
        let cg = context.cg
        cg.setFillColor(cgColor)
        cg.fill(frame)
        guard !NSAppearance.currentDrawing().isDark else { return }
        let width = KitStyle.skeletonEdgeWidth / context.zoom, inside = frame.insetBy(dx: width, dy: width)
        if !inside.isEmpty { cg.addRect(inside) }
        cg.addRect(frame)
        cg.setFillColor(KitStyle.skeletonEdge.cgColor)
        cg.fillPath(using: .evenOdd)
    }

    /// The rows of `count` that the context's drawing reaches, so a long table costs the rows in view.
    static func rowsInView(_ count: Int, in frame: CGRect, _ context: RenderContext) -> Range<Int> {
        KitStyle.rows(count, in: frame, reaching: context.cg.boundingBoxOfClipPath)
    }

    /// The rows a skeleton draws bars for: those of `rowsInView`, none while a row is under `KitStyle.skeletonLeastRow` view
    /// points tall, where its bars would be a smear of fractions of a pixel the paper alone says as well, so a board of
    /// thousands of tables far out costs a card each, and not a bar a row of every one.
    static func skeletonRowsInView(_ count: Int, in frame: CGRect, _ context: RenderContext) -> Range<Int> {
        guard KitStyle.rowHeight * context.zoom >= KitStyle.skeletonLeastRow else { return 0..<0 }
        return rowsInView(count, in: frame, context)
    }

    /// A bar of `columns` columns of `column` wide each, from `x` (or ending at it, `trailing`), in row `row`'s middle.
    static func bar(columns: Int, column: CGFloat, at x: CGFloat, trailing: Bool = false, in row: CGRect, room: CGFloat) -> CGRect? {
        let width = min(room, CGFloat(min(columns, KitStyle.skeletonMostColumns)) * column)
        guard width > 0 else { return nil }
        return CGRect(x: trailing ? x - width : x, y: row.midY - KitStyle.skeletonBarHeight / 2, width: width, height: KitStyle.skeletonBarHeight)
    }
}

/// Where a shape's rows go: while it's edited (LineRows' layout inputs, set only on the shape being edited), a line left for
/// the waiting line, the rows after it a line down, the row the field draws, which the shape doesn't, and a width as wide
/// as the typed line needs; folded (`LineRowsLayout.shown`), the lines it shows, a hidden row standing at the "+N ›" line;
/// while its rows are dragged, those rows faded. None of it at rest.
@MainActor
struct KitRows {
    /// The waiting line's line, nil at rest.
    let waiting: Int?
    /// The row the field has.
    let focused: PartID?
    /// The lines a folded shape shows; nil for every row.
    let shown: RowsShown?
    /// How wide it's laid out while a line typed in it is wider than it stores.
    let width: CGFloat?
    /// The rows a drag is taking, drawn faded where they are.
    let faded: Set<PartID>?

    init<P: ShapeProps>(_ shape: ShapeRecord<P>, in context: ShapeContext) {
        waiting = context.layoutInput(LineRowsLayout.waiting, of: shape)
        focused = context.layoutInput(LineRowsLayout.focused, of: shape)
        shown = context.layoutInput(LineRowsLayout.shown, of: shape)
        width = context.layoutInput(LineRowsLayout.width, of: shape)
        faded = context.layoutInput(LineRowsLayout.faded, of: shape)
    }

    /// Draws row `id` with `draw`: faded, as one layer, while a drag takes it (`RowDragStyle.fadedOpacity`), else as it is.
    func drawing(_ id: PartID, in cg: CGContext, _ draw: () -> Void) {
        guard let faded, faded.contains(id) else { return draw() }
        cg.saveGState()
        cg.setAlpha(RowDragStyle.fadedOpacity)
        cg.beginTransparencyLayer(auxiliaryInfo: nil)
        draw()
        cg.endTransparencyLayer()
        cg.restoreGState()
    }

    /// Zoomed out, the bars of the rows a drag takes (`faded`) and what else of theirs is filled (`more`), drawn at
    /// `RowDragStyle.fadedOpacity`: one fill, so what overlaps in it isn't darkened twice.
    func fillFaded(text bars: [CGRect], in context: RenderContext, _ more: () -> Void) {
        guard !bars.isEmpty else { return }
        context.cg.saveGState()
        context.cg.setAlpha(RowDragStyle.fadedOpacity)
        context.fillSkeletonText(bars)
        more()
        context.cg.restoreGState()
    }

    /// How many lines `rows` rows take: the fold's, else one more while the waiting line is drawn.
    func lines(_ rows: Int) -> Int { shown?.count ?? rows + (waiting == nil ? 0 : 1) }

    /// The line row `index` is drawn on, or stands at, folded.
    func line(of index: Int) -> Int { shown?.line(standingFor: index) ?? LineRowsLayout.line(of: index, waiting: waiting) }

    /// Whether row `index` is drawn on a line of its own: false for a row a fold hides, which stands at the "+N ›" line.
    func isShown(_ index: Int) -> Bool { shown?.isShown(index) ?? true }

    /// The row drawn on `line`; nil for the waiting line and the "+N ›" line.
    func row(atLine line: Int) -> Int? {
        if let shown { return shown.row(atLine: line) }
        guard let waiting else { return line }
        return line == waiting ? nil : line < waiting ? line : line - 1
    }

    /// The "+N ›" line a fold draws, and how many rows it stands for.
    var more: (line: Int, count: Int)? { shown?.more }

    /// How wide a shape that stores `stored` is laid out.
    func width(stored: CGFloat) -> CGFloat { max(stored, width ?? 0) }
}

/// The "+N ›" line of a folded shape: grey, at the names' inset, in the names' font; zoomed out, a short bar.
@MainActor
enum MoreLine {
    static func text(_ count: Int) -> String { "+\(count) \(KitStyle.moreChevron)" }

    static func draw(_ count: Int, in row: CGRect, _ context: RenderContext) {
        let start = row.minX + KitStyle.nameInset
        RowText.draw(RowText.line(text(count), .more), at: start, middle: row.midY, room: row.maxX - KitStyle.trailingInset - start, in: context.cg)
    }

    static func bar(_ count: Int, in row: CGRect) -> CGRect? {
        let start = row.minX + KitStyle.nameInset
        return KitPaper.bar(columns: SkeletonText.columns(of: text(count), upTo: KitStyle.skeletonMostColumns), column: KitStyle.skeletonNameColumn,
                            at: start, in: row, room: row.maxX - KitStyle.trailingInset - start)
    }
}
