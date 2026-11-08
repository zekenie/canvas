import Adornments
import AppKit
import Canvas
import TextEditing

// A title typed in its pill: the line a shape's name is typed in, laid over the pill above its top-left corner, as the
// pill is: its capsule and symbol (Adornments' chip, as wide as what's typed needs), and over it one line of text in
// the pill's font and ink, the caret in it. A kind whose shapes are named as they're put down (the engineering kit's
// table: "the caret in its name") hosts it in its editing view (`TitleFieldHost`, over the shape and the row above it),
// and each change is written as the title in the editing session's step: the step that placed the shape ("Add Table"),
// or the session's own (`editingStepName`, "Rename Table"). Return and Escape end it, keeping what was typed; Tab and
// ⇧Tab say so too, for a host with stops after it or before it.

/// The line a shape's title is typed in, over its pill: a text view with no autocorrect, quotes, dashes or lists,
/// that hands each change, and the key that ends it, to its host, read through the one key table (`KeyMeaning`). Its
/// bounds are world units, as an editing view's are, its height the pill row's; it draws the chip as wide as its text
/// needs and takes presses only there.
@MainActor
public final class TitleField: NSView, NSTextViewDelegate {
    /// How typing ended: Return, Escape, Tab or ⇧Tab. Each keeps what was typed.
    public enum Ending: Sendable { case done, escape, tab, backTab }

    public let field: EditingTextView
    /// The title as typed, after each change.
    public var typed: ((String) -> Void)?
    /// Return, Escape, Tab or ⇧Tab.
    public var finished: ((Ending) -> Void)?
    /// The field took the keyboard (a press on the chip, VoiceOver's): for a host whose keys were elsewhere, in a row under it.
    public var began: (() -> Void)?
    /// ↓, for a host with stops under the title (a table's rows): true takes it. Unset, ↓ is the text's.
    public var onDown: (() -> Bool)?
    /// The pill as it's drawn with no text: its symbol and tint.
    private let chip: AdornmentLabel
    /// The pill as it's drawn while nothing is typed: its placeholder, dimmed, where the kind gives one.
    private let empty: AdornmentLabel?
    /// What the pill says, dimmed, while nothing is typed ("Table", "Enum"): nil for none, where the field is a caret's room.
    public let placeholder: String?

    /// A field holding `title`, its caret at the end, over a pill with `systemImage` first and in `tint` (nil: the
    /// pill's gray); while it holds nothing, the pill's `placeholder` shows dimmed after the caret, as the pill under it
    /// says it, so nothing moves as typing starts. `name` is what VoiceOver calls it.
    public init(title: String?, systemImage: String?, tint: AdornmentTint?, placeholder: String? = nil, name: String) {
        self.placeholder = placeholder
        let blank = AdornmentLabel(" ", systemImage: systemImage)
        chip = tint.map { blank.tinted($0) } ?? blank
        empty = placeholder.map { placeholder in
            let label = AdornmentLabel(placeholder: placeholder, systemImage: systemImage)
            return tint.map { label.tinted($0) } ?? label
        }
        field = TitleTextView()
        super.init(frame: .zero)
        let ink = chip.textInk
        field.textColor = ink
        field.insertionPointColor = ink
        field.string = title ?? ""
        field.setSelectedRange(NSRange(location: (title ?? "").utf16.count, length: 0))
        field.delegate = self
        field.setAccessibilityLabel(name)
        addSubview(field)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    /// Whether its text has the keyboard: what its ring shows (a host with rows under it moves the keys to them).
    public var hasKeys: Bool { field.window?.firstResponder === field }

    /// World units a view point, as the pill is drawn: its row's height in the bounds.
    private var scale: CGFloat { max(bounds.height / AdornmentLayout.rowHeight, .leastNormalMagnitude) }

    /// How wide the chip is, view points: its text as typed (a caret's room when empty), its symbol, its padding.
    public var chipWidth: CGFloat {
        if field.string.isEmpty, let empty { return empty.contentSize.width }
        let text = NSAttributedString(string: field.string, attributes: [.font: AdornmentLabel.rowFont]).size().width
        return (chip.textStart + max(text, TitleFieldStyle.caretRoom) + AdornmentLabel.textEnd).rounded(.up)
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeField()
    }

    public override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        placeField()
    }

    public override func layout() {
        super.layout()
        placeField()
    }

    /// The text's line, where the pill sets its text, in the pill's font at its size in world units.
    private func placeField() {
        let scale = scale, font = NSFont(descriptor: AdornmentLabel.rowFont.fontDescriptor, size: AdornmentLabel.rowFont.pointSize * scale)
            ?? AdornmentLabel.rowFont
        if field.font != font {
            field.font = font
            field.typingAttributes = [.font: font, .foregroundColor: chip.textInk]
        }
        let line = ceil(font.ascender - font.descender + font.leading)
        let start = chip.textStart * scale
        let frame = CGRect(x: start, y: ((bounds.height - line) / 2), width: max(0, min(bounds.width, chipWidth * scale) - start),
                           height: line)
        if field.frame != frame { field.frame = frame }
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        let scale = scale, width = min(chipWidth, bounds.width / scale)
        if field.string.isEmpty, let empty {
            empty.draw(at: .zero, scale: scale, in: cg)
        } else {
            chip.drawChip(width: width, at: .zero, scale: scale, in: cg)
        }
        // The ring a field that has the keys shows, round the chip: a host that moves the keys to a row under it shows none.
        guard hasKeys else { return }
        let reach = TitleFieldStyle.ringWidth * scale / 2
        let ring = CGRect(x: 0, y: 0, width: width * scale, height: bounds.height).insetBy(dx: -reach, dy: -reach)
        cg.addPath(CGPath(roundedRect: ring, cornerWidth: ring.height / 2, cornerHeight: ring.height / 2, transform: nil))
        cg.setStrokeColor(TitleFieldStyle.ring.cgColor)
        cg.setLineWidth(TitleFieldStyle.ringWidth * scale)
        cg.strokePath()
    }

    /// Presses on the chip are the field's; anywhere else in its row they go on to what's under it.
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard local.x <= chipWidth * scale, bounds.contains(local) else { return nil }
        return field.hitTest(local) ?? field
    }

    public func textDidChange(_ notification: Notification) {
        needsLayout = true
        needsDisplay = true
        typed?(field.string)
    }

    public func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let reading = KeyMeaning.Reading(command: selector) else { return false }
        switch reading.meaning {
        // A title is one line: Return with a modifier ends it as Return does, and types no line break.
        case .activate, .finish: finished?(.done)
        case .back: finished?(.escape)
        case .next: finished?(.tab)
        case .previous: finished?(.backTab)
        case .down: return onDown?() ?? false
        default: return false
        }
        return true
    }

    // MARK: Where it goes

    /// Where a shape's title pill is while it's typed in, in world units at `zoom`: the row above `frame`'s top edge,
    /// from its left end, as tall as the pill and `TitleFieldStyle.reach` past the shape's right edge, so a title
    /// longer than the shape has room.
    public static func pillRow(above frame: CGRect, zoom: CGFloat) -> CGRect {
        let scale = AdornmentLayout.scale(atZoom: zoom)
        return CGRect(x: frame.minX, y: frame.minY - (AdornmentLayout.rowGap + AdornmentLayout.rowHeight) * scale,
                      width: frame.width + TitleFieldStyle.reach * scale, height: AdornmentLayout.rowHeight * scale)
    }

    /// The same for shape `id`, as it is drawn at rest: the row starts right of any container's tab it would meet (Adornments'
    /// `adornmentRowStart`), so the field is where the pill was and nothing moves as typing starts. The row's right end stays.
    public static func pillRow(of id: ShapeID, above frame: CGRect, zoom: CGFloat, in editor: CanvasEditor) -> CGRect {
        let row = pillRow(above: frame, zoom: zoom), start = min(editor.adornmentRowStart(of: id), max(0, row.width - 1))
        return CGRect(x: row.minX + start, y: row.minY, width: row.width - start, height: row.height)
    }

    /// The editing frame of a shape whose title is typed in its pill: its frame and the row above it.
    public static func editingFrame(around frame: CGRect, zoom: CGFloat) -> CGRect {
        frame.union(pillRow(above: frame, zoom: zoom))
    }
}

/// The text view the title is typed in: one line, nothing substituted, no undo of its own (each change is a step's), so
/// Edit ▸ Undo is the board's while it has the keyboard ("Undo Add Table").
private final class TitleTextView: EditingTextView, UndoesBoardWhenEmpty {
    override init(frame: NSRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isRichText = false
        drawsBackground = false
        allowsUndo = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        commitsOnLeaving = false
        textContainerInset = .zero
        isHorizontallyResizable = true
        isVerticallyResizable = false
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.lineFragmentPadding = 0
        textContainer?.widthTracksTextView = false
        textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.maximumNumberOfLines = 1
    }

    /// NSTextView's `init(frame:)` makes its text system and calls `init(frame:textContainer:)`, where it's set up.
    init() { super.init(frame: .zero) }

    // Its chip's ring is drawn while it has the keys: the chip is drawn again as they come and go.
    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became {
            superview?.needsDisplay = true
            (superview as? TitleField)?.began?()
        }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { superview?.needsDisplay = true }
        return resigned
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// An editing view for a kind whose title is typed in its pill: as big as its editing frame (`TitleField.editingFrame`),
/// the field on the pill's row at its top, and nothing else of it takes a press. A host with more to edit (a table's rows)
/// adds its views beside the field.
@MainActor
public final class TitleFieldHost: NSView {
    public let titleField: TitleField

    public init(_ titleField: TitleField) {
        self.titleField = titleField
        super.init(frame: .zero)
        addSubview(titleField)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    public override var isFlipped: Bool { true }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        placeField()
    }

    public override func setBoundsSize(_ newSize: NSSize) {
        super.setBoundsSize(newSize)
        placeField()
    }

    public override func layout() {
        super.layout()
        placeField()
    }

    /// The pill's row, at the top: as tall as a pill is at the zoom its frame and bounds say (view points to world units).
    private func placeField() {
        guard bounds.width > 0, frame.width > 0 else { return }
        let zoom = frame.width / bounds.width
        let row = CGRect(x: 0, y: 0, width: bounds.width, height: AdornmentLayout.rowHeight * AdornmentLayout.scale(atZoom: zoom))
        if titleField.frame != row { titleField.frame = row }
    }

    /// Only the field takes presses. `point` is in the superview's coordinates (its frame's, with none).
    public override func hitTest(_ point: NSPoint) -> NSView? {
        let local: CGPoint
        if let superview {
            local = convert(point, from: superview)
        } else {
            guard frame.width > 0, frame.height > 0 else { return nil }
            local = CGPoint(x: bounds.minX + (point.x - frame.minX) * bounds.width / frame.width,
                            y: bounds.minY + (point.y - frame.minY) * bounds.height / frame.height)
        }
        return titleField.hitTest(local)
    }
}

extension TitleField {
    /// The editing view of a shape whose title is typed in its pill, and nothing else (`Editable.makeEditingView`): the
    /// field holding its title, over a pill with `systemImage` in `tint` (its `placeholder` dimmed while it holds nothing),
    /// VoiceOver's `name` for it; each change written as
    /// its title (`TitleProperty`, a blank one none) in the editing session's step, Return, Escape, Tab and ⇧Tab ending it.
    public static func editingView<P: ShapeProps>(for shape: ShapeRecord<P>, context: EditContext<P>, systemImage: String?, tint: AdornmentTint?,
                                                  placeholder: String? = nil, name: String) -> EditingView {
        let field = TitleField(title: shape[TitleProperty.self], systemImage: systemImage, tint: tint, placeholder: placeholder, name: name)
        let id = shape.id
        field.typed = { text in
            let title = TitleProperty.folded(text)
            // A change that changes nothing (the same blank twice) is no step.
            guard context.shape?[TitleProperty.self] != title else { return }
            context.transact { $0.update(id) { $0[TitleProperty.self] = title } }
        }
        field.finished = { _ in context.end() }
        let host = TitleFieldHost(field)
        return EditingView(view: host, firstResponder: field.field)
    }
}

/// The title field's measures, view points.
@MainActor
enum TitleFieldStyle {
    /// What an empty field's chip keeps for the caret.
    static let caretRoom: CGFloat = 4
    /// The ring round the chip while it has the keys: the system's focus ring.
    static let ringWidth: CGFloat = 2
    static var ring: NSColor { .keyboardFocusIndicatorColor }
    /// How far past the shape's right edge the row a title is typed in reaches.
    static let reach: CGFloat = 200
}
