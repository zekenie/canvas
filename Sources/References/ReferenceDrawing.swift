import AppKit
import Canvas
import Chrome
import Mentions
import Palette

/// What the pill draws, worked out once from its condition: the leading symbol, the label and how
/// it's dressed, what trails, and whether it stands for nothing. A value, so what the render, the
/// editor's parity and the tests read is one thing.
@MainActor
struct ReferenceLook {
    struct Symbol: Equatable {
        var name: String
        /// Its color: the kind's tint blended toward the label, or secondary.
        var tint: NSColor?
        var strength: CGFloat
        var size: CGFloat
        /// Whether the tint is blended toward the label's color, as a kind's is, so it reads on the pill;
        /// a warning's isn't: it's always its own orange.
        var blends = true

        /// The magnifier a dynamic pill leads with: the label's own color a little softened, which
        /// reads as the kinds' blended symbols do (secondary alone read as faint beside them).
        @MainActor static var dynamic: Symbol { dynamic(dimmed: false) }

        /// The magnifier of a pill that stands for nothing: dimmed as its words are.
        @MainActor static func dynamic(dimmed: Bool) -> Symbol {
            Symbol(name: ReferenceStyle.dynamicSymbol, tint: ReferenceStyle.dynamicTint,
                   strength: ReferenceStyle.dynamicStrength * (dimmed ? ReferenceStyle.missingStrength : 1),
                   size: ReferenceStyle.symbolSize, blends: false)
        }
    }

    var leading: Symbol?
    var label: String
    var italic: Bool
    var strength: CGFloat
    var isPlaceholder: Bool
    var trailing: Symbol?
    /// The count trailing a pill that stands for every match ("12", "1.2k"), or the "0" of one that
    /// found none, in the room a dynamic pill reserves.
    var badge: String?
    var dashed: Bool
    /// Where its original is, when that isn't where the pill is: the containers it is inside and the board that leads, folded.
    var place: DrawnPlace?
    /// What a pill says of an original that is gone, in the place line's stead: "Deleted", "Not available".
    var word: String?
    /// The colors it wears (its original's); nil for the neutral pill.
    var colors: PillColors?
    /// Whether the pill reserves room for what a dynamic one shows at its trailing end.
    var reservesBadge: Bool

    /// `mismatch`: the pill stands for shapes that don't take the channel of an arrow attached to it
    /// (`ReferenceState.channelMismatch(of:)`), shown as a warning where a dynamic pill's count is.
    init(_ condition: ReferenceCondition, mismatch: Bool = false, place: DrawnPlace? = nil, colors: PillColors? = nil) {
        let missing = ReferenceStyle.missingStrength, finding = ReferenceStyle.findingStrength
        isPlaceholder = false
        trailing = nil
        reservesBadge = false
        self.colors = colors
        // The symbol is the original's `ink` where it wears a color, secondary where it wears none.
        func original(_ strength: CGFloat, _ appearance: MentionAppearance) -> Symbol {
            Symbol(name: appearance.systemImage, tint: colors?.symbol, strength: strength, size: ReferenceStyle.symbolSize, blends: false)
        }
        switch condition {
        case .empty:
            leading = nil
            label = ReferenceStyle.placeholder
            italic = false
            strength = 1
            dashed = false
            isPlaceholder = true
        case .live(let appearance):
            leading = original(1, appearance)
            label = appearance.label
            italic = false
            strength = 1
            dashed = false
            self.place = place
        case .missing(let stored), .unavailable(let stored):
            leading = Symbol(name: ReferenceStyle.missingSymbol, tint: nil, strength: missing, size: ReferenceStyle.symbolSize)
            label = stored
            italic = true
            strength = missing
            dashed = true
            if case .missing = condition { word = ReferenceStyle.deletedHelp } else { word = ReferenceStyle.unavailableHelp }
            self.colors = nil
        case .notPublic(let appearance):
            leading = original(missing, appearance)
            label = appearance.label
            italic = true
            strength = missing
            dashed = true
            trailing = Self.eye
            self.place = place
        case .notInterpreted(let text), .cannotFind(let text):
            leading = Symbol.dynamic
            self.colors = nil
            label = text
            italic = true
            strength = missing
            dashed = true
            reservesBadge = true
        case .finding(let text), .interpreting(let text):
            leading = Symbol.dynamic
            label = text
            italic = false
            strength = finding
            dashed = false
            reservesBadge = true
            self.colors = colors?.dimmed
        case .found(let text, let found):
            leading = Symbol.dynamic
            label = text
            italic = false
            strength = 1
            dashed = false
            reservesBadge = true
            if found.all {
                badge = ReferenceStyle.badge(found.count)
            } else {
                self.place = place
                if let first = found.first { trailing = Symbol(name: first.systemImage, tint: colors?.symbol, strength: 1, size: ReferenceStyle.firstSize, blends: false) }
            }
        case .noMatches(let text), .refused(let text, _):
            leading = Symbol.dynamic(dimmed: true)
            self.colors = nil
            label = text
            italic = true
            strength = missing
            dashed = true
            reservesBadge = true
            badge = ReferenceStyle.badge(0)
        case .privateMatches(let text, _):
            // What it found isn't public: the eye a direct pill trails for a shape that isn't, where
            // the count would be.
            leading = Symbol.dynamic(dimmed: true)
            self.colors = nil
            label = text
            italic = true
            strength = missing
            dashed = true
            reservesBadge = true
            trailing = Self.eye
        case .failed(let text, _):
            leading = Symbol.dynamic(dimmed: true)
            self.colors = nil
            label = text
            italic = true
            strength = missing
            dashed = true
            reservesBadge = true
            trailing = Self.warning
        }
        if mismatch {
            trailing = Self.warning
            badge = nil
        }
    }

    /// What trails a pill whose shape isn't public, or whose query found only shapes that aren't.
    private static var eye: Symbol {
        Symbol(name: ReferenceStyle.eyeSymbol, tint: ReferenceStyle.eyeColor, strength: ReferenceStyle.eyeStrength, size: ReferenceStyle.eyeSize, blends: false)
    }

    /// What trails a pill whose arrows' channel what it stands for doesn't take, or whose answer
    /// failed: always its own orange.
    private static var warning: Symbol {
        Symbol(name: ReferenceStyle.warningSymbol, tint: ReferenceStyle.warningTint, strength: 1, size: ReferenceStyle.warningSize, blends: false)
    }

    /// A pill being typed into: what's typed stands for nothing yet and isn't dressed as if it did (no
    /// dashes), until it's committed; a direct one being edited shows what it names. Once the list
    /// has only the words row left (`handsOff`), what's typed is words for the pill to find, and it
    /// leads with the magnifier, whatever it stood for.
    init(editing condition: ReferenceCondition, handsOff: Bool = false, colors: PillColors? = nil) {
        if handsOff {
            self.init(.empty)
            leading = Symbol.dynamic
            return
        }
        if condition.text != nil || condition == .empty {
            self.init(.empty)
        } else {
            self.init(condition, colors: colors)
        }
    }

    /// Whether the pill has a line over its name: a place, or the word for an original that is gone.
    var hasPlaceLine: Bool { word != nil || place.map { !$0.line.isEmpty } ?? false }

    /// Where the parts go in a pill's frame (world units), and how wide the label's room is.
    struct Layout {
        var symbol: CGRect?
        /// The name's line.
        var label: CGRect
        /// The place's line, over the name: only while the pill is drawn with both lines.
        var place: CGRect?
        var trailing: CGRect?
        /// The badge's capsule, at the end of the room it's reserved.
        var badge: CGRect?
    }

    /// `twoLines`: the pill is drawn at the zoom that has both lines (`ReferenceStyle.placeZoom` and up). With a line to
    /// say the name sits under it; with none, or under that zoom, the name is centered.
    func layout(in frame: CGRect, twoLines: Bool = false) -> Layout {
        let pad = ReferenceStyle.leadingPad
        var x = frame.minX + pad
        var symbol: CGRect?
        if leading != nil {
            symbol = CGRect(x: x, y: frame.midY - ReferenceStyle.symbolBox / 2, width: ReferenceStyle.symbolBox, height: ReferenceStyle.symbolBox)
            x += ReferenceStyle.symbolBox + ReferenceStyle.gap
        }
        var right = frame.maxX - ReferenceStyle.trailingPad
        let lines = twoLines && hasPlaceLine
        // What trails a direct pill (its eye, a warning) is on the name's line when there are two, so the place has the room the
        // pill was fitted for (the name and what may trail it, or the place); a query's count and first match stay in the middle,
        // in the room the pill reserves for them on both lines.
        var placeRight = right
        var trailingRect: CGRect?
        if let trailing {
            let size = trailing.size
            let middle = lines && !reservesBadge ? frame.minY + ReferenceStyle.nameBaseline - ReferenceStyle.labelFont.capHeight / 2 : frame.midY
            trailingRect = CGRect(x: right - size, y: middle - size / 2, width: size, height: size)
            right -= reservesBadge ? ReferenceStyle.badgeRoom : size + ReferenceStyle.gap
            if reservesBadge { placeRight = right }
        } else if reservesBadge {
            right -= ReferenceStyle.badgeRoom
            placeRight = right
        }
        var badgeRect: CGRect?
        if let badge {
            let width = ReferenceMemo.shared.badge(badge, strength: strength).width + ReferenceStyle.badgePad * 2
            let end = frame.maxX - ReferenceStyle.trailingPad
            badgeRect = CGRect(x: end - width, y: frame.midY - ReferenceStyle.badgeHeight / 2, width: width, height: ReferenceStyle.badgeHeight)
        }
        let line = ReferenceStyle.lineHeight
        let room = max(0, right - x)
        let top = lines ? ReferenceStyle.nameTop : ReferenceStyle.lineTop(of: ReferenceStyle.labelFont, in: frame.height)
        let placeRect = lines ? CGRect(x: x, y: frame.minY + ReferenceStyle.placeTop, width: max(0, placeRight - x), height: ReferenceStyle.placeLineHeight) : nil
        return Layout(symbol: symbol, label: CGRect(x: x, y: frame.minY + top, width: room, height: line), place: placeRect,
                      trailing: trailingRect, badge: badgeRect)
    }
}

/// Labels and symbols built once and kept, as Mentions keeps its text: a frame of a thousand pills
/// builds none of them again. Keyed by what makes them, so a rename makes a new key and the old one
/// ages out; when more than a frame's worth is kept, all are let go of.
@MainActor
final class ReferenceMemo {
    static let shared = ReferenceMemo()

    struct Label {
        let string: NSAttributedString
        let width: CGFloat
    }

    private struct LabelKey: Hashable {
        let text: String
        let italic: Bool
        let strength: CGFloat
        let placeholder: Bool
    }

    private struct SymbolKey: Hashable {
        let name: String
        let tint: NSColor?
        let strength: CGFloat
        let size: CGFloat
        let blends: Bool
        let weight: CGFloat
    }

    /// A symbol as a bitmap, and how big it is in points.
    struct Raster {
        let image: CGImage
        let size: CGSize
    }

    private struct RasterKey: Hashable {
        let symbol: SymbolKey
        let appearance: NSAppearance.Name
        /// Device pixels to a point, a power of two: a symbol is drawn from the next size up.
        let scale: Int
    }

    private var labels: [LabelKey: Label] = [:]
    private var badges: [LabelKey: Label] = [:]
    private var words: [LabelKey: Label] = [:]
    private var symbols: [SymbolKey: NSImage] = [:]
    private var rasters: [RasterKey: Raster] = [:]

    /// How many labels and symbols have been built (for tests holding a frame to building none).
    private(set) var made = 0

    func label(_ text: String, italic: Bool, strength: CGFloat, placeholder: Bool = false) -> Label {
        let key = LabelKey(text: text, italic: italic, strength: strength, placeholder: placeholder)
        if let found = labels[key] { return found }
        if labels.count >= ReferenceStyle.memoCapacity { labels.removeAll(keepingCapacity: true) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let color = placeholder ? ReferenceStyle.placeholderColor : strength < 1 ? ReferenceStyle.label.fading(to: strength) : ReferenceStyle.label
        let string = NSAttributedString(string: text, attributes: [.font: italic ? ReferenceStyle.missingFont : ReferenceStyle.labelFont,
                                                                    .foregroundColor: color, .paragraphStyle: paragraph])
        let built = Label(string: string, width: ceil(string.size().width))
        labels[key] = built
        made += 1
        return built
    }

    /// "Deleted" or "Not available", in the place line's stead: the place's color and font, kept.
    func word(_ text: String) -> NSAttributedString {
        let key = LabelKey(text: text, italic: false, strength: 1, placeholder: false)
        if let found = words[key] { return found.string }
        if words.count >= ReferenceStyle.memoCapacity { words.removeAll(keepingCapacity: true) }
        let string = NSAttributedString(string: text, attributes: [.font: ReferenceStyle.placeFont, .foregroundColor: ReferenceStyle.placeColor,
                                                                    .paragraphStyle: Self.truncating])
        words[key] = Label(string: string, width: ceil(string.size().width))
        made += 1
        return string
    }

    fileprivate static let truncating: NSParagraphStyle = {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return paragraph
    }()

    /// A count's digits, in the badge's font, at the pill's strength, centered.
    func badge(_ text: String, strength: CGFloat) -> Label {
        let key = LabelKey(text: text, italic: false, strength: strength, placeholder: false)
        if let found = badges[key] { return found }
        if badges.count >= ReferenceStyle.memoCapacity { badges.removeAll(keepingCapacity: true) }
        let color = strength < 1 ? ReferenceStyle.label.fading(to: strength) : ReferenceStyle.label
        let string = NSAttributedString(string: text, attributes: [.font: ReferenceStyle.badgeFont, .foregroundColor: color])
        let built = Label(string: string, width: ceil(string.size().width))
        badges[key] = built
        made += 1
        return built
    }

    /// The symbol's image in its color, which is dynamic: resolved as it's drawn.
    func symbol(_ symbol: ReferenceLook.Symbol) -> NSImage? {
        let key = SymbolKey(name: symbol.name, tint: symbol.tint, strength: symbol.strength, size: symbol.size, blends: symbol.blends,
                            weight: ReferenceStyle.symbolWeight.rawValue)
        if let found = symbols[key] { return found }
        if symbols.count >= ReferenceStyle.memoCapacity { symbols.removeAll(keepingCapacity: true) }
        let color = Self.color(of: symbol)
        let configuration = NSImage.SymbolConfiguration(pointSize: symbol.size, weight: ReferenceStyle.symbolWeight)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: symbol.name, accessibilityDescription: nil)?.withSymbolConfiguration(configuration) else { return nil }
        symbols[key] = image
        made += 1
        return image
    }

    /// The symbol as a bitmap for the appearance being drawn in, at the next power of two of device pixels
    /// to a point (`ReferenceStyle.rasterScales`), kept: drawing a symbol's vector image costs some ten times a bitmap's, and a
    /// frame draws a thousand. Its colors are as they are in that appearance, so each appearance has its own.
    func raster(_ symbol: ReferenceLook.Symbol, scale: CGFloat) -> Raster? {
        let scales = ReferenceStyle.rasterScales
        let pixels = scales.first { CGFloat($0) >= scale - 0.001 } ?? scales[scales.count - 1]
        let appearance = NSAppearance.currentDrawing()
        let key = RasterKey(symbol: SymbolKey(name: symbol.name, tint: symbol.tint, strength: symbol.strength, size: symbol.size,
                                              blends: symbol.blends, weight: ReferenceStyle.symbolWeight.rawValue),
                            appearance: appearance.name, scale: pixels)
        if let found = rasters[key] { return found }
        guard let image = self.symbol(symbol) else { return nil }
        if rasters.count >= ReferenceStyle.memoCapacity { rasters.removeAll(keepingCapacity: true) }
        let size = image.size
        let width = Int(ceil(size.width)) * pixels, height = Int(ceil(size.height)) * pixels
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
                                         hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        appearance.performAsCurrentDrawingAppearance {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            image.draw(in: CGRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            NSGraphicsContext.restoreGraphicsState()
        }
        guard let bitmap = rep.cgImage else { return nil }
        let raster = Raster(image: bitmap, size: CGSize(width: CGFloat(width) / CGFloat(pixels), height: CGFloat(height) / CGFloat(pixels)))
        rasters[key] = raster
        made += 1
        return raster
    }

    /// The kind's tint blended toward the label's color, so the symbol is the kind's and reads on
    /// the pill; secondary when it has none; at the symbol's strength.
    private static func color(of symbol: ReferenceLook.Symbol) -> NSColor {
        let base: NSColor
        if let tint = symbol.tint {
            base = NSColor(name: nil) { appearance in
                NSColor.resolved(in: appearance) { symbol.blends ? tint.blended(withFraction: ReferenceStyle.tintBlend, of: .labelColor) ?? tint : tint }
            }
        } else {
            base = ReferenceStyle.secondary
        }
        return symbol.strength < 1 ? base.fading(to: symbol.strength) : base
    }

    /// The width of a label as the pill sets it, for fitting a pill to what it says.
    func width(of text: String, italic: Bool) -> CGFloat {
        label(text, italic: italic, strength: 1).width
    }
}

extension ReferenceDefinition {
    /// The condition a reference draws as: its target read through the context (a shape on any board
    /// of the file the editor can show, tracked), as a mention's pill reads its.
    /// (`state`: the service the render has looked up already; a dynamic pill's answer is asked of it,
    /// a direct one's isn't.)
    /// A direct one's is kept by the service from frame to frame (`drawnCondition`), until a commit
    /// changes it or what it names.
    func condition(of shape: ShapeRecord<Reference>, state: ReferenceState?, in context: RenderContext) -> ReferenceCondition {
        let status = shape.props.mode == .dynamic ? state?.answer(of: shape.id) : nil
        let compute = {
            // With the service, a shape's own tint (its color) is the symbol's, as in its row and panel.
            ReferenceCondition.of(shape.props, status: status, registry: context.shapes.registry,
                                  lookup: { context.shape(inFile: $0) }, isElsewhere: { state?.isElsewhere($0) ?? false },
                                  appearance: state.map { state in { state.editor.mentionAppearance(of: $0) } })
        }
        guard let state, let target = shape.props.target else { return compute() }
        return state.drawnCondition(of: shape.id, target: target, width: shape.props.frame.width, compute)
    }

    /// Draws a pill: the capsule (filled and edged in its original's color, or neutral; or, standing for nothing, dashed with no
    /// fill), its symbol, the place over its name, its name and what trails. The place line is drawn from
    /// `ReferenceStyle.placeZoom` up; under it the name is centered alone. While the pill is being edited, its editing view
    /// draws the label.
    func draw(_ look: ReferenceLook, in frame: CGRect, editing: Bool, _ context: RenderContext) {
        let cg = context.cg, memo = ReferenceMemo.shared
        let width = ReferenceStyle.borderWidth, surface = ReferenceStyle.surface
        let colors = look.colors?.parts(dark: surface.dark)
        let outline = ReferenceStyle.capsule(frame.insetBy(dx: width / 2, dy: width / 2))
        if look.dashed {
            cg.addPath(outline)
            cg.setStrokeColor(colors?.edge ?? surface.dash)
            cg.setLineWidth(width)
            cg.setLineDash(phase: 0, lengths: ReferenceStyle.dashPattern)
            cg.strokePath()
            cg.setLineDash(phase: 0, lengths: [])
        } else {
            // Filled and bordered in one pass: two cost twice what one does.
            cg.addPath(outline)
            cg.setFillColor(colors?.fill ?? surface.fill)
            cg.setStrokeColor(colors?.edge ?? surface.border)
            cg.setLineWidth(width)
            cg.drawPath(using: .fillStroke)
        }
        let layout = look.layout(in: frame, twoLines: !editing && ReferenceStyle.showsPlace(atZoom: context.zoom))
        let scale = hypot(cg.userSpaceToDeviceSpaceTransform.a, cg.userSpaceToDeviceSpaceTransform.b)
        if let leading = look.leading, let rect = layout.symbol { drawSymbol(leading, in: rect, scale: scale, cg: cg) }
        if let trailing = look.trailing, let rect = layout.trailing { drawSymbol(trailing, in: rect, scale: scale, cg: cg) }
        if let badge = look.badge, let rect = layout.badge { drawBadge(badge, in: rect, strength: look.strength, fill: colors?.badge ?? surface.badge, cg: cg) }
        guard !editing, !look.label.isEmpty else { return }
        let label = memo.label(look.label, italic: look.italic, strength: look.strength, placeholder: look.isPlaceholder)
        label.string.draw(with: layout.label, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let rect = layout.place {
            let line = look.word.map { memo.word($0) } ?? look.place?.string
            line?.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    /// A count in its capsule, its digits centered in it.
    private func drawBadge(_ text: String, in rect: CGRect, strength: CGFloat, fill: CGColor, cg: CGContext) {
        let radius = rect.height / 2
        cg.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        cg.setFillColor(fill)
        cg.fillPath()
        let label = ReferenceMemo.shared.badge(text, strength: strength)
        let line = ceil(ReferenceStyle.badgeFont.ascender - ReferenceStyle.badgeFont.descender)
        let top = ReferenceStyle.lineTop(of: ReferenceStyle.badgeFont, in: rect.height)
        let box = CGRect(x: rect.midX - label.width / 2, y: rect.minY + top, width: label.width + 1, height: line)
        label.string.draw(with: box, options: [.usesLineFragmentOrigin])
    }

    /// A symbol's bitmap, centered in its box (the canvas's context is flipped, so it's drawn flipped back).
    private func drawSymbol(_ symbol: ReferenceLook.Symbol, in box: CGRect, scale: CGFloat, cg: CGContext) {
        guard let raster = ReferenceMemo.shared.raster(symbol, scale: scale) else { return }
        cg.saveGState()
        cg.translateBy(x: box.midX, y: box.midY)
        cg.scaleBy(x: 1, y: -1)
        cg.draw(raster.image, in: CGRect(x: -raster.size.width / 2, y: -raster.size.height / 2, width: raster.size.width, height: raster.size.height))
        cg.restoreGState()
    }
}

#if DEBUG
/// How many labels and symbols pills have built in this process (debug builds only), so tests can hold
/// a frame of pills already drawn to building none.
@MainActor
public var referenceLooksBuilt: Int { ReferenceMemo.shared.made }
#endif

/// A place kept with a condition drawn: its steps, their fold in the pill's room, and, when the line leads with the root,
/// the name the file had. A class, so the line's string is built once, the first time it is drawn, and kept with it.
@MainActor
final class DrawnPlace {
    let steps: [PlaceStep]
    let line: PlaceLine
    let rootName: String?

    init(steps: [PlaceStep], line: PlaceLine, rootName: String?) {
        self.steps = steps
        self.line = line
        self.rootName = rootName
    }

    /// The line as drawn: the label's color at 60%, a board's name semibold, the `›` and `…` and an untitled container's name
    /// at 30%, a board without a title semibold at 30%.
    lazy var string: NSAttributedString = {
        let string = NSMutableAttributedString()
        for piece in line.pieces {
            var font = ReferenceStyle.placeFont, color = ReferenceStyle.placeColor
            switch piece.kind {
            case .separator, .ellipsis:
                color = ReferenceStyle.placeFaintColor
            case .step(_, let opensBoard, let isPlaceholder):
                if opensBoard { font = ReferenceStyle.placeBoardFont }
                if isPlaceholder { color = ReferenceStyle.placeFaintColor }
            }
            string.append(NSAttributedString(string: piece.text, attributes: [.font: font, .foregroundColor: color]))
        }
        string.addAttribute(.paragraphStyle, value: ReferenceMemo.truncating, range: NSRange(location: 0, length: string.length))
        return string
    }()
}
