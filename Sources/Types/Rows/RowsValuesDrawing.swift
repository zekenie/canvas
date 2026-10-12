import Adornments
import AppKit
import Canvas
import CoreGraphics
import Mentions

// The values of a note that is one, drawn in its rows: each field's name muted at the left and its value in
// the column after it, left-aligned, as board 5 draws them. The look of a value is its content's and the
// check's mark (`RowLook`), read at each draw: the render has no way to observe, so whatever changes the
// answer, or `typing`, redraws.

extension RowLook {
    var style: FieldLines.Style {
        switch self {
        case .plain: .value
        case .empty: .empty
        case .needed: .needed
        case .neededInside: .neededInside
        case .wrong: .wrong
        }
    }
}

/// How a pointer's pills look in a row: Mentions' pill, outlined (white, a hairline, the live name, no
/// symbol: board 5's panel 2), in the rows' font; a wrong one in the wrong red.
@MainActor
enum LinkPills {
    /// A pill's line is this tall: the room its pill sits in.
    static let lineHeight: CGFloat = 20
    static let style = MentionTextStyle(font: NSFont.systemFont(ofSize: TypesStyle.rowFontSize), color: TypesStyle.rowInk,
                                        lineHeight: lineHeight, surface: .outlined)
    static let wrongStyle = MentionTextStyle(font: NSFont.systemFont(ofSize: TypesStyle.rowFontSize), color: TypesStyle.wrongInk,
                                             lineHeight: lineHeight, surface: .outlined)
}

extension RowBook {
    /// Draws a note's rows: tick, name and value of each, then the outline of the row whose card is open.
    func drawValues(of record: AnyShapeRecord, template: RowTemplate, subject: RowSubject, in block: CGRect, isEditing: Bool,
                    to context: RenderContext) {
        let cg = context.cg
        let kept = shownRows(of: record, subject: subject, template: template, block: block)
        let check = self.check(of: record)
        // The row being typed in draws its own text: a caret in its field, which is a path of one step. A caret deeper (a cell
        // of the card the row opened) leaves the row's summary to be drawn, behind the card.
        let typed = editor?.fieldChecks?.typing.flatMap { $0.shape == record.id && $0.path.steps.count == 1 ? $0.path.field : nil }
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.translateBy(x: block.minX, y: block.minY)
        for (index, row) in kept.rows.enumerated() {
            let mark = check.problems.isEmpty ? nil : kept.marks[index].compactMap { check.mark(at: $0) }.max()
            let rect = row.rect, midY = rect.midY
            if let tick = row.tick { drawTick(TypeColors.base(tick), in: rect, to: cg) }
            if row.path == nil {
                drawFold(row, mark: mark, midY: midY, to: cg)
                continue
            }
            FieldLines.draw(FieldLines.line(row.name, .muted, cutTo: row.nameRect.width), at: row.nameRect.minX, midY: midY, in: cg)
            // The row being typed in draws its own text, and so does one being picked in.
            if let typed, row.path?.field == typed { continue }
            if let picking, picking.shape == record.id, row.path?.field == picking.key { continue }
            drawValue(row, look: RowLook.of(content: row.content, mark: mark), context: context)
        }
        if !isEditing { drawOpenOutline(of: record, rows: kept.rows, template: template, to: cg) }
    }

    private func drawFold(_ row: ShownRow, mark: FieldClass?, midY: CGFloat, to cg: CGContext) {
        let look = RowLook.of(content: row.content, mark: mark)
        let style: FieldLines.Style = look == .wrong ? .wrong : look == .neededInside ? .neededInside : .kind
        guard case .fold(let value) = row.content else { return }
        if value.isEmpty {
            FieldLines.draw(FieldLines.line(row.name + " ›", style), at: row.rect.minX, midY: midY, in: cg)
        } else {
            FieldLines.draw(FieldLines.line(row.name, .faint, cutTo: row.nameRect.width), at: row.nameRect.minX, midY: midY, in: cg)
            let words = FieldLines.line(value + " ›", style, cutTo: row.valueRect.width)
            FieldLines.draw(words, at: row.valueRect.maxX - words.width, midY: midY, in: cg)
        }
    }

    /// A value, left-aligned in its column.
    private func drawValue(_ row: ShownRow, look: RowLook, context: RenderContext) {
        let cg = context.cg
        let value = row.valueRect, midY = row.rect.midY
        switch row.content {
        case .text(let text):
            drawText(text, look: look, in: value, midY: midY, to: cg)
        case .empty(let words):
            FieldLines.draw(FieldLines.line(words, look.style, cutTo: value.width), at: value.minX, midY: midY, in: cg)
        case .choice(let label):
            if let label {
                drawText(label, look: look, in: value, midY: midY, to: cg)
            } else {
                FieldLines.draw(FieldLines.line(FieldWords.add(row.name), look.style, cutTo: value.width), at: value.minX, midY: midY, in: cg)
            }
        case .box(let ticked):
            drawBox(ticked, look: look, at: CGPoint(x: value.minX, y: midY), to: cg)
        case .summary(let text):
            let line = FieldLines.line(text, look.style, cutTo: max(0, value.width - Self.chevronRoom))
            FieldLines.draw(line, at: value.minX, midY: midY, in: cg)
            if look == .wrong { drawWave(from: value.minX, to: value.minX + line.width, midY: midY, to: cg) }
            FieldLines.draw(FieldLines.line("›", .kind), at: value.minX + line.width + TypesStyle.partGap, midY: midY, in: cg)
        case .gone(let target):
            guard let types = editor?.types else { return }
            let label = TypeChips.label(for: TypeLink(target), in: types)
            label.draw(at: CGPoint(x: value.minX, y: midY - label.contentSize.height / 2), in: cg)
        case .links(let links, let more):
            for shown in links {
                let box = CGRect(x: value.minX + shown.x, y: midY - LinkPills.lineHeight / 2, width: shown.width + 1, height: LinkPills.lineHeight)
                context.drawMentionText(MentionTextPlacement(shown.text, in: box, style: look == .wrong ? LinkPills.wrongStyle : LinkPills.style, lines: 1))
                // Under the name, inside the pill.
                if look == .wrong { drawWave(from: box.minX + TypesStyle.linkWaveInset, to: box.minX + shown.width - TypesStyle.linkWaveInset, midY: midY - 0.75, to: cg) }
            }
            if more > 0, let last = links.last {
                FieldLines.draw(FieldLines.line("+\(more)", .kind), at: value.minX + last.x + last.width + TypesStyle.linkGap, midY: midY, in: cg)
            }
        case .kind, .fold:
            break
        }
    }

    private func drawText(_ text: String, look: RowLook, in value: CGRect, midY: CGFloat, to cg: CGContext) {
        let line = FieldLines.line(text, look.style, cutTo: value.width)
        FieldLines.draw(line, at: value.minX, midY: midY, in: cg)
        if look == .wrong { drawWave(from: value.minX, to: value.minX + line.width, midY: midY, to: cg) }
    }

    /// A wrong value's wavy line, under its text.
    private func drawWave(from start: CGFloat, to end: CGFloat, midY: CGFloat, to cg: CGContext) {
        guard end > start else { return }
        let y = midY + TypesStyle.waveDrop
        let path = CGMutablePath()
        path.move(to: CGPoint(x: start, y: y))
        var x = start
        while x < end {
            x = min(end, x + 1)
            path.addLine(to: CGPoint(x: x, y: y + TypesStyle.waveAmplitude * sin((x - start) / TypesStyle.wavePeriod * 2 * .pi)))
        }
        cg.saveGState()
        cg.addPath(path)
        cg.setStrokeColor(TypesStyle.wrongInk.cgColor)
        cg.setLineWidth(1)
        cg.strokePath()
        cg.restoreGState()
    }

    /// A yes or no's box: outlined, and ticked in the accent blue with a white check.
    private func drawBox(_ ticked: Bool, look: RowLook, at left: CGPoint, to cg: CGContext) {
        let size = TypesStyle.boxSize
        let box = CGRect(x: left.x, y: left.y - size / 2, width: size, height: size).insetBy(dx: 0.5, dy: 0.5)
        let path = CGPath(roundedRect: box, cornerWidth: TypesStyle.boxCorner, cornerHeight: TypesStyle.boxCorner, transform: nil)
        cg.saveGState()
        defer { cg.restoreGState() }
        let ink = look == .wrong ? TypesStyle.wrongInk : TypesStyle.linkInk
        if ticked {
            cg.addPath(path)
            cg.setFillColor(ink.cgColor)
            cg.fillPath()
            let check = CGMutablePath()
            check.move(to: CGPoint(x: box.minX + box.width * 0.24, y: box.midY))
            check.addLine(to: CGPoint(x: box.minX + box.width * 0.44, y: box.midY + box.height * 0.2))
            check.addLine(to: CGPoint(x: box.minX + box.width * 0.78, y: box.midY - box.height * 0.2))
            cg.addPath(check)
            cg.setStrokeColor(CGColor(gray: 1, alpha: 1))
            cg.setLineWidth(1.5)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.strokePath()
        } else {
            cg.addPath(path)
            cg.setStrokeColor(look == .wrong ? TypesStyle.wrongInk.cgColor : TypesStyle.rowInk.withAlphaComponent(TypesStyle.mutedStrength).cgColor)
            cg.setLineWidth(1)
            cg.strokePath()
        }
    }

    // MARK: The outline

    /// The rect that hugs a row's value, from the block's top-left like the shown rows: what the outline of a
    /// focused row and of the row whose card is open goes round. At least `fieldFocusMinimum` wide, at most the
    /// value column.
    func hug(_ row: ShownRow, focused: Bool = false) -> CGRect {
        let value = row.valueRect
        var width: CGFloat
        switch row.content {
        case .text(let text): width = FieldLines.width(of: text, .value)
        case .empty(let words): width = FieldLines.width(of: words, .empty)
        case .choice(let label):
            width = FieldLines.width(of: label ?? FieldWords.add(row.name), label == nil ? .empty : .value) + (focused ? Self.choiceMarkRoom : 0)
        case .box: width = TypesStyle.boxSize
        case .summary(let text): width = FieldLines.width(of: text, .value) + Self.chevronRoom
        case .gone(let target):
            width = editor?.types.map { TypeChips.label(for: TypeLink(target), in: $0).contentSize.width } ?? 0
        case .links(let links, let more):
            if let last = links.last {
                let counted = more > 0 ? TypesStyle.linkGap + FieldLines.width(of: "+\(more)", .kind) : 0
                width = last.x + last.width + counted
            } else {
                width = 0
            }
        case .kind, .fold: width = value.width
        }
        width = min(value.width, max(width, 0))
        let outset = TypesStyle.fieldFocusOutset
        return CGRect(x: value.minX - outset, y: row.rect.minY + 1, width: max(width + 2 * outset, TypesStyle.fieldFocusMinimum), height: row.rect.height - 2)
    }

    private func drawOpenOutline(of record: AnyShapeRecord, rows: [ShownRow], template: RowTemplate, to cg: CGContext) {
        guard let open = editor?.fieldCards?.openTarget, open.shape == record.id else { return }
        let folded = editor?.fieldCards?.openFolded
        for (index, row) in rows.enumerated() {
            let isOpen: Bool
            switch (open.target, template.items[index]) {
            case (.field(let path), .field):
                isOpen = row.path == path
            case (.fold, .fold(let fold)):
                isOpen = fold.folded.first?.field.name == folded
            default:
                isOpen = false
            }
            guard isOpen else { continue }
            outline(focusRect(of: row, class: nil), to: cg)
        }
    }

    /// What the `▾` after a focused choice takes.
    static var choiceMarkRoom: CGFloat { FieldLines.width(of: "▾", .kind) + TypesStyle.partGap }

    /// What the outline of a focused row or of the row whose card is open goes round: a value as it hugs it, a
    /// fold's words (`+12 more ›` at the left, `4 fields ›` at the right).
    func focusRect(of row: ShownRow, class kind: RowClass?) -> CGRect {
        guard row.path == nil else { return hug(row, focused: { if case .choice = kind { true } else { false } }()) }
        let outset = TypesStyle.fieldFocusOutset
        if row.valueRect == .zero {
            let width = FieldLines.width(of: row.name + " ›", .kind)
            return CGRect(x: row.rect.minX - 2, y: row.rect.minY + 1, width: width + 4, height: row.rect.height - 2)
        }
        guard case .fold(let value) = row.content else { return row.rect }
        let width = FieldLines.width(of: value + " ›", .kind)
        return CGRect(x: row.valueRect.maxX - width - outset, y: row.rect.minY + 1, width: width + 2 * outset, height: row.rect.height - 2)
    }

    /// A focused row's outline, and the `▾` of a focused choice inside it.
    func drawFocus(_ rect: CGRect, of row: ShownRow, class kind: RowClass, to cg: CGContext) {
        outline(rect, to: cg)
        if case .choice = kind {
            let mark = FieldLines.line("▾", .kind)
            FieldLines.draw(mark, at: rect.maxX - TypesStyle.fieldFocusOutset - mark.width, midY: row.rect.midY, in: cg)
        }
    }

    /// The focus outline: a thin accent line with rounded corners.
    func outline(_ rect: CGRect, to cg: CGContext) {
        cg.saveGState()
        cg.addPath(CGPath(roundedRect: rect.insetBy(dx: TypesStyle.fieldFocusWidth / 2, dy: TypesStyle.fieldFocusWidth / 2),
                          cornerWidth: TypesStyle.fieldFocusCorner, cornerHeight: TypesStyle.fieldFocusCorner, transform: nil))
        cg.setStrokeColor(TypesStyle.linkInk.cgColor)
        cg.setLineWidth(TypesStyle.fieldFocusWidth)
        cg.strokePath()
        cg.restoreGState()
    }
}
