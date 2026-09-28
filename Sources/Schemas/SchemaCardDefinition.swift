import AppKit
import Canvas

/// On the main actor as a whole, so its drawing helpers share the protocol's isolation.
@MainActor
struct SchemaCardDefinition {}

/// A white card: a `{}` mark and the schema's name, then a row per top-level
/// field (its name in a chip; inside it, its fields in braces or its values between bars; its type
/// at the end), at most 7, then `+N more`, then the rules at the root. Nested fields show inside
/// their parent's row, one level down (`{ address {…} · phone }`), so they never take a row. A
/// schema with no fields, or a text that isn't one (with nothing better to show: see
/// `SchemaReadings.shown`), says so in one muted line where the first row would be ("No fields",
/// "Invalid JSON", "Not an object"); Validation outlines the wrong ones. Far out, rows are bars
/// (below 35%), then the title too (below 20%). Colors are the same in both appearances, as every
/// shape's body is; the card's one hue is its accent `{}`.
extension SchemaCardDefinition: ShapeDefinition {
    func render(_ shape: ShapeRecord<SchemaCard>, in context: RenderContext) {
        let frame = shape.frame, cg = context.cg, zoom = context.zoom
        context.fillWithShadow(SchemaStyle.rounded(frame, SchemaStyle.cornerRadius), SchemaStyle.card)
        let layout = SchemaReadings.reading(of: shape).layout(size: frame.size)
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.addPath(SchemaStyle.rounded(frame, SchemaStyle.cornerRadius))
        cg.clip()
        // The layout is from the card's top-left corner.
        cg.translateBy(x: frame.minX, y: frame.minY)
        guard let inner = layout.inner else { return }
        let bars = zoom < SchemaStyle.rowTextZoom
        drawTitle(layout, inner: inner, asBars: zoom < SchemaStyle.titleTextZoom, cg: cg)
        // A state's line isn't a field: no bar stands for it.
        if let state = layout.stateRow, !bars { state.text.drawLine(in: state.rect) }
        for row in layout.rows {
            bars ? drawBars(row, width: inner.width, cg: cg) : drawRow(row, cg: cg)
        }
        for line in [layout.moreRow, layout.rulesRow].compactMap({ $0 }) {
            if bars {
                bar(CGRect(x: line.row.minX, y: line.row.midY - SchemaStyle.barHeight / 2,
                           width: min(CGFloat(line.text.length) * SchemaStyle.barAdvance, line.row.width), height: SchemaStyle.barHeight), cg: cg)
            } else {
                line.text.drawLine(in: line.rect)
            }
        }
    }

    func indicatorPath(of shape: ShapeRecord<SchemaCard>, in context: ShapeContext) -> CGPath {
        SchemaStyle.rounded(shape.frame, SchemaStyle.cornerRadius)
    }

    /// `{}` in the accent, then the name (gray when untitled), one line ending in `…`. Far out, an
    /// accent tick and a bar.
    private func drawTitle(_ layout: SchemaCardLayout, inner: CGRect, asBars: Bool, cg: CGContext) {
        guard asBars else {
            layout.titleText.drawLine(in: layout.titleRect)
            return
        }
        let height = SchemaStyle.titleBarHeight, y = inner.minY + (SchemaCardMetrics.titleLineHeight - height) / 2
        bar(CGRect(x: inner.minX, y: y, width: SchemaStyle.markBarWidth, height: height), cg: cg, color: SchemaStyle.accent)
        let x = inner.minX + SchemaStyle.markBarWidth + SchemaStyle.markBarGap
        bar(CGRect(x: x, y: y, width: min(inner.maxX - x, CGFloat(layout.title.count) * SchemaStyle.titleBarAdvance), height: height),
            cg: cg, color: SchemaStyle.secondaryText)
    }

    private func drawRow(_ row: SchemaCardLayout.Row, cg: CGContext) {
        if let type = row.typeText { type.drawLine(in: row.typeRect) }
        cg.addPath(SchemaStyle.rounded(row.chip, SchemaStyle.chipRadius))
        cg.setFillColor(SchemaStyle.chipFill.cgColor)
        cg.fillPath()
        row.nameText.drawLine(in: row.nameRect)
        if let star = row.starText { star.drawLine(in: row.starRect) }
        if let tray = row.trayText { tray.drawLine(in: row.trayRect) }
    }

    /// A row as its chip with a bar for the name (a pattern's without its slashes): two fills.
    private func drawBars(_ row: SchemaCardLayout.Row, width: CGFloat, cg: CGContext) {
        let characters = CGFloat(row.name.count - (row.isPattern ? 2 : 0))
        let chip = CGRect(x: row.frame.minX, y: row.frame.minY,
                          width: min(characters * SchemaStyle.barAdvance + SchemaStyle.chipInset * 2, width * SchemaStyle.barShare),
                          height: row.frame.height)
        cg.addPath(SchemaStyle.rounded(chip, SchemaStyle.chipRadius))
        cg.setFillColor(SchemaStyle.chipFill.cgColor)
        cg.fillPath()
        bar(CGRect(x: chip.minX + SchemaStyle.chipInset, y: row.frame.midY - SchemaStyle.barHeight / 2,
                   width: chip.width - SchemaStyle.chipInset * 2, height: SchemaStyle.barHeight), cg: cg)
    }

    private func bar(_ rect: CGRect, cg: CGContext, color: NSColor = SchemaStyle.bar) {
        guard rect.width > 0 else { return }
        cg.addPath(SchemaStyle.rounded(rect, rect.height / 2))
        cg.setFillColor(color.cgColor)
        cg.fillPath()
    }
}

/// A card made from properties, or given a schema that way (the command line's `draw`), is as tall
/// as its schema, as `setSchema` would have made it.
extension SchemaCardDefinition: DerivedProps {
    func derive(_ card: inout SchemaCard) { card.setSchema(card.schema) }
}

private extension NSAttributedString {
    /// One line in `rect` (as the layout measured it), ending in `…` if it must.
    func drawLine(in rect: CGRect) {
        guard rect.width > 1 else { return }
        draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// The card's look, in world units, beside `SchemaCardMetrics` (its vertical metrics). Fixed colors:
/// like the sticky note and the subboard, the card is the same in both appearances; only the
/// canvas around it changes.
@MainActor
enum SchemaStyle {
    static let cornerRadius: CGFloat = 8
    static let chipRadius: CGFloat = 5
    /// Text in a chip; `+N more` and the rules line line up with it.
    static let chipInset: CGFloat = 6
    /// Name chip to its tray.
    static let trayGap: CGFloat = 6
    /// The tray's least: room for `{ 4 fields }` or `5 values`.
    static let minTrayWidth: CGFloat = 56
    /// With less left for the name, no tray.
    static let minChipWidth: CGFloat = 40
    /// Anything to the type label.
    static let typeGap: CGFloat = 8
    /// The type label's most, of the inner width.
    static let typeShare: CGFloat = 0.42
    /// Below this zoom the rows draw as bars, no text (11-point text is under 4 points on screen);
    /// below `titleTextZoom` the title does too (14 points, under 3).
    static let rowTextZoom: CGFloat = 0.35
    static let titleTextZoom: CGFloat = 0.2
    /// A bar's width per character of what it stands for, and its height.
    static let barAdvance: CGFloat = 6
    static let barHeight: CGFloat = 6
    /// A name bar's chip is at most this share of the row.
    static let barShare: CGFloat = 0.6
    static let titleBarHeight: CGFloat = 9
    static let titleBarAdvance: CGFloat = 8
    static let markBarWidth: CGFloat = 14
    static let markBarGap: CGFloat = 5

    static let card = NSColor.white
    static let text = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)
    static let secondaryText = NSColor(srgbRed: 0.45, green: 0.45, blue: 0.45, alpha: 1)
    static let tertiaryText = NSColor(srgbRed: 0.62, green: 0.62, blue: 0.62, alpha: 1)
    static let chipFill = NSColor(srgbRed: 0.945, green: 0.945, blue: 0.945, alpha: 1)
    static let bar = NSColor(srgbRed: 0.80, green: 0.80, blue: 0.80, alpha: 1)
    /// The `{}` mark, and the row's symbol in the table of contents.
    static let accent = NSColor(srgbRed: 0.40, green: 0.36, blue: 0.86, alpha: 1)

    static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)
    static let markFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    static let nameFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let patternFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let typeFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let childFont = NSFont.systemFont(ofSize: 10)
    static let noteFont = NSFont.systemFont(ofSize: 10)
    /// What's said about the rows rather than in one: `+N more`, and why there are none.
    static let metaFont = NSFont.systemFont(ofSize: 11)
    /// Every character of a type label is this wide: fitting one is counting.
    static let typeAdvance = NSAttributedString(string: "0", attributes: [.font: typeFont]).size().width

    /// A type label's width: its characters, at `typeAdvance`.
    static func width(ofType label: String) -> CGFloat { (CGFloat(label.count) * typeAdvance).rounded(.up) }

    /// A run of text, ending in `…` where it's cut short unless `truncates` is false.
    static func text(_ string: String, _ font: NSFont, _ color: NSColor, kern: CGFloat? = nil, truncates: Bool = true) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let kern { attributes[.kern] = kern }
        if truncates {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            attributes[.paragraphStyle] = paragraph
        }
        return NSAttributedString(string: string, attributes: attributes)
    }

    /// `text` whole if it fits `width`, else as much of it as fits with `…` after it: cut where
    /// it's measured, so what follows it (a required field's `*`) can follow it closely.
    static func cut(_ text: NSAttributedString, to width: CGFloat) -> NSAttributedString {
        guard text.length > 0, text.size().width > width else { return text }
        let characters = Array(text.string)
        let attributes = text.attributes(at: 0, effectiveRange: nil)
        func kept(_ count: Int) -> NSAttributedString { NSAttributedString(string: String(characters.prefix(count)) + "…", attributes: attributes) }
        var low = 0, high = characters.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if kept(mid).size().width <= width { low = mid } else { high = mid - 1 }
        }
        return kept(low)
    }

    /// Where one line of `text` draws from `origin`, no wider than `width`.
    static func line(_ text: NSAttributedString, at origin: CGPoint, width: CGFloat) -> (text: NSAttributedString, rect: CGRect) {
        let size = text.size()
        return (text, CGRect(x: origin.x, y: origin.y, width: max(0, min(size.width.rounded(.up), width)), height: size.height.rounded(.up)))
    }

    /// Where one line of `text` draws centered on `rect`'s middle, from its left, no wider than it.
    static func centered(_ text: NSAttributedString, in rect: CGRect) -> CGRect {
        line(text, at: CGPoint(x: rect.minX, y: rect.midY - text.size().height / 2), width: rect.width).rect
    }

    /// A rounded rect, its radius at most half its shorter side.
    static func rounded(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
        let radius = max(0, min(radius, rect.width / 2, rect.height / 2))
        return CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }
}
