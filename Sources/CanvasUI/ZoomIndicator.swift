import AppKit
@_spi(Host) import Canvas

/// The zoom in whole percent ("44%", where the camera's headed: `editor.zoomPercentage`), above the
/// minimap, while it changes: it shows at once as the zoom changes on the board shown (a pinch, a
/// ⌘-scroll, a zoom command, a fit), stays while it goes on changing, and fades out a moment after
/// the last change, hidden once it has. A pan doesn't show it, nor another board shown at its own
/// zoom, nor anything before the canvas has a size. It takes no clicks: the canvas under it has
/// them.
///
/// The canvas view hosts it, over everything it hosts but the popover, and asks it with every redraw
/// (`zoomMayHaveChanged`), which costs a comparison; it places it (`ZoomIndicatorStyle.frame`).
public final class ZoomIndicator: NSView {
    public let editor: CanvasEditor

    /// The board and the zoom it last heard of: a change of zoom on the same board shows it.
    private var heard: (board: BoardID, percent: Int)
    /// The fade out to come, or under way: hiding it once done.
    private var fadeOut: ScheduledTask?
    private var text: NSAttributedString
    /// The size it takes for the zoom it shows.
    private(set) var labelSize: CGSize

    init(editor: CanvasEditor) {
        self.editor = editor
        heard = (editor.board, editor.zoomPercentage)
        text = Self.text(percent: editor.zoomPercentage)
        labelSize = Self.size(of: text)
        super.init(frame: .zero)
        wantsLayer = true
        shadow = MinimapStyle.shadow
        alphaValue = 0
        isHidden = true
        setAccessibilityRole(.staticText)
        setAccessibilityLabel("Zoom")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func isAccessibilityElement() -> Bool { isShowing }

    /// Whether it shows: from a change of zoom until it begins to fade out.
    public private(set) var isShowing = false

    /// What it shows, or showed last: "44%".
    public var title: String { text.string }

    static func title(percent: Int) -> String { "\(percent)%" }

    /// In digits all one width, so it doesn't wobble as it counts.
    private static func text(percent: Int) -> NSAttributedString {
        NSAttributedString(string: title(percent: percent),
                           attributes: [.font: ZoomIndicatorStyle.font, .foregroundColor: ZoomIndicatorStyle.textColor])
    }

    private static func size(of text: NSAttributedString) -> CGSize {
        CGSize(width: ceil(text.size().width) + ZoomIndicatorStyle.padding * 2, height: ZoomIndicatorStyle.height)
    }

    /// Shows the zoom if it changed on the board it last heard of; a canvas with no size yet, it
    /// only notes, and on another board it hides at once. Returns whether it showed, for the canvas
    /// to place it.
    @discardableResult
    func zoomMayHaveChanged() -> Bool {
        let now = (board: editor.board, percent: editor.zoomPercentage)
        guard now != heard else { return false }
        let sameBoard = now.board == heard.board
        heard = now
        guard sameBoard else {
            hide()
            return false
        }
        guard editor.viewportSize.width > 0, editor.viewportSize.height > 0 else { return false }
        show(percent: now.percent)
        return true
    }

    private func hide() {
        fadeOut?.cancel()
        fadeOut = nil
        isShowing = false
        layer?.removeAnimation(forKey: "opacity")
        alphaValue = 0
        isHidden = true
    }

    private func show(percent: Int) {
        text = Self.text(percent: percent)
        labelSize = Self.size(of: text)
        setAccessibilityValue(title)
        needsDisplay = true
        isShowing = true
        isHidden = false
        layer?.removeAnimation(forKey: "opacity")
        alphaValue = 1
        fadeOut?.cancel()
        fadeOut = editor.scheduler.schedule(after: ZoomIndicatorStyle.holdDuration) { [weak self] in
            guard let self else { return }
            isShowing = false
            // VoiceOver hears the zoom it came to, once, rather than every step on the way.
            NSAccessibility.post(element: self, notification: .announcementRequested,
                                 userInfo: [.announcement: "Zoom \(title)", .priority: NSAccessibilityPriorityLevel.medium.rawValue])
            NSAnimationContext.runAnimationGroup { context in
                context.duration = ZoomIndicatorStyle.fadeOutDuration / .seconds(1)
                animator().alphaValue = 0
            }
            fadeOut = editor.scheduler.schedule(after: ZoomIndicatorStyle.fadeOutDuration) { [weak self] in
                self?.fadeOut = nil
                self?.isHidden = true
            }
        }
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        layer?.shadowPath = MinimapStyle.panel(bounds)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        cg.addPath(MinimapStyle.panel(bounds))
        cg.setFillColor(MinimapStyle.background.cgColor)
        cg.fillPath()
        let border = MinimapStyle.borderWidth
        cg.addPath(MinimapStyle.panel(bounds.insetBy(dx: border / 2, dy: border / 2)))
        cg.setStrokeColor(MinimapStyle.border.cgColor)
        cg.setLineWidth(border)
        cg.strokePath()
        let size = text.size()
        text.draw(at: CGPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }
}

/// The zoom's label's constants, in view points. It looks as the minimap does (`MinimapStyle`'s
/// panel, colors and shadow).
@MainActor
enum ZoomIndicatorStyle {
    static let height: CGFloat = 22
    /// Either side of the text.
    static let padding: CGFloat = 7
    /// Above the minimap. With none showing, it's the minimap's margin from the canvas's corner.
    static let gap: CGFloat = 8
    static var font: NSFont { .monospacedDigitSystemFont(ofSize: 11, weight: .medium) }
    static var textColor: NSColor { .secondaryLabelColor }
    /// How long it stays after the last change, and then how long it takes to fade out.
    static let holdDuration: Duration = .milliseconds(1000)
    static let fadeOutDuration: Duration = .milliseconds(300)

    /// Where it goes in a canvas of `size`: above the minimap (`minimap`, its frame while it shows,
    /// else nil), their left edges in line; with none, in its corner.
    static func frame(_ indicator: CGSize, in size: CGSize, above minimap: CGRect?) -> CGRect {
        let bottom = minimap.map { $0.minY - gap } ?? size.height - MinimapStyle.margin
        return CGRect(x: MinimapStyle.margin, y: bottom - indicator.height, width: indicator.width, height: indicator.height)
    }
}
