import AppKit
import Canvas

/// A mention as one character of text (U+FFFC): the pill. Its target lives on the attachment, not
/// in an attribute, so text typed beside it never inherits the mention. It draws through `image`
/// (a drawing handler, run again at each device scale, so it's sharp at any zoom) and `bounds`,
/// which TextKit 2 and string drawing both honor: the canvas and the note's editor draw it alike.
///
/// Its metrics come from its style's font (an em): as tall as a line holds without growing, its
/// bottom just above the font's descender, the kind's symbol (in a slot as wide whatever the symbol,
/// so the pill is as wide as its label makes it) then the label, no wider than 16 em (or its text,
/// if narrower), a longer label ending in "…". Live, it's the text's color at 10% on
/// a shape's surface, the system's on a neutral one, white with a hairline outline and no symbol
/// on an outlined one; selected, the selection's colors; naming a
/// shape that isn't there or can't be mentioned, a dashed outline and the name it holds, in
/// italic, with no symbol.
@MainActor
public final class MentionAttachment: NSTextAttachment {
    public let target: ShapeID
    /// The name the mention holds: what it shows while its target isn't live.
    public private(set) var storedLabel: String
    public private(set) var resolution: MentionResolution
    public let style: MentionTextStyle
    /// The widest the text it's in allows; nil for no limit but its own.
    public let widthLimit: CGFloat?
    /// Drawn in the selection's colors: a text view sets it while the pill is in its selection,
    /// since the system's highlight draws behind attachments.
    public var isSelected = false {
        didSet { if isSelected != oldValue { layOut() } }
    }

    public init(target: ShapeID, storedLabel: String, resolution: MentionResolution, style: MentionTextStyle, width: CGFloat? = nil) {
        self.target = target
        self.storedLabel = storedLabel
        self.resolution = resolution
        self.style = style
        widthLimit = width
        layout = MentionPillLayout(label: resolution.shownLabel(stored: storedLabel), resolution: resolution, style: style,
                                   isSelected: false, widthLimit: width)
        super.init(data: nil, ofType: nil)
        draw()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows what a mention of its target shows now: a new image and bounds, if it changed.
    public func update(_ resolution: MentionResolution) {
        guard resolution != self.resolution else { return }
        self.resolution = resolution
        layOut()
    }

    /// Holds another name, what the board holds for the mention now (a text view's pill, once its
    /// text is written): shown only while its target isn't live.
    func hold(_ label: String) {
        guard label != storedLabel else { return }
        storedLabel = label
        if !resolution.isLive { layOut() }
    }

    /// What it reads: its target's live label, else the name it holds, else, holding none, what
    /// its tooltip says.
    public var shownLabel: String { resolution.shownLabel(stored: storedLabel) }

    /// The name to write it with: its live label, else the one it holds.
    public var writtenLabel: String { resolution.appearance?.label ?? storedLabel }

    /// Why it isn't live, for a tooltip: nil while it is.
    public var help: String? { resolution.help }

    /// How it's laid out now.
    public private(set) var layout: MentionPillLayout

    private func layOut() {
        layout = MentionPillLayout(label: shownLabel, resolution: resolution, style: style, isSelected: isSelected, widthLimit: widthLimit)
        draw()
    }

    /// Its bounds and image, from its layout.
    private func draw() {
        let layout = layout
        bounds = layout.bounds
        // Drawn wherever AppKit draws it: the handler holds only the layout, and needs no actor.
        nonisolated(unsafe) let drawn = layout
        let image = NSImage(size: layout.bounds.size, flipped: false) { @Sendable rect in
            drawn.draw(in: rect)
            return true
        }
        // Drawn afresh each time, never kept as a bitmap: an image keeps one for every scale it's
        // drawn at, and the canvas keeps thousands of pills built (`MentionTextMemo`), so a pan
        // at 400% would hold hundreds of megabytes of them.
        image.cacheMode = .never
        self.image = image
    }
}

extension MentionAttachment: ReadsAsText {
    /// The name it shows, without the "@": what a selection across it is searched for by.
    public var readsAs: String { writtenLabel }
}

/// Where a pill's parts go, and in what colors. Made on the main actor (it measures text, with
/// Mentions' style); drawn wherever AppKit draws the pill's image.
public struct MentionPillLayout {
    /// Relative to the baseline, as an attachment's bounds are: its bottom just above the
    /// font's descender.
    public let bounds: CGRect
    public let label: String
    public let isLive: Bool
    let symbol: NSImage?
    let labelFont: NSFont
    let labelRect: CGRect
    let symbolRect: CGRect
    let fill: NSColor?
    let stroke: NSColor?
    let labelColor: NSColor
    let cornerRadius: CGFloat
    let strokeWidth: CGFloat
    let dash: [CGFloat]
    let minDetailScale: CGFloat

    @MainActor
    init(label: String, resolution: MentionResolution, style: MentionTextStyle, isSelected: Bool, widthLimit: CGFloat?) {
        let em = style.font.pointSize
        let isOutlined = style.surface == .outlined
        let height = ((isOutlined ? MentionStyle.outlinedHeight : MentionStyle.pillHeight) * em).rounded()
        let padding = (isOutlined ? MentionStyle.outlinedPadding : MentionStyle.pillPadding) * em
        let appearance = resolution.appearance
        isLive = appearance != nil
        self.label = label
        cornerRadius = isOutlined ? height / 2 : MentionStyle.cornerRadius * em
        strokeWidth = isLive ? MentionStyle.outlinedStrokeWidth : MentionStyle.missingStrokeWidth
        dash = isLive ? [] : MentionStyle.missingDash
        minDetailScale = MentionStyle.minDetailScale

        var font = NSFont.systemFont(ofSize: (isOutlined ? MentionStyle.outlinedLabelSize : MentionStyle.labelSize) * em, weight: .medium)
        if !isLive, let italic = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize) { font = italic }
        labelFont = font

        let colors = Self.colors(for: appearance, style: style, isSelected: isSelected)
        fill = colors.fill
        stroke = colors.stroke
        labelColor = colors.label
        if let appearance, style.surface != .outlined,
           let image = NSImage(systemSymbolName: appearance.systemImage, accessibilityDescription: nil)?
               .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: MentionStyle.symbolSize * em, weight: .semibold)
                   .applying(NSImage.SymbolConfiguration(paletteColors: [colors.symbol]))) {
            symbol = image
        } else {
            symbol = nil
        }
        // A live pill's symbol has its slot, whichever symbol it is (or none, if it can't be found); an outlined one has no symbol.
        let slot = MentionStyle.symbolSlot * em
        let symbolWidth = isLive && style.surface != .outlined ? slot + MentionStyle.symbolGap * em : 0
        let measured = ceil((label as NSString).size(withAttributes: [.font: font]).width)
        let natural = ceil(padding * 2 + symbolWidth + measured)
        let widest = min(MentionStyle.maxWidth * em, widthLimit ?? .infinity)
        let width = max(ceil(padding * 2 + symbolWidth), min(natural, floor(widest)))
        bounds = CGRect(x: 0, y: style.font.descender + MentionStyle.pillBottomAboveDescender * em, width: width, height: height)

        // Centered in its slot, and no wider: one that's wider is drawn smaller.
        var symbolSize = symbol?.size ?? .zero
        if symbolSize.width > slot { symbolSize = CGSize(width: slot, height: symbolSize.height * slot / symbolSize.width) }
        symbolRect = CGRect(x: padding + (slot - symbolSize.width) / 2, y: ((height - symbolSize.height) / 2).rounded(),
                            width: symbolSize.width, height: symbolSize.height)
        let lineHeight = ceil(font.ascender - font.descender)
        let labelX = padding + symbolWidth
        labelRect = CGRect(x: labelX, y: ((height - lineHeight) / 2).rounded(), width: max(0, width - labelX - padding), height: lineHeight)
    }

    /// Fill, outline, symbol and label colors: the text's own on a shape, the system's on a neutral
    /// surface, the selection's when selected; a dashed outline and a fainter label when not live.
    @MainActor
    private static func colors(for appearance: MentionAppearance?, style: MentionTextStyle, isSelected: Bool)
        -> (fill: NSColor?, stroke: NSColor?, label: NSColor, symbol: NSColor) {
        let base = style.surface == .neutral ? NSColor.labelColor : style.color
        let strength = style.surface == .neutral ? 1 : style.color.usingColorSpace(.deviceRGB)?.alphaComponent ?? 1
        if appearance == nil {
            let stroke = base.withAlphaComponent(MentionStyle.missingStroke * strength)
            let label = base.withAlphaComponent(MentionStyle.missingLabel * strength)
            return isSelected ? (.selectedTextBackgroundColor, stroke, .selectedTextColor, .selectedTextColor)
                : (nil, stroke, label, label)
        }
        if isSelected { return (.selectedTextBackgroundColor, nil, .selectedTextColor, .selectedTextColor) }
        switch style.surface {
        case .shape:
            return (base.withAlphaComponent(MentionStyle.shapeFill * strength), nil, base,
                    base.withAlphaComponent(MentionStyle.shapeSymbol * strength))
        case .neutral:
            return (.quaternaryLabelColor, nil, .labelColor, appearance?.tint ?? .secondaryLabelColor)
        case .outlined:
            return (MentionStyle.outlinedFill, base.withAlphaComponent(MentionStyle.outlinedStroke * strength), base, base)
        }
    }

    /// Draws the pill in `rect` (its image's, unflipped): the fill or the dashed outline, and, at
    /// a scale its text can be read at, the symbol and the label.
    func draw(in rect: CGRect) {
        let inset = stroke == nil ? 0 : strokeWidth / 2
        let path = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: cornerRadius, yRadius: cornerRadius)
        if let fill {
            fill.setFill()
            path.fill()
        }
        if let stroke {
            stroke.setStroke()
            path.lineWidth = strokeWidth
            path.setLineDash(dash, count: dash.count, phase: 0)
            path.stroke()
        }
        guard Self.deviceScale >= minDetailScale else { return }
        symbol?.draw(in: symbolRect)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (label as NSString).draw(with: labelRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                 attributes: [.font: labelFont, .foregroundColor: labelColor, .paragraphStyle: paragraph])
    }

    /// Draws the pill straight into `cg`, a context with y down (the canvas's), in `frame`: what
    /// its attachment's image shows there, with no image made. Its parts go onto the context one
    /// by one, where an image goes on whole: the same wherever the context's alpha is 1.
    @MainActor
    func draw(in frame: CGRect, of cg: CGContext) {
        cg.saveGState()
        cg.translateBy(x: frame.minX, y: frame.maxY)
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        draw(in: CGRect(origin: .zero, size: frame.size))
        NSGraphicsContext.restoreGraphicsState()
        cg.restoreGState()
    }

    /// Device pixels per point where it's being drawn now: the canvas's zoom times the screen's.
    static var deviceScale: CGFloat {
        guard let context = NSGraphicsContext.current?.cgContext else { return 1 }
        let t = context.userSpaceToDeviceSpaceTransform
        return hypot(t.a, t.b)
    }
}
