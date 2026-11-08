import AppKit
import Canvas
import Connections
import FuzzyMatching
import Palette
import TextEditing

// The one line a row is typed in: an `EditingTextView` on TextKit 2 (so `placeSelection(at:)` and `caretFrame` work), moved
// to the row with the caret, as Types' `RowField` is. Nothing rewrites what's typed (no autocorrect, quotes, dashes,
// replacement or spelling marks), `@` and `/` are letters (no mentions, no slash commands), and it never holds a line
// break: a pasted block is the session's to make rows of. What it holds is a draft, read by the grammar after every
// change into spans (looks as attributes, pills as highlights) and a gutter mark; what fits at the caret is offered in
// the one caret list, whose Return does only an action (Tab picks a word), and its highlighted offer is lit on the board.
// Its keys are the session's: it hands each to `onKey` and holds none, so ⌥↑, ⇧↩ and ⌘↩ reach it with the list open.

/// What a key does in a line: the keys of a row being typed in.
public enum LineKey: Equatable, Sendable {
    /// Return: the row's done, a line below it; on an empty line, editing ends.
    case commit
    /// ↑ ↓: the stop above, below.
    case up, down
    /// Tab, ⇧Tab: the next, the previous stop.
    case next, previous
    /// Escape, ⌘↑, ⌘.: out of the line, the draft kept (editing ends; in a row's card, the row has the keyboard back).
    case end
    /// ⌘↩: editing ends, the draft kept.
    case finish
    /// ⌘↓: the row's card.
    case card
    /// ⌥↑ ⌥↓: the row one place up, down.
    case moveUp, moveDown
    /// ⇧↩: editing ends, a shape of the kind beside.
    case addBeside
    /// ⌫ on an empty line: the row goes.
    case deleteEmpty
    /// ⌘L, Connect's key: the line written, the picker opens on its row.
    case connect
    /// ⇧↑ ⇧↓: whole rows selected, the first the caret's row, then the run drawn up or down.
    case extendUp, extendDown
    /// ⌫ ⌦ with whole rows selected: the rows go.
    case deleteRows
}

/// What the keys do with rows on the pasteboard.
public enum LineRowsAction: Sendable {
    /// ⌘C with whole rows selected.
    case copy
    /// ⌘X with whole rows selected.
    case cut
    /// ⌘V with rows on the pasteboard.
    case paste
}

@MainActor
public final class LineField: EditingTextView, UndoesBoardWhenEmpty {
    /// The attribute of a run that stands for a shape: a `LineField.Reference`.
    public static let referenceKey = NSAttributedString.Key("LineRows.reference")

    /// What a run stands for, as an attribute's value.
    public final class Reference: NSObject {
        public let target: PartAddress
        public init(_ target: PartAddress) { self.target = target }
        public override func isEqual(_ object: Any?) -> Bool { (object as? Reference)?.target == target }
        public override var hash: Int { target.hashValue }
    }

    /// A key of the line's (true: taken).
    public var onKey: ((LineKey) -> Bool)?
    /// The text changed by typing, pasting, a pick or an undo (not by `show`).
    public var onChange: (() -> Void)?
    /// A block of several lines pasted (true: taken, as rows).
    public var onPasteLines: ((String) -> Bool)?
    /// Rows cut, copied or pasted as wholes (true: taken): ⌘X ⌘C with whole rows selected, ⌘V with rows on the pasteboard.
    public var onRows: ((LineRowsAction) -> Bool)?
    /// Whole rows are selected (⇧↑ ⇧↓): the line is hidden and takes no typing; ⌫ ⌦, ⌘X and ⌘C are the rows'.
    public var isBanded = false {
        didSet { isEditable = !isBanded }
    }
    /// The keyboard left it.
    public var onBlur: (() -> Void)?
    /// The keyboard came to it (back from a card the line opened: the picker).
    public var onFocus: (() -> Void)?
    /// Whether the line holds words not yet written as a row (asked by Undo and Redo, which are the line's then).
    public var draft: () -> Bool = { false }
    public var holdsDraft: Bool { draft() }
    /// What fits at the caret now (nil: nothing), asked after every change and move of the caret.
    public var offering: (() -> LineOffers?)?
    /// The offer highlighted in the list (nil: none, or no list), as it changes: what's lit on the board.
    public var onLight: ((PartAddress?) -> Void)?
    /// What's typed that becomes something else as it's typed.
    public var substitutions: [LineSubstitution] = []
    /// What VoiceOver calls the list.
    public var listName = LineFieldStyle.listName

    /// How its characters look before a span says otherwise.
    public var plain: [NSAttributedString.Key: Any] = [:] {
        didSet { typingAttributes = plain }
    }

    private var isShowing = false
    /// While a line break is inserted as a space instead.
    private var isOneLining = false
    private var isSubstituting = false
    /// Between a change to the text and its end: the caret moving then is the change's.
    private var isChangingText = false
    /// While a pick puts its offer in.
    private var isPicking = false
    /// A key let go of nothing but a held ⌫ that removed its row: its repeats remove nothing more.
    public var swallowsDeleteRepeats = false
    private var open: OpenOffers?
    /// The range start of the offers Escape closed: none open there again until the offers move.
    private var closedAt: Int?

    public init() {
        // `init(frame:)` calls `init(frame:textContainer:)` on the view, which sets it up.
        super.init(frame: .zero)
    }

    public override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        isRichText = false
        allowsUndo = true
        drawsBackground = false
        focusRingType = .none
        isHorizontallyResizable = false
        isVerticallyResizable = false
        textContainer?.widthTracksTextView = false
        textContainer?.heightTracksTextView = false
        textContainer?.containerSize = CGSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.lineFragmentPadding = 0
        textContainer?.maximumNumberOfLines = 1
        textContainerInset = .zero
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
        CaretListSubstitutions.off.apply(to: self)
        commitsOnLeaving = false
        tabBehavior = .host
        setAccessibilityRole(.textField)
        onKeyDown = { [weak self] event in self?.lineKey(event) ?? false }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Its keys are the line's whatever is listed: the list's own (↑ ↓, Tab, Escape) it takes in `doCommand`.
    public override var holdsKeys: Bool { false }

    public override var caretListWindow: CaretListWindow? { open?.window }

    /// The list open at the caret, in a window or not (a field in no window lists all the same, for a test to read).
    public var offerList: CaretList? { open?.list }

    /// Nothing typed takes another look than the plain one, nor a reference.
    public override var typingAttributes: [NSAttributedString.Key: Any] {
        get { plain }
        set {}
    }

    // MARK: The text

    /// Shows `line`, its references carried, the caret at `caret` (UTF-16; nil: the end); its undo forgotten.
    public func show(_ line: LineText, caret: Int? = nil) {
        isShowing = true
        defer { isShowing = false }
        closeOffers()
        closedAt = nil
        let text = NSMutableAttributedString(string: line.string, attributes: plain)
        for reference in line.references where NSMaxRange(reference.range) <= text.length {
            text.addAttribute(Self.referenceKey, value: Reference(reference.target), range: reference.range)
        }
        textStorage?.setAttributedString(text)
        let length = text.length
        setSelectedRange(NSRange(location: min(max(0, caret ?? length), length), length: 0))
        if let manager = undoManager {
            if let storage = textStorage { manager.removeAllActions(withTarget: storage) }
            manager.removeAllActions(withTarget: self)
        }
    }

    /// What it holds: the text and the runs that still stand for what they were printed or picked for.
    public var line: LineText {
        guard let storage = textStorage else { return LineText(string) }
        var references: [LineReference] = []
        storage.enumerateAttribute(Self.referenceKey, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            if let value = value as? Reference { references.append(LineReference(range: range, target: value.target)) }
        }
        return LineText(storage.string, references: references)
    }

    /// Draws the line as `reading` says it reads: each span's look, on the plain look, and its pills under it.
    public func show<Row>(_ reading: LineReading<Row>, style: LineStyle) {
        guard let storage = textStorage else { return }
        let whole = NSRange(location: 0, length: storage.length)
        let references = line.references
        storage.beginEditing()
        storage.setAttributes(plain, range: whole)
        // The references survive the looks.
        for reference in references { storage.addAttribute(Self.referenceKey, value: Reference(reference.target), range: reference.range) }
        var highlights: [TextHighlight] = []
        for span in reading.spans where NSMaxRange(span.range) <= storage.length && span.range.length > 0 {
            storage.addAttributes(style.attributes(for: span.look), range: span.range)
            if let highlight = style.highlight(of: span) { highlights.append(highlight) }
        }
        storage.endEditing()
        self.highlights = highlights
    }

    /// Typing in a run that stands for a shape, or onto its ends, makes it words again: it's read by name. Undoing the typing
    /// makes it the shape's again (the run's attribute isn't the text's own undo). A line break, typed or dropped in, is a
    /// space, inserted as one so the text's undo holds what went in.
    public override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        if !isShowing, !isOneLining, let typed = replacementString, typed.contains(where: \.isNewline) {
            isOneLining = true
            defer { isOneLining = false }
            insertText(Self.oneLine(typed), replacementRange: affectedCharRange)
            return false
        }
        let dropped = isShowing ? [] : references(touchedBy: affectedCharRange, typed: replacementString ?? "")
        // Registered before the text's own undo, so it's undone after it: the characters are back, then the run is the shape's.
        if let manager = undoManager, allowsUndo, !manager.isUndoing, !manager.isRedoing {
            for run in dropped { Self.registerReference(run.target, over: run.range, present: true, on: self, with: manager) }
        }
        guard super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        guard !isShowing, let storage = textStorage, storage.length > 0 else { return true }
        for run in dropped { storage.removeAttribute(Self.referenceKey, range: run.range) }
        isChangingText = true
        return true
    }

    /// `text` with each line break a space.
    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: " ").map { $0.isNewline ? " " : String($0) }.joined()
    }

    /// The runs that stand for a shape that a change of `range` to `typed` makes words: typed in, over or onto.
    private func references(touchedBy range: NSRange, typed: String) -> [(range: NSRange, target: PartAddress)] {
        guard let storage = textStorage, storage.length > 0 else { return [] }
        var dropped: [(range: NSRange, target: PartAddress)] = []
        storage.enumerateAttribute(Self.referenceKey, in: NSRange(location: 0, length: storage.length)) { value, run, _ in
            guard let value = value as? Reference else { return }
            let at = range.location, end = NSMaxRange(range)
            let inside = at > run.location && at < NSMaxRange(run)
            let over = range.length > 0 && NSIntersectionRange(range, run).length > 0
            let after = at == NSMaxRange(run) && range.length == 0 && !(typed.first?.isWhitespace ?? true)
            let before = end == run.location && range.length == 0 && !(typed.last?.isWhitespace ?? true)
            if inside || over || after || before { dropped.append((run, value.target)) }
        }
        return dropped
    }

    /// An undo that sets the run at `range` to stand for `target` (`present`) or to stand for nothing, and registers the
    /// other way for the redo: the run's attribute goes with the typing and comes back with its undo.
    private static func registerReference(_ target: PartAddress, over range: NSRange, present: Bool, on field: LineField, with manager: UndoManager) {
        manager.registerUndo(withTarget: field) { field in
            MainActor.assumeIsolated {
                guard let storage = field.textStorage, NSMaxRange(range) <= storage.length else { return }
                if present {
                    storage.addAttribute(Self.referenceKey, value: Reference(target), range: range)
                } else {
                    storage.removeAttribute(Self.referenceKey, range: range)
                }
                if let manager = field.undoManager { Self.registerReference(target, over: range, present: !present, on: field, with: manager) }
                field.onChange?()
            }
        }
    }

    public override func didChangeText() {
        // Never a line break: a block is pasted as rows, and one typed in is a space (`shouldChangeText`); what's left is
        // text set by other means.
        if let storage = textStorage, storage.string.contains(where: \.isNewline) {
            let text = Self.oneLine(storage.string)
            let selection = selectedRange()
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
            setSelectedRange(NSRange(location: min(selection.location, storage.length), length: 0))
        }
        substitute()
        super.didChangeText()
        guard !isShowing, !isSubstituting else { return }
        isChangingText = false
        onChange?()
        if !isPicking { refreshOffers() }
    }

    /// What's just been typed that becomes something else: the characters before the caret, put in its place, part of
    /// the typing's undo.
    private func substitute() {
        guard !isShowing, !isSubstituting, !substitutions.isEmpty else { return }
        let caret = selectedRange()
        guard caret.length == 0 else { return }
        let text = string as NSString
        for substitution in substitutions {
            let typed = (substitution.typed as NSString).length
            guard caret.location >= typed, text.substring(with: NSRange(location: caret.location - typed, length: typed)) == substitution.typed else { continue }
            isSubstituting = true
            insertText(substitution.becomes, replacementRange: NSRange(location: caret.location - typed, length: typed))
            isSubstituting = false
            return
        }
    }

    // MARK: Keys

    /// ⌘L, Connect's key, comes as a key equivalent, which the field answers before the menu bar does (the menu's Connect would end
    /// editing and act on the shape): the row's, while the field has the keyboard.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, ConnectKey.isPressed(by: event) {
            if event.isARepeat { return true }
            return key(.connect, closing: true)
        }
        // ⌘X ⌘C with whole rows selected, ⌘V with rows on the pasteboard: the rows', as Edit › Cut, Copy and Paste are.
        if window?.firstResponder === self, event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command,
           let action = Self.rowsActions[event.charactersIgnoringModifiers ?? ""] {
            if event.isARepeat { return true }
            if (action == .paste || isBanded), onRows?(action) == true { return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    private static let rowsActions: [String: LineRowsAction] = ["x": .cut, "c": .copy, "v": .paste]

    public override func copy(_ sender: Any?) {
        if isBanded, onRows?(.copy) == true { return }
        super.copy(sender)
    }

    public override func cut(_ sender: Any?) {
        if isBanded, onRows?(.cut) == true { return }
        super.cut(sender)
    }

    /// Edit › Cut and Copy are the rows' while whole rows are selected, though the line takes no typing then.
    public override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if isBanded, item.action == #selector(NSText.cut(_:)) || item.action == #selector(NSText.copy(_:)) { return true }
        return super.validateUserInterfaceItem(item)
    }

    /// The keys a text view's bindings never send as one command: ⌥↑ ⌥↓, ⇧↩, ⌘↩, ⌘↑, ⌘↓ (the row's card), a held Return once,
    /// and a held ⌫ stopping at the row it removed.
    private func lineKey(_ event: NSEvent) -> Bool {
        if !(event.isARepeat && event.keyCode == 51) { swallowsDeleteRepeats = false }
        if event.isARepeat, event.keyCode == 51, swallowsDeleteRepeats { return true }
        guard let reading = KeyMeaning.Reading(event: event) else { return false }
        let modifiers = reading.modifiers
        switch (reading.meaning, modifiers) {
        case (.up, [.shift]): return key(.extendUp, closing: true)
        case (.down, [.shift]): return key(.extendDown, closing: true)
        case (.up, [.option]): return key(.moveUp, closing: true)
        case (.down, [.option]): return key(.moveDown, closing: true)
        case (.up, [.command]): return key(.end, closing: true)
        case (.down, [.command]): return key(.card, closing: true) || true
        case (.finish, _): return key(.finish, closing: true)
        case (.activate, [.shift]):
            if event.isARepeat { return true }
            return key(.addBeside, closing: true)
        case (.activate, []):
            // A held Return is one press: the line it opened stays empty.
            return event.isARepeat
        default: return false
        }
    }

    @discardableResult
    private func key(_ key: LineKey, closing: Bool) -> Bool {
        if closing { closeOffers() }
        return onKey?(key) ?? false
    }

    /// The list's keys first (↑ ↓ and the page keys move it, Tab picks, Return does an action and otherwise goes on to the
    /// line, ⇧Tab and Escape close it; it isn't open over a word typed whole); then the line's: Return, ↑ ↓, Tab ⇧Tab, Escape, and ⌫ on an empty line. Never a
    /// line break (⌥↩ and ⌃↩ do nothing).
    public override func doCommand(by selector: Selector) {
        if let list = open?.list {
            let (taken, action) = list.perform(selector)
            if taken {
                switch action {
                case .pick: list.highlighted.map(pick(row:))
                case .close:
                    closedAt = open?.offers.range.location
                    closeOffers()
                case .closeAndPass:
                    closeOffers()
                    route(selector)
                default: break
                }
                return
            }
            // Return on a word: the list goes and the line takes the key.
            if KeyMeaning(command: selector) == .activate { closeOffers() }
        }
        route(selector)
    }

    private func route(_ selector: Selector) {
        let reading = KeyMeaning.Reading(command: selector)
        switch (reading?.meaning, reading?.modifiers ?? []) {
        case (.activate, []): if key(.commit, closing: true) { return }
        case (.activate, _): return
        case (.up, _): if key(.up, closing: true) { return }
        case (.down, _): if key(.down, closing: true) { return }
        case (.next, _): if key(.next, closing: true) { return }
        case (.previous, _): if key(.previous, closing: true) { return }
        case (.back, _): if key(.end, closing: true) { return }
        case (.delete, _) where isBanded: if key(.deleteRows, closing: true) { return }
        case (.delete, _) where selector == #selector(NSResponder.deleteBackward(_:)) && string.isEmpty:
            if key(.deleteEmpty, closing: true) { return }
        default: break
        }
        super.doCommand(by: selector)
    }

    /// ⌘., which the window sends up the chain: the list closes first, then editing ends.
    public override func cancelOperation(_ sender: Any?) {
        if open != nil {
            closedAt = open?.offers.range.location
            closeOffers()
            return
        }
        key(.end, closing: false)
    }

    /// Several lines pasted are the session's, a row a line; one is text.
    public override func paste(_ sender: Any?) {
        if onRows?(.paste) == true { return }
        if let text = NSPasteboard.general.string(forType: .string), text.contains(where: \.isNewline), onPasteLines?(text) == true { return }
        super.paste(sender)
    }

    /// The text of a paste, as a test or a host hands it: several lines go to the session as rows; one is typed.
    public func paste(text: String) {
        if text.contains(where: \.isNewline), onPasteLines?(text) == true { return }
        insertText(text, replacementRange: selectedRange())
    }

    // MARK: The keyboard

    public override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    public override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            closeOffers()
            onBlur?()
        }
        return resigned
    }

    public override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        // A move of the caret asks again while the list is open (closing it where nothing's offered), and lets one Escape
        // or a pick closed open at the next change; one a change of the text makes, the change asks.
        guard !isShowing, !isSubstituting, !isChangingText, !isPicking, !stillSelecting else { return }
        closedAt = nil
        if open != nil { refreshOffers() }
    }

    // MARK: Offers

    /// The offers at the caret, listed as what's typed ranks them: the list opens where something's offered (not where
    /// Escape closed it, until the offers move), follows what's typed, and closes where nothing is or the offers move.
    public func refreshOffers() {
        guard isEditable, !hasMarkedText() else { return closeOffers() }
        let caret = selectedRange(), length = (string as NSString).length
        guard caret.length == 0, let offers = offering?(),
              offers.range.location <= caret.location, caret.location <= NSMaxRange(offers.range), NSMaxRange(offers.range) <= length else {
            closedAt = nil
            return closeOffers()
        }
        if let closedAt, closedAt == offers.range.location { return closeOffers() }
        closedAt = nil
        let listed = offers.completions.listed(isBlank: { FuzzyMatcher.Query($0).isEmpty }) { query, labels in
            FuzzyMatcher.matches(query, in: labels).map { $0.map { (score: $0.score, matched: $0.matched) } }
        }
        // Nothing to list, or the word typed whole: what's typed is what it would pick, so the arrows go on to the rows
        // (T4: `uuid` typed over as `int`, then ↓, is the next row).
        guard !listed.isEmpty, !listed.contains(where: { $0.item.label == offers.query }) else { return closeOffers() }
        if let current = open, current.offers.range.location != offers.range.location { closeOffers() }
        if open == nil {
            let list = CaretList(metrics: LineFieldStyle.listMetrics)
            list.returnPicks = .actionsOnly
            // Shown only from a window; a field in none lists all the same, for what reads it.
            let window = self.window == nil ? nil : CaretListWindow(list, accessibilityLabel: listName, over: self,
                                                                     anchor: { [weak self] in self?.listAnchor },
                                                                     pick: { [weak self] row in self?.pick(row: row) },
                                                                     close: { [weak self] in self?.closeOffers() })
            list.onChange = { [weak self, weak window] in
                window?.listDidChange()
                self?.lightHighlighted()
            }
            open = OpenOffers(list: list, window: window, offers: offers, listed: [])
        }
        guard var current = open else { return }
        current.offers = offers
        current.listed = listed
        open = current
        current.list.setRows(listed.map { listed in
            .item(CaretListItem(listed.item.label, matched: listed.matched, font: LineFieldStyle.listFont,
                                detail: listed.item.detail.isEmpty ? nil : listed.item.detail, chip: listed.item.chip, isAction: listed.item.isAction))
        })
    }

    /// The offers listed now, in the list's order (for tests and VoiceOver's sake): their labels.
    public var listedOffers: [String] { open?.listed.map(\.item.label) ?? [] }
    /// The lines about them (a column's type, and the board a table on another board is on), in the same order.
    public var listedDetails: [String] { open?.listed.map(\.item.detail) ?? [] }
    /// The offer highlighted, if a list is open.
    public var highlightedOffer: String? {
        guard let open, let row = open.list.highlighted, open.listed.indices.contains(row) else { return nil }
        return open.listed[row].item.label
    }

    private var listAnchor: NSRange? {
        guard let offers = open?.offers else { return nil }
        let caret = selectedRange().location
        let start = max(offers.range.location, caret - (offers.query as NSString).length)
        return start <= (string as NSString).length ? NSRange(location: start, length: 0) : nil
    }

    /// The highlighted offer's light, to the board.
    private func lightHighlighted() {
        guard let open, let row = open.list.highlighted, open.listed.indices.contains(row) else { return onLight?(nil) ?? () }
        let label = open.listed[row].item
        onLight?(open.offers.items.first { $0.completion == label }?.light)
    }

    /// Puts a row's offer in place of what it replaces, the caret where it says, one step of the text's undo; an action's
    /// is the grammar's to do (it reads the line it leaves).
    private func pick(row: Int) {
        guard let current = open, current.listed.indices.contains(row) else { return }
        let item = current.listed[row].item, range = current.offers.range
        let light = current.offers.items.first { $0.completion == item }?.light
        closeOffers()
        guard isEditable, NSMaxRange(range) <= (string as NSString).length else { return }
        isPicking = true
        defer { isPicking = false }
        // Picked, the list stays closed there until the caret moves or the offers do.
        closedAt = range.location
        breakUndoCoalescing()
        insertText(item.insert, replacementRange: range)
        // A pick of a shape's name stands for that shape.
        if let light, let storage = textStorage {
            let inserted = NSRange(location: range.location, length: (item.insert as NSString).length)
            let word = (item.insert as NSString).range(of: item.label)
            if word.location != NSNotFound, NSMaxRange(inserted) <= storage.length {
                storage.addAttribute(Self.referenceKey, value: Reference(light), range: NSRange(location: inserted.location + word.location, length: word.length))
                onChange?()
            }
        }
        let length = (string as NSString).length
        let start = min(range.location + item.selection.location, length)
        setSelectedRange(NSRange(location: start, length: min(item.selection.length, length - start)))
        breakUndoCoalescing()
        if item.reopens {
            closedAt = nil
            isPicking = false
            refreshOffers()
        }
    }

    /// Closes the list, if it's open, and puts the light out.
    public func closeOffers() {
        guard let current = open else { return }
        open = nil
        current.list.onChange = nil
        current.window?.dismiss()
        onLight?(nil)
    }
}

/// The list open at a line's caret: the list, its window, what was offered last and what the list shows of it.
@MainActor
private struct OpenOffers {
    let list: CaretList
    let window: CaretListWindow?
    var offers: LineOffers
    var listed: [CaretCompletions.Listed]
}

/// The line's list, view points: as every caret list looks, a row a word.
@MainActor
public enum LineFieldStyle {
    static let listMetrics = CaretListMetrics(width: 260, rowHeight: 22, rowsShown: 8, offset: 3)
    static let listFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    static let listName = "Suggestions"
    /// The focused row's band: its corner radius.
    static let bandRadius: CGFloat = 3
    /// Room after the text in its field, so the caret at the end isn't cut.
    static let textSlack: CGFloat = 4
    /// How far short of the clip's edge the caret is kept.
    static let caretMargin: CGFloat = 1
    /// What VoiceOver hears as whole rows are selected: "3 columns selected".
    static func selected(_ counted: String) -> String { "\(counted) selected" }
    /// Whole rows selected while a shape is edited (⇧↑ ⇧↓): the accent, light, behind them.
    static let rowsBand = NSColor(name: nil) { NSColor.controlAccentColor.withAlphaComponent($0.isDark ? 0.28 : 0.18) }
}
