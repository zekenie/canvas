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

    /// A symbol as a disc `height` tall shows it: half as tall, bold, white.
    static func symbol(_ name: String, height: CGFloat) -> NSImage? {
        let key = SymbolKey(name: name, height: height)
        if let known = symbols[key] { return known }
        let configuration = NSImage.SymbolConfiguration(pointSize: height / 2, weight: .bold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration)
        symbols[key] = image
        return image
    }

    private struct SymbolKey: Hashable {
        let name: String
        let height: CGFloat
    }
    private static var symbols: [SymbolKey: NSImage?] = [:]

    /// A label as its place draws it: text set in the place's font and measured, or a symbol's
    /// image, with the width it takes.
    enum Face {
        case text(NSAttributedString, size: CGSize, width: CGFloat)
        case symbol(NSImage?, width: CGFloat)

        var width: CGFloat {
            switch self {
            case .text(_, _, let width), .symbol(_, let width): width
            }
        }

        var isText: Bool {
            if case .text = self { return true }
            return false
        }
    }

    /// Nil for a label that shows nothing: blank text, or neither text nor a symbol.
    static func face(of label: AdornmentLabel, in placement: AdornmentPlacement) -> Face? {
        let height = AdornmentLayout.height(of: placement)
        if let text = label.text {
            guard !text.isEmpty else { return nil }
            let isCorner = placement == .onTopRightCorner
            let string = NSAttributedString(string: text, attributes: isCorner ? cornerText : rowText)
            let size = string.size()
            return .text(string, size: size, width: (size.width + 2 * (isCorner ? cornerPadding : rowPadding)).rounded(.up))
        }
        if let name = label.systemImage { return .symbol(symbol(name, height: height), width: height) }
        return nil
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

    /// An adornment in its frame (view points from `corner`, the corner of its shape its place runs
    /// from, in world units, at `scale` world units per point): a capsule with its text, or a disc
    /// with its symbol in the middle, all of it under one transparency layer when it's drawn less
    /// than opaque.
    static func draw(_ adornment: ShownAdornment, in frame: CGRect, from corner: CGPoint, scale: CGFloat, look: Look, in cg: CGContext) {
        let opacity = adornment.label.opacity
        cg.saveGState()
        defer { cg.restoreGState() }
        if opacity < 1 {
            cg.setAlpha(opacity)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        cg.setFillColor(fill(for: adornment.label.tone, look: look).cgColor)
        switch adornment.face {
        case .symbol(let image, _):
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
        case .text(let text, let size, _):
            cg.translateBy(x: corner.x, y: corner.y)
            cg.scaleBy(x: scale, y: scale)
            let radius = min(frame.width, frame.height) / 2
            cg.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            cg.fillPath()
            if adornment.id.placement == .onTopRightCorner {
                text.draw(at: CGPoint(x: frame.minX + cornerPadding, y: frame.midY - size.height / 2))
            } else {
                text.draw(with: CGRect(x: frame.minX + rowPadding, y: frame.midY - size.height / 2,
                                       width: frame.width - 2 * rowPadding, height: size.height),
                          options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            }
        }
        if opacity < 1 { cg.endTransparencyLayer() }
    }
}

/// Every shape's adornments, above every shape, in one pass: a shape at a time, back to front, so
/// a front shape's are over a back shape's. They go where their shape is drawn
/// (`editor.setDrawingOffset`), so they shake with it, and keep drawing while a session runs.
/// Shapes never know about them.
struct AdornmentOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in context: OverlayContext) {
        guard let state = context.editor.adornmentState, !state.isEmpty else { return }
        let scale = AdornmentLayout.scale(atZoom: context.zoom)
        let hovered = context.editor.hoveredButton, pressed = context.editor.pressedButton
        // What's in view where shapes are drawn: grown by the farthest a shake draws one, so a
        // shape just outside the view, shaken toward it, shows what of its adornments reaches in.
        let reach = context.worldDrawingReach
        let visible = context.visibleRect.insetBy(dx: -reach, dy: -reach)
        for record in context.editor.paintOrder(in: AdornmentLayout.area(showing: visible, scale: scale)) {
            let shown = state.shown(on: record)
            guard !shown.isEmpty, let bounds = AdornmentState.bounds(of: record.id, in: context.shapes) else { continue }
            let slots = AdornmentLayout.slots(of: shown.map(\.item), width: bounds.width / scale)
            // Where the shape is drawn.
            let offset = context.worldDrawingOffset(of: record.id)
            let drawn = bounds.offsetBy(dx: offset.x, dy: offset.y)
            for (adornment, slot) in zip(shown, slots) {
                guard let slot else { continue }
                var look = AdornmentStyle.Look.normal
                if adornment.isClickable {
                    let button = AnyHashable(AdornmentButton(adornment.id, on: record.id))
                    look = button == pressed ? .pressed : button == hovered ? .hovered : .normal
                }
                AdornmentStyle.draw(adornment, in: slot.frame, from: slot.corner(in: drawn), scale: scale, look: look, in: context.cg)
            }
        }
    }
}
