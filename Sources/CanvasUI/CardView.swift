import AppKit
@_spi(Host) import Canvas

/// The box around a card's view (`editor.card`), which `CanvasView` puts over what it hosts, under the
/// popover: the bubble (white, rounded, with its shadow) and the plugin's view in it, clipped to the
/// rounded rect. A key, a command, a scroll, a pinch, a press or a menu the content didn't take stops
/// here, so none reaches the canvas under it, and the box's place in the responder chain is the
/// canvas's own next, past the canvas (`CanvasView` sets it), so neither an event nor a menu's action
/// sent to the first responder climbs from the card into the canvas (Edit › Select All and Delete are
/// the card's content's, or nobody's). The shadow's margin takes no click.
final class CardView: NSView {
    let cardID: AnyHashable
    let content: NSView
    /// Clips the content to the bubble's rounded corners.
    private let clip = NSView()

    init(_ card: CanvasCard) {
        cardID = card.id
        content = card.view
        super.init(frame: .zero)
        clip.wantsLayer = true
        clip.layer?.cornerRadius = CardStyle.cornerRadius
        clip.layer?.cornerCurve = .continuous
        clip.layer?.masksToBounds = true
        addSubview(clip)
        clip.addSubview(content)
        setAccessibilityElement(false)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// The bubble, in the canvas's coordinates: the frame less the shadow's reach.
    var bubbleFrame: CGRect { frame.insetBy(dx: CardStyle.shadowReach, dy: CardStyle.shadowReach) }

    /// Puts the bubble at `bubble` (in the canvas's coordinates): the view is larger by the shadow's reach.
    func place(_ bubble: CGRect) {
        let frame = bubble.insetBy(dx: -CardStyle.shadowReach, dy: -CardStyle.shadowReach)
        if frame != self.frame { self.frame = frame }
        let inner = bounds.insetBy(dx: CardStyle.shadowReach, dy: CardStyle.shadowReach)
        if clip.frame != inner { clip.frame = inner }
        let fill = clip.bounds
        if content.frame != fill { content.frame = fill }
        needsDisplay = true
    }

    /// Nothing outside the bubble: its shadow takes no click.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bubbleFrame.contains(point) ? super.hitTest(point) : nil
    }

    // What the content didn't take stops here. A modifier change alone goes to the canvas, which keeps
    // the editor's held keys (Space's pan, ⇧'s axis).
    override func keyDown(with event: NSEvent) {}
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func smartMagnify(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    /// A key binding's command the content passed on (`deleteBackward:`) is nobody's, and doesn't beep.
    override func doCommand(by selector: Selector) {}
    /// Not the canvas's menu: a view looks up its superviews for one.
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func flagsChanged(with event: NSEvent) { superview?.flagsChanged(with: event) }

    override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let reach = CardStyle.shadowReach
        let bubble = bounds.insetBy(dx: reach, dy: reach)
        let radius = CardStyle.cornerRadius
        cg.saveGState()
        cg.setShadow(offset: CardStyle.shadowOffset, blur: CardStyle.shadowBlur, color: CardStyle.shadow.cgColor)
        cg.addPath(CGPath(roundedRect: bubble, cornerWidth: radius, cornerHeight: radius, transform: nil))
        cg.setFillColor(CardStyle.background.cgColor)
        cg.fillPath()
        cg.restoreGState()
        cg.addPath(CGPath(roundedRect: bubble.insetBy(dx: 0.25, dy: 0.25), cornerWidth: radius, cornerHeight: radius, transform: nil))
        cg.setStrokeColor(CardStyle.border.cgColor)
        cg.setLineWidth(0.5)
        cg.strokePath()
    }
}

/// A card's look and place. View points.
@MainActor
enum CardStyle {
    /// Between the bubble and the rect it hangs from.
    static let gap: CGFloat = 4
    /// The least room it leaves at the canvas's edges.
    static let margin: CGFloat = 8
    static let cornerRadius: CGFloat = 8
    /// The least tall it is asked to be when there is hardly room.
    static let minHeight: CGFloat = 44
    static let background = NSColor.textBackgroundColor
    static let border = NSColor.separatorColor
    // The popover's shadow.
    static let shadow = PopoverStyle.shadow
    static let shadowOffset = PopoverStyle.shadowOffset
    static let shadowBlur = PopoverStyle.shadowBlur
    static let shadowReach = PopoverStyle.shadowReach
}
