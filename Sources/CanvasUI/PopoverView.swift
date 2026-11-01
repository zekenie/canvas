import AppKit
@_spi(Host) import Canvas
import Chrome

/// The editor's popover (`editor.popover`), which `CanvasView` puts over everything it shows: its text
/// as the text says (its fonts, its colors, its lines), no wider than `PopoverStyle.maxTextWidth` and
/// no taller than the room it's given, cut short with "…", in a bubble with a shadow. It takes no
/// clicks: the canvas, or the editing view, under it has them.
final class PopoverView: NSView {
    let popoverID: AnyHashable
    private let text: NSAttributedString
    /// The text's size, laid out as wide as it may be and as tall as it is.
    private let textSize: CGSize
    /// The tallest the bubble may be, the room where it's placed: its text is cut to fit.
    private var maxBubbleHeight: CGFloat = .greatestFiniteMagnitude

    init(_ popover: CanvasPopover) {
        popoverID = popover.id
        text = popover.text
        let laid = popover.text.boundingRect(with: CGSize(width: PopoverStyle.maxTextWidth, height: CGFloat.greatestFiniteMagnitude),
                                             options: [.usesLineFragmentOrigin])
        textSize = CGSize(width: min(laid.width.rounded(.up), PopoverStyle.maxTextWidth), height: laid.height.rounded(.up))
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The bubble, no taller than `maxHeight` (and `PopoverStyle.maxHeight`): its text's size and
    /// padding.
    func bubbleSize(maxHeight: CGFloat) -> CGSize {
        let padding = PopoverStyle.padding
        let height = min(textSize.height + padding.height * 2, maxHeight, PopoverStyle.maxHeight)
        return CGSize(width: textSize.width + padding.width * 2, height: max(height, padding.height * 2))
    }

    /// Puts the bubble at `bubble` (in its superview's coordinates), cut to its height: the view is
    /// larger by the shadow's reach.
    func place(_ bubble: CGRect) {
        maxBubbleHeight = bubble.height
        let reach = PopoverStyle.shadowReach
        let frame = bubble.insetBy(dx: -reach, dy: -reach)
        if frame != self.frame { self.frame = frame }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let reach = PopoverStyle.shadowReach, padding = PopoverStyle.padding
        let bubble = bounds.insetBy(dx: reach, dy: reach)
        let radius = PopoverStyle.cornerRadius(height: bubble.height)
        let path = CGPath(roundedRect: bubble, cornerWidth: radius, cornerHeight: radius, transform: nil)
        cg.saveGState()
        cg.setShadow(offset: PopoverStyle.shadowOffset, blur: PopoverStyle.shadowBlur, color: PopoverStyle.shadow.cgColor)
        cg.addPath(path)
        cg.setFillColor(PopoverStyle.background.cgColor)
        cg.fillPath()
        cg.restoreGState()
        cg.addPath(CGPath(roundedRect: bubble.insetBy(dx: 0.25, dy: 0.25), cornerWidth: radius, cornerHeight: radius, transform: nil))
        cg.setStrokeColor(PopoverStyle.border.cgColor)
        cg.setLineWidth(0.5)
        cg.strokePath()
        let box = CGRect(x: bubble.minX + padding.width, y: bubble.minY + padding.height, width: textSize.width,
                         height: min(textSize.height, maxBubbleHeight - padding.height * 2))
        text.draw(with: box, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

/// The popover's look. View points.
@MainActor
enum PopoverStyle {
    /// Around the text, across and down.
    static let padding = CGSize(width: 8, height: 6)
    /// Its corners: a float's, as the window's chrome rounds them, or a capsule's on a bubble shorter
    /// than twice that.
    static func cornerRadius(height: CGFloat) -> CGFloat { ChromeStyle.floatCorner(height: height) }
    /// Between the bubble and what it's about.
    static let gap: CGFloat = 4
    /// The least room it leaves at the canvas's edges.
    static let margin: CGFloat = 8
    static let maxTextWidth: CGFloat = 440
    static let maxHeight: CGFloat = 360
    static let background = NSColor.textBackgroundColor
    static let border = NSColor.separatorColor
    /// A float's shadow (`ChromeStyle`), down: Core Graphics takes a shadow's offset with y up,
    /// whatever the view's flip.
    static let shadow = ChromeStyle.floatShadow
    static let shadowOffset = CGSize(width: 0, height: -ChromeStyle.floatShadowY)
    static let shadowBlur = ChromeStyle.floatShadowBlur
    /// How far past the bubble its shadow reaches, which the view makes room for.
    static let shadowReach: CGFloat = 12
}
