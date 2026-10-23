import AppKit
import Canvas
import CoreText
import Palette
import Selection

/// How adornments look: every plugin's alike. Sizes are view points; where they go is
/// `AdornmentLayout`'s.
@MainActor
enum AdornmentStyle {
    /// A title's pill's dark gray, lighter hovered and darker pressed (a clickable one's).
    static let fill = NSColor(white: 0.25, alpha: 0.9)
    static let hoverFill = NSColor(white: 0.4, alpha: 0.9)
    static let pressedFill = NSColor(white: 0.1, alpha: 0.9)
    /// Something done (`.success`): a tally with every item done.
    static var successFill: NSColor { .systemGreen }
    /// Between a capsule's ends and its text, in the row.
    static let rowPadding: CGFloat = 7
    /// Text in the row: one line, ending in "…" where it gives way.
    static let rowText: [NSAttributedString.Key: Any] = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph,
        ]
    }()
    /// Between a capsule's ends and its text, on the corner.
    static let cornerPadding: CGFloat = 5
    /// Text on the corner: figures that line up ("☑ 2/5").
    static let cornerText: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
        .foregroundColor: NSColor.white,
    ]
    /// A placeholder's text (`AdornmentLabel(placeholder:)`), dimmed: its place's, in white as faint
    /// as secondary text is on a dark surface (`secondaryLabelColor` in the dark).
    static let placeholderWhite = NSColor(white: 1, alpha: 0.55)
    /// A placeholder's text on a light tint: its ink at this strength; on a solid one, its ink at
    /// `solidPlaceholderInk`, the strength of `placeholderWhite`.
    static let lightPlaceholderInk: CGFloat = 0.6
    static let solidPlaceholderInk: CGFloat = 0.55
    private static let rowPlaceholderText = rowText.merging([.foregroundColor: placeholderWhite]) { $1 }
    private static let cornerPlaceholderText = cornerText.merging([.foregroundColor: placeholderWhite]) { $1 }

    /// A chip that names what is gone (`AdornmentLabel.missing()`): no fill, a dashed stroke at this
    /// strength of the canvas's label color, `missingStrokeWidth` wide, and its text in italic at
    /// `missingTextStrength` of it, as a mention's pill says it (Mentions); the name is the only
    /// record of what was there, so it reads, while the dashes and the italic say it's gone.
    static let missingStroke: CGFloat = 0.35
    static let missingStrokeWidth: CGFloat = 1
    static let missingDash: [CGFloat] = [2, 2]
    static let missingTextStrength: CGFloat = 0.65
    /// A chip that says something is wrong (`AdornmentLabel.wrong()`): a light tint in red, no line inside
    /// its edge, and under its text a wavy line one point wide, `waveHeight` high either side of the
    /// baseline, a corner every `waveStep`.
    static let waveWidth: CGFloat = 1
    static let waveHeight: CGFloat = 1
    static let waveStep: CGFloat = 2
    /// Plain text with no capsule (`AdornmentLabel.line(_:ink:)`): in this font, in the canvas's label color or the
    /// softer one.
    static let lineFont = NSFont.systemFont(ofSize: 11)
    /// A chip's number (`AdornmentLabel.counted(_:)`): `countGap` after its text, in the text's ink this strong.
    static let countGap: CGFloat = 4
    static let countStrength: CGFloat = 0.6
    /// A label's note (`AdornmentLabel.noted(_:)`) is set after its text as a number is, after this mark.
    static let noteMark = "·"
    /// The widest a pill at a label's lead is, whatever its name: past it the name ends in an ellipsis, its note kept.
    static let leadMaxWidth: CGFloat = 240
    /// A dot (`AdornmentLabel.Mark.dot`) is this across, and a ghost this wide, as tall as a row.
    static let dotSize: CGFloat = 10
    static let ghostWidth: CGFloat = 30
    /// Hovered and pressed, a faint fill of the same color, since it has none to lighten.
    static let missingHoverFill: CGFloat = 0.1
    static let missingPressedFill: CGFloat = 0.2
    /// The text of a chip that is missing, in its place: the place's font, italic, in the canvas's
    /// own (dynamic) label color.
    static let missingText: [NSAttributedString.Key: Any] = missingAttributes(of: rowText)
    private static let cornerMissingText = missingAttributes(of: cornerText)

    private static func missingAttributes(of base: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
        var attributes = base
        if let font = base[.font] as? NSFont { attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        attributes[.foregroundColor] = NSColor.labelColor.withAlphaComponent(missingTextStrength)
        return attributes
    }

    /// Between a group's chips that didn't all fit, the one chip that stands for them is "+" and
    /// how many.
    static let overflowPrefix = "+"

    /// What a label's text is set in, in its place: the place's text, dimmed for a placeholder,
    /// italic and in the canvas's colors where it's missing.
    private static func textAttributes(of label: AdornmentLabel, isCorner: Bool) -> [NSAttributedString.Key: Any] {
        if label.isMissing { return isCorner ? cornerMissingText : missingText }
        if let tint = label.tint {
            var attributes = isCorner ? cornerText : rowText
            let dimmed = tint.style == .light ? lightPlaceholderInk : solidPlaceholderInk
            attributes[.foregroundColor] = label.isPlaceholder ? tint.ink.withAlphaComponent(dimmed) : tint.ink
            return attributes
        }
        return switch (isCorner, label.isPlaceholder) {
        case (false, false): rowText
        case (false, true): rowPlaceholderText
        case (true, false): cornerText
        case (true, true): cornerPlaceholderText
        }
    }

    /// A chip that shows a moment (`ChipFade`) shows in full this long, longer while the pointer's on
    /// it, which is looked at again this often, then fades over `fadeDuration`, a frame this long.
    static let lingerDuration: Duration = .milliseconds(1500)
    static let hoverRecheck: Duration = .milliseconds(500)
    static let fadeDuration: Duration = .milliseconds(300)
    static let fadeFrame: Duration = .milliseconds(16)

    /// A symbol before text: its place, as wide as the place's text is tall, and the gap after it.
    static let rowSymbolPlace: CGFloat = 11
    static let cornerSymbolPlace: CGFloat = 10
    static let symbolGap: CGFloat = 3

    /// The room a label's number keeps after its text, in its place: the gap and the number as it is set; 0 for none.
    /// The row's layout counts it with the lead (`ShownAdornment.lead`), so text that gives way leaves the number whole.
    static func countRoom(of label: AdornmentLabel, in placement: AdornmentPlacement) -> CGFloat {
        guard let count = countText(of: label, in: placement) else { return 0 }
        return countGap + count.size().width.rounded(.up)
    }

    /// A label's number, set in its place's text at `countStrength` of the text's ink; nil for none.
    private static func countText(of label: AdornmentLabel, in placement: AdornmentPlacement) -> NSAttributedString? {
        guard label.text != nil, let figure = label.note.map({ noteMark + " " + $0 }) ?? label.count.map(String.init) else { return nil }
        var attributes = textAttributes(of: label, isCorner: placement == .onTopRightCorner)
        if let ink = attributes[.foregroundColor] as? NSColor { attributes[.foregroundColor] = ink.withAlphaComponent(ink.alphaComponent * countStrength) }
        return NSAttributedString(string: figure, attributes: attributes)
    }

    /// How far a label's text starts past its padding: its symbol's place and the gap after it, for
    /// text with a symbol; else nothing.
    static func lead(of label: AdornmentLabel, in placement: AdornmentPlacement) -> CGFloat {
        guard label.text != nil, label.systemImage != nil, !label.isMissing else { return 0 }
        return (placement == .onTopRightCorner ? cornerSymbolPlace : rowSymbolPlace) + symbolGap
    }

    /// A symbol as a disc `height` tall shows it: half as tall, bold, white.
    static func symbol(_ name: String, height: CGFloat, tint: AdornmentTint? = nil) -> NSImage? {
        symbol(SymbolKey(name: name, pointSize: height / 2, weight: .bold, white: 1, ink: tint.map(ink(of:))))
    }

    /// A symbol before text in its place: two points smaller than the text, semibold, in white a
    /// little softer than the text's, so it marks the text rather than reading as part of it (a
    /// label's `brightSymbol()`: as white as the text).
    static func leadingSymbol(_ name: String, in placement: AdornmentPlacement, bright: Bool = false, tint: AdornmentTint? = nil) -> NSImage? {
        symbol(SymbolKey(name: name, pointSize: placement == .onTopRightCorner ? 8 : 9, weight: .semibold,
                         white: bright ? 1 : 0.75, ink: tint.map(ink(of:))))
    }

    /// A tint's ink as it is now, in the appearance being drawn: an image made with a dynamic
    /// color is fixed when it is made, so the image is made (and kept) for the color it resolves to.
    private static func ink(of tint: AdornmentTint) -> NSColor {
        var resolved = tint.ink
        NSAppearance.currentDrawing().performAsCurrentDrawingAppearance { resolved = NSColor(cgColor: tint.ink.cgColor) ?? tint.ink }
        return resolved
    }

    /// What a symbol's image is made from: its name, size and weight, and how opaque its white is, or
    /// the ink it is drawn in (a tint's, as it resolves in the appearance drawn).
    private struct SymbolKey: Hashable {
        let name: String
        let pointSize: CGFloat
        let weight: NSFont.Weight
        let white: CGFloat
        let ink: NSColor?
    }
    private static var symbols: [SymbolKey: NSImage?] = [:]

    private static func symbol(_ key: SymbolKey) -> NSImage? {
        if let known = symbols[key] { return known }
        let configuration = NSImage.SymbolConfiguration(pointSize: key.pointSize, weight: key.weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [key.ink ?? NSColor(white: 1, alpha: key.white)]))
        let image = NSImage(systemSymbolName: key.name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        symbols[key] = image
        return image
    }

    /// A label as its place draws it in full: text set in the place's font and measured, after its
    /// symbol if it has one (`symbol`: its image, nil for a name SF Symbols hasn't, and its place's
    /// width; the text starts that and `symbolGap` past the padding) and before its number if it has one
    /// (`count`), or a symbol's image alone, with the width it takes.
    enum Face {
        case text(NSAttributedString, size: CGSize, symbol: (image: NSImage?, place: CGFloat)?, count: NSAttributedString?, width: CGFloat)
        case symbol(NSImage?, width: CGFloat)
        /// A dot or a ghost: no text, no symbol.
        case blank(width: CGFloat, height: CGFloat)
        /// Plain text, set once in each appearance (its ink follows it) as a Core Text line, with no capsule or
        /// padding: drawn from the line each frame, never typeset again. `size` is what the text measures as a string
        /// (the height of the line fragment a string drawn at a point sets it in), `ascent` the line's.
        case line(light: CTLine, dark: CTLine, size: CGSize, ascent: CGFloat, width: CGFloat)

        var width: CGFloat {
            switch self {
            case .text(_, _, _, _, let width), .symbol(_, let width), .line(_, _, _, _, let width), .blank(let width, _): width
            }
        }

        /// How tall it is drawn in its place.
        func height(in placement: AdornmentPlacement) -> CGFloat {
            if case .blank(_, let height) = self { return height }
            return AdornmentLayout.height(of: placement)
        }
    }

    private static let appearances: [NSAppearance.Name] = [.darkAqua, .aqua]

    /// Whether the appearance being drawn is the dark one.
    static func isDarkAppearance() -> Bool { NSAppearance.currentDrawing().bestMatch(from: appearances) == .darkAqua }

    /// A plain line's ink in an appearance: the label color, or the softer one.
    private static func lineColor(of ink: AdornmentLabel.LineInk, in name: NSAppearance.Name) -> NSColor {
        let base: NSColor = ink == .primary ? .labelColor : .secondaryLabelColor
        var resolved = base
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance { resolved = NSColor(cgColor: base.cgColor) ?? base }
        return resolved
    }

    /// The face of a plain line of text: set and measured here and nowhere else, once in each appearance.
    private static func lineFace(_ text: String, ink: AdornmentLabel.LineInk) -> Face {
        func string(in name: NSAppearance.Name) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [
                .font: lineFont, NSAttributedString.Key(kCTForegroundColorAttributeName as String): lineColor(of: ink, in: name).cgColor])
        }
        let lit = string(in: .aqua)
        let size = lit.size()
        let light = CTLineCreateWithAttributedString(lit), dark = CTLineCreateWithAttributedString(string(in: .darkAqua))
        var ascent: CGFloat = 0
        CTLineGetTypographicBounds(light, &ascent, nil, nil)
        return .line(light: light, dark: dark, size: size, ascent: ascent, width: size.width.rounded(.up))
    }

    /// The face of a label that shows something (`ShownAdornment`): its text, after its symbol if
    /// it has one, else its symbol in a disc.
    static func face(of label: AdornmentLabel, in placement: AdornmentPlacement) -> Face {
        let height = AdornmentLayout.height(of: placement)
        switch label.mark {
        case .dot?: return .blank(width: dotSize, height: dotSize)
        case .ghost?: return .blank(width: ghostWidth, height: height)
        case nil: break
        }
        if let ink = label.lineInk, let text = label.text { return lineFace(text, ink: ink) }
        guard let text = label.text else {
            return .symbol(label.isMissing ? nil : label.systemImage.flatMap { symbol($0, height: height, tint: label.tint) }, width: height)
        }
        let isCorner = placement == .onTopRightCorner
        let string = NSAttributedString(string: text, attributes: textAttributes(of: label, isCorner: isCorner))
        let size = string.size()
        let mark = label.isMissing ? nil : label.systemImage.map { (image: leadingSymbol($0, in: placement, bright: label.hasBrightSymbol, tint: label.tint), place: isCorner ? cornerSymbolPlace : rowSymbolPlace) }
        let width = (size.width + lead(of: label, in: placement) + countRoom(of: label, in: placement)
                     + 2 * (isCorner ? cornerPadding : rowPadding)).rounded(.up)
        return .text(string, size: size, symbol: mark, count: countText(of: label, in: placement),
                     width: placement == .inLabelLead ? min(width, leadMaxWidth) : width)
    }

    private static func resolvedMissing(_ text: NSAttributedString) -> NSAttributedString {
        let resolved = NSMutableAttributedString(attributedString: text)
        resolved.addAttribute(.foregroundColor, value: NSColor(cgColor: NSColor.labelColor.withAlphaComponent(missingTextStrength).cgColor) as Any,
                              range: NSRange(location: 0, length: resolved.length))
        return resolved
    }

    /// A chip that is missing: no fill (a faint one hovered or pressed), a dashed stroke, in the
    /// canvas's label color. `unit` is how many units of the context a point is.
    private static func paintMissing(_ path: CGPath, unit: CGFloat, look: Look, in cg: CGContext) {
        let ink = NSColor.labelColor
        if look != .normal {
            cg.addPath(path)
            cg.setFillColor(ink.withAlphaComponent(look == .hovered ? missingHoverFill : missingPressedFill).cgColor)
            cg.fillPath()
        }
        cg.addPath(path)
        cg.setStrokeColor(ink.withAlphaComponent(missingStroke).cgColor)
        cg.setLineWidth(missingStrokeWidth * unit)
        cg.setLineDash(phase: 0, lengths: missingDash.map { $0 * unit })
        cg.strokePath()
    }

    /// A wavy line `width` long from `x`, its middle at `y` (`unit` context units a point): a corner every
    /// `waveStep`, up and down `waveHeight` from it.
    private static func paintWave(from x: CGFloat, width: CGFloat, at y: CGFloat, color: NSColor, unit: CGFloat, in cg: CGContext) {
        guard width > 0 else { return }
        cg.saveGState()
        defer { cg.restoreGState() }
        cg.setStrokeColor(color.cgColor)
        cg.setLineWidth(waveWidth * unit)
        cg.setLineJoin(.round)
        cg.setLineDash(phase: 0, lengths: [])
        var along: CGFloat = 0, up = false
        cg.move(to: CGPoint(x: x, y: y))
        while along < width {
            along = min(width, along + waveStep)
            up.toggle()
            cg.addLine(to: CGPoint(x: x + along, y: y + (up ? -waveHeight : waveHeight) * unit))
        }
        cg.strokePath()
    }

    /// How a clickable adornment is drawn: hovered or pressed while the pointer's on it.
    enum Look: Int {
        case normal, hovered, pressed
    }
    /// How strong a dot's color is, normal, hovered and pressed.
    static let dotStrength: [CGFloat] = [0.7, 0.85, 1]

    /// A tint's capsule: solid is its color, lighter hovered and darker pressed; light is its color
    /// faint, a little less so hovered and pressed, with a thin line of it. Made for an appearance
    /// (a color that follows it is a different color in each) and kept, once a tint and appearance.
    struct TintFills {
        let normal: NSColor, hovered: NSColor, pressed: NSColor
        /// A light tint's line inside the capsule's edge.
        let line: NSColor?

        func fill(for look: Look) -> NSColor {
            switch look {
            case .normal: normal
            case .hovered: hovered
            case .pressed: pressed
            }
        }
    }
    static let lightFill: [CGFloat] = [0.14, 0.22, 0.30]
    static let lightLine: CGFloat = 0.35
    static let lightLineWidth: CGFloat = 1
    /// What a tint's fills are kept by: the tint and whether the appearance drawn is dark.
    private struct FillsKey: Hashable {
        let tint: AdornmentTint
        let isDark: Bool
    }
    private static var tintFillsKept: [FillsKey: TintFills] = [:]
    /// How many are kept before the lot is let go: a color picked by dragging asks for a tint a frame.
    private static let tintFillsCapacity = 1024
    /// The appearance last drawn in and whether it is dark: asked once an appearance, not a label.
    private static var drawnAppearance: (appearance: NSAppearance, isDark: Bool)?

    /// Whether the appearance being drawn in is dark.
    private static var drawsDark: Bool {
        let current = NSAppearance.currentDrawing()
        if let known = drawnAppearance, known.appearance === current { return known.isDark }
        let isDark = current.isDark
        drawnAppearance = (current, isDark)
        return isDark
    }

    /// A tint's fills in the appearance being drawn, its color resolved to what it is in it.
    static func fills(of tint: AdornmentTint) -> TintFills {
        let key = FillsKey(tint: tint, isDark: drawsDark)
        if let known = tintFillsKept[key] { return known }
        let color = NSColor(cgColor: tint.color.cgColor) ?? tint.color
        let fills: TintFills
        let edge = tint.edge.map { NSColor(cgColor: $0.cgColor) ?? $0 }
        switch tint.style {
        case .solid:
            fills = TintFills(normal: color, hovered: color.blended(withFraction: 0.15, of: .white) ?? color,
                              pressed: color.blended(withFraction: 0.2, of: .black) ?? color, line: edge)
        case .light:
            fills = TintFills(normal: color.withAlphaComponent(lightFill[0]), hovered: color.withAlphaComponent(lightFill[1]),
                              pressed: color.withAlphaComponent(lightFill[2]), line: edge ?? color.withAlphaComponent(lightLine))
        }
        if tintFillsKept.count >= tintFillsCapacity { tintFillsKept.removeAll(keepingCapacity: true) }
        tintFillsKept[key] = fills
        return fills
    }

    /// What a label's capsule is filled with: its tint's if it has one (a missing label has no fill, and
    /// ignores it), else its tone's.
    static func fill(for label: AdornmentLabel, look: Look) -> NSColor {
        if !label.isMissing, let tint = label.tint { return fills(of: tint).fill(for: look) }
        return fill(for: label.tone, look: look)
    }

    /// A light tint's line, `unit` context units a point, inside `path`'s edge.
    private static func paintLine(_ line: NSColor, around rect: CGRect, radius: CGFloat?, unit: CGFloat, in cg: CGContext) {
        let inset = lightLineWidth * unit / 2
        let box = rect.insetBy(dx: inset, dy: inset)
        cg.addPath(radius.map { CGPath(roundedRect: box, cornerWidth: max(0, $0 - inset), cornerHeight: max(0, $0 - inset), transform: nil) }
                   ?? CGPath(ellipseIn: box, transform: nil))
        cg.setStrokeColor(line.cgColor)
        cg.setLineWidth(lightLineWidth * unit)
        cg.setLineDash(phase: 0, lengths: [])
        cg.strokePath()
    }

    static func fill(for tone: AdornmentLabel.Tone, look: Look) -> NSColor {
        switch (tone, look) {
        case (.neutral, .normal): fill
        case (.neutral, .hovered): hoverFill
        case (.neutral, .pressed): pressedFill
        case (.success, .normal): successFill
        case (.success, .hovered): successFill.blended(withFraction: 0.2, of: .white) ?? successFill
        case (.success, .pressed): successFill.blended(withFraction: 0.2, of: .black) ?? successFill
        }
    }

    /// An adornment in full, its face in its frame (view points from `corner`, the corner of its
    /// shape its place runs from, in world units, at `scale` world units per point): a capsule with
    /// its text, or a disc with its symbol in the middle, all of it under one transparency layer
    /// when it's drawn less than opaque.
    /// `isDark`: whether the appearance being drawn is the dark one, which a line of text is drawn by; a caller that
    /// draws many in one frame asks it once.
    /// `turned`: a tab turned down its edge (`AdornmentLayout.Slot.isTurned`), its upright frame holding the
    /// face drawn a quarter turn clockwise, reading downward.
    static func draw(_ label: AdornmentLabel, in placement: AdornmentPlacement, face: Face, in frame: CGRect, from corner: CGPoint, scale: CGFloat, look: Look,
                     isDark: Bool? = nil, turned: Bool = false, in cg: CGContext) {
        if turned {
            cg.saveGState()
            defer { cg.restoreGState() }
            cg.translateBy(x: corner.x + frame.maxX * scale, y: corner.y + frame.minY * scale)
            cg.rotate(by: .pi / 2)
            draw(label, in: placement, face: face, in: CGRect(x: 0, y: 0, width: frame.height, height: frame.width), from: .zero, scale: scale,
                 look: look, isDark: isDark, in: cg)
            return
        }
        let opacity = label.opacity
        cg.saveGState()
        defer { cg.restoreGState() }
        if opacity < 1 {
            cg.setAlpha(opacity)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        // A line of text has no capsule, so no fill.
        let isLine: Bool
        if case .line = face { isLine = true } else { isLine = false }
        if !isLine { cg.setFillColor(fill(for: label, look: look).cgColor) }
        let line = isLine || label.isMissing || label.isWrong ? nil : label.tint.flatMap { fills(of: $0).line }
        switch face {
        case .symbol(let image, _):
            if label.isMissing {
                let disc = CGRect(x: corner.x + frame.minX * scale, y: corner.y + frame.minY * scale,
                                  width: frame.width * scale, height: frame.height * scale)
                paintMissing(CGPath(ellipseIn: disc, transform: nil), unit: scale, look: look, in: cg)
                break
            }
            // In world units, the symbol's image sized to match: an image drawn into a scaled
            // context comes out otherwise.
            let disc = CGRect(x: corner.x + frame.minX * scale, y: corner.y + frame.minY * scale,
                              width: frame.width * scale, height: frame.height * scale)
            cg.fillEllipse(in: disc)
            if let line { paintLine(line, around: disc, radius: nil, unit: scale, in: cg) }
            if let image = label.tint != nil ? label.systemImage.flatMap({ symbol($0, height: frame.height, tint: label.tint) }) : image {
                let size = image.size, glyphScale = disc.width / frame.width
                image.draw(in: CGRect(x: disc.midX - size.width * glyphScale / 2, y: disc.midY - size.height * glyphScale / 2,
                                      width: size.width * glyphScale, height: size.height * glyphScale),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        case .blank:
            let box = CGRect(x: corner.x + frame.minX * scale, y: corner.y + frame.minY * scale, width: frame.width * scale, height: frame.height * scale)
            if label.mark == .ghost {
                let radius = min(box.width, box.height) / 2
                paintMissing(CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil), unit: scale, look: look, in: cg)
            } else {
                // A dot has no letters to carry its tint: it is the color itself, strong, where a pill's capsule is faint.
                if let tint = label.tint { cg.setFillColor(tint.color.withAlphaComponent(dotStrength[look.rawValue]).cgColor) }
                cg.fillEllipse(in: box)
                if let line { paintLine(line, around: box, radius: nil, unit: scale, in: cg) }
            }
        case .line(let light, let dark, let size, let ascent, _):
            // No capsule: the text where its frame is, in the ink of the appearance drawn. Its baseline is where a
            // string drawn at the frame's top sets it: a whole ascent below it.
            cg.translateBy(x: corner.x, y: corner.y)
            cg.scaleBy(x: scale, y: scale)
            let isDark = isDark ?? Self.isDarkAppearance()
            cg.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
            cg.textPosition = CGPoint(x: frame.minX, y: frame.midY - size.height / 2 + ascent.rounded(.up))
            CTLineDraw(isDark ? dark : light, cg)
            cg.textMatrix = .identity
        case .text(let laidOut, let size, let symbol, let count, _):
            // A missing chip's ink is the canvas's label color, which the face was made before the
            // drawing's appearance was known: resolved now, as its dashes are.
            let text = label.isMissing ? resolvedMissing(laidOut) : laidOut
            cg.translateBy(x: corner.x, y: corner.y)
            cg.scaleBy(x: scale, y: scale)
            // A tab's corners are a tab's; anything else is a capsule.
            let radius = placement == .onTopEdge ? AdornmentLayout.tabRadius : min(frame.width, frame.height) / 2
            let capsule = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
            if label.isMissing {
                paintMissing(capsule, unit: 1, look: look, in: cg)
            } else {
                cg.addPath(capsule)
                cg.fillPath()
                if let line { paintLine(line, around: frame, radius: radius, unit: 1, in: cg) }
            }
            let isCorner = placement == .onTopRightCorner
            let start = frame.minX + (isCorner ? cornerPadding : rowPadding)
            // Where the text starts, as its width was measured.
            let lead = lead(of: label, in: placement)
            // A tinted label's symbol is made for the appearance drawn, as its ink resolves in it.
            let mark = label.tint != nil ? label.systemImage.flatMap { leadingSymbol($0, in: placement, bright: label.hasBrightSymbol, tint: label.tint) } : symbol?.image
            if let symbol, let image = mark {
                // In world units from the corner, as a disc's symbol is drawn: centered in its place.
                let size = image.size
                cg.saveGState()
                cg.scaleBy(x: 1 / scale, y: 1 / scale)
                image.draw(in: CGRect(x: (start + (symbol.place - size.width) / 2) * scale, y: (frame.midY - size.height / 2) * scale,
                                      width: size.width * scale, height: size.height * scale),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                cg.restoreGState()
            }
            // The number keeps its room at the capsule's end, and the text gives way before it.
            let countWidth = count.map { $0.size().width.rounded(.up) } ?? 0
            let countRoom = count == nil ? 0 : countGap + countWidth
            let textRoom = max(0, frame.width - 2 * (isCorner ? cornerPadding : rowPadding) - lead - countRoom)
            if isCorner {
                text.draw(at: CGPoint(x: start + lead, y: frame.midY - size.height / 2))
            } else {
                text.draw(with: CGRect(x: start + lead, y: frame.midY - size.height / 2, width: textRoom, height: size.height),
                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
            if let count {
                let x = isCorner ? start + lead + size.width + countGap : frame.maxX - rowPadding - countWidth
                count.draw(at: CGPoint(x: x, y: frame.midY - size.height / 2))
            }
            if label.isWrong, !label.isMissing {
                paintWave(from: start + lead, width: min(size.width, textRoom), at: frame.midY + size.height / 2 - waveHeight,
                          color: AdornmentLabel.wrongColor, unit: 1, in: cg)
            }
        }
        if opacity < 1 { cg.endTransparencyLayer() }
    }
}


/// Every shape's adornments, above every shape, in one pass: a shape at a time, back to front, so
/// a front shape's are over a back shape's. They go where their shape is drawn
/// (`editor.setDrawingOffset`), so they shake with it, and keep drawing while a session runs.
/// Zoomed out, where shapes are drawn as skeletons (`OverlayContext.drawsSkeleton(of:)`), only tabs
/// are drawn (`AdornmentPlacement.onTopEdge`: what names a shape that holds others): a skeleton shows
/// what a shape is and where, and what's said just outside it (a title, a lock) is left off, as the
/// shape's text is greeked; Titles puts a title on the shape itself there. The shape being edited,
/// drawn in full, keeps its own, in full. The frame allocates nothing per shape once its labels are
/// kept, but for the tabs placed together, once a frame. Shapes never know about them.
struct AdornmentOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in context: OverlayContext) {
        guard let state = context.editor.adornmentState, !state.isEmpty else { return }
        // Zoomed out, only tabs, and the shape being edited's: it's the one shape drawn in full.
        let skeletons = context.drawsSkeletons, editing = context.editor.editingShapeID
        if skeletons && editing == nil && !state.hasTabs { return }
        let scale = AdornmentLayout.scale(atZoom: context.zoom), cg = context.cg
        let tabs = state.hasTabs ? state.drawnTabs(in: context.visibleRect) : nil
        // The clickable adornment hovered and pressed, if either is one: each adornment is compared
        // with them as it is, never boxed as a button of its own.
        let hovered = context.editor.hoveredButton?.base as? AdornmentButton
        let pressed = context.editor.pressedButton?.base as? AdornmentButton
        // What's in view where shapes are drawn: grown by the farthest a shake draws one, so a shape just
        // outside the view, shaken toward it, shows what of its adornments reaches in.
        let reach = context.worldDrawingReach
        let visible = context.visibleRect.insetBy(dx: -reach, dy: -reach)
        let records: [AnyShapeRecord]
        if skeletons {
            // The shapes with a tab, back to front, and the one being edited, drawn in full, last.
            let document = context.editor.document
            var shown = (tabs?.shapes ?? []).compactMap { $0 == editing ? nil : document[$0] }
            if let editing, let record = document[editing] { shown.append(record) }
            records = shown
        } else {
            records = context.editor.paintOrder(in: AdornmentLayout.area(showing: visible, scale: scale))
        }
        var slots: [AdornmentLayout.Slot?] = []
        let isDark = AdornmentStyle.isDarkAppearance()
        for record in records {
            let skeleton = context.drawsSkeleton(of: record.id), hasTab = tabs?.tabs[record.id] != nil
            // The area is the widest reach any shape has: nothing is made for a shape whose own does not reach the view.
            guard skeleton ? hasTab : hasTab || state.mayShow(record, in: visible, scale: scale, shapes: context.shapes) else { continue }
            guard let laidOut = state.laidOut(record, tabsOnly: skeleton),
                  let anchored = AdornmentState.anchored(of: record.id, in: context.shapes, zoom: context.zoom) else { continue }
            let anchor = anchored.rect
            state.slots(of: laidOut, id: record.id, anchored: anchored, scale: scale, tabs: tabs, into: &slots)
            // Where the shape is drawn.
            let offset = context.worldDrawingOffset(of: record.id)
            let drawn = anchor.offsetBy(dx: offset.x, dy: offset.y)
            for index in slots.indices {
                guard let slot = slots[index] else { continue }
                // A slot clear of the view draws nothing in it, and its text and symbol are what a frame spends here.
                let unit = slot.unit(scale)
                // A label's lead is where its shape's geometry put it (and is drawn, a shake included, where the shape is).
                let placed = slot.lead == nil ? slot.worldRect(in: drawn, scale: scale) : slot.worldRect(in: anchor, scale: scale).offsetBy(dx: offset.x, dy: offset.y)
                guard placed.insetBy(dx: -AdornmentLayout.slotMargin * unit, dy: -AdornmentLayout.slotMargin * unit)
                    .intersects(context.visibleRect) else { continue }
                let adornment = laidOut.shown[index]
                var look = AdornmentStyle.Look.normal
                if adornment.isClickable, adornment.isButton(pressed, on: record.id, isOverflow: slot.isOverflow) {
                    look = .pressed
                } else if adornment.isClickable, adornment.isButton(hovered, on: record.id, isOverflow: slot.isOverflow) {
                    look = .hovered
                }
                let (label, face) = laidOut.look(of: index, in: slot)
                AdornmentStyle.draw(label, in: adornment.id.placement, face: face, in: slot.frame,
                                    from: slot.lead == nil ? slot.corner(in: drawn) : placed.origin, scale: unit, look: look, isDark: isDark,
                                    turned: slot.isTurned, in: cg)
            }
        }
    }
}
