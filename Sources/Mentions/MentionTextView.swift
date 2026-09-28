import AppKit
import Canvas

extension NSPasteboard.PasteboardType {
    /// Mention text on the pasteboard, in its stored form: what a mention text view copies beside
    /// the plain form, and pastes first, with its mentions' ids as they were.
    public static let mentionText = NSPasteboard.PasteboardType("com.example.InfiniteCanvas.mention-text")
    /// The plain string under its legacy name, which a text view is asked to write too: answering
    /// only `.string` would leave a raw U+FFFC for each pill there.
    static let legacyString = NSPasteboard.PasteboardType("NSStringPboardType")
}

/// The text view for editable mention text (TextKit 2): its pills, the `@` picker, copy and paste,
/// accessibility, live labels. A host sets its delegate as usual and reads the text back as
/// `mentionText` in `textDidChange`; the view's own keys run first.
///
/// - A pill is one character, U+FFFC, holding a `MentionAttachment`: the caret steps over it, a
///   selection takes it whole, one Backspace deletes it, and text typed beside it is plain. A
///   click on it selects it (the whole character); a double-click on a live one goes to its target
///   (`MentionState.follow`, on the next turn, since going ends the editing this view is part of).
///   Its release is the view's too, never the canvas's behind it. Pills aren't links. The pointer over a live one hovers its target on the canvas; over one
///   that isn't live, its tooltip says why ("Deleted"). Its menu adds Go to and Remove Mention.
/// - `@` typed where a word starts opens the picker (`MentionPicker`, shown in a child window that
///   never takes the keyboard): what's typed after it is the query, the keys that move and pick
///   come here first (`doCommand(by:)`), and a pick puts the pill in the query's place, then a
///   space, as one undoable change.
/// - Copy writes the stored form (`.mentionText`) and the plain one ("@Label"); paste reads the
///   stored form first, then plain text, where a whole `@[label](shape:UUID)` becomes a pill.
/// - Each pill shows its target as it's called now: the view observes its targets
///   (`MentionState.observe`) and redraws the pills of those that change, with no edit.
/// - Under TextKit 2 its own undo and redo change the text without telling the delegate: after
///   either, it shows the pills put back as their targets are now and, if the text differs from
///   what it last reported, reports it (`didChangeText`), in any window. A board's window tells the
///   text it changed after its undo too; the text is reported by then, so the host writes once.
@MainActor
public final class MentionTextView<Scope: MentionScope>: NSTextView {
    /// The shape the text is on: never offered in its picker.
    public private(set) var owner: ShapeID?
    public private(set) weak var mentions: MentionState?
    /// Its style; nil for one made without (`init(frame:textContainer:)`), which makes no pills.
    public private(set) var style: MentionTextStyle?

    // Made once NSTextView's init has run (`setUp`): `init(frame:)` calls `init(frame:textContainer:)`
    // on the view, which would otherwise make them twice.
    /// The host's delegate, behind the view's own.
    private var forwarder: MentionTextDelegate?
    /// The view's Objective-C face: notifications, menu items, tooltips.
    private var helper: MentionTextViewHelper?

    /// The open picker, and its window.
    public private(set) var picker: MentionPicker?
    private var pickerWindow: MentionPickerWindow?
    /// The substitutions the picker turned off while it's open, to put back as they were.
    private var substitutions: Substitutions?
    /// The target the picker's highlight hovers, and the one the pointer hovers.
    private var pickerHover: ShapeID?
    private var pointerHover: ShapeID?
    /// Between `shouldChangeText` and `didChangeText`: the selection moving then is the edit's.
    private var isChangingText = false
    /// A press the view took on a pill, until its release: the drags and the release are the
    /// view's too, so none of them reaches the canvas behind it.
    private var tookPillPress = false

    /// What the host last heard the text is, to tell after an undo whether it changed.
    private var reported: ScopedMentionText<Scope>?
    private var observation: MentionObservation?
    private var observedTargets: Set<ShapeID> = []
    private var hoverArea: NSTrackingArea?
    private var toolTipTags: [NSView.ToolTipTag] = []
    private var toolTipsAreStale = true

    public init(frame: CGRect, text: ScopedMentionText<Scope>, style: MentionTextStyle, owner: ShapeID?, mentions: MentionState?) {
        super.init(frame: frame)
        self.owner = owner
        self.mentions = mentions
        self.style = style
        isRichText = false
        typingAttributes = style.attributes
        textStorage?.setAttributedString(style.attributedString(text, width: pillWidth) { [weak mentions] in mentions?.resolve($0) ?? .missing })
        reported = mentionText
        observeTargets()
    }

    /// What NSTextView's `init(frame:)` calls on itself: a view made this way has no style, so it
    /// makes no pills, but keeps the host's delegate as any other does.
    public override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        setUp()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setUp()
    }

    private func setUp() {
        let forwarder = MentionTextDelegate()
        self.forwarder = forwarder
        super.delegate = forwarder
        helper = MentionTextViewHelper()
    }

    /// The host's delegate. The view's own stands in front of it, answering what only a delegate
    /// can (Writing Tools skip pills) and passing the host everything else.
    public override weak var delegate: (any NSTextViewDelegate)? {
        get { forwarder == nil ? super.delegate : forwarder?.host }
        set {
            guard let forwarder else { return super.delegate = newValue }
            forwarder.host = newValue
            super.delegate = forwarder
        }
    }

    // MARK: The text

    /// The text, from its storage (never `string`, which holds a raw U+FFFC for each pill), written
    /// canonically: each pill named as it shows now.
    public var mentionText: ScopedMentionText<Scope> {
        MentionTextStyle.mentionText(from: textStorage ?? NSAttributedString())
    }

    /// Each pill in the text, with its character's index.
    private func pills() -> [(location: Int, pill: MentionAttachment)] {
        guard let storage = textStorage else { return [] }
        var found: [(Int, MentionAttachment)] = []
        storage.enumerateAttribute(.attachment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let pill = value as? MentionAttachment else { return }
            for location in range.location..<NSMaxRange(range) { found.append((location, pill)) }
        }
        return found
    }

    /// The pill at a character index, if there's one.
    private func pill(at location: Int) -> MentionAttachment? {
        guard let storage = textStorage, location >= 0, location < storage.length else { return nil }
        return storage.attribute(.attachment, at: location, effectiveRange: nil) as? MentionAttachment
    }

    /// What a mention of `target` shows now; missing without a state to ask.
    private func resolve(_ target: ShapeID) -> MentionResolution { mentions?.resolve(target) ?? .missing }

    /// The widest a pill may be: the text's line, to a 64th of a point. A view scaled by the zoom
    /// has a frame a hair off its bounds (200.0000000000001 at 60%), which would otherwise make
    /// every pill again at each zoom, laying the text out again while it's being drawn.
    private var pillWidth: CGFloat? {
        guard let container = textContainer, container.size.width < 1e6 else { return nil }
        return (max(0, container.size.width - 2 * container.lineFragmentPadding) * 64).rounded() / 64
    }

    /// A pill naming `target`, as it shows now, the text's attributes on its character.
    private func pillString(_ target: ShapeID, storedLabel: String) -> NSAttributedString? {
        guard let style else { return nil }
        return style.pill(MentionAttachment(target: target, storedLabel: storedLabel, resolution: resolve(target), style: style, width: pillWidth))
    }

    /// Mention text as the view shows it, its pills made for the view's line.
    private func attributed(_ text: ScopedMentionText<Scope>) -> NSAttributedString {
        guard let style else { return NSAttributedString(string: text.plainText(), attributes: typingAttributes) }
        return style.attributedString(text, width: pillWidth) { [weak mentions] in mentions?.resolve($0) ?? .missing }
    }

    /// Replaces a range with `replacement`, as an edit a person makes: undoable, and heard by the
    /// host (`shouldChangeText`, `didChangeText`), its own step of undo. The caret lands after it.
    @discardableResult
    private func replace(_ range: NSRange, with replacement: NSAttributedString) -> Bool {
        breakUndoCoalescing()
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: replacement.string) else { return false }
        storage.replaceCharacters(in: range, with: replacement)
        setSelectedRange(NSRange(location: range.location + replacement.length, length: 0))
        didChangeText()
        breakUndoCoalescing()
        return true
    }

    public override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        let should = super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        if should { isChangingText = true }
        return should
    }

    public override func didChangeText() {
        isChangingText = false
        reported = mentionText
        holdWrittenLabels()
        super.didChangeText()
        textDidChangeHere()
    }

    /// Each pill holds the name the host was last told it has (its live one, when the text was
    /// written), which is what the board holds: a pill whose shape goes shows that name, as the
    /// canvas does.
    private func holdWrittenLabels() {
        for (_, pill) in pills() { pill.hold(pill.writtenLabel) }
    }

    /// After any change to the characters: the targets to observe, the tooltips, the picker.
    private func textDidChangeHere() {
        observeTargets()
        toolTipsAreStale = true
        readPicker(isEdit: true)
    }

    // MARK: Pills that fit and show as they are

    /// Makes again, for the view's line, each pill made for another width (a host sets the view's
    /// insets after making it). Only attributes change: nothing is heard, nothing undone.
    private func fitPills() {
        guard let storage = textStorage, let style else { return }
        let width = pillWidth
        let unfit = pills().filter { $0.pill.widthLimit != width }
        guard !unfit.isEmpty else { return }
        storage.beginEditing()
        for (location, old) in unfit {
            let pill = MentionAttachment(target: old.target, storedLabel: old.storedLabel, resolution: old.resolution, style: style, width: width)
            pill.isSelected = old.isSelected
            storage.addAttribute(.attachment, value: pill, range: NSRange(location: location, length: 1))
        }
        storage.endEditing()
        toolTipsAreStale = true
    }

    public override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        fitPills()
    }

    public override var textContainerInset: NSSize {
        get { super.textContainerInset }
        set {
            super.textContainerInset = newValue
            fitPills()
        }
    }

    /// Observes the targets of the text's pills, so each shows its target as it is now.
    private func observeTargets() {
        guard let mentions else { return }
        let targets = Set(pills().map(\.pill.target))
        guard targets != observedTargets else { return }
        observation?.cancel()
        observedTargets = targets
        observation = targets.isEmpty ? nil : mentions.observe(targets) { [weak self] changed in self?.refreshPills(of: changed) }
    }

    /// Shows the pills of `targets` (all, if nil) as their targets are now: new images and bounds,
    /// laid out again. A pill whose target stops being live shows the name the board holds for it
    /// (`holdWrittenLabels`), as the canvas does, so nothing changes as editing ends or begins.
    /// The characters don't change, so nothing is heard and nothing commits.
    private func refreshPills(of targets: Set<ShapeID>?) {
        guard let storage = textStorage else { return }
        var changed: [Int] = []
        storage.beginEditing()
        for (location, pill) in pills() where targets?.contains(pill.target) ?? true {
            let now = resolve(pill.target)
            guard now != pill.resolution else { continue }
            pill.update(now)
            // The tooltip goes with the state: a pill that isn't live says why.
            let range = NSRange(location: location, length: 1)
            if let help = pill.help { storage.addAttribute(.toolTip, value: help, range: range) }
            else { storage.removeAttribute(.toolTip, range: range) }
            changed.append(location)
        }
        storage.endEditing()
        for location in changed { invalidateLayout(of: NSRange(location: location, length: 1)) }
        if !changed.isEmpty { toolTipsAreStale = true }
    }

    /// Lays a range out again and redraws it: a pill's image or bounds changed.
    private func invalidateLayout(of range: NSRange) {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let start = content.location(content.documentRange.location, offsetBy: range.location),
              let end = content.location(start, offsetBy: range.length),
              let textRange = NSTextRange(location: start, end: end) else { return }
        layout.invalidateLayout(for: textRange)
        needsDisplay = true
    }

    // MARK: Selection

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        showSelectedPills()
        if !isChangingText { readPicker(isEdit: false) }
    }

    /// Draws each pill in the selection in the selection's colors: the system's highlight is
    /// drawn behind attachments, so it wouldn't show on one.
    private func showSelectedPills() {
        let selected = selectedRanges.map(\.rangeValue).filter { $0.length > 0 }
        for (location, pill) in pills() {
            let isSelected = selected.contains { NSLocationInRange(location, $0) }
            guard pill.isSelected != isSelected else { continue }
            pill.isSelected = isSelected
            invalidateLayout(of: NSRange(location: location, length: 1))
        }
    }

    /// Selects the pill at a point in the view's coordinates (its whole character), if there's one.
    @discardableResult
    public func selectPill(at point: CGPoint) -> Bool {
        guard let range = pillRange(at: point) else { return false }
        setSelectedRange(range)
        return true
    }

    /// The character of the pill drawn at a point in the view's coordinates.
    func pillRange(at point: CGPoint) -> NSRange? {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return nil }
        let inContainer = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        for (location, _) in pills() {
            guard let frame = segmentFrame(of: location, layout: layout, content: content) else { continue }
            if frame.contains(inContainer) { return NSRange(location: location, length: 1) }
        }
        return nil
    }

    /// Where a character is laid out, in the text container.
    private func segmentFrame(of location: Int, layout: NSTextLayoutManager, content: NSTextContentManager) -> CGRect? {
        guard let start = content.location(content.documentRange.location, offsetBy: location),
              let end = content.location(start, offsetBy: 1),
              let range = NSTextRange(location: start, end: end) else { return nil }
        layout.ensureLayout(for: range)
        var found: CGRect?
        layout.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            found = found.map { $0.union(frame) } ?? frame
            return true
        }
        return found
    }

    /// Where the pill at a character index is, in the view's coordinates.
    private func pillFrame(at location: Int) -> CGRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let frame = segmentFrame(of: location, layout: layout, content: content) else { return nil }
        return frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    // MARK: Clicks

    /// A plain click on a pill selects it whole; a double-click on a live one goes to its target,
    /// and on one that isn't live keeps it selected. Neither tracks the pointer as a click in text
    /// does. Anywhere else, or with a modifier, the click is the text view's.
    /// The press on a pill is the view's to its release, which it keeps from the canvas behind it
    /// (a release there would hover the shape being edited).
    public override func mouseDown(with event: NSEvent) {
        let plain = event.modifierFlags.intersection([.shift, .command, .option, .control]).isEmpty
        guard plain, let range = pillRange(at: convert(event.locationInWindow, from: nil)), let pill = pill(at: range.location) else {
            tookPillPress = false
            return super.mouseDown(with: event)
        }
        tookPillPress = true
        if window?.firstResponder !== self { window?.makeFirstResponder(self) }
        setSelectedRange(range)
        if event.clickCount == 2, pill.resolution.isLive { mentions?.follow(pill.target) }
    }

    public override func mouseDragged(with event: NSEvent) {
        guard !tookPillPress else { return }
        super.mouseDragged(with: event)
    }

    public override func mouseUp(with event: NSEvent) {
        guard !tookPillPress else {
            tookPillPress = false
            return
        }
        super.mouseUp(with: event)
    }

    // MARK: Hover and tooltips

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    /// The pointer over a live pill hovers its target (again on each move: the canvas ends hover
    /// once as the pointer comes onto the view, perhaps after this does).
    public override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if toolTipsAreStale { updateToolTips() }
        let target = pillRange(at: convert(event.locationInWindow, from: nil)).flatMap { pill(at: $0.location) }
            .flatMap { $0.resolution.isLive ? $0.target : nil }
        if let pointerHover, pointerHover != target { mentions?.endHover(pointerHover) }
        pointerHover = target
        if let target { mentions?.hover(target) }
    }

    public override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        endPointerHover()
    }

    private func endPointerHover() {
        if let pointerHover { mentions?.endHover(pointerHover) }
        pointerHover = nil
    }

    public override func viewWillDraw() {
        super.viewWillDraw()
        if toolTipsAreStale { updateToolTips() }
    }

    /// A tooltip over each pill that isn't live, saying why: TextKit 2 is left to show none.
    private func updateToolTips() {
        toolTipsAreStale = false
        for tag in toolTipTags { removeToolTip(tag) }
        toolTipTags = []
        guard let helper else { return }
        for (location, pill) in pills() where !pill.resolution.isLive {
            guard let frame = pillFrame(at: location) else { continue }
            toolTipTags.append(addToolTip(frame, owner: helper, userData: nil))
        }
        helper.toolTip = { [weak self] point in self?.toolTip(at: point) }
    }

    /// What the tooltip says at a point in the view: why the pill there isn't live; nil elsewhere.
    public func toolTip(at point: CGPoint) -> String? {
        pillRange(at: point).flatMap { pill(at: $0.location) }?.help
    }

    // MARK: The pill's menu

    /// The text view's menu, with Go to and Remove Mention first on a pill (which it selects).
    public override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event)
        guard let range = pillRange(at: convert(event.locationInWindow, from: nil)), let pill = pill(at: range.location), let helper else {
            return menu
        }
        setSelectedRange(range)
        let result = menu ?? NSMenu()
        var items: [NSMenuItem] = []
        if pill.resolution.isLive {
            let target = pill.target
            items.append(helper.item(MentionStyle.goTo(pill.shownLabel)) { [weak self] in self?.mentions?.follow(target) })
        }
        items.append(helper.item(MentionStyle.removeMention) { [weak self] in self?.removeMention(target: pill) })
        items.append(.separator())
        for (index, item) in items.enumerated() { result.insertItem(item, at: index) }
        return result
    }

    /// Turns a pill into its name, as text: one undoable change the host hears.
    private func removeMention(target pill: MentionAttachment) {
        guard let location = pills().first(where: { $0.pill === pill })?.location else { return }
        replace(NSRange(location: location, length: 1), with: NSAttributedString(string: pill.writtenLabel, attributes: typingAttributes))
    }

    // MARK: The picker

    /// An `@` typed where a word starts opens the picker; nothing else does (a paste, an undo, what
    /// an input method is still composing).
    public override func insertText(_ string: Any, replacementRange: NSRange) {
        let wasComposing = hasMarkedText()
        super.insertText(string, replacementRange: replacementRange)
        let typed = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
        guard !wasComposing, !hasMarkedText(), typed.hasSuffix("@"), picker == nil, let storage = textStorage else { return }
        let at = selectedRange().location - 1
        guard selectedRange().length == 0, MentionPicker.opens(in: storage.string as NSString, at: at) else { return }
        openPicker(at: at)
    }

    private func openPicker(at location: Int) {
        guard let mentions, style != nil, isEditable else { return }
        let picker = MentionPicker(at: location, mentions: mentions, scope: Scope.self, owner: owner)
        self.picker = picker
        substitutions = Substitutions(of: self)
        Substitutions.off.apply(to: self)
        let window = MentionPickerWindow(picker: picker) { [weak self] candidate in self?.pick(candidate) }
        window.rowsView.setAccessibilityParent(self)
        pickerWindow = window
        picker.onChange = { [weak self] in self?.pickerDidChange() }
        observeAncestors()
        readPicker(isEdit: true)
        if self.picker != nil { pickerDidChange() }
    }

    /// Reads the picker's query again after a change (or a move of the caret), and closes it if
    /// that's what the change says.
    private func readPicker(isEdit: Bool) {
        guard let picker, let storage = textStorage else { return }
        if picker.read(storage.string as NSString, selection: selectedRange(), isEdit: isEdit) != nil { closePicker() }
    }

    /// Closes the picker, if it's open: its `@` stays as typed, and opens nothing until another is typed.
    /// VoiceOver hears its list go.
    public func closePicker() {
        guard picker != nil else { return }
        picker?.onChange = nil
        picker = nil
        substitutions?.apply(to: self)
        substitutions = nil
        helper?.stopObservingAncestors()
        if let pickerWindow {
            MentionAccessibility.post(element: pickerWindow.rowsView, notification: .uiElementDestroyed)
            pickerWindow.parent?.removeChildWindow(pickerWindow)
            pickerWindow.orderOut(nil)
        }
        pickerWindow = nil
        if let pickerHover { mentions?.endHover(pickerHover) }
        pickerHover = nil
    }

    /// The picker's rows or highlight changed: the window shows them, the highlighted shape is
    /// hovered on the canvas, and VoiceOver hears it.
    private func pickerDidChange() {
        guard let picker, let pickerWindow else { return }
        let target = picker.highlightedCandidate?.id
        if target != pickerHover {
            if let pickerHover { mentions?.endHover(pickerHover) }
            pickerHover = target
            if let target { mentions?.hover(target) }
        }
        placePicker()
        pickerWindow.reload()
        announce(picker)
    }

    /// Where the picker's window is, in screen points, while it's open: shown or not, it's placed.
    public var pickerFrame: CGRect? { picker == nil ? nil : pickerWindow?.frame }

    /// Whether the picker's window is on screen: never while the text's window isn't.
    public var isPickerShown: Bool { pickerWindow?.isVisible ?? false }

    /// Puts the picker's window under its `@` (the window keeps its size at any zoom: the `@`'s
    /// rect is in screen points), shown if the text's window is. Closes it if its `@` has left
    /// what's visible of the view.
    private func placePicker() {
        guard let picker, let pickerWindow, let window, let storage = textStorage, picker.location < storage.length else { return }
        let anchor = firstRect(forCharacterRange: NSRange(location: picker.location, length: 1), actualRange: nil)
        let inView = convert(window.convertFromScreen(anchor), from: nil)
        guard visibleRect.intersects(inView.insetBy(dx: -1, dy: -1)) else { return closePicker() }
        pickerWindow.place(below: anchor, on: (window.screen ?? NSScreen.main)?.visibleFrame)
        if window.isVisible, !pickerWindow.isVisible { window.addChildWindow(pickerWindow, ordered: .above) }
    }

    /// Re-anchors the picker whenever a view it's in moves or is scaled (the canvas moves the
    /// editing view on every pan and zoom), and closes it when the window stops being key.
    private func observeAncestors() {
        guard let helper else { return }
        var ancestors: [NSView] = []
        var view: NSView? = self
        while let next = view {
            ancestors.append(next)
            view = next.superview
        }
        helper.observe(ancestors, window: window, moved: { [weak self] in self?.placePicker() },
                       resignedKey: { [weak self] in self?.closePicker() })
    }

    /// Picks a shape: the pill in the place of `@query`, then a space unless what follows is
    /// whitespace or closing punctuation, the caret after; one step of undo, which gives back the
    /// query as typed.
    private func pick(_ candidate: MentionCandidate) {
        guard let picker, let storage = textStorage else { return }
        let caret = selectedRange().location
        guard caret > picker.location, let pill = pillString(candidate.id, storedLabel: candidate.appearance.label) else { return closePicker() }
        closePicker()
        let replacement = NSMutableAttributedString(attributedString: pill)
        let next: unichar? = caret < storage.length ? (storage.string as NSString).character(at: caret) : nil
        if MentionPicker.spaceAfterPick(before: next) { replacement.append(NSAttributedString(string: " ", attributes: typingAttributes)) }
        if replace(NSRange(location: picker.location, length: caret - picker.location), with: replacement) {
            mentions?.didPick(candidate.id)
        }
    }

    /// The keys that move through the picker and pick from it come here before the host's
    /// delegate; with the picker closed, every command is the text view's.
    public override func doCommand(by selector: Selector) {
        guard let picker else { return super.doCommand(by: selector) }
        let (taken, action) = picker.perform(selector)
        guard taken else { return super.doCommand(by: selector) }
        switch action {
        case .pick: if let candidate = picker.highlightedCandidate { pick(candidate) }
        case .close: closePicker()
        default: break
        }
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            closePicker()
            endPointerHover()
        }
        return resigned
    }

    /// Says the highlighted row, or an empty state, to VoiceOver.
    private func announce(_ picker: MentionPicker) {
        guard let pickerWindow else { return }
        let rows = pickerWindow.rowsView
        MentionAccessibility.post(element: rows, notification: .selectedChildrenChanged)
        guard let index = picker.highlighted ?? picker.rows.indices.first else { return }
        MentionAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: MentionPickerRowsView.spoken(picker, row: index),
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    // MARK: Windows and undo

    /// Leaving its window, it takes its steps of undo with it, and only its own (its text's and
    /// its own actions): they'd change a text no one sees (the window's undo manager outlives an
    /// editing view), and write nothing back. A board's window forgets its text's undo as the text
    /// loses the keyboard anyway; any other window keeps what its undo manager holds.
    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            closePicker()
            endPointerHover()
            if let undoManager {
                if let textStorage { undoManager.removeAllActions(withTarget: textStorage) }
                undoManager.removeAllActions(withTarget: self)
            }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        fitPills()
        toolTipsAreStale = true
        if window != nil {
            helper?.observeUndo { [weak self] manager in self?.undoDidChangeText(manager) }
        } else {
            helper?.stopObservingUndo()
        }
    }

    /// An undo or redo in this view's undo manager: under TextKit 2 the text view changes its text
    /// without telling its delegate, so if the text isn't what the host last heard, tell it. The
    /// pills it put back show their targets as they are now (renamed or deleted meanwhile).
    private func undoDidChangeText(_ manager: UndoManager) {
        guard manager === undoManager else { return }
        isChangingText = false
        fitPills()
        refreshPills(of: nil)
        observeTargets()
        readPicker(isEdit: false)
        if mentionText != reported { didChangeText() } else { holdWrittenLabels() }
    }

    // MARK: Copy and paste

    public override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.mentionText, .string] + super.writablePasteboardTypes.filter { $0 != .mentionText && $0 != .string }
    }

    /// The selection as stored mention text, and as plain text ("@Label") under both of the
    /// string's names; other types as the text view writes them.
    public override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        switch type {
        case .mentionText:
            return pboard.setString(selectedMentionText.stored, forType: type)
        case .string, .legacyString:
            return pboard.setString(selectedMentionText.plainText(), forType: type)
        default:
            return super.writeSelection(to: pboard, type: type)
        }
    }

    /// The selected ranges, as mention text, one after another: each pill named as it shows now.
    private var selectedMentionText: ScopedMentionText<Scope> {
        guard let storage = textStorage else { return "" }
        let selected = NSMutableAttributedString()
        for range in selectedRanges.map(\.rangeValue) where range.length > 0 {
            selected.append(storage.attributedSubstring(from: range))
        }
        return MentionTextStyle.mentionText(from: selected)
    }

    public override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [.mentionText] + super.readablePasteboardTypes.filter { $0 != .mentionText }
    }

    /// Stored mention text as it was copied, ids and all; plain text with whole mentions in it
    /// (`@[label](shape:UUID)`, an agent's or a board's) as pills; any other text as the text view
    /// pastes it.
    public override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        let text: ScopedMentionText<Scope>
        switch type {
        case .mentionText:
            guard let stored = pboard.string(forType: type) else { return false }
            text = ScopedMentionText(stored: stored)
        case .string, .legacyString:
            guard style != nil, let plain = pboard.string(forType: type) else { return super.readSelection(from: pboard, type: type) }
            let parsed = ScopedMentionText<Scope>(stored: plain)
            guard !parsed.mentioned.isEmpty else { return super.readSelection(from: pboard, type: type) }
            text = parsed
        default:
            return super.readSelection(from: pboard, type: type)
        }
        return replace(rangeForUserTextChange, with: attributed(text))
    }

    // MARK: Accessibility

    // Every range is the text's own, a pill one character (its value, as the text view has it,
    // holds U+FFFC there), so the value, the count and the selection agree; what VoiceOver reads for
    // a range, or the selection, says each pill as its name and kind.

    /// The range as VoiceOver reads it: each pill its name and kind ("Groceries, Task"), or its name
    /// and why it isn't live ("Groceries, deleted").
    public override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        NSAttributedString(string: spokenText(range, pill: MentionStyle.spoken))
    }

    public override func accessibilityString(for range: NSRange) -> String? { spokenText(range, pill: MentionStyle.spoken) }

    public override func accessibilitySelectedText() -> String? { spokenText(selectedRange(), pill: MentionStyle.spoken) }

    private func spokenText(_ range: NSRange?, pill spoken: (MentionAttachment) -> String) -> String {
        guard let storage = textStorage else { return "" }
        let whole = NSRange(location: 0, length: storage.length)
        let range = range.map { NSIntersectionRange($0, whole) } ?? whole
        var text = ""
        let characters = storage.string as NSString
        storage.enumerateAttribute(.attachment, in: range) { value, run, _ in
            if let pill = value as? MentionAttachment {
                for _ in 0..<run.length { text += spoken(pill) }
            } else {
                text += characters.substring(with: run)
            }
        }
        return text
    }
}

extension MentionStyle {
    static func goTo(_ label: String) -> String { "Go to “\(label)”" }
    static let removeMention = "Remove Mention"

    /// A pill as VoiceOver reads it: "Groceries, Task", or "Groceries, deleted".
    static func spoken(_ pill: MentionAttachment) -> String {
        switch pill.resolution {
        case .live(let appearance): "\(appearance.label), \(appearance.kindName)"
        case .missing: "\(pill.shownLabel), deleted"
        case .unavailable: "\(pill.shownLabel), not available"
        }
    }
}

/// The substitutions that could rewrite `@query` as it's typed: off while the picker is open, and
/// put back as they were once it closes.
@MainActor
private struct Substitutions {
    var spelling: Bool
    var replacement: Bool
    var quotes: Bool
    var dashes: Bool

    static let off = Substitutions(spelling: false, replacement: false, quotes: false, dashes: false)

    init(spelling: Bool, replacement: Bool, quotes: Bool, dashes: Bool) {
        self.spelling = spelling
        self.replacement = replacement
        self.quotes = quotes
        self.dashes = dashes
    }

    init(of view: NSTextView) {
        spelling = view.isAutomaticSpellingCorrectionEnabled
        replacement = view.isAutomaticTextReplacementEnabled
        quotes = view.isAutomaticQuoteSubstitutionEnabled
        dashes = view.isAutomaticDashSubstitutionEnabled
    }

    func apply(to view: NSTextView) {
        view.isAutomaticSpellingCorrectionEnabled = spelling
        view.isAutomaticTextReplacementEnabled = replacement
        view.isAutomaticQuoteSubstitutionEnabled = quotes
        view.isAutomaticDashSubstitutionEnabled = dashes
    }
}

/// The view's delegate, in front of the host's: it answers what only a delegate can for mention
/// text (Writing Tools leave pills alone) and hands everything else to the host, which the text
/// view reports as its delegate.
@MainActor
private final class MentionTextDelegate: NSObject, NSTextViewDelegate {
    nonisolated(unsafe) weak var host: (any NSTextViewDelegate)?

    nonisolated override func responds(to selector: Selector!) -> Bool {
        super.responds(to: selector) || (host as AnyObject?)?.responds(to: selector) == true
    }

    nonisolated override func forwardingTarget(for selector: Selector!) -> Any? {
        (host as AnyObject?)?.responds(to: selector) == true ? host : nil
    }

    /// Writing Tools skip each pill in the range.
    @available(macOS 15.0, *)
    func textView(_ textView: NSTextView, writingToolsIgnoredRangesInEnclosingRange enclosingRange: NSRange) -> [NSValue] {
        guard let storage = textView.textStorage else { return [] }
        var ranges: [NSValue] = []
        let range = NSIntersectionRange(enclosingRange, NSRange(location: 0, length: storage.length))
        storage.enumerateAttribute(.attachment, in: range) { value, run, _ in
            if value is MentionAttachment { ranges.append(NSValue(range: run)) }
        }
        return ranges
    }
}

/// What a mention text view needs of Objective-C, kept off the generic view: the notifications
/// it observes (undo, its ancestors moving, its window resigning key), its menu items' actions,
/// and its tooltips.
@MainActor
final class MentionTextViewHelper: NSObject, NSViewToolTipOwner {
    private var undone: ((UndoManager) -> Void)?
    private var moved: (() -> Void)?
    private var resignedKey: (() -> Void)?
    var toolTip: ((CGPoint) -> String?)?

    func observeUndo(_ changed: @escaping (UndoManager) -> Void) {
        stopObservingUndo()
        undone = changed
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(undoManagerDidChange(_:)), name: .NSUndoManagerDidUndoChange, object: nil)
        center.addObserver(self, selector: #selector(undoManagerDidChange(_:)), name: .NSUndoManagerDidRedoChange, object: nil)
    }

    func stopObservingUndo() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: .NSUndoManagerDidUndoChange, object: nil)
        center.removeObserver(self, name: .NSUndoManagerDidRedoChange, object: nil)
        undone = nil
    }

    @objc private func undoManagerDidChange(_ notification: Notification) {
        guard let manager = notification.object as? UndoManager else { return }
        undone?(manager)
    }

    func observe(_ views: [NSView], window: NSWindow?, moved: @escaping () -> Void, resignedKey: @escaping () -> Void) {
        stopObservingAncestors()
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

    func stopObservingAncestors() {
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSView.frameDidChangeNotification, object: nil)
        center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: nil)
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: nil)
        moved = nil
        resignedKey = nil
    }

    @objc private func viewDidMove(_ notification: Notification) { moved?() }
    @objc private func windowDidResignKey(_ notification: Notification) { resignedKey?() }

    /// A menu item that runs `action`.
    func item(_ title: String, _ action: @escaping () -> Void) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(runAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = MenuAction(action)
        return item
    }

    @objc private func runAction(_ item: NSMenuItem) { (item.representedObject as? MenuAction)?.run() }

    nonisolated func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        MainActor.assumeIsolated { toolTip?(point) ?? "" }
    }
}

/// A menu item's action, held by the item.
@MainActor
private final class MenuAction: NSObject {
    let run: () -> Void
    init(_ run: @escaping () -> Void) { self.run = run }
}

/// What Mentions posts to VoiceOver, posted, and in debug builds counted, so a test can hold the
/// picker to what it says.
@MainActor
public enum MentionAccessibility {
    #if DEBUG
    /// Each notification posted, in order (debug builds).
    public private(set) static var posted: [NSAccessibility.Notification] = []
    #endif

    static func post(element: Any, notification: NSAccessibility.Notification, userInfo: [NSAccessibility.NotificationUserInfoKey: Any]? = nil) {
        #if DEBUG
        posted.append(notification)
        #endif
        if let userInfo {
            NSAccessibility.post(element: element, notification: notification, userInfo: userInfo)
        } else {
            NSAccessibility.post(element: element, notification: notification)
        }
    }
}
