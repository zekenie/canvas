import AppKit
import Canvas

/// On the main actor as a whole, so its drawing helpers share the protocol's isolation.
@MainActor
struct SchemaCardDefinition {}

/// A white card like the task card: a `{}` mark and the schema's name, then a row per top-level
/// field (its name in a chip; inside it, its fields in braces or its values between bars; its type
/// at the end), at most 7, then `+N more`, then the rules at the root. Nested fields show inside
/// their parent's row, one level down (`{ address {…} · phone }`), so they never take a row. A
/// schema with no fields, or a text that isn't one, draws a box saying so; Validation outlines
/// the wrong ones red. Far out, rows are bars (below 35%), then the title too (below 20%). Colors
/// are the same in both appearances, as every shape's body is.
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
        if let box = layout.stateBox {
            drawState(layout, box: box, bars: bars, cg: cg)
            return
        }
        for row in layout.rows {
            bars ? drawBars(row, width: inner.width, cg: cg) : drawRow(row, cg: cg)
        }
        if let more = layout.moreRow {
            if bars {
                bar(CGRect(x: more.row.minX, y: more.row.midY - SchemaStyle.barHeight / 2,
                           width: CGFloat(more.text.length) * SchemaStyle.barAdvance, height: SchemaStyle.barHeight), cg: cg)
            } else {
                more.text.drawLine(in: more.rect)
            }
        }
        if let rules = layout.rulesRow, !bars { rules.text.drawLine(in: rules.rect) }
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

    /// A box of two lines under the title: the empty card's (dashed, an invitation) or a broken
    /// one's (filled and gray, as Validation's red outline already says it's wrong).
    private func drawState(_ layout: SchemaCardLayout, box: CGRect, bars: Bool, cg: CGContext) {
        let path = SchemaStyle.rounded(layout.state == .empty ? box.insetBy(dx: 0.5, dy: 0.5) : box, SchemaStyle.stateRadius)
        cg.addPath(path)
        if layout.state == .empty {
            cg.saveGState()
            cg.setStrokeColor(SchemaStyle.emptyStroke.cgColor)
            cg.setLineWidth(1)
            cg.setLineDash(phase: 0, lengths: SchemaStyle.emptyDash)
            cg.strokePath()
            cg.restoreGState()
        } else {
            cg.setFillColor(SchemaStyle.chipFill.cgColor)
            cg.fillPath()
        }
        guard !bars else { return }
        for line in layout.stateTexts { line.text.drawLine(in: line.rect) }
    }

    private func drawRow(_ row: SchemaCardLayout.Row, cg: CGContext) {
        if let type = row.typeText { type.drawLine(in: row.typeRect) }
        cg.addPath(SchemaStyle.rounded(row.chip, SchemaStyle.chipRadius))
        cg.setFillColor(SchemaStyle.chipFill.cgColor)
        cg.fillPath()
        row.nameText.drawLine(in: row.nameRect)
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

/// A card made from properties (the command line's `create`) is as tall as its schema, as
/// `setSchema` would have made it.
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
/// like the task card and the sticky note, the card is the same in both appearances; only the
/// canvas around it changes.
@MainActor
enum SchemaStyle {
    static let cornerRadius: CGFloat = 8               // TaskStyle.cornerRadius
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
    static let stateRadius: CGFloat = 6
    static let stateInset: CGFloat = 10
    /// The state box's two lines, from its top: what it is (11 points), then what to do (10).
    static let stateTitleTop: CGFloat = 6
    static let stateNoteTop: CGFloat = 21
    static let emptyDash: [CGFloat] = [3, 3]
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

    static let card = NSColor.white                                                        // TaskStyle.card
    static let text = NSColor(srgbRed: 0.12, green: 0.12, blue: 0.12, alpha: 1)           // TaskStyle.text
    static let secondaryText = NSColor(srgbRed: 0.45, green: 0.45, blue: 0.45, alpha: 1)  // TaskStyle.secondaryText
    static let tertiaryText = NSColor(srgbRed: 0.62, green: 0.62, blue: 0.62, alpha: 1)
    static let chipFill = NSColor(srgbRed: 0.945, green: 0.945, blue: 0.945, alpha: 1)
    static let emptyStroke = NSColor(srgbRed: 0.80, green: 0.80, blue: 0.80, alpha: 1)
    static let bar = NSColor(srgbRed: 0.80, green: 0.80, blue: 0.80, alpha: 1)
    static let required = NSColor(srgbRed: 0.90, green: 0.36, blue: 0.24, alpha: 1)
    /// The `{}` mark, and the row's symbol in the table of contents.
    static let accent = NSColor(srgbRed: 0.40, green: 0.36, blue: 0.86, alpha: 1)

    static let titleFont = NSFont.systemFont(ofSize: 14, weight: .semibold)               // TaskStyle.titleFont
    static let markFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    static let nameFont = NSFont.systemFont(ofSize: 11, weight: .medium)
    static let patternFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let typeFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    static let childFont = NSFont.systemFont(ofSize: 10)
    static let noteFont = NSFont.systemFont(ofSize: 10)
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
