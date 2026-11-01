import AppKit
@_spi(Host) import Canvas
import Chrome

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
        setAccessibilityElement(true)
        setAccessibilityRole(.popover)
        setAccessibilityLabel(card.accessibilityLabel ?? CardStyle.accessibilityLabel)
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

    /// Closes the card (`editor.closeCard(.asked)`): what Escape does when the content didn't take it.
    var onEscape: (() -> Void)?

    // What the content didn't take stops here. Escape closes the card, a fallback for content that
    // handles it itself (the shipped cards do), and Tab and ⇧Tab walk the card's own stops, wrapping;
    // every other key is swallowed. A modifier change alone goes to the canvas, which keeps the
    // editor's held keys (Space's pan, ⇧'s axis).
    override func keyDown(with event: NSEvent) {
        let held = event.modifierFlags.intersection([.command, .control, .option])
        guard held.isEmpty else { return }
        switch event.keyCode {
        case 53: onEscape?()
        case 48: walk(by: event.modifierFlags.contains(.shift) ? -1 : 1)
        default: break
        }
    }
    /// ⌘. and Escape as a command: the same.
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func scrollWheel(with event: NSEvent) {}
    override func magnify(with event: NSEvent) {}
    override func smartMagnify(with event: NSEvent) {}
    override func mouseDown(with event: NSEvent) {}
    override func mouseDragged(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func otherMouseDown(with event: NSEvent) {}
    /// A key binding's command the content passed on (`deleteBackward:`) is nobody's, and doesn't beep.
    override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.cancelOperation(_:)) { onEscape?() }
    }
    /// Not the canvas's menu: a view looks up its superviews for one.
    override func menu(for event: NSEvent) -> NSMenu? { nil }
    override func flagsChanged(with event: NSEvent) { superview?.flagsChanged(with: event) }

    /// What can take the keyboard in the content, in reading order (top to bottom, then left to right).
    private var stops: [NSView] {
        var found: [NSView] = []
        func collect(_ view: NSView) {
            if view.acceptsFirstResponder, view.canBecomeKeyView, !view.isHiddenOrHasHiddenAncestor, !((view as? NSTextView)?.isFieldEditor ?? false) {
                found.append(view)
            }
            for sub in view.subviews { collect(sub) }
        }
        collect(content)
        // A container and what it holds begin together: the container is first (the walk's own order).
        return found.enumerated().sorted {
            let a = convert($0.element.bounds, from: $0.element), b = convert($1.element.bounds, from: $1.element)
            return (a.minY, a.minX, $0.offset) < (b.minY, b.minX, $1.offset)
        }.map(\.element)
    }

    /// The keyboard to the next (`step` 1) or previous stop, wrapping inside the card.
    private func walk(by step: Int) {
        let stops = stops
        guard !stops.isEmpty, let window else { return }
        var current = window.firstResponder as? NSView
        if let text = current as? NSTextView, text.isFieldEditor { current = text.delegate as? NSView }
        let here = stops.firstIndex { $0 === current } ?? stops.lastIndex { current?.isDescendant(of: $0) ?? false }
        let next = here.map { ($0 + step + stops.count) % stops.count } ?? (step > 0 ? 0 : stops.count - 1)
        window.makeFirstResponder(stops[next])
    }

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
    /// A float's corners, as the window's chrome rounds them.
    static let cornerRadius = ChromeStyle.floatCorner
    /// The least tall it is asked to be when there is hardly room.
    static let minHeight: CGFloat = 44
    /// What VoiceOver calls a card that says nothing of itself.
    static let accessibilityLabel = "Card"
    static let background = NSColor.textBackgroundColor
    static let border = NSColor.separatorColor
    // The popover's shadow.
    static let shadow = PopoverStyle.shadow
    static let shadowOffset = PopoverStyle.shadowOffset
    static let shadowBlur = PopoverStyle.shadowBlur
    static let shadowReach = PopoverStyle.shadowReach
}
