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
    /// How a line is set: a row's name, a type, a nullable's `?`, an enum's value.
    enum Role: Hashable {
        case name, type, null, value

        @MainActor var font: NSFont {
            switch self {
            case .name, .null: KitStyle.nameFont
            case .type: KitStyle.typeFont
            case .value: KitStyle.valueFont
            }
        }

        @MainActor var ink: CGColor {
            switch self {
            case .name, .null, .value: KitStyle.ink.cgColor
            case .type: KitStyle.secondaryInk.cgColor
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

    static func image(_ name: String, color: RGB) -> NSImage? {
        let key = "\(name) \(color.hexString)"
        if let image = images[key] { return image }
        let configuration = NSImage.SymbolConfiguration(pointSize: TableStyle.markSize, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(color)]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
        images[key] = image
        return image
    }

    /// Draws a mark centered at `middle`, as big as its symbol is set (world units).
    static func draw(_ name: String, color: RGB, centeredAt middle: CGPoint) {
        guard let image = image(name, color: color) else { return }
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

    /// A bar of `columns` columns of `column` wide each, from `x` (or ending at it, `trailing`), in row `row`'s middle.
    static func bar(columns: Int, column: CGFloat, at x: CGFloat, trailing: Bool = false, in row: CGRect, room: CGFloat) -> CGRect? {
        let width = min(room, CGFloat(min(columns, TableStyle.skeletonMostColumns)) * column)
        guard width > 0 else { return nil }
        return CGRect(x: trailing ? x - width : x, y: row.midY - TableStyle.skeletonBarHeight / 2, width: width, height: TableStyle.skeletonBarHeight)
    }
}

/// Where a shape's rows go while it's edited (LineRows' layout inputs, set only on the shape being edited): a line left for
/// the waiting line, the rows after it a line down, and the row the field draws, which the shape doesn't. Neither, at rest.
@MainActor
struct KitRows {
    /// The waiting line's line, nil at rest.
    let waiting: Int?
    /// The row the field has.
    let focused: PartID?

    init<P: ShapeProps>(_ shape: ShapeRecord<P>, in context: ShapeContext) {
        waiting = context.layoutInput(LineRowsLayout.waiting, of: shape)
        focused = context.layoutInput(LineRowsLayout.focused, of: shape)
    }

    /// How many lines `rows` rows take: one more while the waiting line is drawn.
    func lines(_ rows: Int) -> Int { rows + (waiting == nil ? 0 : 1) }

    /// The line row `index` is drawn on.
    func line(of index: Int) -> Int { LineRowsLayout.line(of: index, waiting: waiting) }

    /// The row drawn on `line`; nil for the waiting line.
    func row(atLine line: Int) -> Int? {
        guard let waiting else { return line }
        return line == waiting ? nil : line < waiting ? line : line - 1
    }
}
