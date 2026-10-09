import AppKit
import Canvas
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

    /// How far a label's text starts past its padding: its symbol's place and the gap after it, for
    /// text with a symbol; else nothing.
    static func lead(of label: AdornmentLabel, in placement: AdornmentPlacement) -> CGFloat {
        guard label.text != nil, label.systemImage != nil, !label.isMissing else { return 0 }
        return (placement == .onTopRightCorner ? cornerSymbolPlace : rowSymbolPlace) + symbolGap
    }

    /// A symbol as a disc `height` tall shows it: half as tall, bold, white.
    static func symbol(_ name: String, height: CGFloat) -> NSImage? {
        symbol(SymbolKey(name: name, pointSize: height / 2, weight: .bold, white: 1))
    }

    /// A symbol before text in its place: two points smaller than the text, semibold, in white a
    /// little softer than the text's, so it marks the text rather than reading as part of it (a
    /// label's `brightSymbol()`: as white as the text).
    static func leadingSymbol(_ name: String, in placement: AdornmentPlacement, bright: Bool = false) -> NSImage? {
        symbol(SymbolKey(name: name, pointSize: placement == .onTopRightCorner ? 8 : 9, weight: .semibold, white: bright ? 1 : 0.75))
    }

    /// What a symbol's image is made from: its name, size and weight, and how opaque its white is.
    private struct SymbolKey: Hashable {
        let name: String
        let pointSize: CGFloat
        let weight: NSFont.Weight
        let white: CGFloat
    }
    private static var symbols: [SymbolKey: NSImage?] = [:]

    private static func symbol(_ key: SymbolKey) -> NSImage? {
        if let known = symbols[key] { return known }
        let configuration = NSImage.SymbolConfiguration(pointSize: key.pointSize, weight: key.weight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [NSColor(white: 1, alpha: key.white)]))
        let image = NSImage(systemSymbolName: key.name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        symbols[key] = image
        return image
    }

    /// A label as its place draws it in full: text set in the place's font and measured, after its
    /// symbol if it has one (`symbol`: its image, nil for a name SF Symbols hasn't, and its place's
    /// width; the text starts that and `symbolGap` past the padding), or a symbol's image alone, with
    /// the width it takes.
    enum Face {
        case text(NSAttributedString, size: CGSize, symbol: (image: NSImage?, place: CGFloat)?, width: CGFloat)
        case symbol(NSImage?, width: CGFloat)

        var width: CGFloat {
            switch self {
            case .text(_, _, _, let width), .symbol(_, let width): width
            }
        }
    }

    /// The face of a label that shows something (`ShownAdornment`): its text, after its symbol if
    /// it has one, else its symbol in a disc.
    static func face(of label: AdornmentLabel, in placement: AdornmentPlacement) -> Face {
        let height = AdornmentLayout.height(of: placement)
        guard let text = label.text else {
            return .symbol(label.isMissing ? nil : label.systemImage.flatMap { symbol($0, height: height) }, width: height)
        }
        let isCorner = placement == .onTopRightCorner
        let string = NSAttributedString(string: text, attributes: textAttributes(of: label, isCorner: isCorner))
        let size = string.size()
        let mark = label.isMissing ? nil : label.systemImage.map { (image: leadingSymbol($0, in: placement, bright: label.hasBrightSymbol), place: isCorner ? cornerSymbolPlace : rowSymbolPlace) }
        return .text(string, size: size, symbol: mark,
                     width: (size.width + lead(of: label, in: placement) + 2 * (isCorner ? cornerPadding : rowPadding)).rounded(.up))
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

    /// How a clickable adornment is drawn: hovered or pressed while the pointer's on it.
    enum Look {
        case normal, hovered, pressed
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
    static func draw(_ label: AdornmentLabel, in placement: AdornmentPlacement, face: Face, in frame: CGRect, from corner: CGPoint, scale: CGFloat, look: Look,
                     in cg: CGContext) {
        let opacity = label.opacity
        cg.saveGState()
        defer { cg.restoreGState() }
        if opacity < 1 {
            cg.setAlpha(opacity)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        cg.setFillColor(fill(for: label.tone, look: look).cgColor)
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
            if let image {
                let size = image.size, glyphScale = disc.width / frame.width
                image.draw(in: CGRect(x: disc.midX - size.width * glyphScale / 2, y: disc.midY - size.height * glyphScale / 2,
                                      width: size.width * glyphScale, height: size.height * glyphScale),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        case .text(let text, let size, let symbol, _):
            cg.translateBy(x: corner.x, y: corner.y)
            cg.scaleBy(x: scale, y: scale)
            let radius = min(frame.width, frame.height) / 2
            let capsule = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
            if label.isMissing {
                paintMissing(capsule, unit: 1, look: look, in: cg)
            } else {
                cg.addPath(capsule)
                cg.fillPath()
            }
            let isCorner = placement == .onTopRightCorner
            let start = frame.minX + (isCorner ? cornerPadding : rowPadding)
            // Where the text starts, as its width was measured.
            let lead = lead(of: label, in: placement)
            if let symbol, let image = symbol.image {
                // In world units from the corner, as a disc's symbol is drawn: centered in its place.
                let size = image.size
                cg.saveGState()
                cg.scaleBy(x: 1 / scale, y: 1 / scale)
                image.draw(in: CGRect(x: (start + (symbol.place - size.width) / 2) * scale, y: (frame.midY - size.height / 2) * scale,
                                      width: size.width * scale, height: size.height * scale),
                           from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
                cg.restoreGState()
            }
            if isCorner {
                text.draw(at: CGPoint(x: start + lead, y: frame.midY - size.height / 2))
            } else {
                text.draw(with: CGRect(x: start + lead, y: frame.midY - size.height / 2,
                                       width: frame.width - 2 * rowPadding - lead, height: size.height),
                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
        if opacity < 1 { cg.endTransparencyLayer() }
    }
}


/// Every shape's adornments, above every shape, in one pass: a shape at a time, back to front, so
/// a front shape's are over a back shape's. They go where their shape is drawn
/// (`editor.setDrawingOffset`), so they shake with it, and keep drawing while a session runs.
/// Zoomed out, where shapes are drawn as skeletons (`OverlayContext.drawsSkeleton(of:)`), none are
/// drawn: a skeleton shows what a shape is and where, and what's said just outside it (a title,
/// a lock) is left off, as the shape's text is greeked; Titles puts a title on the shape itself
/// there. The shape being edited, drawn in full, keeps its own, in full. The frame allocates
/// nothing per shape once its labels are kept. Shapes never know about them.
struct AdornmentOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in context: OverlayContext) {
        guard let state = context.editor.adornmentState, !state.isEmpty else { return }
        // Zoomed out, only the shape being edited has any: it's the one shape drawn in full.
        let skeletons = context.drawsSkeletons, editing = context.editor.editingShapeID
        if skeletons && editing == nil { return }
        let scale = AdornmentLayout.scale(atZoom: context.zoom), cg = context.cg
        // The clickable adornment hovered and pressed, if either is one: each adornment is compared
        // with them as it is, never boxed as a button of its own.
        let hovered = context.editor.hoveredButton?.base as? AdornmentButton
        let pressed = context.editor.pressedButton?.base as? AdornmentButton
        let records: [AnyShapeRecord]
        if skeletons {
            records = editing.flatMap { context.editor.document[$0] }.map { [$0] } ?? []
        } else {
            // What's in view where shapes are drawn: grown by the farthest a shake draws one, so a
            // shape just outside the view, shaken toward it, shows what of its adornments reaches in.
            let reach = context.worldDrawingReach
            let visible = context.visibleRect.insetBy(dx: -reach, dy: -reach)
            records = context.editor.paintOrder(in: AdornmentLayout.area(showing: visible, scale: scale))
        }
        var slots: [AdornmentLayout.Slot?] = []
        for record in records {
            guard let laidOut = state.laidOut(record), let anchor = AdornmentState.anchor(of: record.id, in: context.shapes, zoom: context.zoom) else { continue }
            AdornmentLayout.slots(of: laidOut.items, width: anchor.width / scale, into: &slots)
            // Where the shape is drawn.
            let offset = context.worldDrawingOffset(of: record.id)
            let drawn = anchor.offsetBy(dx: offset.x, dy: offset.y)
            for index in slots.indices {
                guard let slot = slots[index] else { continue }
                let adornment = laidOut.shown[index]
                var look = AdornmentStyle.Look.normal
                if adornment.isClickable, adornment.isButton(pressed, on: record.id, isOverflow: slot.isOverflow) {
                    look = .pressed
                } else if adornment.isClickable, adornment.isButton(hovered, on: record.id, isOverflow: slot.isOverflow) {
                    look = .hovered
                }
                let (label, face) = laidOut.look(of: index, in: slot)
                AdornmentStyle.draw(label, in: adornment.id.placement, face: face, in: slot.frame, from: slot.corner(in: drawn), scale: scale,
                                    look: look, in: cg)
            }
        }
    }
}
