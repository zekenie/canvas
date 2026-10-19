import AppKit

/// The text view under every editable text in the app (a note's on the canvas, an arrow's label, the detail panel's boxes): an `NSTextView` with what a host
/// needs and `TextEditor` doesn't give, which a plugin subclasses for text of its own (the panel's
/// `DetailTextContent`s). What it adds does nothing until it's set, so a subclass with none of it
/// set is a plain text view:
///
/// - `onCommit` says the text is done: ⌘↩, the keyboard leaving it, and its leaving its window with
///   the keyboard (the panel showing another shape) call it, a turn later for the last. Nil, none
///   of them is taken: ⌘↩ goes on as any other key does. A view that isn't editable (read-only,
///   though its text can still be clicked, selected and copied) never calls it: nothing was written;
///   but for ⌘↩ where it `commitsWhileReadOnly`, whose commit only says the person is done (a
///   type note's words, read-only while the model writes them, end editing on ⌘↩).
/// - `commitsOnReturn`, with `onCommit`: Return calls it too, and ⇧↩ is a new line.
/// - `commitsOnLeaving`, true unless set: whether the keyboard leaving calls `onCommit` too. Text
///   whose host ends it itself (a note's editor on the canvas) sets it false, so only ⌘↩ says it's
///   done. `onLeave` hears the keyboard leave, whatever for, after that: for a host that decides
///   what leaving means.
/// - `onExit`: Escape calls it (the panel's, which gives the keyboard back to the canvas) in place
///   of what a text view does with Escape. (In the panel, the panel hears Escape before the view
///   does, and leaves itself. ⌘. never comes to the view as a key: the window sends
///   `cancelOperation:` up the responder chain, which the view leaves to the panel's root.)
/// - `placeholder` is drawn, dimmed, where the text starts while there's none.
/// - `highlights` are ranges of the text drawn on a rounded background under it, as a mention's pill
///   is (`TextHighlight`): how an owner marks text that means something to it, with nothing for a
///   host to forward. Made read-only, the view lets go of them.
/// - `spelling` checks its words as the app does (`Spelling.app`), for text that's words (a note's,
///   a title): its toggles for spelling, grammar and correction (Edit › Spelling and Grammar's, its
///   context menu's) change the app's, for every such text at once, and the words it's told to
///   ignore are ignored in every such text made after. Nil, it checks as AppKit has a text view
///   check, for text that isn't words (code, a query, a name typed to pick a shape).
///
/// A subclass may show a list at its caret (`caretListWindow`: Mentions' `@` picker, a code
/// editor's completions), the app's one caret list; when it opens, what it lists and what a pick
/// puts in are the subclass's, and the rest is this class's, for every such list alike. While one
/// is open the view holds keys (`holdsKeys`): the list's commands (`CaretList.perform`: ↑ ↓ ⌃P ⌃N,
/// Page Up and Down, Return, Enter and Tab with an item highlighted, Escape, ⌥⎋ and F5) are the
/// list's, before the delegate's turn, and Return and Escape are never `onCommit`'s or `onExit`'s;
/// ⌘↩, where it commits, still says the text's done, the list closed first. A host that takes
/// Escape before the view does (the panel's root) lets it through to a view that holds keys, and
/// ⌘. closes the list rather than leaving the panel. The list closes as the keyboard leaves the
/// view, as the view leaves its window, and as it's made read-only (and as its window stops being
/// key, or what it's under scrolls out of view: the window's rules). A view that `offersCompletions`
/// (a code editor's list) has ⌥⎋ for its own too, list or not: AppKit's `complete:`.
@MainActor
open class EditingTextView: NSTextView {
    /// The text is done (a box's `onCommit`).
    public var onCommit: (@MainActor () -> Void)?
    /// Return calls `onCommit`, and ⇧↩ is a new line; only with `onCommit`.
    public var commitsOnReturn = false
    /// The keyboard leaving, and the view leaving its window with it, call `onCommit`, as ⌘↩ does.
    /// False for text whose host ends it when the keyboard leaves (a note's editor on the canvas).
    public var commitsOnLeaving = true
    /// ⌘↩ calls `onCommit` while the text can't be written too: for text whose commit only says the
    /// person is done with it (a type note's words end editing, read-only or not). Return
    /// and the keyboard leaving still never commit read-only text.
    public var commitsWhileReadOnly = false
    /// The keyboard left it, whatever for (after `onCommit`, if it commits on leaving).
    public var onLeave: (@MainActor () -> Void)?
    /// Escape, when set: the panel's hand-back to the canvas.
    public var onExit: (@MainActor () -> Void)?
    /// A key the host answers before the text does, true if it took it (a note's ⇧↩, which goes on to
    /// a new note): asked first of every key down, but never while a list at the caret holds keys or
    /// text is being composed.
    public var onKeyDown: (@MainActor (NSEvent) -> Bool)?
    /// Drawn where the text starts while there's none, in the text's font, dimmed.
    public var placeholder: String? {
        didSet { if placeholder != oldValue { needsDisplay = true } }
    }
    /// Ranges of the text drawn on a rounded background under it. Set by the owner that marks them,
    /// and taken away when the view is made read-only.
    public var highlights: [TextHighlight] = [] {
        didSet { if highlights != oldValue { needsDisplay = true } }
    }
    /// How its words are checked, as they change (`Spelling.app`, for words). Nil, as AppKit has it.
    public var spelling: Spelling? {
        didSet {
            guard spelling !== oldValue else { return }
            oldValue?.unfollow(self)
            spelling?.follow(self)
        }
    }

    /// Whether Return, ⌘↩ and Escape are the view's own just now: while a list is open at its caret
    /// (though ⌘↩, where it commits, closes the list and commits), unless a subclass says otherwise.
    open var holdsKeys: Bool { caretListWindow != nil }

    /// Whether it completes what's typed just now (`complete(_:)`, which ⌥⎋ and F5 send), so
    /// Escape with ⌥ is its own: the panel lets it through. False unless a subclass says.
    open var offersCompletions: Bool { false }

    /// The list open at its caret, if one is (Mentions' `@` picker, a code editor's completions),
    /// which the subclass that opened it keeps: where it's placed (its `frame`, placed even while
    /// the text's window isn't shown) and what it lists. Nil unless a subclass says.
    open var caretListWindow: CaretListWindow? { nil }

    /// Made read-only (a locked shape's, something else writing the text), it closes the list at
    /// its caret and lets go of its highlights: text that can't be written acts on nothing.
    open override var isEditable: Bool {
        didSet {
            guard !isEditable else { return }
            caretListWindow?.closeList()
            highlights = []
        }
    }

    /// Shows the text as its box is: enabled, or dimmed (read-only, or something else writing it).
    /// Its box asks on every update. By default the text's color, the label's or the secondary
    /// label's, set only when it changes; a view that colors its text itself says how.
    open func showEnabled(_ isEnabled: Bool) {
        let color: NSColor = isEnabled ? .labelColor : .secondaryLabelColor
        if textColor != color { textColor = color }
    }

    // MARK: Keys

    open override func keyDown(with event: NSEvent) {
        if let onKeyDown, !holdsKeys, !hasMarkedText(), onKeyDown(event) { return }
        // ⌘↩ says the text's done, list or not: a list at the caret closes first.
        if commandCommit != nil, Self.isCommandReturn(event), !hasMarkedText() { caretListWindow?.closeList() }
        if !holdsKeys, Self.isReturn(event), !hasMarkedText() {
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if modifiers == .command, let onCommit = commandCommit {
                onCommit()
                return
            }
            if let onCommit = commit, commitsOnReturn, modifiers.isEmpty {
                onCommit()
                return
            }
            if commit != nil, commitsOnReturn, modifiers == .shift {
                insertNewline(nil)
                return
            }
        }
        super.keyDown(with: event)
    }

    /// ⌘↩ may come as a key equivalent (before the menus) rather than a key down.
    open override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if commandCommit != nil, window?.firstResponder === self, Self.isCommandReturn(event) { caretListWindow?.closeList() }
        if let onCommit = commandCommit, !holdsKeys, window?.firstResponder === self, Self.isCommandReturn(event) {
            onCommit()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    private static func isReturn(_ event: NSEvent) -> Bool { event.keyCode == 36 || event.keyCode == 76 }

    /// ⌘↩ (or ⌘Enter): Return with exactly Command.
    fileprivate static func isCommandReturn(_ event: NSEvent) -> Bool {
        isReturn(event) && event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command
    }

    /// `onCommit`, while the text can be written: a read-only view's text is never done, since
    /// nothing was written (a locked shape's, whose clicks still land so it can be copied from).
    private var commit: (@MainActor () -> Void)? { isEditable ? onCommit : nil }
    /// What ⌘↩ calls: `commit`, or `onCommit` whatever the text is, where it `commitsWhileReadOnly`.
    private var commandCommit: (@MainActor () -> Void)? { commitsWhileReadOnly ? onCommit : commit }

    /// While a list is open at the caret, the commands that move through it and pick from it (and
    /// close it) are its own; Return and Tab with nothing to pick, and every other command, are the
    /// text's. Escape leaves the panel. Both are taken as the command comes, before the delegate's
    /// turn: a view with no list and no `onExit` answers every command exactly as a text view does.
    open override func doCommand(by selector: Selector) {
        if let listWindow = caretListWindow {
            let (taken, action) = listWindow.list.perform(selector)
            if taken {
                switch action {
                case .pick: listWindow.pickHighlighted()
                case .close: listWindow.closeList()
                default: break
                }
                return
            }
        }
        if selector == #selector(cancelOperation(_:)), let onExit, !holdsKeys {
            onExit()
            return
        }
        super.doCommand(by: selector)
    }

    /// ⌘., which the window sends up the responder chain as this command with no key, closes the
    /// list at the caret, as Escape does. The view answers it only while a list is open
    /// (`responds(to:)`): otherwise the command goes on up as though the view weren't there (in the
    /// panel, the panel leaves; on the canvas, it's the canvas's Cancel, which leaves editing as it
    /// is), and Escape is answered exactly as a text view answers it.
    open override func cancelOperation(_ sender: Any?) {
        caretListWindow?.closeList()
    }

    open override func responds(to selector: Selector!) -> Bool {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return super.responds(to: selector) }
        // The responder chain asks on the main thread; anything asking elsewhere hears what a text
        // view with no list says.
        return Thread.isMainThread && MainActor.assumeIsolated { caretListWindow != nil }
    }

    // MARK: Committing when the keyboard leaves

    /// The keyboard leaving commits, closes the list at the caret, and tells `onLeave`. The words it
    /// was told to ignore go to `spelling`, for every text that follows it.
    open override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            spelling?.keepIgnoredWords(of: self)
            if commitsOnLeaving { commit?() }
            caretListWindow?.closeList()
            onLeave?()
        }
        return resigned
    }

    /// Taken out of the window while it had the keyboard (the panel showing another shape):
    /// that's leaving it too. After the update that took it out. Leaving its window, for none or
    /// another, closes the list at the caret, which follows the window it was opened in; for none,
    /// the words it was told to ignore go to `spelling`.
    open override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow !== window { caretListWindow?.closeList() }
        if newWindow == nil { spelling?.keepIgnoredWords(of: self) }
        if newWindow == nil, commitsOnLeaving, window?.firstResponder === self, let onCommit = commit {
            Task { @MainActor in onCommit() }
        }
        super.viewWillMove(toWindow: newWindow)
    }

    // MARK: Spelling

    /// Check Spelling While Typing, from the menu bar or the view's menu: with `spelling`, the app's,
    /// for every text that follows it. Each toggle turns over what the view shows (its item's mark).
    open override func toggleContinuousSpellChecking(_ sender: Any?) {
        guard let spelling else { return super.toggleContinuousSpellChecking(sender) }
        spelling.checksWhileTyping = !isContinuousSpellCheckingEnabled
    }

    /// Check Grammar With Spelling: with `spelling`, the app's.
    open override func toggleGrammarChecking(_ sender: Any?) {
        guard let spelling else { return super.toggleGrammarChecking(sender) }
        spelling.checksGrammar = !isGrammarCheckingEnabled
    }

    /// Correct Spelling Automatically: with `spelling`, the app's.
    open override func toggleAutomaticSpellingCorrection(_ sender: Any?) {
        guard let spelling else { return super.toggleAutomaticSpellingCorrection(sender) }
        spelling.correctsAutomatically = !isAutomaticSpellingCorrectionEnabled
    }

    // MARK: The caret, laid out by TextKit 2

    /// Puts the selection where a press at a point in the view's coordinates would: the caret
    /// between the characters nearest it, or, with `selectingWord` (a double-click's), the word
    /// there. What editing on the canvas begun from a press does with its point
    /// (`EditContext.startPoint`). Nothing on TextKit 1.
    open func placeSelection(at point: CGPoint, selectingWord: Bool = false) {
        guard let layout = textLayoutManager, let content = layout.textContentManager else { return }
        let inContainer = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        layout.ensureLayout(for: layout.documentRange)
        let navigation = layout.textSelectionNavigation
        let bounds = CGRect(origin: .zero, size: textContainer?.size ?? bounds.size)
        guard var selection = navigation.textSelections(interactingAt: inContainer, inContainerAt: layout.documentRange.location,
                                                        anchors: [], modifiers: [], selecting: false, bounds: bounds).first else { return }
        if selectingWord { selection = navigation.textSelection(for: .word, enclosing: selection) }
        guard let range = selection.textRanges.first else { return }
        let start = content.offset(from: content.documentRange.location, to: range.location)
        setSelectedRange(NSRange(location: start, length: content.offset(from: range.location, to: range.endLocation)))
    }

    /// Where the caret is, in the view's coordinates: the line fragment it's on, as TextKit 2 lays
    /// it out (nil on TextKit 1). TextKit 2 lays out only the text in view, so the text is laid out
    /// first (text edited on a shape is short): the caret may have gone where nothing was (⌘↓ in a
    /// long note). What an editor on the canvas keeps in view as its shape grows past the window's
    /// edge (`EditContext.keepInView`).
    public var caretFrame: CGRect? {
        guard let layout = textLayoutManager, let content = layout.textContentManager,
              let location = content.location(content.documentRange.location, offsetBy: NSMaxRange(selectedRange())) else { return nil }
        layout.ensureLayout(for: content.documentRange)
        var frame: CGRect?
        layout.enumerateTextSegments(in: NSTextRange(location: location), type: .selection, options: [.rangeNotRequired]) { _, segment, _, _ in
            frame = segment
            return false
        }
        let origin = textContainerOrigin
        return frame.map { CGRect(x: $0.minX + origin.x, y: $0.minY + origin.y, width: max($0.width, 1), height: $0.height) }
    }

    // MARK: The placeholder

    open override func didChangeText() {
        super.didChangeText()
        if placeholder != nil { needsDisplay = true }
    }

    /// The highlights and the placeholder are drawn with the background, under where the text is
    /// (would be): overriding `draw(_:)` would opt every subclass out of TextKit 2 (AppKit makes a
    /// text view whose class draws for itself with TextKit 1), which a subclass may need (a mention
    /// text view's pills).
    open override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        drawHighlights(in: rect)
        guard let placeholder, string.isEmpty else { return }
        let origin = textContainerOrigin, padding = textContainer?.lineFragmentPadding ?? 0
        NSAttributedString(string: placeholder, attributes: [.font: font ?? TextEditingStyle.placeholderFont, .foregroundColor: NSColor.placeholderTextColor])
            .draw(with: NSRect(x: origin.x + padding, y: origin.y, width: bounds.width - origin.x - padding * 2, height: bounds.height - origin.y),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}
