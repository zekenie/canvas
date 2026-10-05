import AppKit

/// Posts a notification to VoiceOver, as `NSAccessibility.post` does: what a caret list says, which
/// its owner may route through a hook of its own (Mentions counts what its picker says).
public typealias CaretListPost = @MainActor (_ element: Any, _ notification: NSAccessibility.Notification,
                                             _ userInfo: [NSAccessibility.NotificationUserInfoKey: Any]?) -> Void

/// A caret list's window, over the text view it lists for: borderless, a child of the text's window
/// that never becomes key, so the text keeps the keyboard (Apple's CustomMenus pattern). Menu
/// material, rounded, as wide as its list's metrics say, showing `rowsShown` rows and scrolling
/// within them. It sits just below its anchor, or above the anchor's line where there's no room
/// below, and on the screen; it has the same size at any zoom, since the anchor's rect is in screen
/// points. The anchor is a range of the text its owner names (the `@` a mention is typed after),
/// its rows' text under the anchor's start; or a rect of its own in screen coordinates (a closure,
/// asked as the window is placed), which the window sits centered under, at its metrics' width: a
/// field that isn't the text's caret (Jump To's capsule), the text view then only the window's
/// parent and what it follows, and no reason to close as the anchor leaves it.
///
/// Its owner makes it as the list opens, calls `listDidChange()` after each change to the list, and
/// `dismiss()` as it closes. Meanwhile the window follows its anchor as every view the text is in
/// moves or is scaled (the canvas moves an editing view on every pan and zoom; a scroll view scrolls it),
/// and asks its owner to close the list (`close`) once the anchor leaves what's visible of the text
/// or the text's window stops being key. What a pick inserts is the owner's: a click on an item's
/// row highlights it and hands its index to `pick`. What the keys do is the text view's, and every
/// `EditingTextView`'s alike: through `pickHighlighted()` and `closeList()`, which run the owner's.
///
/// VoiceOver hears its list change (the highlighted row said, or the empty state) and go, through
/// `post`. It's never ordered in while its parent window isn't visible (so an unshown window's
/// tests put nothing on screen), but it's placed all the same: `frame` is where it would be.
@MainActor
public final class CaretListWindow: NSPanel {
    public let list: CaretList
    let rowsView: CaretListRowsView
    private let scrollView = NSScrollView()
    private weak var textView: NSTextView?
    private let anchor: Anchor
    private let pickByOwner: @MainActor (Int) -> Void
    private let closeByOwner: @MainActor () -> Void
    private let post: CaretListPost
    private let follower = CaretListFollower()
    private var isDismissed = false

    /// Where the window goes: under a range of the text, or a rect in screen coordinates.
    private enum Anchor {
        case range(@MainActor () -> NSRange?)
        case rect(@MainActor () -> CGRect?)
    }

    /// A window for `list` over `textView`, following it from now on. `anchor` is where it goes, a
    /// range of the text (nil: it stays where it is); `pick` gets the index of an item's row
    /// clicked; `close` is the owner closing the list, which dismisses the window. `post` routes
    /// what VoiceOver hears (nil: `NSAccessibility.post`).
    public convenience init(_ list: CaretList, accessibilityLabel: String, over textView: NSTextView, anchor: @escaping @MainActor () -> NSRange?,
                            pick: @escaping @MainActor (Int) -> Void, close: @escaping @MainActor () -> Void, post: CaretListPost? = nil) {
        self.init(list, accessibilityLabel: accessibilityLabel, over: textView, anchor: .range(anchor), pick: pick, close: close, post: post)
    }

    /// A window for `list` over `textView`, as above, but under a rect (`anchorRect`, in screen
    /// coordinates; nil: it stays where it is), centered on it at the list's width, below it, or above
    /// it where there's no room.
    public convenience init(_ list: CaretList, accessibilityLabel: String, over textView: NSTextView,
                            anchorRect: @escaping @MainActor () -> CGRect?, pick: @escaping @MainActor (Int) -> Void,
                            close: @escaping @MainActor () -> Void, post: CaretListPost? = nil) {
        self.init(list, accessibilityLabel: accessibilityLabel, over: textView, anchor: .rect(anchorRect), pick: pick, close: close, post: post)
    }

    private init(_ list: CaretList, accessibilityLabel: String, over textView: NSTextView, anchor: Anchor,
                 pick: @escaping @MainActor (Int) -> Void, close: @escaping @MainActor () -> Void, post: CaretListPost?) {
        self.list = list
        rowsView = CaretListRowsView(list: list, pick: pick)
        self.textView = textView
        self.anchor = anchor
        pickByOwner = pick
        closeByOwner = close
        self.post = post ?? Self.postToVoiceOver
        // Not deferred: it has a window number from the start, by which a click's events name it
        // (a board's window leaves clicks in its children alone), shown or not.
        super.init(contentRect: CGRect(x: 0, y: 0, width: list.metrics.width, height: list.metrics.rowHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = true
        level = .popUpMenu
        animationBehavior = .none

        let effect = NSVisualEffectView()
        effect.material = .menu
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.mask(radius: TextEditingStyle.caretListCornerRadius)
        contentView = effect

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = rowsView
        scrollView.autoresizingMask = [.width, .height]
        effect.addSubview(scrollView)

        rowsView.setAccessibilityLabel(accessibilityLabel)
        rowsView.setAccessibilityParent(textView)
        follow(textView)
    }

    public override var canBecomeKey: Bool { false }
    public override var canBecomeMain: Bool { false }

    /// A rounded rectangle that stretches to any size: the material's shape.
    private static func mask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: CGSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    // MARK: What the keys do

    /// Picks the highlighted item, as a click on its row does: its index to the owner's `pick`.
    /// Nothing while none is highlighted.
    public func pickHighlighted() {
        guard !isDismissed, let index = list.highlighted else { return }
        pickByOwner(index)
    }

    /// Closes the list as its owner does (`close`), which dismisses the window (and does, whatever
    /// the owner does). Only once.
    public func closeList() {
        guard !isDismissed else { return }
        closeByOwner()
        dismiss()
    }

    // MARK: Showing the list

    /// The list's rows or highlight changed: it goes under its anchor (or closes, if that's out of
    /// view), shows them, the highlight in view, and VoiceOver hears it.
    public func listDidChange() {
        guard !isDismissed else { return }
        place()
        guard !isDismissed else { return }
        reload()
        announce()
    }

    /// Takes the window away as its list closes: it stops following, VoiceOver hears the list go,
    /// and it leaves the screen. Only once.
    public func dismiss() {
        guard !isDismissed else { return }
        isDismissed = true
        follower.stop()
        post(rowsView, .uiElementDestroyed, nil)
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    /// How tall it is for its rows: as many as show at once, and its insets.
    private var fittedHeight: CGFloat {
        let metrics = list.metrics
        return CGFloat(min(max(list.rows.count, 1), metrics.rowsShown)) * metrics.rowHeight + 2 * TextEditingStyle.caretListInset
    }

    /// Puts the window under its anchor, shown if the text's window is; for a range of the text,
    /// asks the owner to close the list if the anchor has left what's visible of the text.
    private func place() {
        guard let textView, let window = textView.window else { return }
        let screen = (window.screen ?? NSScreen.main)?.visibleFrame
        switch anchor {
        case .range(let range):
            guard let range = range() else { return }
            let rect = textView.firstRect(forCharacterRange: range, actualRange: nil)
            let inView = textView.convert(window.convertFromScreen(rect), from: nil)
            guard textView.visibleRect.intersects(inView.insetBy(dx: -1, dy: -1)) else { return closeList() }
            place(below: rect, centered: false, on: screen)
        case .rect(let rect):
            guard let rect = rect() else { return }
            place(below: rect, centered: true, on: screen)
        }
        if window.isVisible, !isVisible { window.addChildWindow(self, ordered: .above) }
    }

    /// Places it for an anchor whose rect on screen is `anchor`: its rows' text under the anchor's
    /// start (or, `centered`, the window centered on the anchor), `offset` below the line, or above
    /// it where there's no room below, and within `screen`'s visible frame.
    private func place(below anchor: CGRect, centered: Bool, on screen: CGRect?) {
        let metrics = list.metrics
        let size = CGSize(width: metrics.width, height: fittedHeight)
        let left = centered ? anchor.midX - size.width / 2 : anchor.minX - TextEditingStyle.caretListRowInset - TextEditingStyle.caretListTextInset
        var origin = CGPoint(x: left, y: anchor.minY - metrics.offset - size.height)
        if let screen {
            if origin.y < screen.minY { origin.y = anchor.maxY + metrics.offset }
            origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
            origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        }
        let frame = CGRect(origin: origin, size: size)
        if frame != self.frame {
            setFrame(frame, display: isVisible)
            invalidateShadow()
        }
        let content = CGRect(origin: .zero, size: size)
        scrollView.frame = content.insetBy(dx: 0, dy: TextEditingStyle.caretListInset)
        rowsView.fit(width: size.width)
    }

    /// The rows changed or the highlight moved: redraw, and keep the highlight in view.
    private func reload() {
        rowsView.fit(width: frame.width)
        rowsView.needsDisplay = true
        if let index = list.highlighted { rowsView.scrollToVisible(rowsView.rect(ofRow: index)) }
    }

    /// Says the highlighted row, or the first (an empty state), to VoiceOver.
    private func announce() {
        post(rowsView, .selectedChildrenChanged, nil)
        guard let textView, let index = list.highlighted ?? list.rows.indices.first else { return }
        post(textView, .announcementRequested, [
            .announcement: CaretListRowsView.spoken(list, row: index),
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    // MARK: Following the text

    /// Re-anchors the window whenever a view the text is in moves or is scaled, and closes the list
    /// when the text's window stops being key.
    private func follow(_ textView: NSTextView) {
        var ancestors: [NSView] = []
        var view: NSView? = textView
        while let next = view {
            ancestors.append(next)
            view = next.superview
        }
        follower.follow(ancestors, window: textView.window, moved: { [weak self] in self?.place() },
                        resignedKey: { [weak self] in self?.closeList() })
    }

    private static func postToVoiceOver(_ element: Any, _ notification: NSAccessibility.Notification,
                                        _ userInfo: [NSAccessibility.NotificationUserInfoKey: Any]?) {
        if let userInfo {
            NSAccessibility.post(element: element, notification: notification, userInfo: userInfo)
        } else {
            NSAccessibility.post(element: element, notification: notification)
        }
    }
}

/// What a caret list's window observes of the text it follows: its views moving, its window
/// resigning key. An object of its own, so the window's own observations are never touched.
@MainActor
private final class CaretListFollower: NSObject {
    private var moved: (() -> Void)?
    private var resignedKey: (() -> Void)?

    func follow(_ views: [NSView], window: NSWindow?, moved: @escaping () -> Void, resignedKey: @escaping () -> Void) {
        stop()
        self.moved = moved
        self.resignedKey = resignedKey
        let center = NotificationCenter.default
        for view in views {
            center.addObserver(self, selector: #selector(viewDidMove(_:)), name: NSView.frameDidChangeNotification, object: view)
            center.addObserver(self, selector: #selector(viewDidMove(_:)), name: NSView.boundsDidChangeNotification, object: view)
        }
        if let window {
            center.addObserver(self, selector: #selector(windowDidResignKey(_:)), name: NSWindow.didResignKeyNotification, object: window)
        }
    }

    func stop() {
        NotificationCenter.default.removeObserver(self)
        moved = nil
        resignedKey = nil
    }

    @objc private func viewDidMove(_ notification: Notification) { moved?() }
    @objc private func windowDidResignKey(_ notification: Notification) { resignedKey?() }
}

/// A caret list's rows, drawn: an item's symbol in its tint, its title with the matched characters
/// in semibold, its trailing symbol after the title, and its detail at the trailing end; a header's
/// words small and secondary; an empty state secondary. The pointer over an item's row highlights
/// it, and a click picks it. To VoiceOver, a list of its items (and its empty state), each said as
/// its item says (`CaretListItem.spoken`).
@MainActor
final class CaretListRowsView: NSView {
    let list: CaretList
    private let pick: @MainActor (Int) -> Void
    private var trackingArea: NSTrackingArea?

    init(list: CaretList, pick: @escaping @MainActor (Int) -> Void) {
        self.list = list
        self.pick = pick
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var rowHeight: CGFloat { list.metrics.rowHeight }

    /// As tall as all its rows, and as wide as the window.
    func fit(width: CGFloat) {
        let size = CGSize(width: width, height: CGFloat(list.rows.count) * rowHeight)
        if frame.size != size { setFrameSize(size) }
    }

    func rect(ofRow index: Int) -> CGRect {
        CGRect(x: 0, y: CGFloat(index) * rowHeight, width: bounds.width, height: rowHeight)
    }

    /// The row at a point in the view, if there's one.
    func row(at point: CGPoint) -> Int? {
        let index = Int(floor(point.y / rowHeight))
        return list.rows.indices.contains(index) ? index : nil
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        if let index = row(at: convert(event.locationInWindow, from: nil)) { list.highlight(row: index) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = row(at: convert(event.locationInWindow, from: nil)), list.rows[index].item != nil else { return }
        list.highlight(row: index)
        pick(index)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        for index in list.rows.indices {
            let rect = rect(ofRow: index)
            guard rect.intersects(dirtyRect) else { continue }
            switch list.rows[index] {
            case .header(let title):
                draw(title, font: .systemFont(ofSize: TextEditingStyle.caretListHeaderSize, weight: .semibold), color: .secondaryLabelColor,
                     in: rect, from: TextEditingStyle.caretListRowInset + TextEditingStyle.caretListTextInset)
            case .empty(let words):
                draw(words, font: .systemFont(ofSize: TextEditingStyle.caretListLabelSize), color: .secondaryLabelColor,
                     in: rect, from: TextEditingStyle.caretListRowInset + TextEditingStyle.caretListTextInset)
            case .item(let item):
                draw(item, in: rect, highlighted: list.highlighted == index)
            }
        }
    }

    private func draw(_ text: String, font: NSFont, color: NSColor, in rect: CGRect, from x: CGFloat) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let height = string.size().height
        string.draw(with: CGRect(x: rect.minX + x, y: rect.midY - height / 2, width: rect.width - x - TextEditingStyle.caretListRowInset * 2,
                                 height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func draw(_ item: CaretListItem, in rect: CGRect, highlighted: Bool) {
        let row = rect.insetBy(dx: TextEditingStyle.caretListRowInset, dy: 0)
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: row, xRadius: TextEditingStyle.caretListHighlightRadius, yRadius: TextEditingStyle.caretListHighlightRadius).fill()
        }
        let onHighlight = NSColor.alternateSelectedControlTextColor
        let primary = highlighted ? onHighlight : .labelColor
        let secondary = highlighted ? onHighlight.withAlphaComponent(0.75) : .secondaryLabelColor

        // The symbol, in the item's tint.
        var x = row.minX + TextEditingStyle.caretListTextInset
        if let name = item.symbol {
            let symbolColor = highlighted ? onHighlight : item.tint ?? .secondaryLabelColor
            if let symbol = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: TextEditingStyle.caretListLabelSize, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [symbolColor]))) {
                let size = symbol.size
                symbol.draw(in: CGRect(x: x + (TextEditingStyle.caretListSymbolWidth - size.width) / 2, y: row.midY - size.height / 2,
                                       width: size.width, height: size.height))
            }
            x += TextEditingStyle.caretListSymbolWidth + TextEditingStyle.caretListGap
        }

        // The detail, at the trailing end, then the title in what's left, its symbol after it. The
        // title comes first: the detail takes what the title leaves, and at least its share of the
        // row, where both are long.
        let label = Self.label(item, color: primary)
        let trailing = item.trailingSymbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil) }?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: TextEditingStyle.caretListDetailSize, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [secondary])))
        let trailingWidth = trailing.map { $0.size.width + TextEditingStyle.caretListGap } ?? 0
        let detail = Self.detail(item, color: secondary)
        let leftByTitle = row.maxX - TextEditingStyle.caretListTextInset - x - ceil(label.size().width) - trailingWidth - TextEditingStyle.caretListGap
        let detailWidth = max(0, min(ceil(detail.size().width), max(leftByTitle, row.width * TextEditingStyle.caretListDetailShare)))
        let detailX = row.maxX - TextEditingStyle.caretListTextInset - detailWidth
        let detailHeight = detail.size().height
        detail.draw(with: CGRect(x: detailX, y: row.midY - detailHeight / 2, width: detailWidth, height: detailHeight),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        let room = max(0, detailX - TextEditingStyle.caretListGap - x - trailingWidth)
        let labelWidth = min(ceil(label.size().width), room)
        let labelHeight = label.size().height
        label.draw(with: CGRect(x: x, y: row.midY - labelHeight / 2, width: labelWidth, height: labelHeight),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let trailing {
            let size = trailing.size
            trailing.draw(in: CGRect(x: x + labelWidth + TextEditingStyle.caretListGap, y: row.midY - size.height / 2, width: size.width,
                                     height: size.height))
        }
    }

    /// An item's title, its matched characters in semibold, cut short with "…".
    static func label(_ item: CaretListItem, color: NSColor) -> NSAttributedString {
        let text = item.title
        let font = item.font ?? NSFont.systemFont(ofSize: TextEditingStyle.caretListLabelSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let string = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        let bold = item.font.map(semibold) ?? NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        for range in item.matched {
            guard let r = characterRange(range, in: text) else { continue }
            string.addAttribute(.font, value: bold, range: r)
        }
        return string
    }

    /// An item's detail, its matched characters in semibold and its dimmed ones fainter.
    static func detail(_ item: CaretListItem, color: NSColor) -> NSAttributedString {
        let text = item.detail ?? ""
        let string = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: TextEditingStyle.caretListDetailSize), .foregroundColor: color])
        let bold = NSFont.systemFont(ofSize: TextEditingStyle.caretListDetailSize, weight: .semibold)
        for range in item.detailMatched {
            guard let r = characterRange(range, in: text) else { continue }
            string.addAttribute(.font, value: bold, range: r)
        }
        for range in item.detailDimmed {
            guard let r = characterRange(range, in: text) else { continue }
            string.addAttribute(.foregroundColor, value: color.withAlphaComponent(color.alphaComponent * TextEditingStyle.caretListDimmedAlpha), range: r)
        }
        return string
    }

    /// A font's heavier face, the size it is: what AppKit makes of it bold, which for the system's
    /// monospaced font (a code editor's) is its semibold. A descriptor asked for a weight keeps the
    /// face it names.
    static func semibold(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    /// A range of `Character` offsets in a string as an `NSRange`; nil past its end.
    static func characterRange(_ range: Range<Int>, in text: String) -> NSRange? {
        guard range.lowerBound >= 0, range.upperBound <= text.count else { return nil }
        let start = text.index(text.startIndex, offsetBy: range.lowerBound)
        let end = text.index(start, offsetBy: range.count)
        return NSRange(start..<end, in: text)
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? {
        list.rows.indices.compactMap { index -> NSAccessibilityElement? in
            if case .header = list.rows[index] { return nil }
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(Self.spoken(list, row: index))
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(rect(ofRow: index))
            element.setAccessibilitySelected(list.highlighted == index)
            return element
        }
    }

    /// What VoiceOver says for a row: an item's `spoken`; a header's or an empty state's words.
    static func spoken(_ list: CaretList, row index: Int) -> String {
        switch list.rows[index] {
        case .header(let words), .empty(let words): words
        case .item(let item): item.spoken
        }
    }
}
