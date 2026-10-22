import AppKit
import SwiftUI
import TextEditing

/// Code in a bordered box (JSON, say), typed exactly as keyed: monospaced, with smart quotes and
/// dashes, text replacement, autocorrect, spelling, automatic completion, inline predictions, math
/// results and Writing Tools off (a curly quote isn't JSON). Lines never wrap (a line's indentation
/// says where it is, and the line an error names is the line on screen): a long one scrolls sideways.
/// The box is as tall as its lines, at least `height` and at most what the panel shows less room
/// for its section's title and a line under it; past that it scrolls. Tab inserts two spaces,
/// Return a new line as indented as the one it ends (one step more after an opening `{` or `[`).
/// It writes on every keystroke, as the panel's other text does; ⌘↩ and the keyboard leaving it
/// call `onCommit` (it's done), which a plugin may use to act on what was written.
/// `isEditable: false`, or the panel's read-only shape, makes it read-only: the text can still be
/// selected and copied. Escape leaves the panel.
///
/// `coloring` says what the text's runs are (`DetailCodeSpan`), each time it changes, and the
/// panel colors them; the language is the plugin's business, the colors the panel's. It's asked
/// for the whole text on every keystroke, so keep it a scan (a tokenizer), not a parse. Read-only
/// text isn't colored: it's dimmed as a whole.
///
/// `completions` says what can be typed at the caret (`DetailCodeCompletions`), and the editor
/// lists it there, in the app's one caret list (`CaretList`, as Mentions' `@` picker): ⌃Space
/// opens it, as AppKit's `complete:` does (⌥⎋, F5), while the text can be written; where nothing's
/// offered, nothing opens. While it's open, ↑ and ↓ (⌃P, ⌃N) move through it, Page Up and Down a
/// page, Return, Enter and Tab pick, and Escape, ⌃Space, ⌥⎋ and F5 close it (the panel stays);
/// ⌘↩ closes it and commits, as ever; every other key is the text's, and after each keystroke
/// and move of the caret the list asks again. It lists what's offered ranked by what's typed
/// (`FuzzyMatcher`), and closes once nothing is, the caret leaves the place it opened for, the
/// text is shown from elsewhere or can't be written, or the keyboard or the window goes. A pick is
/// one step of the text's undo, typed as far as the box is concerned. `onCompleting` hears the
/// list open (true) and close (false): while it's open the person is still choosing, though the
/// text may already say something whole (a pick that opens it again). Without `completions`, ⌥⎋
/// and F5 do nothing: code gets no dictionary words.
public struct DetailCodeEditor: View {
    @Binding var text: String
    let height: CGFloat
    let isEditable: Bool
    let coloring: DetailCodeColoring?
    let completions: DetailCodeCompleting?
    let onCompleting: (@MainActor (Bool) -> Void)?
    let label: String?
    let onCommit: (@MainActor () -> Void)?

    public init(_ text: Binding<String>, height: CGFloat = DetailStyle.codeEditorHeight, isEditable: Bool = true,
                coloring: DetailCodeColoring? = nil, completions: DetailCodeCompleting? = nil,
                onCompleting: (@MainActor (Bool) -> Void)? = nil, label: String? = nil, onCommit: (@MainActor () -> Void)? = nil) {
        _text = text
        self.label = label
        self.height = height
        self.isEditable = isEditable
        self.coloring = coloring
        self.completions = completions
        self.onCompleting = onCompleting
        self.onCommit = onCommit
    }

    public var body: some View {
        let lines = CGFloat(Self.lineCount(text, upTo: DetailStyle.codeEditorMaxLines))
        // A line more than it has, for the caret on a new one and a sideways scroller.
        let fitted = max(height, (lines + 1) * DetailStyle.codeLineHeight + DetailStyle.fieldCorner * 2)
        let coloring = coloring, completions = completions, onCompleting = onCompleting
        // ⌘↩ commits; Return is a new line.
        DetailTextBox($text, height: nil, isEditable: isEditable, commitsOnReturn: false, label: label, onCommit: onCommit,
                      make: PlainTextView.code, prepare: PlainTextView.unwrapLines, update: { view in
                          view.coloring = coloring
                          view.onCompleting = onCompleting
                          view.completing = completions
                      }, baseline: DetailStyle.codeBaseline)
            .containerRelativeFrame(.vertical, alignment: .top) { visible, _ in
                min(fitted, max(height, visible - DetailStyle.codeEditorMargin))
            }
    }

    /// How many lines `text` has, counting no further than `limit`.
    static func lineCount(_ text: String, upTo limit: Int) -> Int {
        var lines = 1
        for byte in text.utf8 where byte == UInt8(ascii: "\n") {
            lines += 1
            if lines >= limit { break }
        }
        return lines
    }
}

/// What a code editor's text is, a run at a time: `DetailCodeEditor`'s `coloring`.
public typealias DetailCodeColoring = @MainActor (_ text: String) -> [DetailCodeSpan]

/// A run of a code editor's text and what it is, which decides its color. Runs left out keep the
/// text's own color (punctuation, say).
public struct DetailCodeSpan: Equatable, Sendable {
    public enum Role: Equatable, Sendable {
        /// A member's name: a JSON object's key.
        case name
        /// A string value.
        case string
        case number
        /// A word the language gives meaning (`true`, `false`, `null`).
        case keyword
        /// What doesn't belong: a stray character, a string left open. Underlined too.
        case invalid
    }

    public var role: Role
    /// Where it is, as `NSString` counts (UTF-16).
    public var range: NSRange

    public init(_ role: Role, _ range: NSRange) {
        self.role = role
        self.range = range
    }
}

extension View {
    /// Marks a text box (`DetailTextArea`, `DetailCodeEditor`, any `DetailTextBox`) that something
    /// other than the person is writing just now: read-only, and so dimmed, while `isUpdating`.
    /// What's writing it says so in words where the person is (a `DetailStatusLine` with
    /// `isBusy`), never over the text.
    public func detailUpdating(_ isUpdating: Bool) -> some View {
        disabled(isUpdating)
    }

    /// The panel's text box: inset, `height` tall (or as tall as it's made, nil), on the text
    /// background, in a hairline border. Its first text baseline is its first line's (`baseline`
    /// down from its top), so a row's label sits on the text's line and not at the box's edge.
    func detailTextBox(height: CGFloat?, baseline: CGFloat) -> some View {
        padding(DetailStyle.fieldCorner)
            .frame(height: height)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: DetailStyle.fieldCorner))
            .overlay(RoundedRectangle(cornerRadius: DetailStyle.fieldCorner).strokeBorder(.separator))
            .alignmentGuide(.firstTextBaseline) { _ in baseline }
    }
}

/// A status line of a section's own, laid out as the panel's footer and tab lines are (its tone's
/// symbol, then its text, which can be selected and copied), with a spinner in place of the symbol
/// while `isBusy` (as wide, so the text doesn't move when one takes the other's place), and buttons
/// under the text for what can be done about it ("Retry").
public struct DetailStatusLine: View {
    let status: DetailStatus
    let isBusy: Bool
    let actions: [DetailStatusAction]
    @Environment(\.detailReclaim) private var reclaim

    public init(_ status: DetailStatus, isBusy: Bool = false, actions: [DetailStatusAction] = []) {
        self.status = status
        self.isBusy = isBusy
        self.actions = actions
    }

    public var body: some View {
        // Only the symbol takes the tone: orange or red text is hard to read. The text can be
        // selected and copied, to hand an issue to someone (or an agent).
        Label {
            // Selected, its text has the keyboard: gone with it (an issue fixed, a failure retried,
            // a line in its place with or without buttons), the keyboard would stay on the window,
            // where no key reaches the canvas, so the panel hands it back.
            let text = Text(status.text).foregroundStyle(status.tone == .neutral ? .secondary : .primary).textSelection(.enabled)
                .accessibilityLabel(status.tone.spoken(status.text))
                .onDisappear { reclaim() }
            if actions.isEmpty {
                text
            } else {
                VStack(alignment: .leading, spacing: DetailStyle.smallSpacing) {
                    text.fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: DetailStyle.pairSpacing) {
                        ForEach(actions.indices, id: \.self) { i in
                            Button(actions[i].title) { actions[i].perform() }
                        }
                    }
                    .buttonStyle(.link)
                }
            }
        } icon: {
            Group {
                if isBusy {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: status.tone.symbol).foregroundStyle(status.tone.color)
                }
            }
            .frame(width: DetailStyle.statusIconWidth)
            .accessibilityHidden(true)
        }
    }
}

extension DetailStatus.Tone {
    /// A status line as assistive apps hear it: the tone, then the text ("Warning: …"); a neutral line is
    /// its text.
    @MainActor func spoken(_ text: String) -> String {
        switch self {
        case .neutral: text
        case .info: "\(DetailStyle.infoName): \(text)"
        case .warning: "\(DetailStyle.warningName): \(text)"
        case .error: "\(DetailStyle.errorName): \(text)"
        }
    }
}

/// A button under a `DetailStatusLine`.
public struct DetailStatusAction {
    public let title: String
    public let perform: @MainActor () -> Void

    public init(_ title: String, perform: @escaping @MainActor () -> Void) {
        self.title = title
        self.perform = perform
    }
}

/// An `EditingTextView` whose text is a value its box binds (`DetailTextBox`): a string, or text a
/// plugin keeps in a form of its own (mentions of shapes, say). Adopt it on a subclass (a view of
/// `EditingTextView` itself adopting it would fix every subclass's `Value`).
@MainActor
public protocol DetailTextContent: EditingTextView {
    associatedtype Value: Equatable
    /// What the text is now: what its box writes to the binding after every change.
    var value: Value { get }
    /// Shows `value` in place of the text, as something other than typing does: the model writing
    /// it, an undo of the board. It changes only the text's storage (the caret stays where it was,
    /// as far as the new text reaches), and never calls `didChangeText`, so nothing is written
    /// back: its box calls it while the board may be applying a step, when nothing may commit.
    /// The box drops what typing registered with its undo after it.
    func show(_ value: Value)
}

/// A box of text in the panel, as `DetailTextArea` is, over a text view a plugin makes
/// (`make`, a `DetailTextContent`: its own class, its own font and substitutions), so text that
/// isn't a string (mentions of shapes, say) edits in the panel as a string does. The box lays it
/// out (`height` tall, bordered, scrolling), writes the binding on every change (a panel field's run
/// of writes is one undo step), and shows what the binding says only when it changed from outside
/// (the model writing it, an undo), so a keystroke typed before the panel draws again is never
/// lost; typing's undo is the box's own, dropped when the text is shown from outside. With
/// `onCommit`, Return, ⌘↩ and the keyboard leaving say the text is done, and ⇧↩ is a new line;
/// without, Return is a new line. Escape leaves the panel; `placeholder` shows while it's empty.
/// The panel's read-only shape, `detailUpdating`, or any `disabled` around it makes it read-only
/// and dimmed (`EditingTextView.showEnabled(_:)`), and still there to read: its text is selected and
/// copied, and its view answers clicks (a pill in it followed).
public struct DetailTextBox<Content: DetailTextContent>: View {
    @Binding var value: Content.Value
    let height: CGFloat?
    let placeholder: String?
    let isEditable: Bool
    let commitsOnReturn: Bool
    let label: String?
    let onCommit: (@MainActor () -> Void)?
    let make: @MainActor () -> Content
    let prepare: (@MainActor (Content, NSScrollView) -> Void)?
    let update: (@MainActor (Content) -> Void)?
    /// Where the first line's baseline is, down from the box's top: the panel's text font's, unless a box is in another.
    let baseline: CGFloat
    @Environment(\.isEnabled) private var isEnabled

    public init(_ value: Binding<Content.Value>, height: CGFloat = DetailStyle.textAreaHeight, placeholder: String? = nil,
                label: String? = nil, onCommit: (@MainActor () -> Void)? = nil, make: @escaping @MainActor () -> Content) {
        self.init(value, height: height, placeholder: placeholder, commitsOnReturn: onCommit != nil, label: label, onCommit: onCommit, make: make)
    }

    /// `height` nil: as tall as it's made. `prepare` sets up the view and its scroll view once
    /// made (the box's own settings made first), and `update` sets it up again on every update of
    /// the box (before it's shown enabled or not).
    init(_ value: Binding<Content.Value>, height: CGFloat?, placeholder: String? = nil, isEditable: Bool = true, commitsOnReturn: Bool,
         label: String? = nil, onCommit: (@MainActor () -> Void)?, make: @escaping @MainActor () -> Content,
         prepare: (@MainActor (Content, NSScrollView) -> Void)? = nil, update: (@MainActor (Content) -> Void)? = nil,
         baseline: CGFloat = DetailStyle.textBaseline) {
        _value = value
        self.height = height
        self.placeholder = placeholder
        self.isEditable = isEditable
        self.commitsOnReturn = commitsOnReturn
        self.label = label
        self.onCommit = onCommit
        self.make = make
        self.prepare = prepare
        self.update = update
        self.baseline = baseline
    }

    public var body: some View {
        // Disabled, SwiftUI would take every click over the view, so none reached the text: the
        // view is told (not editable, dimmed), and SwiftUI sees it enabled.
        DetailTextHost(value: $value, placeholder: placeholder, isEditable: isEditable, isEnabled: isEnabled,
                       commitsOnReturn: commitsOnReturn, label: label, onCommit: onCommit, make: make, prepare: prepare, update: update)
            .environment(\.isEnabled, true)
            .detailTextBox(height: height, baseline: baseline)
    }
}

/// A box's text view, in a scroll view built around it by hand: `scrollableTextView()` would make
/// the receiver's class with `init(frame:)`, and a plugin's view may need more to be made.
struct DetailTextHost<Content: DetailTextContent>: NSViewRepresentable {
    @Binding var value: Content.Value
    let placeholder: String?
    let isEditable: Bool
    /// The box's, where it is: false, it's read-only and dimmed. (The host's own environment says
    /// it's enabled, so it answers clicks.)
    let isEnabled: Bool
    let commitsOnReturn: Bool
    let label: String?
    let onCommit: (@MainActor () -> Void)?
    let make: @MainActor () -> Content
    let prepare: (@MainActor (Content, NSScrollView) -> Void)?
    let update: (@MainActor (Content) -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(value: $value) }

    func makeNSView(context: Context) -> NSScrollView {
        let view = make()
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        // As `scrollableTextView()` sets it up: as wide as the box, as tall as its text or the box.
        view.minSize = .zero
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width, .height]
        view.textContainer?.widthTracksTextView = true
        view.drawsBackground = false
        view.allowsUndo = true
        view.textContainerInset = .zero
        scroll.documentView = view
        prepare?(view, scroll)
        let coordinator = context.coordinator
        if view.value != value { view.show(value) }
        coordinator.shown = value
        view.delegate = coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? Content else { return }
        let coordinator = context.coordinator
        coordinator.value = $value
        view.isEditable = isEditable && isEnabled
        view.isSelectable = true
        view.tabBehavior = .movesKeyView
        update?(view)
        view.showEnabled(isEnabled)
        view.commitsOnReturn = commitsOnReturn
        view.onCommit = onCommit
        let exit = context.environment.detailExit
        view.onExit = exit
        // ⌘↩ finishes: a box with something to commit commits (the view does), and one without
        // leaves the panel, keeping what is typed (it is written as it is typed).
        if onCommit == nil, view.onKeyDown == nil || coordinator.hooksKeys {
            coordinator.hooksKeys = true
            view.onKeyDown = { event in
                guard event.keyCode == 36 || event.keyCode == 76,
                      event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else { return false }
                exit()
                return true
            }
        } else if coordinator.hooksKeys {
            coordinator.hooksKeys = false
            view.onKeyDown = nil
        }
        view.placeholder = placeholder
        let spoken = label ?? placeholder
        if view.accessibilityLabel() != spoken { view.setAccessibilityLabel(spoken) }
        // Changed from outside: show it. (Typing changes the text view first, then the binding.)
        if value != coordinator.shown {
            coordinator.shown = value
            if view.value != value {
                view.show(value)
                coordinator.undo.removeAllActions()
            }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var value: Binding<Content.Value>
        /// What the binding said last, as far as this box knows: set by typing, and by the
        /// binding changing from outside.
        var shown: Content.Value
        /// The box's own, so text shown from outside can drop what typing registered.
        let undo = UndoManager()
        /// Whether the box's `onKeyDown` is its own (⌘↩ leaves), rather than the content's.
        var hooksKeys = false

        init(value: Binding<Content.Value>) {
            self.value = value
            shown = value.wrappedValue
        }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? Content else { return }
            let typed = view.value
            shown = typed
            value.wrappedValue = typed
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }
    }
}

// MARK: Plain text

/// A box's text as a string: a `DetailTextArea`'s words, or a `DetailCodeEditor`'s code. In
/// TextKit 1, as the panel's text has always been laid out: a code editor is as tall as its lines
/// in TextKit 1's metrics (`DetailStyle.codeLineHeight`), and as wide as its longest.
final class PlainTextView: EditingTextView, DetailTextContent {
    /// `DetailCodeEditor`'s: Return keeps the line's indentation, ⌥Tab indents two spaces and ⌥⇧Tab outdents.
    private(set) var isCode = false
    var coloring: DetailCodeColoring?
    /// `DetailCodeEditor`'s: what can be typed at the caret. Taken away, the list closes.
    var completing: DetailCodeCompleting? {
        didSet { if completing == nil { closeCompletions() } }
    }
    /// `DetailCodeEditor`'s: told as the list opens (true) and closes (false).
    var onCompleting: (@MainActor (Bool) -> Void)?
    /// The text's own color, and whether `coloring`'s runs are colored over it.
    private var baseColor: NSColor?
    private var colorsSpans = false
    /// The completion list, while it's open. `onCompleting` hears it open and close, but a pick's
    /// closing it and opening it again only as it ends up.
    private var completions: OpenCompletions? {
        didSet { if (completions == nil) != (oldValue == nil), !isPicking { onCompleting?(completions != nil) } }
    }
    /// Between a change to the text and its end, while the list is open: the caret moving then is
    /// the change's, after which the list asks again once.
    private var isChangingText = false
    /// While a pick puts its item in.
    private var isPicking = false

    /// A code editor with completions, while it can be written: ⌥⎋ opens its list.
    override var offersCompletions: Bool { isCode && completing != nil && isEditable }

    /// The completion list, while it's open: its keys, and when it closes, are every caret list's.
    override var caretListWindow: CaretListWindow? { completions?.window }

    /// Words: the system's substitutions as the person has them, and their spelling checked as the
    /// app's is (`Spelling.app`).
    static func prose() -> PlainTextView {
        let view = PlainTextView(usingTextLayoutManager: false)
        view.plain(font: DetailStyle.textFont)
        view.spelling = .app
        return view
    }

    /// Code, typed exactly as keyed: every substitution, automatic completion, prediction and Writing
    /// Tools off.
    static func code() -> PlainTextView {
        let view = PlainTextView(usingTextLayoutManager: false)
        view.plain(font: DetailStyle.codeFont)
        view.isCode = true
        view.typedAsKeyed()
        return view
    }

    /// Words typed exactly as keyed, in the panel's own font: what `code()` turns off turned off, and no
    /// spelling (`Spelling.app` would set autocorrection from the app's setting, and a value typed in a
    /// field must never be corrected). Not code: Return and Tab are a prose box's.
    static func keyed() -> PlainTextView {
        let view = PlainTextView(usingTextLayoutManager: false)
        view.plain(font: DetailStyle.textFont)
        view.typedAsKeyed()
        return view
    }

    private func typedAsKeyed() {
        inlinePredictionType = .no
        if #available(macOS 15.0, *) {
            mathExpressionCompletionType = .no
            writingToolsBehavior = .none
        }
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        smartInsertDeleteEnabled = false
    }

    /// No wrapping: the text is as wide as its longest line, and scrolls sideways.
    static func unwrapLines(_ view: PlainTextView, in scroll: NSScrollView) {
        view.isHorizontallyResizable = true
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        scroll.hasHorizontalScroller = true
    }

    /// Plain text in one font, as `scrollableTextView()` makes it: no rich text, pictures, ruler or
    /// font panel.
    private func plain(font: NSFont) {
        isRichText = false
        importsGraphics = false
        usesRuler = false
        usesFontPanel = false
        self.font = font
    }

    var value: String { string }

    /// The caret stays where it was, as far as the new text reaches; the list closes.
    func show(_ value: String) {
        closeCompletions()
        let caret = selectedRange().location
        string = value
        setSelectedRange(NSRange(location: min(caret, (value as NSString).length), length: 0))
        recolor()
        needsDisplay = true
    }

    override func showEnabled(_ isEnabled: Bool) {
        color(isEnabled ? .labelColor : .secondaryLabelColor, spans: isEnabled && coloring != nil)
    }

    /// Colored again before its box hears of it; the list asks again after.
    override func didChangeText() {
        isChangingText = false
        recolor()
        super.didChangeText()
        refreshCompletions()
    }

    // MARK: Color

    /// Sets the text's color, and colors `coloring`'s runs over it while `spans`; the text is
    /// colored again only when either changes (and when the text does: `recolor`).
    func color(_ base: NSColor, spans: Bool) {
        guard base != baseColor || spans != colorsSpans else { return }
        baseColor = base
        colorsSpans = spans
        recolor()
    }

    /// Colors the whole text: its own color, then each run's. Not while text is being composed
    /// (an input method's marked text has attributes of its own); once it's put in, it is.
    func recolor() {
        guard let baseColor, let storage = textStorage, !hasMarkedText() else { return }
        textColor = baseColor
        let whole = NSRange(location: 0, length: storage.length)
        guard coloring != nil else { return }
        storage.beginEditing()
        storage.removeAttribute(.underlineStyle, range: whole)
        if colorsSpans, let coloring {
            for span in coloring(string) where NSMaxRange(span.range) <= whole.length {
                storage.addAttributes(DetailStyle.codeAttributes(span.role), range: span.range)
            }
        }
        storage.endEditing()
    }

    // MARK: Code

    /// Code keeps the line's indentation, one step more after an opening bracket; between a
    /// pair of brackets, the closing one goes on a line of its own.
    override func insertNewline(_ sender: Any?) {
        guard isCode, isEditable else { return super.insertNewline(sender) }
        let text = string as NSString, selection = selectedRange()
        let line = text.lineRange(for: NSRange(location: selection.location, length: 0))
        let head = text.substring(with: NSRange(location: line.location, length: selection.location - line.location))
        let indent = String(head.prefix { $0 == " " || $0 == "\t" })
        let before = head.last { !$0.isWhitespace }
        let rest = text.substring(with: NSRange(location: NSMaxRange(selection), length: min(80, text.length - NSMaxRange(selection))))
        let after = rest.first { $0 != " " && $0 != "\t" }
        guard let opener = before, opener == "{" || opener == "[" else {
            return insertText("\n" + indent, replacementRange: selection)
        }
        let inner = indent + Self.indentStep
        if (opener == "{" && after == "}") || (opener == "[" && after == "]") {
            insertText("\n" + inner + "\n" + indent, replacementRange: selection)
            setSelectedRange(NSRange(location: selection.location + 1 + (inner as NSString).length, length: 0))
        } else {
            insertText("\n" + inner, replacementRange: selection)
        }
    }

    /// ⌥Tab in code indents one step (Tab moves on, as in every box of the panel).
    override func insertTabIgnoringFieldEditor(_ sender: Any?) {
        guard isCode, isEditable else { return super.insertTabIgnoringFieldEditor(sender) }
        insertText(Self.indentStep, replacementRange: selectedRange())
    }

    /// ⌥⇧Tab in code takes one step off the start of each line the selection touches: two spaces, or a tab.
    private func outdent() {
        guard isEditable else { return }
        let text = string as NSString
        let lines = text.lineRange(for: selectedRange())
        let original = text.substring(with: lines)
        var changed = false
        let outdented = original.split(separator: "\n", omittingEmptySubsequences: false).map { line -> Substring in
            var rest = line
            if rest.first == "\t" { rest = rest.dropFirst(); changed = true; return rest }
            var removed = 0
            while removed < Self.indentStep.count, rest.first == " " { rest = rest.dropFirst(); removed += 1; changed = true }
            return rest
        }.joined(separator: "\n")
        guard changed, shouldChangeText(in: lines, replacementString: outdented) else { return }
        textStorage?.replaceCharacters(in: lines, with: outdented)
        setSelectedRange(NSRange(location: lines.location, length: (outdented as NSString).length))
        didChangeText()
    }

    private static let indentStep = "  "

    // MARK: Completions

    /// ⌃Space opens a code editor's list, or closes it, while it offers completions. Anything else
    /// (and ⌃Space where there's nothing to offer) is the text's.
    override func keyDown(with event: NSEvent) {
        if isCode, Self.isControlSpace(event), !hasMarkedText(), completions != nil || offersCompletions {
            return toggleCompletions()
        }
        if isCode, completions == nil, !hasMarkedText(), event.keyCode == 48,
           event.modifierFlags.intersection([.command, .shift, .option, .control]) == [.shift, .option] {
            return outdent()
        }
        super.keyDown(with: event)
    }

    /// The space bar with exactly Control.
    private static func isControlSpace(_ event: NSEvent) -> Bool {
        event.keyCode == 49 && event.modifierFlags.intersection([.command, .shift, .option, .control]) == .control
    }

    /// AppKit's command to complete what's typed, which ⌥⎋ and F5 send: in code, the list, opened
    /// or closed. A code editor without completions answers it with nothing: code gets no
    /// dictionary words (AppKit's would write each one highlighted into the text).
    override func complete(_ sender: Any?) {
        guard isCode else { return super.complete(sender) }
        toggleCompletions()
    }

    private func toggleCompletions() {
        if completions != nil { closeCompletions() } else { openCompletions() }
    }

    /// Opens the list at the caret, listing what's offered there as what's typed ranks it (every
    /// caret list's window, under what's typed, following it as the panel scrolls and closing the
    /// list once it's out of view or the window stops being key). Nothing opens where nothing's
    /// offered, and nothing beeps.
    private func openCompletions() {
        guard completions == nil, offersCompletions, window != nil, !hasMarkedText(), let found = completionsAtCaret() else { return }
        let list = CaretList(metrics: DetailStyle.completionsMetrics)
        let listWindow = CaretListWindow(list, accessibilityLabel: DetailStyle.completionsAccessibilityLabel, over: self,
                                         anchor: { [weak self] in self?.completionsAnchor },
                                         pick: { [weak self] row in self?.pickCompletion(row: row) },
                                         close: { [weak self] in self?.closeCompletions() })
        completions = OpenCompletions(list: list, window: listWindow, offered: found.offered, listed: [])
        isChangingText = false
        list.onChange = { [weak listWindow] in listWindow?.listDidChange() }
        listCompletions(found)
    }

    /// What's offered at the caret, and what of it the list shows; nil where there's nothing to
    /// show: no completions, a selection rather than a caret, a range that doesn't hold the caret,
    /// or nothing what's typed matches.
    private func completionsAtCaret() -> (offered: DetailCodeCompletions, listed: [DetailCodeCompletions.Listed])? {
        let caret = selectedRange(), length = (string as NSString).length
        guard let completing, caret.length == 0, let offered = completing(string, caret.location),
              offered.range.location <= caret.location, caret.location <= NSMaxRange(offered.range), NSMaxRange(offered.range) <= length else {
            return nil
        }
        let listed = offered.listed()
        return listed.isEmpty ? nil : (offered, listed)
    }

    /// Shows what's offered in the open list: each item's label in the code's font, what's typed
    /// matched in its semibold, its detail after it (VoiceOver says both).
    private func listCompletions(_ found: (offered: DetailCodeCompletions, listed: [DetailCodeCompletions.Listed])) {
        guard var open = completions else { return }
        open.offered = found.offered
        open.listed = found.listed.map(\.item)
        completions = open
        open.list.setRows(found.listed.map { listed in
            .item(CaretListItem(listed.item.label, matched: listed.matched, font: DetailStyle.codeFont,
                                detail: listed.item.detail.isEmpty ? nil : listed.item.detail))
        })
    }

    /// Asks again after a change to the text or a move of the caret, while the list is open: it
    /// lists what's offered now for what it opened for (what's typed there grows and shrinks, but
    /// the range a pick replaces starts where it did), or closes where there's nothing to list or
    /// the caret has left it for another place. Not while an input method composes: once what it
    /// composed is in, the change asks.
    private func refreshCompletions() {
        guard let open = completions, !hasMarkedText() else { return }
        guard isEditable, let found = completionsAtCaret(), found.offered.range.location == open.offered.range.location else {
            return closeCompletions()
        }
        listCompletions(found)
    }

    /// Where the list goes: under what's typed of what a pick replaces (a key's first letter, past
    /// its quote), as far as the text reaches.
    private var completionsAnchor: NSRange? {
        guard let offered = completions?.offered else { return nil }
        let caret = selectedRange().location
        let start = max(offered.range.location, caret - (offered.query as NSString).length)
        guard start <= (string as NSString).length else { return nil }
        return NSRange(location: start, length: 0)
    }

    /// Picks a row's item: its insert in place of the range the offer replaces, the selection where
    /// it says, one step of the text's undo, heard as typing is (the box writes it). An item that
    /// reopens asks again where it left the caret.
    private func pickCompletion(row: Int) {
        guard let open = completions, open.listed.indices.contains(row) else { return }
        let item = open.listed[row], range = open.offered.range
        isPicking = true
        defer {
            isPicking = false
            if completions == nil { onCompleting?(false) }
        }
        closeCompletions()
        guard isEditable, NSMaxRange(range) <= (string as NSString).length else { return }
        breakUndoCoalescing()
        insertText(item.insert, replacementRange: range)
        let length = (string as NSString).length
        let start = min(range.location + item.selection.location, length)
        setSelectedRange(NSRange(location: start, length: min(item.selection.length, length - start)))
        scrollRangeToVisible(selectedRange())
        breakUndoCoalescing()
        if item.reopens { openCompletions() }
    }

    /// Closes the list, if it's open: VoiceOver hears it go.
    func closeCompletions() {
        guard let open = completions else { return }
        completions = nil
        open.list.onChange = nil
        open.window.dismiss()
    }

    override func shouldChangeText(inRanges affectedRanges: [NSValue], replacementStrings: [String]?) -> Bool {
        let should = super.shouldChangeText(inRanges: affectedRanges, replacementStrings: replacementStrings)
        if should, completions != nil { isChangingText = true }
        return should
    }

    override func setSelectedRanges(_ ranges: [NSValue], affinity: NSSelectionAffinity, stillSelecting: Bool) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        if !isChangingText { refreshCompletions() }
    }
}

/// A code editor's open completion list: the list, the window it shows in, what the provider
/// offered last, and the items the list shows of it, row for row.
@MainActor
private struct OpenCompletions {
    let list: CaretList
    let window: CaretListWindow
    var offered: DetailCodeCompletions
    var listed: [DetailCodeCompletion]
}

// MARK: The header's field

/// `DetailHeaderField`'s field: a borderless `NSTextField` set up as SwiftUI's plain one is (one
/// line, clipped, scrolling sideways while it's typed in), whose field editor is its own
/// `EditingTextView` (`HeaderField.editor`), which checks spelling as the app does: SwiftUI's fields
/// can't be told to. It writes the binding on every change, and shows what the binding says only
/// when it changed from outside (the model writing it, an undo), so a keystroke typed before the
/// panel draws again is never lost, dropping typing's undo then. Return calls `onSubmit`; disabled
/// around it, it's dimmed.
struct HeaderTitleField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onSubmit: onSubmit) }

    func makeNSView(context: Context) -> NSTextField {
        let field = HeaderField(string: text)
        field.font = DetailStyle.headerTitleFont
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.usesSingleLineMode = true
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderString = placeholder
        field.setAccessibilityLabel(DetailStyle.nameLabel)
        field.cell?.setAccessibilityLabel(DetailStyle.nameLabel)
        field.delegate = context.coordinator
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        let coordinator = context.coordinator
        coordinator.text = $text
        coordinator.onSubmit = onSubmit
        if field.placeholderString != placeholder { field.placeholderString = placeholder }
        if field.isEnabled != context.environment.isEnabled { field.isEnabled = context.environment.isEnabled }
        // Changed from outside: show it. (Typing changes the field first, then the binding.)
        guard text != coordinator.shown else { return }
        coordinator.shown = text
        guard let editor = field.currentEditor() as? NSTextView else { return field.stringValue = text }
        // Being typed in: the caret stays where it was, as far as the new text reaches, and typing's
        // undo goes, as a box's does: its ranges are the old text's, which an undo would run past.
        let caret = editor.selectedRange().location
        editor.string = text
        editor.setSelectedRange(NSRange(location: min(caret, (text as NSString).length), length: 0))
        editor.undoManager?.removeAllActions()
    }

    /// As wide as it's offered, a line of its font tall.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView field: NSTextField, context: Context) -> CGSize? {
        let fitting = field.cell?.cellSize ?? field.intrinsicContentSize
        return CGSize(width: proposal.width ?? fitting.width, height: fitting.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var text: Binding<String>
        var onSubmit: @MainActor () -> Void
        /// What the binding said last, as far as the field knows: set by typing, and by the binding
        /// changing from outside.
        var shown: String

        init(text: Binding<String>, onSubmit: @escaping @MainActor () -> Void) {
            self.text = text
            self.onSubmit = onSubmit
            shown = text.wrappedValue
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            shown = field.stringValue
            text.wrappedValue = shown
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            onSubmit()
            return true
        }
    }
}

/// The header's text field, with a field editor of its own, which its cell (`HeaderFieldCell`) hands
/// AppKit: an `EditingTextView` that checks spelling as the app does, set up otherwise as SwiftUI's
/// fields' editors are (plain text, undo, no smart quotes or dashes).
final class HeaderField: NSTextField {
    override class var cellClass: AnyClass? {
        get { HeaderFieldCell.self }
        set {}
    }

    lazy var editor: EditingTextView = {
        let editor = EditingTextView(frame: .zero)
        editor.isFieldEditor = true
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.spelling = .app
        return editor
    }()
}

/// The header field's cell, which edits in the field's own editor. It keeps nothing itself: AppKit
/// may copy a cell bit for bit, which a reference it held wouldn't survive.
final class HeaderFieldCell: NSTextFieldCell {
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        (controlView as? HeaderField)?.editor ?? super.fieldEditor(for: controlView)
    }
}
