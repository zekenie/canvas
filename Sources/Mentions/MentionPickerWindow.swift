import AppKit
import Canvas

/// The `@` picker's window: borderless, a child of the text view's window that never becomes key,
/// so the text view keeps the keyboard (Apple's CustomMenus pattern). Menu material, rounded,
/// `MentionStyle.pickerWidth` wide, showing `pickerRowsShown` rows and scrolling within them. It
/// sits just below the `@`, or above its line where there's no room below, and on the screen; it
/// has the same size at any zoom, since the `@`'s rect is in screen points.
///
/// It's never ordered in while its parent window isn't visible (so an unshown window's tests put
/// nothing on screen), but it's placed all the same: `frame` is where it would be.
@MainActor
final class MentionPickerWindow: NSPanel {
    let rowsView: MentionPickerRowsView
    private let scrollView = NSScrollView()

    init(picker: MentionPicker, pick: @escaping @MainActor (MentionCandidate) -> Void) {
        rowsView = MentionPickerRowsView(picker: picker, pick: pick)
        super.init(contentRect: CGRect(x: 0, y: 0, width: MentionStyle.pickerWidth, height: MentionStyle.pickerRowHeight),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
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
        effect.maskImage = Self.mask(radius: MentionStyle.pickerCornerRadius)
        contentView = effect

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .none
        scrollView.documentView = rowsView
        scrollView.autoresizingMask = [.width, .height]
        effect.addSubview(scrollView)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

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

    /// How tall it is for its rows: as many as show at once, and its insets.
    var fittedHeight: CGFloat {
        CGFloat(min(max(rowsView.picker.rows.count, 1), MentionStyle.pickerRowsShown)) * MentionStyle.pickerRowHeight
            + 2 * MentionStyle.pickerInset
    }

    /// Places it for an `@` whose rect on screen is `anchor`: its symbols under the `@`, 4 points
    /// below the line, or above it where there's no room below, and within `screen`'s visible frame.
    func place(below anchor: CGRect, on screen: CGRect?) {
        let size = CGSize(width: MentionStyle.pickerWidth, height: fittedHeight)
        var origin = CGPoint(x: anchor.minX - MentionStyle.pickerRowInset - MentionStyle.pickerTextInset,
                             y: anchor.minY - MentionStyle.pickerOffset - size.height)
        if let screen {
            if origin.y < screen.minY { origin.y = anchor.maxY + MentionStyle.pickerOffset }
            origin.x = min(max(origin.x, screen.minX), screen.maxX - size.width)
            origin.y = min(max(origin.y, screen.minY), screen.maxY - size.height)
        }
        let frame = CGRect(origin: origin, size: size)
        if frame != self.frame {
            setFrame(frame, display: isVisible)
            invalidateShadow()
        }
        let content = CGRect(origin: .zero, size: size)
        scrollView.frame = content.insetBy(dx: 0, dy: MentionStyle.pickerInset)
        rowsView.fit(width: size.width)
    }

    /// The rows changed or the highlight moved: redraw, and keep the highlight in view.
    func reload() {
        rowsView.fit(width: frame.width)
        rowsView.needsDisplay = true
        if let index = rowsView.picker.highlighted { rowsView.scrollToVisible(rowsView.rect(ofRow: index)) }
    }
}

/// The picker's rows, drawn: a shape's symbol in its tint, its label with the matched characters
/// in semibold (a placeholder label in italic, secondary), a lock after a read-only shape's, and
/// its detail at the trailing end; a header's words small and secondary; an empty state secondary.
/// The pointer over a shape's row highlights it, and a click picks it.
@MainActor
final class MentionPickerRowsView: NSView {
    let picker: MentionPicker
    private let pick: @MainActor (MentionCandidate) -> Void
    private var trackingArea: NSTrackingArea?

    init(picker: MentionPicker, pick: @escaping @MainActor (MentionCandidate) -> Void) {
        self.picker = picker
        self.pick = pick
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.list)
        setAccessibilityLabel(MentionStyle.pickerAccessibilityLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// As tall as all its rows, and as wide as the window.
    func fit(width: CGFloat) {
        let size = CGSize(width: width, height: CGFloat(picker.rows.count) * MentionStyle.pickerRowHeight)
        if frame.size != size { setFrameSize(size) }
    }

    func rect(ofRow index: Int) -> CGRect {
        CGRect(x: 0, y: CGFloat(index) * MentionStyle.pickerRowHeight, width: bounds.width, height: MentionStyle.pickerRowHeight)
    }

    /// The row at a point in the view, if there's one.
    func row(at point: CGPoint) -> Int? {
        let index = Int(floor(point.y / MentionStyle.pickerRowHeight))
        return picker.rows.indices.contains(index) ? index : nil
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
        if let index = row(at: convert(event.locationInWindow, from: nil)) { picker.highlight(row: index) }
    }

    override func mouseDown(with event: NSEvent) {
        guard let index = row(at: convert(event.locationInWindow, from: nil)), let candidate = picker.rows[index].candidate else { return }
        picker.highlight(row: index)
        pick(candidate)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        for index in picker.rows.indices {
            let rect = rect(ofRow: index)
            guard rect.intersects(dirtyRect) else { continue }
            switch picker.rows[index] {
            case .header(let title):
                draw(title, font: .systemFont(ofSize: MentionStyle.pickerHeaderSize, weight: .semibold), color: .secondaryLabelColor,
                     in: rect, from: MentionStyle.pickerRowInset + MentionStyle.pickerTextInset)
            case .empty(let words):
                draw(words, font: .systemFont(ofSize: MentionStyle.pickerLabelSize), color: .secondaryLabelColor,
                     in: rect, from: MentionStyle.pickerRowInset + MentionStyle.pickerTextInset)
            case .candidate(let candidate):
                draw(candidate, in: rect, highlighted: picker.highlighted == index)
            }
        }
    }

    private func draw(_ text: String, font: NSFont, color: NSColor, in rect: CGRect, from x: CGFloat) {
        let string = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        let height = string.size().height
        string.draw(with: CGRect(x: rect.minX + x, y: rect.midY - height / 2, width: rect.width - x - MentionStyle.pickerRowInset * 2,
                                 height: height), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func draw(_ candidate: MentionCandidate, in rect: CGRect, highlighted: Bool) {
        let appearance = candidate.appearance
        let row = rect.insetBy(dx: MentionStyle.pickerRowInset, dy: 0)
        if highlighted {
            NSColor.selectedContentBackgroundColor.setFill()
            NSBezierPath(roundedRect: row, xRadius: MentionStyle.pickerHighlightRadius, yRadius: MentionStyle.pickerHighlightRadius).fill()
        }
        let onHighlight = NSColor.alternateSelectedControlTextColor
        let primary = highlighted ? onHighlight : .labelColor
        let secondary = highlighted ? onHighlight.withAlphaComponent(0.75) : .secondaryLabelColor

        // The symbol, in the shape's tint.
        let symbolColor = highlighted ? onHighlight : appearance.tint ?? .secondaryLabelColor
        var x = row.minX + MentionStyle.pickerTextInset
        if let symbol = NSImage(systemSymbolName: appearance.systemImage, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: MentionStyle.pickerLabelSize, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [symbolColor]))) {
            let size = symbol.size
            symbol.draw(in: CGRect(x: x + (MentionStyle.pickerSymbolWidth - size.width) / 2, y: row.midY - size.height / 2,
                                   width: size.width, height: size.height))
        }
        x += MentionStyle.pickerSymbolWidth + MentionStyle.pickerGap

        // The detail, at the trailing end, then the label in what's left, a lock after it.
        let detail = NSAttributedString(string: appearance.detail, attributes: [
            .font: NSFont.systemFont(ofSize: MentionStyle.pickerDetailSize), .foregroundColor: secondary])
        let detailWidth = min(ceil(detail.size().width), row.width * MentionStyle.pickerDetailShare)
        let detailX = row.maxX - MentionStyle.pickerTextInset - detailWidth
        let detailHeight = detail.size().height
        detail.draw(with: CGRect(x: detailX, y: row.midY - detailHeight / 2, width: detailWidth, height: detailHeight),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])

        let label = Self.label(candidate, color: appearance.isPlaceholder ? secondary : primary)
        let lock = candidate.isReadOnly
            ? NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: MentionStyle.pickerDetailSize, weight: .regular)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [secondary])))
            : nil
        let lockWidth = lock.map { $0.size.width + MentionStyle.pickerGap } ?? 0
        let room = max(0, detailX - MentionStyle.pickerGap - x - lockWidth)
        let labelWidth = min(ceil(label.size().width), room)
        let labelHeight = label.size().height
        label.draw(with: CGRect(x: x, y: row.midY - labelHeight / 2, width: labelWidth, height: labelHeight),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        if let lock {
            let size = lock.size
            lock.draw(in: CGRect(x: x + labelWidth + MentionStyle.pickerGap, y: row.midY - size.height / 2, width: size.width, height: size.height))
        }
    }

    /// A shape's label, its matched characters in semibold; a placeholder's in italic.
    static func label(_ candidate: MentionCandidate, color: NSColor) -> NSAttributedString {
        let text = candidate.appearance.label
        var font = NSFont.systemFont(ofSize: MentionStyle.pickerLabelSize)
        if candidate.appearance.isPlaceholder,
           let italic = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: font.pointSize) { font = italic }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let string = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
        let bold = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
        for range in candidate.matched {
            guard let r = characterRange(range, in: text) else { continue }
            string.addAttribute(.font, value: bold, range: r)
        }
        return string
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
        picker.rows.indices.compactMap { index -> NSAccessibilityElement? in
            guard picker.rows[index].candidate != nil || { if case .empty = picker.rows[index] { true } else { false } }() else { return nil }
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(Self.spoken(picker, row: index))
            element.setAccessibilityParent(self)
            element.setAccessibilityFrameInParentSpace(rect(ofRow: index))
            element.setAccessibilitySelected(picker.highlighted == index)
            return element
        }
    }

    /// What VoiceOver says for a row: "Groceries, Task, 2 of 7"; an empty state's words.
    static func spoken(_ picker: MentionPicker, row index: Int) -> String {
        switch picker.rows[index] {
        case .header(let title), .empty(let title): return title
        case .candidate(let candidate):
            let shapes = picker.rows.indices.filter { picker.rows[$0].candidate != nil }
            let position = (shapes.firstIndex(of: index) ?? 0) + 1
            return "\(candidate.appearance.label), \(candidate.appearance.kindName), \(position) of \(shapes.count)"
        }
    }
}

extension MentionStyle {
    /// Between the window's edge and its first and last rows.
    static let pickerInset: CGFloat = 5
    /// Between the window's sides and a row's highlight.
    static let pickerRowInset: CGFloat = 5
    /// Between a row's highlight and its symbol, and its detail.
    static let pickerTextInset: CGFloat = 7
    static let pickerSymbolWidth: CGFloat = 16
    static let pickerGap: CGFloat = 6
    static let pickerHighlightRadius: CGFloat = 4
    static let pickerLabelSize: CGFloat = 13
    static let pickerDetailSize: CGFloat = 11
    static let pickerHeaderSize: CGFloat = 11
    /// The most of a row its detail takes: the label comes first.
    static let pickerDetailShare: CGFloat = 0.4
    static let pickerAccessibilityLabel = "Mentions"
}
