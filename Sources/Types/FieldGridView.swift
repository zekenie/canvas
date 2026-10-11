import AppKit
import Adornments
import Canvas
import TextEditing

// The form's drawing and its presses. The lines are the document view of a scroll view and draw only the
// ones in the dirty rect, with string drawing; what stays put above them (the line back, the chip, the
// branch names, a table's names) is the header's. Nothing here decides anything: a press is handed to
// the form as a stop.

/// The lines of the form: its scroll view's document view.
@MainActor
final class FieldGridView: NSView {
    unowned var form: FieldFormView!

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirty: NSRect) {
        form?.drawLines(in: dirty)
    }

    override func mouseDown(with event: NSEvent) {
        form.pressed(atGrid: convert(event.locationInWindow, from: nil))
    }

    override func rightMouseDown(with event: NSEvent) {
        form.rightPressed(atGrid: convert(event.locationInWindow, from: nil))
    }

    func lineRect(_ line: Int) -> CGRect {
        CGRect(x: 0, y: form.top(ofLine: line), width: max(bounds.width, form.metrics.gridWidth), height: form.height(ofLine: line))
    }

    /// Where a line's content starts: past its panel indent and the column the triangles hang in.
    private func contentX(_ held: FieldLine) -> CGFloat {
        TypesStyle.formPadX + CGFloat(held.depth) * TypesStyle.formIndent + (form.presentation == .panel ? TypesStyle.formTriangleWidth : 0)
    }

    private var rightEdge: CGFloat { max(bounds.width, form.metrics.gridWidth) - TypesStyle.formPadX }

    /// A cell's place: after the name in rows, its share of the line in a table or pairs, past the check's place
    /// in a list of choices, else the line's width.
    func cellRect(line: Int, column: Int) -> CGRect {
        let row = TypesStyle.formRowHeight, held = form.sheet.lines[line], y = form.top(ofLine: line)
        var x = contentX(held)
        // A JSON box is the whole width, under its name's row.
        if let box = form.jsonCell(of: held) {
            let top = y + (held.name == nil ? 0 : row)
            return CGRect(x: x, y: top, width: max(rightEdge - x, 0), height: form.boxHeight(for: form.jsonText(of: box)))
        }
        if held.cells.count > 1 {
            let share = (rightEdge - x) / CGFloat(held.cells.count)
            return CGRect(x: x + CGFloat(column) * share, y: y, width: share - (column == held.cells.count - 1 ? 0 : TypesStyle.formGap - 2), height: row)
        }
        if held.name != nil {
            x += form.metrics.nameWidth + TypesStyle.formGap
        } else if let cell = held.cells.first, cell.control.isCheckLine {
            x += TypesStyle.formCheckWidth
        }
        return CGRect(x: x, y: y, width: max(rightEdge - x, 0), height: row)
    }

    func nameRect(_ line: Int) -> CGRect {
        let held = form.sheet.lines[line]
        let width = form.jsonCell(of: held) == nil ? form.metrics.nameWidth : max(rightEdge - contentX(held), 0)
        return CGRect(x: contentX(held), y: form.top(ofLine: line), width: width, height: TypesStyle.formRowHeight)
    }
}

/// What stays put above the lines.
@MainActor
final class FieldHeaderView: NSView {
    unowned var form: FieldFormView!

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func draw(_ dirty: NSRect) {
        form?.drawHeader(in: dirty)
    }

    override func mouseDown(with event: NSEvent) {
        form.pressed(atHeader: convert(event.locationInWindow, from: nil))
    }

    /// A branch name, in the header's coordinates: each as wide as its text and a padding, from the left.
    func branchRect(_ branch: Int) -> CGRect {
        guard let row = form.metrics.branches, form.sheet.branches.indices.contains(branch) else { return .zero }
        var x = row.minX
        for place in 0..<branch { x += form.branchWidth(place) + 6 }
        return CGRect(x: x, y: row.minY + 2, width: form.branchWidth(branch), height: row.height - 4)
    }
}

extension FieldCell.Control {
    /// A line of several choices, ticked or not, and their `None`.
    var isCheckLine: Bool {
        switch self {
        case .check, .clear: true
        default: false
        }
    }
}

// MARK: Presses

extension FieldFormView {
    func pressed(atGrid point: CGPoint) {
        guard let stop = stop(atGrid: point) else {
            window?.makeFirstResponder(self)
            return
        }
        if let cell = cell(at: stop), isTypedControl(cell.control), cell.isEditable, !isReadOnly {
            focus(stop)
            let held = grid.cellRect(line: stop.line, column: stop.column)
            cellEditor.placeSelection(at: CGPoint(x: point.x - held.minX + cellClip.documentVisibleRect.minX, y: cellEditor.textContainerInset.height + 2))
            return
        }
        if let cell = cell(at: stop), cell.control == .json, cell.isEditable, !isReadOnly {
            focus(stop)
            let held = grid.cellRect(line: stop.line, column: stop.column)
            jsonEditor.placeSelection(at: CGPoint(x: point.x - held.minX, y: point.y - held.minY + jsonClip.documentVisibleRect.minY))
            return
        }
        activate(stop)
    }

    func rightPressed(atGrid point: CGPoint) {
        guard let stop = stop(atGrid: point), let menu = contextMenu(for: stop) else { return }
        present(menu, at: point, in: grid)
    }

    func pressed(atHeader point: CGPoint) {
        if let back = metrics.back, back.contains(point), sheet.back != nil {
            goBack()
            return
        }
        for branch in sheet.branches.indices where header.branchRect(branch).contains(point) {
            pickBranch(branch)
            return
        }
    }

    func present(_ menu: NSMenu, at point: CGPoint, in view: NSView) {
        let point = view.convert(point, to: self)
        if let menuPresenter {
            menuPresenter(menu, point)
        } else {
            menu.popUp(positioning: nil, at: point, in: self)
        }
    }
}

// MARK: Drawing

extension FieldFormView {
    private var ink: NSColor { TypesStyle.formValueInk }

    func chipName(_ type: ShapeID) -> (text: String, isGone: Bool) {
        guard let index = editor.types, index.isType(type) else { return (TypesStyle.untitledType, true) }
        return (index.name(of: type) ?? TypesStyle.untitledType, false)
    }

    func branchWidth(_ branch: Int) -> CGFloat {
        textWidth(sheet.branches[branch], in: font) + 16
    }

    /// A line of text in a rect, vertically centered, cut with an ellipsis. The width it took.
    @discardableResult
    private func drawText(_ text: String, in rect: CGRect, ink: NSColor, font: NSFont? = nil, italic: Bool = false, align: NSTextAlignment = .left,
                          wave: Bool = false) -> CGFloat {
        guard !text.isEmpty, rect.width > 0 else { return 0 }
        var face = font ?? self.font
        if italic { face = NSFontManager.shared.convert(face, toHaveTrait: .italicFontMask) }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = align
        let attributes: [NSAttributedString.Key: Any] = [.font: face, .foregroundColor: ink, .paragraphStyle: style]
        let line = String(text.prefix { $0 != "\n" })
        let height = ceil(face.ascender - face.descender + face.leading)
        let box = CGRect(x: rect.minX, y: rect.minY + (rect.height - height) / 2, width: rect.width, height: height)
        NSAttributedString(string: line, attributes: attributes).draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        let took = min(ceil(NSAttributedString(string: line, attributes: [.font: face]).size().width), rect.width)
        if wave {
            let start = align == .right ? rect.maxX - took : rect.minX
            drawWave(from: start, to: start + took, at: box.maxY - 1)
        }
        return took
    }

    private func drawWave(from start: CGFloat, to end: CGFloat, at y: CGFloat) {
        let path = NSBezierPath()
        path.lineWidth = 1
        var x = start, up = false
        path.move(to: CGPoint(x: x, y: y))
        while x < end {
            x = min(x + TypesStyle.formWaveStep, end)
            up.toggle()
            path.line(to: CGPoint(x: x, y: y + (up ? TypesStyle.formWaveHeight : 0)))
        }
        TypesStyle.wrongInk.setStroke()
        path.stroke()
    }

    // MARK: Lines

    func drawLines(in dirty: NSRect) {
        let row = TypesStyle.formRowHeight
        if sheet.lines.isEmpty {
            if presentation == .card {
                drawText(FieldWords.noFields, in: CGRect(x: TypesStyle.formPadX, y: 0, width: grid.bounds.width - 2 * TypesStyle.formPadX, height: row),
                         ink: TypesStyle.formFaintInk, italic: true)
            }
            return
        }
        let first = max(line(atY: dirty.minY), 0), last = min(line(atY: dirty.maxY), sheet.lines.count - 1)
        guard first <= last else { return }
        for place in first...last { drawLine(place) }
        if let stop = focus, stop.line >= 0, stop.line <= last, stop.line >= first { drawFocus(stop) }
    }

    private func drawLine(_ place: Int) {
        let held = sheet.lines[place]
        let row = grid.lineRect(place)
        let nameRow = CGRect(x: row.minX, y: row.minY, width: row.width, height: TypesStyle.formRowHeight)
        if let isOpen = held.disclosure { drawTriangle(isOpen, at: CGPoint(x: TypesStyle.formPadX + CGFloat(held.depth) * TypesStyle.formIndent + 3, y: nameRow.midY)) }
        if let name = held.name {
            let rect = grid.nameRect(place)
            var space = rect
            let tail = (held.isNeeded ? TypesStyle.formDot + 6 : 0) + (held.chip == nil ? 0 : chipWidth(held.chip!) + 6)
            space.size.width = max(rect.width - tail, 0)
            let took = drawText(name, in: space, ink: TypesStyle.formNameInk)
            var x = rect.minX + took + 6
            if held.isNeeded {
                TypesStyle.neededInk.setFill()
                NSBezierPath(ovalIn: CGRect(x: x, y: nameRow.midY - TypesStyle.formDot / 2, width: TypesStyle.formDot, height: TypesStyle.formDot)).fill()
                x += TypesStyle.formDot + 6
            }
            if let chip = held.chip { drawChip(chip, at: CGPoint(x: x, y: nameRow.midY - TypesStyle.formChipHeight / 2)) }
        }
        for column in held.cells.indices { drawCell(held.cells[column], line: place, column: column, held: held) }
    }

    private func drawCell(_ cell: FieldCell, line: Int, column: Int, held: FieldLine) {
        var rect = grid.cellRect(line: line, column: column)
        let isEditing = editorStop == FieldStop(line: line, column: column) && !cellClip.isHidden
        let dim: CGFloat = cell.isEditable || isReadOnly == false ? 1 : TypesStyle.formDimmed
        let wrong = cell.mark == .wrong, needed = cell.mark == .needed
        let atRight = mode == .kinds
        switch cell.control {
        case .json:
            drawJSON(cell, in: rect, line: line)
        case .text, .oneOf:
            guard !isEditing else { return }
            let align: NSTextAlignment = cell.alignsRight ? .right : .left
            if cell.shown.isEmpty {
                drawText(cell.placeholder, in: rect, ink: needed ? TypesStyle.neededInk : TypesStyle.formFaintInk, italic: true, align: align)
            } else {
                drawText(cell.shown, in: rect, ink: wrong ? TypesStyle.wrongInk : ink, align: align, wave: wrong)
            }
        case .yesNo:
            drawBox(cell.value == .bool(true), at: CGPoint(x: rect.minX, y: rect.midY), dim: isReadOnly ? TypesStyle.formDimmed : 1)
        case .choice:
            let chevron: CGFloat = 12
            rect.size.width = max(rect.width - chevron, 0)
            if cell.shown.isEmpty {
                drawText(cell.placeholder, in: rect, ink: needed ? TypesStyle.neededInk : TypesStyle.formFaintInk, italic: true)
            } else {
                drawText(cell.shown, in: rect, ink: wrong ? TypesStyle.wrongInk : ink.withAlphaComponent(dim), wave: wrong)
            }
            if !isReadOnly { drawGlyph("⌄", at: CGPoint(x: rect.maxX + 2, y: rect.minY - 2), in: rect.height) }
        case .more(let summary):
            drawMore(summary, in: rect, mark: cell.mark, right: atRight)
        case .check(let on):
            let gutter = CGPoint(x: rect.minX - TypesStyle.formCheckWidth + TypesStyle.formBoxSize / 2, y: rect.midY)
            if on { drawCheckMark(at: gutter, dim: cell.isEditable ? 1 : TypesStyle.formDimmed) }
            drawText(cell.shown, in: rect, ink: ink.withAlphaComponent(cell.isEditable || !isReadOnly ? 1 : 0.7))
        case .clear:
            drawText(cell.shown, in: rect, ink: TypesStyle.formNameInk)
        case .label(let text):
            drawText(text, in: rect, ink: text == FieldWords.none ? TypesStyle.formFaintInk : TypesStyle.formNameInk, italic: text == FieldWords.none,
                     align: atRight ? .right : .left)
        }
    }

    /// The panel's box: a rounded outline (red when the value is wrong, accent while it has the keyboard) around the JSON, in
    /// the monospaced face, the first twelve lines; under it `Not JSON` while what was typed does not parse. The editor
    /// is over it while it has the keyboard.
    private func drawJSON(_ cell: FieldCell, in box: CGRect, line: Int) {
        let isEditing = jsonStop == FieldStop(line: line, column: 0) && !jsonClip.isHidden
        let text = jsonText(of: cell)
        let outline = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: TypesStyle.formJSONRadius, yRadius: TypesStyle.formJSONRadius)
        NSColor.textBackgroundColor.withAlphaComponent(0.5).setFill()
        outline.fill()
        (cell.mark == .wrong ? TypesStyle.wrongInk : isEditing ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        outline.lineWidth = 1
        outline.stroke()
        if !isEditing {
            let inner = box.insetBy(dx: TypesStyle.formJSONPad, dy: TypesStyle.formJSONPad)
            if text.isEmpty {
                drawText(cell.placeholder, in: CGRect(x: inner.minX, y: inner.minY, width: inner.width, height: TypesStyle.formJSONLineHeight), ink: TypesStyle.formFaintInk,
                         font: TypesStyle.formJSONFont, italic: true)
            } else {
                let style = NSMutableParagraphStyle()
                style.lineBreakMode = .byClipping
                let attributes: [NSAttributedString.Key: Any] = [.font: TypesStyle.formJSONFont, .foregroundColor: cell.isEditable || !isReadOnly ? ink : ink.withAlphaComponent(0.7), .paragraphStyle: style]
                NSAttributedString(string: text, attributes: attributes).draw(with: inner, options: [.usesLineFragmentOrigin])
            }
        }
        if jsonErrors.contains(cell.path) {
            drawText(FieldWords.notJSON, in: CGRect(x: box.minX, y: box.maxY, width: box.width, height: TypesStyle.formRowHeight), ink: TypesStyle.wrongInk)
        }
    }

    /// A summary and `›`: faint italic for none, red and wavy for wrong, amber for needed; items cut to what fits, ended `+N`.
    private func drawMore(_ summary: FieldSummary, in rect: CGRect, mark: FieldClass?, right: Bool) {
        let chevron: CGFloat = 12
        var room = rect
        room.size.width = max(rect.width - chevron, 0)
        var text = summary.text, italic = false, color = ink
        switch summary {
        case .empty: italic = true; color = mark == .needed ? TypesStyle.neededInk : TypesStyle.formFaintInk
        case .items(let items): text = cut(items, toFit: room.width)
        case .json: color = TypesStyle.formNameInk
        default: break
        }
        if mark == .wrong { color = TypesStyle.wrongInk } else if mark == .needed, !italic { color = TypesStyle.neededInk }
        let took: CGFloat
        if right {
            took = drawText(text, in: room, ink: color, italic: italic, align: .right, wave: mark == .wrong)
            drawGlyph("›", at: CGPoint(x: rect.maxX - chevron + 4, y: rect.minY), in: rect.height)
        } else {
            took = drawText(text, in: room, ink: color, italic: italic, wave: mark == .wrong)
            drawGlyph("›", at: CGPoint(x: rect.minX + took + 5, y: rect.minY), in: rect.height)
        }
    }

    /// `a, b, +3`: the items that fit the width, then how many are left.
    func cut(_ items: [String], toFit width: CGFloat) -> String {
        for count in stride(from: items.count, through: 1, by: -1) {
            let text = items.prefix(count).joined(separator: ", ") + (count < items.count ? ", +\(items.count - count)" : "")
            if textWidth(text, in: font) <= width { return text }
        }
        return items.count > 1 ? "\(items[0]), +\(items.count - 1)" : items.first ?? ""
    }

    private func drawGlyph(_ glyph: String, at point: CGPoint, in height: CGFloat) {
        drawText(glyph, in: CGRect(x: point.x, y: point.y, width: 12, height: height), ink: TypesStyle.formFaintInk)
    }

    private func drawBox(_ on: Bool, at center: CGPoint, dim: CGFloat) {
        let size = TypesStyle.formBoxSize
        let rect = CGRect(x: center.x, y: center.y - size / 2, width: size, height: size)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        if on {
            NSColor.controlAccentColor.withAlphaComponent(dim).setFill()
            path.fill()
            drawCheckMark(at: CGPoint(x: rect.midX, y: rect.midY), dim: dim, ink: .white)
        } else {
            TypesStyle.formFaintInk.withAlphaComponent(dim).setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func drawCheckMark(at center: CGPoint, dim: CGFloat, ink: NSColor? = nil) {
        let path = NSBezierPath()
        path.lineWidth = 1.6
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: CGPoint(x: center.x - 3.5, y: center.y))
        path.line(to: CGPoint(x: center.x - 1, y: center.y + 3))
        path.line(to: CGPoint(x: center.x + 3.5, y: center.y - 3))
        (ink ?? NSColor.controlAccentColor).withAlphaComponent(dim).setStroke()
        path.stroke()
    }

    private func drawTriangle(_ open: Bool, at center: CGPoint) {
        let path = NSBezierPath()
        if open {
            path.move(to: CGPoint(x: center.x - 4, y: center.y - 2))
            path.line(to: CGPoint(x: center.x + 4, y: center.y - 2))
            path.line(to: CGPoint(x: center.x, y: center.y + 3))
        } else {
            path.move(to: CGPoint(x: center.x - 2, y: center.y - 4))
            path.line(to: CGPoint(x: center.x - 2, y: center.y + 4))
            path.line(to: CGPoint(x: center.x + 3, y: center.y))
        }
        path.close()
        TypesStyle.formFaintInk.setFill()
        path.fill()
    }

    /// The type's chip: its color faint with a line of it and its title in the color's ink; a type that is gone,
    /// dashed and italic; no title, gray.
    @discardableResult
    func drawChip(_ type: ShapeID, at origin: CGPoint) -> CGFloat {
        let (text, isGone) = chipName(type)
        let font = TypesStyle.formChipFont
        let width = textWidth(text, in: font) + 2 * TypesStyle.formChipPad
        let rect = CGRect(x: origin.x, y: origin.y, width: width, height: TypesStyle.formChipHeight)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: rect.height / 2, yRadius: rect.height / 2)
        let untitled = text == TypesStyle.untitledType
        if isGone {
            NSColor.labelColor.withAlphaComponent(0.35).setStroke()
            path.setLineDash([2, 2], count: 2, phase: 0)
            path.lineWidth = 1
            path.stroke()
            drawText(text, in: rect.insetBy(dx: TypesStyle.formChipPad, dy: 0), ink: NSColor.labelColor.withAlphaComponent(0.65), font: font, italic: true)
            return width
        }
        let tint = untitled ? TypeColors.gray : TypeColors.light(type)
        tint.color.withAlphaComponent(TypesStyle.formChipFill).setFill()
        path.fill()
        tint.color.withAlphaComponent(TypesStyle.formChipStroke).setStroke()
        path.lineWidth = 1
        path.stroke()
        drawText(text, in: rect.insetBy(dx: TypesStyle.formChipPad, dy: 0), ink: untitled ? NSColor.secondaryLabelColor : tint.ink, font: font)
        return width
    }

    private func drawFocus(_ stop: FieldStop) {
        let rect: CGRect
        if stop.column == -1, let held = line(at: stop), held.cells.count != 1 || held.disclosure != nil {
            rect = grid.lineRect(stop.line).insetBy(dx: TypesStyle.formPadX - 2, dy: 1)
        } else {
            rect = grid.cellRect(line: stop.line, column: max(stop.column, 0)).insetBy(dx: -3, dy: 1)
        }
        let path = NSBezierPath(roundedRect: rect, xRadius: TypesStyle.formFocusRadius, yRadius: TypesStyle.formFocusRadius)
        path.lineWidth = TypesStyle.formFocusWidth
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    // MARK: The header

    func drawHeader(in dirty: NSRect) {
        if let back = metrics.back, let words = sheet.back {
            drawText(words, in: back, ink: NSColor.controlAccentColor)
        }
        if let row = metrics.chip, let type = sheet.chip { drawChip(type, at: CGPoint(x: row.minX, y: row.midY - TypesStyle.formChipHeight / 2)) }
        if metrics.branches != nil {
            for branch in sheet.branches.indices {
                let rect = header.branchRect(branch)
                let picked = branch == sheet.branch
                if picked {
                    NSColor.controlAccentColor.withAlphaComponent(0.15).setFill()
                    NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
                }
                drawText(sheet.branches[branch], in: rect, ink: picked ? ink : TypesStyle.formNameInk, align: .center)
                if let stop = focus, stop.line == -1, stop.column == branch {
                    let path = NSBezierPath(roundedRect: rect.insetBy(dx: -1, dy: -1), xRadius: 5, yRadius: 5)
                    path.lineWidth = TypesStyle.formFocusWidth
                    NSColor.controlAccentColor.setStroke()
                    path.stroke()
                }
            }
        }
        if let band = metrics.names, case .table(let names) = sheet.layout {
            let offset = scroll.contentView.bounds.minX
            let share = (grid.bounds.width - 2 * TypesStyle.formPadX) / CGFloat(max(names.count, 1))
            let sample = sheet.lines.first?.cells ?? []
            for (column, name) in names.enumerated() {
                let rect = CGRect(x: TypesStyle.formPadX + CGFloat(column) * share - offset, y: band.minY, width: share - TypesStyle.formGap + 2, height: band.height)
                let right = sample.indices.contains(column) && sample[column].alignsRight
                drawText(name, in: rect, ink: TypesStyle.formFaintInk, font: TypesStyle.formNamesFont, align: right ? .right : .left)
            }
            NSColor.separatorColor.setFill()
            CGRect(x: TypesStyle.formPadX, y: band.maxY - 1, width: band.width, height: 1).fill()
        }
    }
}
