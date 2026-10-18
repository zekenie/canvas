import AppKit
import Adornments
import Canvas
import Foundation

// The card drawn: the form's inks, fonts and marks (`FieldFormStyle`), the chip of a type as every chip of it is drawn.

extension DefinitionView {
    func drawLines(in dirty: NSRect) {
        for (line, row) in placed where row.intersects(dirty) {
            switch line {
            case .title:
                drawCell(.title, text: model.title, placeholder: TypesStyle.untitledType, font: titleFont)
            case .field(let index):
                let field = model.fields[index]
                drawCell(.fieldName(field.key), text: field.name, placeholder: "", font: font)
                drawKind(of: field)
            case .kindChoice(let index, let kind):
                if kind == 0 { drawKindList(of: index) }
            case .option(let index, let place):
                drawCell(.option(model.fields[index].key, place), text: model.fields[index].options[place], placeholder: "", font: font)
            case .newOption(let index):
                drawCell(.newOption(model.fields[index].key), text: "", placeholder: "", font: font)
            case .addField:
                drawCell(.addField, text: "", placeholder: TypesStyle.addFieldWords, font: font, italic: true)
            case .rule:
                NSColor.separatorColor.setFill()
                CGRect(x: TypesStyle.formPadX, y: row.midY, width: width - 2 * TypesStyle.formPadX, height: 1).fill()
            case .end(let index):
                drawEnd(model.ends[index], in: row)
            }
        }
    }

    /// A text stop: its text (the editor draws it while the caret is in it), or its placeholder, faint, and the focus around it.
    private func drawCell(_ stop: DefinitionStop, text: String, placeholder: String, font: NSFont, italic: Bool = false) {
        guard let rect = rect(of: stop) else { return }
        let editing = editorStop == stop && !cellClip.isHidden
        let shown = editing ? cellEditor.string : text
        if shown.isEmpty {
            drawText(placeholder, in: rect, ink: TypesStyle.formFaintInk, font: font, italic: italic)
        } else if !editing {
            drawText(shown, in: rect, ink: TypesStyle.formValueInk, font: font)
        }
        if focus == stop { drawFocus(rect.insetBy(dx: -3, dy: 1)) }
    }

    private func drawFocus(_ rect: CGRect) {
        let path = NSBezierPath(roundedRect: rect, xRadius: TypesStyle.formFocusRadius, yRadius: TypesStyle.formFocusRadius)
        path.lineWidth = TypesStyle.formFocusWidth
        NSColor.controlAccentColor.setStroke()
        path.stroke()
    }

    /// The kind at the right of a field's line: its name and a small chevron.
    private func drawKind(of field: DefinedField) {
        guard let rect = rect(of: .fieldKind(field.key)) else { return }
        let chevron: CGFloat = 8
        let textRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width - chevron - 6, height: rect.height)
        drawText(field.kind?.label ?? "", in: textRect, ink: TypesStyle.formNameInk, font: font, align: .right)
        let center = CGPoint(x: rect.maxX - chevron / 2, y: rect.midY)
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: CGPoint(x: center.x - 3, y: center.y - 1.5))
        path.line(to: CGPoint(x: center.x, y: center.y + 1.5))
        path.line(to: CGPoint(x: center.x + 3, y: center.y - 1.5))
        TypesStyle.formFaintInk.setStroke()
        path.stroke()
        if focus == .fieldKind(field.key) { drawFocus(rect.insetBy(dx: -3, dy: 1)) }
    }

    /// The five kinds in a box under the kind, the highlighted one filled.
    private func drawKindList(of field: Int) {
        guard let first = listRect(at: 0, of: field), let last = listRect(at: DefinedKind.allCases.count - 1, of: field) else { return }
        let box = first.union(last)
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSColor.controlBackgroundColor.setFill()
        path.fill()
        NSColor.separatorColor.setStroke()
        path.lineWidth = 1
        path.stroke()
        for (place, kind) in DefinedKind.allCases.enumerated() {
            guard let rect = listRect(at: place, of: field) else { continue }
            let picked = place == highlight
            if picked {
                NSColor.controlAccentColor.setFill()
                NSBezierPath(roundedRect: rect.insetBy(dx: 3, dy: 1), xRadius: 4, yRadius: 4).fill()
            }
            drawText(kind.label, in: rect.insetBy(dx: 10, dy: 0), ink: picked ? .white : TypesStyle.formValueInk, font: font)
        }
    }

    private func drawEnd(_ end: DefinitionEnd, in row: CGRect) {
        drawChip(end.type, at: CGPoint(x: TypesStyle.formPadX, y: row.midY - TypesStyle.formChipHeight / 2))
        drawCell(.endName(end.carrier), text: end.name, placeholder: end.placeholder, font: font)
        drawCheck(.needed(end.carrier), TypesStyle.neededChoice, on: end.rule.needed)
        drawCheck(.onlyOne(end.carrier), TypesStyle.onlyOneChoice, on: end.rule.onlyOne)
    }

    private func drawCheck(_ stop: DefinitionStop, _ label: String, on: Bool) {
        guard let rect = rect(of: stop) else { return }
        let size = TypesStyle.formBoxSize
        let box = CGRect(x: rect.minX, y: rect.midY - size / 2, width: size, height: size)
        let path = NSBezierPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        if on {
            NSColor.controlAccentColor.setFill()
            path.fill()
            let mark = NSBezierPath()
            mark.lineWidth = 1.6
            mark.lineCapStyle = .round
            mark.lineJoinStyle = .round
            mark.move(to: CGPoint(x: box.midX - 3.5, y: box.midY))
            mark.line(to: CGPoint(x: box.midX - 1, y: box.midY + 3))
            mark.line(to: CGPoint(x: box.midX + 3.5, y: box.midY - 3))
            NSColor.white.setStroke()
            mark.stroke()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
        let words = CGRect(x: box.maxX + TypesStyle.definitionCheckGap, y: rect.minY, width: rect.maxX - box.maxX - TypesStyle.definitionCheckGap, height: rect.height)
        drawText(label, in: words, ink: TypesStyle.formNameInk, font: TypesStyle.definitionCheckFont)
        if focus == stop { drawFocus(rect.insetBy(dx: -3, dy: 1)) }
    }

    /// The type's chip: its color faint with a line of it and its title in the color's ink; a type that is gone, dashed and italic.
    private func drawChip(_ type: ShapeID, at origin: CGPoint) {
        let (text, isGone) = chipName(type)
        let font = TypesStyle.formChipFont
        let chip = textWidth(text, in: font) + 2 * TypesStyle.formChipPad
        let rect = CGRect(x: origin.x, y: origin.y, width: chip, height: TypesStyle.formChipHeight)
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: rect.height / 2, yRadius: rect.height / 2)
        let untitled = text == TypesStyle.untitledType
        if isGone {
            NSColor.labelColor.withAlphaComponent(0.35).setStroke()
            path.setLineDash([2, 2], count: 2, phase: 0)
            path.lineWidth = 1
            path.stroke()
            drawText(text, in: rect.insetBy(dx: TypesStyle.formChipPad, dy: 0), ink: NSColor.labelColor.withAlphaComponent(0.65), font: font, italic: true)
            return
        }
        let tint = untitled ? TypeColors.gray : editor.types?.look(of: type).light ?? TypeColors.gray
        tint.color.withAlphaComponent(TypesStyle.formChipFill).setFill()
        path.fill()
        tint.color.withAlphaComponent(TypesStyle.formChipStroke).setStroke()
        path.lineWidth = 1
        path.stroke()
        drawText(text, in: rect.insetBy(dx: TypesStyle.formChipPad, dy: 0), ink: untitled ? NSColor.secondaryLabelColor : tint.ink, font: font)
    }

    /// A line of text in a rect, vertically centered, cut with an ellipsis.
    private func drawText(_ text: String, in rect: CGRect, ink: NSColor, font: NSFont, italic: Bool = false, align: NSTextAlignment = .left) {
        guard !text.isEmpty, rect.width > 0 else { return }
        var face = font
        if italic { face = NSFontManager.shared.convert(face, toHaveTrait: .italicFontMask) }
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = align
        let attributes: [NSAttributedString.Key: Any] = [.font: face, .foregroundColor: ink, .paragraphStyle: style]
        let line = String(text.prefix { $0 != "\n" })
        let height = ceil(face.ascender - face.descender + face.leading)
        let box = CGRect(x: rect.minX, y: rect.minY + (rect.height - height) / 2, width: rect.width, height: height)
        NSAttributedString(string: line, attributes: attributes).draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
