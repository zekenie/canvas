import AppKit
@_spi(Host) import Canvas
import CanvasTesting
import Mentions
import TestKit

// The pill: its image and bounds in every state, and mention text to an attributed string and back.

@MainActor private let note = MentionTextStyle(font: .systemFont(ofSize: 16), color: NSColor(white: 0.12, alpha: 1), lineHeight: 19)
@MainActor private let neutral = MentionTextStyle(font: .systemFont(ofSize: 13), color: .labelColor, surface: .neutral)

private func live(_ label: String, symbol: String = "rectangle.fill", tint: NSColor? = nil) -> MentionResolution {
    .live(MentionAppearance(label: label, systemImage: symbol, kindName: "Plate", detail: "Plate", tint: tint))
}

/// The pill's image drawn on white at `scale` pixels a point (in a light appearance), its top-left
/// at the bitmap's.
@MainActor private func draw(_ pill: MentionAttachment, scale: CGFloat = 2) -> NSBitmapImageRep {
    let size = pill.bounds.size
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(ceil(size.width * scale)), pixelsHigh: Int(ceil(size.height * scale)),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        CGRect(origin: .zero, size: size).fill()
        pill.image?.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
    }
    return rep
}

/// The darkest channel of any pixel in the bitmap (0 black, 255 white).
@MainActor private func darkest(_ rep: NSBitmapImageRep) -> Int {
    var p = [Int](repeating: 0, count: 4), darkest = 255
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide {
            rep.getPixel(&p, atX: x, y: y)
            darkest = min(darkest, p[0], p[1], p[2])
        }
    }
    return darkest
}

/// Whether some pixel in a rect of points is colored like `test` says.
@MainActor private func anyPixel(_ rep: NSBitmapImageRep, in rect: CGRect, _ test: ([Int]) -> Bool) -> Bool {
    stride(from: rect.minY, to: rect.maxY, by: 0.5).contains { y in
        stride(from: rect.minX, to: rect.maxX, by: 0.5).contains { x in test(pixel(rep, at: CGPoint(x: x, y: y))) }
    }
}

/// The pills in an attributed string, in order.
@MainActor private func pills(in string: NSAttributedString) -> [MentionAttachment] {
    var pills: [MentionAttachment] = []
    string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, _, _ in
        if let pill = value as? MentionAttachment { pills.append(pill) }
    }
    return pills
}

/// How tall text is laid out `width` points wide, by string drawing.
@MainActor private func drawnHeight(_ string: NSAttributedString, width: CGFloat) -> CGFloat {
    string.boundingRect(with: CGSize(width: width, height: 10_000), options: [.usesLineFragmentOrigin]).height
}

/// How tall a TextKit 2 text view lays text out, `width` points wide.
@MainActor private func editedHeight(_ string: NSAttributedString, width: CGFloat) -> CGFloat {
    let view = NSTextView(frame: CGRect(x: 0, y: 0, width: width, height: 400))
    view.textContainer?.lineFragmentPadding = 0
    view.textStorage?.setAttributedString(string)
    guard let layout = view.textLayoutManager else { return -1 }
    layout.ensureLayout(for: layout.documentRange)
    return layout.usageBoundsForTextContainer.height
}

@MainActor let pillTests = Suite("Pills", [
    test("a live pill is 17 points tall for 16-point text, its bottom half a point above the descender; symbol then label") {
        let pill = MentionAttachment(target: idA, storedLabel: "Old", resolution: live("Groceries"), style: note)
        expectEqual(pill.bounds.height, 17)
        expectClose(pill.bounds.minY, note.font.descender + 0.5, within: 0.001)
        expectEqual(pill.bounds.minX, 0)
        expectEqual(pill.shownLabel, "Groceries")
        expectEqual(pill.writtenLabel, "Groceries")
        expectEqual(pill.help, nil)
        let missing = MentionAttachment(target: idA, storedLabel: "Groceries", resolution: .missing, style: note)
        expect(pill.bounds.width - missing.bounds.width > 10, "the symbol takes room: \(pill.bounds.width) vs \(missing.bounds.width)")
        expectEqual(missing.bounds.height, 17)
        let small = MentionAttachment(target: idA, storedLabel: "", resolution: live("Groceries"), style: neutral)
        expectEqual(small.bounds.height, (13 * 17.0 / 16).rounded())
    },

    test("no wider than 16 em, or the text it's in; a longer label is cut") {
        let long = String(repeating: "Very long name ", count: 10)
        let pill = MentionAttachment(target: idA, storedLabel: "", resolution: live(long), style: note)
        expectEqual(pill.bounds.width, 256)
        let narrow = MentionAttachment(target: idA, storedLabel: "", resolution: live(long), style: note, width: 100)
        expectEqual(narrow.bounds.width, 100)
        let short = MentionAttachment(target: idA, storedLabel: "", resolution: live("A"), style: note, width: 100)
        expect(short.bounds.width < 40, "\(short.bounds.width)")
    },

    test("a live pill's symbol is centered in a slot an em wide, so a pill is as wide whatever its symbol; a wider one is drawn smaller, within it") {
        // 9 to 18 points wide at 0.7 em, and one that isn't a symbol.
        let symbols = ["rectangle.fill", "note.text", "square.dashed", "curlybraces", "ellipsis.curlybraces", "no.such.symbol"]
        for style in [note, neutral] {
            let widths = symbols.map { MentionAttachment(target: idA, storedLabel: "", resolution: live("Groceries", symbol: $0), style: style).bounds.width }
            expectEqual(Set(widths).count, 1, "\(widths)")
        }
        // 0.3 em at each end, the slot's em, and 0.2 em before the label: 28.8 at 16.
        let wide = MentionAttachment(target: idA, storedLabel: "", resolution: live("", symbol: "ellipsis.curlybraces"), style: note)
        expectEqual(wide.bounds.width, 29)
        let rep = draw(wide)
        expect(anyPixel(rep, in: CGRect(x: 5, y: 0, width: 15, height: wide.bounds.height)) { $0[0] < 160 }, "the symbol, in its slot")
        expect(!anyPixel(rep, in: CGRect(x: 21.5, y: 0, width: wide.bounds.width - 21.5, height: wide.bounds.height)) { $0[0] < 200 },
               "none of it past the slot, 4.8 to 20.8")
    },

    test("text measured from itself alone: each mention a live pill by the name it holds, as wide as one drawn live while its shape is called that, whatever its kind; a missing one is narrower") {
        let text = MentionText([.text("Ask "), .mention(idA, label: "Groceries"), .text(" and "), .mention(idB, label: "Milk"), .text(" or "),
                                .mention(idA, label: "Food")])
        for style in [note, neutral] {
            let measured = style.measuredString(text, width: 200)
            var shown = [live("Groceries", symbol: "note.text"), live("Milk", symbol: "rectangle.dashed"), live("Food", symbol: "square.dashed")]
                .makeIterator()
            let drawn = style.attributedString(text, width: 200) { _ in shown.next()! }
            expectEqual(measured.string, drawn.string)
            expectEqual(pills(in: measured).map(\.bounds), pills(in: drawn).map(\.bounds))
            expectEqual(pills(in: measured).map(\.shownLabel), ["Groceries", "Milk", "Food"])
            expectEqual(pills(in: measured).map(\.target), [idA, idB, idA])
            let missing = style.attributedString(text, width: 200) { _ in .missing }
            expect(zip(pills(in: missing), pills(in: measured)).allSatisfy { $0.bounds.width < $1.bounds.width }, "no symbol")
        }
        // A long name is cut where a drawn one is: at the text's width.
        let long = MentionText([.mention(idA, label: String(repeating: "Very long name ", count: 10))])
        expectEqual(pills(in: note.measuredString(long, width: 100)).first?.bounds.width, 100)
        // So a text of many mentions is as tall measured as drawn, where measuring each as missing
        // (as notes made by draw were) left lines out.
        let many = MentionText((0..<24).flatMap { [MentionRun.text($0 == 0 ? "See " : " and "), .mention($0 % 2 == 0 ? idA : idB, label: "Milk")] })
        let width: CGFloat = 168
        let drawn = note.attributedString(many, width: width) { _ in live("Milk", symbol: "note.text") }
        expectEqual(drawnHeight(note.measuredString(many, width: width), width: width), drawnHeight(drawn, width: width))
        expect(drawnHeight(note.attributedString(many, width: width) { _ in .missing }, width: width) < drawnHeight(drawn, width: width))
    },

    test("missing and unavailable: the name held, or what's wrong when it holds none, and a tooltip") {
        let missing = MentionAttachment(target: idA, storedLabel: "Groceries", resolution: .missing, style: note)
        expectEqual(missing.shownLabel, "Groceries")
        expectEqual(missing.writtenLabel, "Groceries")
        expectEqual(missing.help, "Deleted")
        let unavailable = MentionAttachment(target: idA, storedLabel: "", resolution: .unavailable, style: note)
        expectEqual(unavailable.shownLabel, "Not available")
        expectEqual(unavailable.writtenLabel, "")
        expectEqual(unavailable.help, "Not available")
        expectEqual(MentionAttachment(target: idA, storedLabel: "", resolution: .missing, style: note).shownLabel, "Deleted")
    },

    test("update: a new look makes a new image and bounds; the same look keeps them") {
        let pill = MentionAttachment(target: idA, storedLabel: "G", resolution: live("Groceries"), style: note)
        let image = pill.image
        pill.update(live("Groceries"))
        expect(pill.image === image)
        pill.update(live("Groceries and more"))
        expect(pill.image !== image)
        expect(pill.bounds.width > 100)
        pill.update(.missing)
        expectEqual(pill.shownLabel, "G")
        expectEqual(pill.resolution, .missing)
    },

    test("colors: on a shape, the text's color at 10%; missing, no fill; selected, the selection's; on a neutral surface, the tint") {
        let pill = MentionAttachment(target: idA, storedLabel: "", resolution: live("Groceries"), style: note)
        let padding = CGPoint(x: pill.bounds.width - 3, y: pill.bounds.height / 2)
        let fill = pixel(draw(pill), at: padding)
        expect((215...245).contains(fill[0]) && fill[0] == fill[2], "a light gray fill: \(fill)")
        expect(darkest(draw(pill)) < 100, "the label, in the text's color")
        let missing = MentionAttachment(target: idA, storedLabel: "Groceries", resolution: .missing, style: note)
        expect(pixel(draw(missing), at: CGPoint(x: missing.bounds.width - 3, y: missing.bounds.height / 2))[0] > 250, "no fill")
        expect(anyPixel(draw(missing), in: CGRect(x: 0, y: 0, width: 1, height: missing.bounds.height)) { $0[0] < 230 }, "a dashed outline")
        // The name it holds is all that's left of what was mentioned: at about two thirds of the
        // text's strength, 4.6:1 on a note's yellow, not half (3:1). On white, the text's 31 at
        // 65% is about 109.
        expect((95...125).contains(darkest(draw(missing))), "its label, at about two thirds: \(darkest(draw(missing)))")
        pill.isSelected = true
        let selected = pixel(draw(pill), at: padding)
        expect(selected[2] > selected[0], "the selection's blue: \(selected)")
        let tinted = MentionAttachment(target: idA, storedLabel: "", resolution: live("Groceries", symbol: "circle.fill", tint: .systemRed),
                                       style: neutral)
        expect(anyPixel(draw(tinted), in: CGRect(x: 0, y: 0, width: 16, height: tinted.bounds.height)) { $0[0] > 180 && $0[1] < 120 },
               "a red symbol")
        let untinted = MentionAttachment(target: idA, storedLabel: "", resolution: live("Groceries", symbol: "circle.fill"), style: note)
        expect(!anyPixel(draw(untinted), in: CGRect(x: 0, y: 0, width: 16, height: untinted.bounds.height)) { $0[0] > 180 && $0[1] < 120 },
               "monochrome on a shape")
    },

    test("below 25% zoom only the fill draws") {
        let pill = MentionAttachment(target: idA, storedLabel: "", resolution: live("Groceries"), style: note)
        expect(darkest(draw(pill, scale: 1)) < 120)
        expect(darkest(draw(pill, scale: 0.2)) > 200, "\(darkest(draw(pill, scale: 0.2)))")
    },

    test("mention text as an attributed string: text with the style's attributes, each mention one pill; and back, canonically") {
        let text = MentionText(stored: "Ask @[Groceries](shape:\(idA.rawValue.uuidString.lowercased())) and @[Gone](shape:\(idB)) now")
        let string = note.attributedString(text) { $0 == idA ? live("Food") : .missing }
        expectEqual(string.string, "Ask \u{FFFC} and \u{FFFC} now")
        var pills: [MentionAttachment] = []
        string.enumerateAttribute(.attachment, in: NSRange(location: 0, length: string.length)) { value, _, _ in
            if let pill = value as? MentionAttachment { pills.append(pill) }
        }
        expectEqual(pills.map(\.target), [idA, idB])
        expectEqual(pills.map(\.shownLabel), ["Food", "Gone"])
        expectEqual(string.attribute(.toolTip, at: 10, effectiveRange: nil) as? String, "Deleted")
        expect(string.attribute(.toolTip, at: 4, effectiveRange: nil) == nil)
        expectEqual(string.attribute(.font, at: 4, effectiveRange: nil) as? NSFont, note.font, "a pill keeps the text's attributes")
        let back: MentionText = MentionTextStyle.mentionText(from: string)
        expectEqual(back.runs, [.text("Ask "), .mention(idA, label: "Food"), .text(" and "), .mention(idB, label: "Gone"), .text(" now")])
        expectEqual(back.stored, "Ask @[Food](shape:\(idA)) and @[Gone](shape:\(idB)) now", "canonical: uppercase ids, live names")
        let scoped: ScopedMentionText<Only<Plate>> = MentionTextStyle.mentionText(from: string)
        expectEqual(scoped.stored, back.stored)
    },

    test("text without mentions is one plain run with the style's attributes; an attachment that isn't a pill is dropped") {
        let plain = note.attributedString(MentionText(plain: "Just @[text]")) { _ in .missing }
        expectEqual(plain.string, "Just @[text]")
        var runs = 0
        plain.enumerateAttributes(in: NSRange(location: 0, length: plain.length)) { attributes, _, _ in
            runs += 1
            expectEqual(attributes[.font] as? NSFont, note.font)
            expectEqual(attributes[.foregroundColor] as? NSColor, note.color)
            let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
            expectEqual(paragraph?.minimumLineHeight, 19)
            expectEqual(paragraph?.maximumLineHeight, 19)
            expect(attributes[.attachment] == nil)
        }
        expectEqual(runs, 1)
        let mixed = NSMutableAttributedString(string: "A ")
        mixed.append(NSAttributedString(attachment: NSTextAttachment()))
        mixed.append(NSAttributedString(string: " B"))
        let back: MentionText = MentionTextStyle.mentionText(from: mixed)
        expectEqual(back.runs, [.text("A  B")])
        let empty: MentionText = MentionTextStyle.mentionText(from: note.attributedString(MentionText(plain: "")) { _ in .missing })
        expectEqual(empty.stored, "")
    },

    test("a pill never changes a line's height, in string drawing or TextKit 2, with a fixed line height or the font's") {
        let plainNote = MentionTextStyle(font: .systemFont(ofSize: 16), color: .black)
        for style in [note, plainNote] {
            let words = MentionText(plain: "First line\nAsk Groceries now\nThird Groceries\nlast")
            let pills = MentionText([.text("First line\nAsk "), .mention(idA, label: ""), .text(" now\nThird "), .mention(idB, label: "Gone"),
                                     .text("\nlast")])
            let a = style.attributedString(words) { _ in .missing }
            let b = style.attributedString(pills) { $0 == idA ? live("Groceries") : .missing }
            expectEqual(drawnHeight(b, width: 400), drawnHeight(a, width: 400))
            expectEqual(editedHeight(b, width: 400), editedHeight(a, width: 400))
            expect(drawnHeight(a, width: 400) > 3 * 18, "four lines")
        }
    },

    test("string drawing draws the pill where the text puts it") {
        let pills = MentionText([.mention(idA, label: "")])
        let string = note.attributedString(pills) { _ in live("Groceries") }
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 40, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            let context = NSGraphicsContext(bitmapImageRep: rep)!
            context.cgContext.translateBy(x: 0, y: 40)
            context.cgContext.scaleBy(x: 1, y: -1)
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
            NSColor.white.setFill()
            CGRect(x: 0, y: 0, width: 300, height: 40).fill()
            string.draw(with: CGRect(x: 0, y: 0, width: 300, height: 40), options: [.usesLineFragmentOrigin])
            NSGraphicsContext.restoreGraphicsState()
        }
        expect(anyPixel(rep, in: CGRect(x: 0, y: 0, width: 100, height: 19)) { $0[0] < 100 }, "the label")
        expect(!anyPixel(rep, in: CGRect(x: 120, y: 0, width: 180, height: 40)) { $0[0] < 250 }, "nothing past it")
    },

    test("styles are equal when their font, color, line height and surface are") {
        let same = MentionTextStyle(font: .systemFont(ofSize: 16), color: NSColor(white: 0.12, alpha: 1), lineHeight: 19)
        expect(same == note)
        expectEqual(same.hashValue, note.hashValue)
        expect(MentionTextStyle(font: .systemFont(ofSize: 16), color: NSColor(white: 0.12, alpha: 1), lineHeight: 19, surface: .neutral) != note)
        expect(MentionTextStyle(font: .systemFont(ofSize: 16), color: NSColor(white: 0.12, alpha: 1)) != note)
    },

    test("the jot: its editor shows its pills, a point on one selects it, typing writes back canonically; its render draws them") {
        let h = try mentionHarness()
        let plate = h.editor.add(Plate(CGRect(x: 300, y: 0, width: 120, height: 80)), titled: "Groceries")
        let lower = plate.rawValue.uuidString.lowercased()
        let jot = h.add(Jot(CGRect(x: 0, y: 0, width: 200, height: 200), text: MentionText(stored: "@[Old](shape:\(lower)) and more")))
        let before = renderBitmap(h.editor, size: CGSize(width: 200, height: 200))
        expect(anyPixel(before, in: CGRect(x: 16, y: 16, width: 60, height: 17)) { $0[0] < 100 }, "the pill's label, drawn")
        expect(h.editor.beginEditing(jot))
        let editing = try require(h.editor.makeEditingView())
        let view = try require(editing.firstResponder as? MentionTextView<AnyMentionable>)
        expectEqual(view.mentionText.stored, "@[Groceries](shape:\(plate)) and more", "live names, uppercase ids")
        expectEqual(view.string, "\u{FFFC} and more")
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 200), styleMask: [.borderless], backing: .buffered, defer: true)
        editing.view.frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        window.contentView = editing.view
        expect(view.selectPill(at: CGPoint(x: 26, y: 24)))
        expectEqual(view.selectedRange(), NSRange(location: 0, length: 1))
        expect(!view.selectPill(at: CGPoint(x: 150, y: 150)))
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText("!", replacementRange: view.selectedRange())
        expectEqual(h.editor.document[jot]?.typed(as: Jot.self)?.props.text.stored, "@[Groceries](shape:\(plate)) and more!")
        window.contentView = nil
    },
])
