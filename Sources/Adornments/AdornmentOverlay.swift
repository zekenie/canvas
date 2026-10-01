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
    /// A label drawn blank, zoomed out (`OverlayContext.drawsSkeleton(of:)`): its capsule or disc
    /// alone, no text or symbol, in a pale gray of the skeletons' own hue, a little off the canvas
    /// (lighter than a shape's skeleton on the light canvas, darker on the dark one), so it's there
    /// as a placeholder without weighing more than the greeked text beside it, and gray over a
    /// note's yellow, which it may overlap. Opaque, so labels drawn blank are filled a run at a time
    /// (`BlankRun`) and a grid dot never shows through one. Something done is as pale a green.
    static let blankFill = NSColor(name: nil) {
        $0.isDark ? NSColor(srgbRed: 0.21, green: 0.22, blue: 0.23, alpha: 1) : NSColor(srgbRed: 0.84, green: 0.85, blue: 0.86, alpha: 1)
    }
    static let blankSuccessFill = NSColor(name: nil) {
        $0.isDark ? NSColor(srgbRed: 0.18, green: 0.29, blue: 0.21, alpha: 1) : NSColor(srgbRed: 0.7, green: 0.86, blue: 0.74, alpha: 1)
    }
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

    /// What a label's text is set in, in its place: the place's text, dimmed for a placeholder.
    private static func textAttributes(of label: AdornmentLabel, isCorner: Bool) -> [NSAttributedString.Key: Any] {
        switch (isCorner, label.isPlaceholder) {
        case (false, false): rowText
        case (false, true): rowPlaceholderText
        case (true, false): cornerText
        case (true, true): cornerPlaceholderText
        }
    }

    /// The average advance of a column of the row's text and of the corner's (a narrow character's,
    /// `SkeletonText`), measured once from a sample of each: a label drawn blank is as long as its
    /// text's columns would be at this, and its text is never set or measured.
    private static let rowAdvance = advance(of: "Front desk, the quick brown fox jumps over the lazy dog", in: rowText)
    private static let cornerAdvance = advance(of: "☑ 12/34", in: cornerText)

    private static func advance(of sample: String, in attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        NSAttributedString(string: sample, attributes: attributes).size().width / CGFloat(SkeletonText.columns(of: sample))
    }

    /// How wide a label is drawn blank in its place: text as long as its columns at the place's
    /// average advance (`SkeletonText.columns(of:)`: a CJK character or an emoji two, a combining
    /// mark none, as every greeked text counts them), after its symbol's place if it has one, with
    /// the place's padding, as its face is measured; a symbol's disc as wide as its place is tall.
    /// The layout gives way as it does to a face (at the row's left end).
    static func blankWidth(of label: AdornmentLabel, in placement: AdornmentPlacement) -> CGFloat {
        guard let text = label.text else { return AdornmentLayout.height(of: placement) }
        let isCorner = placement == .onTopRightCorner
        let columns = CGFloat(SkeletonText.columns(of: text))
        return (columns * (isCorner ? cornerAdvance : rowAdvance) + lead(of: label, in: placement)
                + 2 * (isCorner ? cornerPadding : rowPadding)).rounded(.up)
    }

    /// A symbol before text: its place, as wide as the place's text is tall, and the gap after it.
    static let rowSymbolPlace: CGFloat = 11
    static let cornerSymbolPlace: CGFloat = 10
    static let symbolGap: CGFloat = 3

    /// How far a label's text starts past its padding: its symbol's place and the gap after it, for
    /// text with a symbol; else nothing. The same in full and blank, so a label is as long either way
    /// as its text makes it.
    static func lead(of label: AdornmentLabel, in placement: AdornmentPlacement) -> CGFloat {
        guard label.text != nil, label.systemImage != nil else { return 0 }
        return (placement == .onTopRightCorner ? cornerSymbolPlace : rowSymbolPlace) + symbolGap
    }

    /// A symbol as a disc `height` tall shows it: half as tall, bold, white.
    static func symbol(_ name: String, height: CGFloat) -> NSImage? {
        symbol(SymbolKey(name: name, pointSize: height / 2, weight: .bold, white: 1))
    }

    /// A symbol before text in its place: two points smaller than the text, semibold, in white a
    /// little softer than the text's, so it marks the text rather than reading as part of it.
    static func leadingSymbol(_ name: String, in placement: AdornmentPlacement) -> NSImage? {
        symbol(SymbolKey(name: name, pointSize: placement == .onTopRightCorner ? 8 : 9, weight: .semibold, white: 0.75))
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
        guard let text = label.text else { return .symbol(label.systemImage.flatMap { symbol($0, height: height) }, width: height) }
        let isCorner = placement == .onTopRightCorner
        let string = NSAttributedString(string: text, attributes: textAttributes(of: label, isCorner: isCorner))
        let size = string.size()
        let mark = label.systemImage.map { (image: leadingSymbol($0, in: placement), place: isCorner ? cornerSymbolPlace : rowSymbolPlace) }
        return .text(string, size: size, symbol: mark,
                     width: (size.width + lead(of: label, in: placement) + 2 * (isCorner ? cornerPadding : rowPadding)).rounded(.up))
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

    /// A label drawn blank: its tone's gray or green, lighter hovered and darker pressed.
    static func blankFill(for tone: AdornmentLabel.Tone, look: Look) -> NSColor {
        let base = tone == .success ? blankSuccessFill : blankFill
        switch look {
        case .normal: return base
        case .hovered: return base.blended(withFraction: 0.2, of: .white) ?? base
        case .pressed: return base.blended(withFraction: 0.2, of: .black) ?? base
        }
    }

    /// An adornment in full, its face in its frame (view points from `corner`, the corner of its
    /// shape its place runs from, in world units, at `scale` world units per point): a capsule with
    /// its text, or a disc with its symbol in the middle, all of it under one transparency layer
    /// when it's drawn less than opaque.
    static func draw(_ adornment: ShownAdornment, face: Face, in frame: CGRect, from corner: CGPoint, scale: CGFloat, look: Look,
                     in cg: CGContext) {
        let opacity = adornment.label.opacity
        cg.saveGState()
        defer { cg.restoreGState() }
        if opacity < 1 {
            cg.setAlpha(opacity)
            cg.beginTransparencyLayer(auxiliaryInfo: nil)
        }
        cg.setFillColor(fill(for: adornment.label.tone, look: look).cgColor)
        switch face {
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
        case .text(let text, let size, let symbol, _):
            cg.translateBy(x: corner.x, y: corner.y)
            cg.scaleBy(x: scale, y: scale)
            let radius = min(frame.width, frame.height) / 2
            cg.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
            cg.fillPath()
            let isCorner = adornment.id.placement == .onTopRightCorner
            let start = frame.minX + (isCorner ? cornerPadding : rowPadding)
            // Where the text starts, as its width was measured.
            let lead = lead(of: adornment.label, in: adornment.id.placement)
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

/// Labels drawn blank, zoomed out, a run at a time: each one's capsule or disc (in world units) is
/// added to one path while they're alike (tone, look and opacity), and the path is filled once the
/// next isn't, and at the end. In paint order, so what's over what is as when each is filled alone;
/// the fills are opaque, so where two of a run meet is no darker, and a label drawn less than opaque
/// is one fill at that opacity, as a transparency layer over it would give.
@MainActor
struct BlankRun {
    /// World units per device pixel: how finely a capsule's ends are flattened.
    private let pixel: CGFloat
    private var path = CGMutablePath()
    private var style: (tone: AdornmentLabel.Tone, look: AdornmentStyle.Look, opacity: CGFloat)?

    init(pixel: CGFloat) { self.pixel = pixel }

    mutating func add(_ adornment: ShownAdornment, in rect: CGRect, look: AdornmentStyle.Look, to cg: CGContext) {
        let next = (tone: adornment.label.tone, look: look, opacity: adornment.label.opacity)
        if let style, style != next { fill(in: cg) }
        style = next
        Self.addCapsule(rect, pixel: pixel, to: path)
    }

    /// The most a flattened end strays from its half circle, in device pixels.
    private static let tolerance: CGFloat = 0.2

    /// A capsule, a disc when it's as wide as it's tall, as lines: each end a half circle flattened
    /// to chords that stray from it by no more than `tolerance`. Core Graphics fills a path of many
    /// lines for a fraction of what the curves they stand for cost, and a path of many curves costs
    /// more than each filled alone (7,200 labels drawn blank at 10%: some 5 ms in all as lines in
    /// one path, where filling them as curves took 12 one at a time and 24 in one path).
    static func addCapsule(_ rect: CGRect, pixel: CGFloat, to path: CGMutablePath) {
        let radius = min(rect.width, rect.height) / 2
        let turn = halfCircle(radius: radius / pixel)
        let right = CGPoint(x: rect.maxX - radius, y: rect.midY), left = CGPoint(x: rect.minX + radius, y: rect.midY)
        path.move(to: CGPoint(x: right.x + radius * turn[0].x, y: right.y + radius * turn[0].y))
        for unit in turn.dropFirst() { path.addLine(to: CGPoint(x: right.x + radius * unit.x, y: right.y + radius * unit.y)) }
        for unit in turn { path.addLine(to: CGPoint(x: left.x - radius * unit.x, y: left.y - radius * unit.y)) }
        path.closeSubpath()
    }

    /// A half circle of radius 1 from its top, (0, −1), round its right to its bottom, in as few
    /// chords as keep one `radius` device pixels across within `tolerance` of it (up to 32), each
    /// count's made once.
    private static func halfCircle(radius: CGFloat) -> [CGPoint] {
        let chords = min(halfCircles.count - 1, max(1, Int((CGFloat.pi / (2 * acos(max(-1, 1 - tolerance / radius)))).rounded(.up))))
        if halfCircles[chords].isEmpty {
            halfCircles[chords] = (0...chords).map { step in
                let angle = -CGFloat.pi / 2 + .pi * CGFloat(step) / CGFloat(chords)
                return CGPoint(x: cos(angle), y: sin(angle))
            }
        }
        return halfCircles[chords]
    }
    private static var halfCircles = [[CGPoint]](repeating: [], count: 33)

    mutating func fill(in cg: CGContext) {
        guard let style, !path.isEmpty else { return }
        cg.saveGState()
        cg.setAlpha(style.opacity)
        cg.setFillColor(AdornmentStyle.blankFill(for: style.tone, look: style.look).cgColor)
        cg.addPath(path)
        cg.fillPath()
        cg.restoreGState()
        path = CGMutablePath()
        self.style = nil
    }
}

/// Every shape's adornments, above every shape, in one pass: a shape at a time, back to front, so
/// a front shape's are over a back shape's. They go where their shape is drawn
/// (`editor.setDrawingOffset`), so they shake with it, and keep drawing while a session runs.
/// Each follows its own shape's level (`OverlayContext.drawsSkeleton(of:)`): on a shape drawn as a
/// skeleton, zoomed out, it's drawn blank, as long as `AdornmentState` lays it out there, and those
/// are filled a run at a time (`BlankRun`); on the shape being edited, drawn in full, in full. The
/// frame allocates nothing per shape once its labels are kept. Shapes never know about them.
struct AdornmentOverlay: CanvasOverlay {
    var space: OverlaySpace { .world }

    func draw(in context: OverlayContext) {
        guard let state = context.editor.adornmentState, !state.isEmpty else { return }
        let scale = AdornmentLayout.scale(atZoom: context.zoom), cg = context.cg
        // The clickable adornment hovered and pressed, if either is one: each adornment is compared
        // with them as it is, never boxed as a button of its own.
        let hovered = context.editor.hoveredButton?.base as? AdornmentButton
        let pressed = context.editor.pressedButton?.base as? AdornmentButton
        // `drawsSkeleton(of:)`, the shape being edited read once for the frame, as the canvas
        // reads it for the shapes it draws, rather than once a shape.
        let skeletons = context.drawsSkeletons, editing = skeletons ? context.editor.editingShapeID : nil
        // What's in view where shapes are drawn: grown by the farthest a shake draws one, so a
        // shape just outside the view, shaken toward it, shows what of its adornments reaches in.
        let reach = context.worldDrawingReach
        let visible = context.visibleRect.insetBy(dx: -reach, dy: -reach)
        let device = cg.userSpaceToDeviceSpaceTransform
        var run = BlankRun(pixel: 1 / max(hypot(device.a, device.b), .leastNormalMagnitude))
        var slots: [AdornmentLayout.Slot?] = []
        for record in context.editor.paintOrder(in: AdornmentLayout.area(showing: visible, scale: scale)) {
            let blank = skeletons && record.id != editing
            guard let laidOut = state.laidOut(record, blank: blank),
                  let bounds = AdornmentState.bounds(of: record.id, in: context.shapes) else { continue }
            AdornmentLayout.slots(of: laidOut.items, width: bounds.width / scale, into: &slots)
            // Where the shape is drawn.
            let offset = context.worldDrawingOffset(of: record.id)
            let drawn = bounds.offsetBy(dx: offset.x, dy: offset.y)
            // What's drawn in full goes over the blank labels behind it.
            if !blank { run.fill(in: cg) }
            for index in slots.indices {
                guard let slot = slots[index] else { continue }
                let adornment = laidOut.shown[index]
                var look = AdornmentStyle.Look.normal
                if adornment.isClickable, adornment.isButton(pressed, on: record.id) {
                    look = .pressed
                } else if adornment.isClickable, adornment.isButton(hovered, on: record.id) {
                    look = .hovered
                }
                if blank {
                    run.add(adornment, in: slot.worldRect(in: drawn, scale: scale), look: look, to: cg)
                } else {
                    AdornmentStyle.draw(adornment, face: laidOut.faces[index], in: slot.frame, from: slot.corner(in: drawn), scale: scale,
                                        look: look, in: cg)
                }
            }
        }
        run.fill(in: cg)
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
