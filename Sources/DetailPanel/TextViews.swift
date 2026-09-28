import AppKit
import SwiftUI

/// Code in a bordered box (JSON, say), typed exactly as keyed: monospaced, with smart quotes and
/// dashes, text replacement, autocorrect, spelling, completion, inline predictions, math results
/// and Writing Tools off (a curly quote isn't JSON). Lines never wrap (a line's indentation says
/// where it is, and the line an error names is the line on screen): a long one scrolls sideways.
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
public struct DetailCodeEditor: View {
    @Binding var text: String
    let height: CGFloat
    let isEditable: Bool
    let coloring: DetailCodeColoring?
    let onCommit: (@MainActor () -> Void)?

    public init(_ text: Binding<String>, height: CGFloat = DetailStyle.codeEditorHeight, isEditable: Bool = true,
                coloring: DetailCodeColoring? = nil, onCommit: (@MainActor () -> Void)? = nil) {
        _text = text
        self.height = height
        self.isEditable = isEditable
        self.coloring = coloring
        self.onCommit = onCommit
    }

    public var body: some View {
        let lines = CGFloat(Self.lineCount(text, upTo: DetailStyle.codeEditorMaxLines))
        // A line more than it has, for the caret on a new one and a sideways scroller.
        let fitted = max(height, (lines + 1) * DetailStyle.codeLineHeight + DetailStyle.fieldCorner * 2)
        PanelTextView(text: $text, kind: .code, placeholder: nil, isEditable: isEditable, coloring: coloring, onCommit: onCommit)
            .detailTextBox(height: nil)
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
    /// Marks a text box (`DetailTextArea`, `DetailCodeEditor`) that something other than the person
    /// is writing just now: read-only, and so dimmed, while `isUpdating`. What's writing it says
    /// so in words where the person is (a `DetailStatusLine` with `isBusy`), never over the text.
    public func detailUpdating(_ isUpdating: Bool) -> some View {
        disabled(isUpdating)
    }

    /// The panel's text box: inset, `height` tall (or as tall as it's made, nil), on the text
    /// background, in a hairline border.
    func detailTextBox(height: CGFloat?) -> some View {
        padding(DetailStyle.fieldCorner)
            .frame(height: height)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: DetailStyle.fieldCorner))
            .overlay(RoundedRectangle(cornerRadius: DetailStyle.fieldCorner).strokeBorder(.separator))
    }
}

/// A status line of a section's own, laid out as the panel's footer and tab lines are (its tone's
/// symbol, then its text), with a spinner in place of the symbol while `isBusy` (as wide, so the
/// text doesn't move when one takes the other's place), and buttons under the text for what can be
/// done about it ("Retry").
public struct DetailStatusLine: View {
    let status: DetailStatus
    let isBusy: Bool
    let actions: [DetailStatusAction]

    public init(_ status: DetailStatus, isBusy: Bool = false, actions: [DetailStatusAction] = []) {
        self.status = status
        self.isBusy = isBusy
        self.actions = actions
    }

    public var body: some View {
        // Only the symbol takes the tone: orange or red text is hard to read.
        Label {
            let text = Text(status.text).foregroundStyle(status.tone == .neutral ? .secondary : .primary)
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

// MARK: The text view under both

/// An `NSTextView` in a scroll view, for the panel's text boxes that need what `TextEditor` doesn't
/// give: keys that commit, code typed exactly as keyed, a placeholder drawn where the text starts.
/// It writes the binding on every keystroke; what the binding says changes the text only when it
/// changed from outside (the model writing it, another view), so a keystroke typed before the panel
/// draws again is never lost.
struct PanelTextView: NSViewRepresentable {
    enum Kind {
        /// Words: Return commits, ⇧↩ is a new line; the system's substitutions stay as the user
        /// has them.
        case prose
        /// `DetailCodeEditor`'s.
        case code
    }

    @Binding var text: String
    let kind: Kind
    let placeholder: String?
    let isEditable: Bool
    var coloring: DetailCodeColoring? = nil
    let onCommit: (@MainActor () -> Void)?

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        guard let view = scroll.documentView as? TextView else { preconditionFailure("scrollableTextView makes the receiver's class") }
        view.drawsBackground = false
        view.isRichText = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.textContainerInset = .zero
        view.isCode = kind == .code
        view.font = kind == .code ? DetailStyle.codeFont : DetailStyle.bodyFont
        if kind == .code {
            // No wrapping: the text is as wide as its longest line, and scrolls sideways.
            view.isHorizontallyResizable = true
            view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            view.textContainer?.widthTracksTextView = false
            view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            scroll.hasHorizontalScroller = true
            view.inlinePredictionType = .no
            if #available(macOS 15.0, *) {
                view.mathExpressionCompletionType = .no
                view.writingToolsBehavior = .none
            }
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.isAutomaticSpellingCorrectionEnabled = false
            view.isContinuousSpellCheckingEnabled = false
            view.isGrammarCheckingEnabled = false
            view.isAutomaticLinkDetectionEnabled = false
            view.isAutomaticDataDetectionEnabled = false
            view.isAutomaticTextCompletionEnabled = false
            view.smartInsertDeleteEnabled = false
        }
        view.string = text
        context.coordinator.shown = text
        view.delegate = context.coordinator
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? TextView else { return }
        let coordinator = context.coordinator
        coordinator.text = $text
        let isEnabled = context.environment.isEnabled
        view.isEditable = isEditable && isEnabled
        view.isSelectable = true
        view.coloring = coloring
        view.color(isEnabled ? .labelColor : .secondaryLabelColor, spans: isEnabled && coloring != nil)
        view.returnCommits = kind == .prose && onCommit != nil
        view.onCommit = onCommit
        view.onExit = context.environment.detailExit
        view.placeholder = placeholder.map {
            NSAttributedString(string: $0, attributes: [.font: DetailStyle.bodyFont, .foregroundColor: NSColor.placeholderTextColor])
        }
        // Changed from outside: show it. (Typing changes the text view first, then the binding.)
        if text != coordinator.shown {
            coordinator.shown = text
            if view.string != text { view.show(text, undo: coordinator.undo) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        /// What the binding said last, as far as this view knows: set by typing, and by the
        /// binding changing from outside.
        var shown = ""
        /// The view's own, so text replaced from outside can drop what typing registered.
        let undo = UndoManager()

        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? TextView else { return }
            shown = view.string
            view.recolor()
            text.wrappedValue = view.string
        }

        func undoManager(for view: NSTextView) -> UndoManager? { undo }
    }

    final class TextView: NSTextView {
        var isCode = false
        var returnCommits = false
        var onCommit: (@MainActor () -> Void)?
        var onExit: (@MainActor () -> Void)?
        var placeholder: NSAttributedString? {
            didSet { if placeholder != oldValue { needsDisplay = true } }
        }
        var coloring: DetailCodeColoring?
        /// The text's own color, and whether `coloring`'s runs are colored over it.
        private var baseColor: NSColor?
        private var colorsSpans = false

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
                    storage.addAttribute(.foregroundColor, value: DetailStyle.codeColor(span.role), range: span.range)
                    if span.role == .invalid {
                        storage.addAttribute(.underlineStyle, value: NSUnderlineStyle([.single, .patternDot]).rawValue, range: span.range)
                    }
                }
            }
            storage.endEditing()
        }

        // MARK: Keys

        override func keyDown(with event: NSEvent) {
            if Self.isReturn(event), !hasMarkedText() {
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                if modifiers == .command || (returnCommits && modifiers.isEmpty) {
                    onCommit?()
                    return
                }
                if returnCommits && modifiers == .shift {
                    insertNewline(nil)
                    return
                }
            }
            super.keyDown(with: event)
        }

        /// ⌘↩ may come as a key equivalent (before the menus) rather than a key down.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if window?.firstResponder === self, Self.isReturn(event),
               event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command {
                onCommit?()
                return true
            }
            return super.performKeyEquivalent(with: event)
        }

        private static func isReturn(_ event: NSEvent) -> Bool { event.keyCode == 36 || event.keyCode == 76 }

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

        override func insertTab(_ sender: Any?) {
            guard isCode, isEditable else { return super.insertTab(sender) }
            insertText(Self.indentStep, replacementRange: selectedRange())
        }

        private static let indentStep = "  "

        /// Escape leaves the panel (a text view's own Escape offers completions).
        override func cancelOperation(_ sender: Any?) {
            guard let onExit else { return super.cancelOperation(sender) }
            onExit()
        }

        // MARK: Committing when the keyboard leaves

        override func resignFirstResponder() -> Bool {
            let resigned = super.resignFirstResponder()
            if resigned { onCommit?() }
            return resigned
        }

        /// Taken out of the window while it had the keyboard (the panel showing another shape):
        /// that's leaving it too. After the update that took it out.
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil, window?.firstResponder === self, let onCommit {
                Task { @MainActor in onCommit() }
            }
            super.viewWillMove(toWindow: newWindow)
        }

        // MARK: Text from outside, and the placeholder

        /// Replaces the text, as something other than typing: the caret stays where it was, as
        /// far as the new text reaches, and typing's undo steps (which were for the old text) go.
        func show(_ text: String, undo: UndoManager) {
            let caret = selectedRange().location
            string = text
            setSelectedRange(NSRange(location: min(caret, (text as NSString).length), length: 0))
            undo.removeAllActions()
            recolor()
            needsDisplay = true
        }

        override func didChangeText() {
            super.didChangeText()
            if placeholder != nil { needsDisplay = true }
        }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            guard string.isEmpty, let placeholder else { return }
            let origin = textContainerOrigin, padding = textContainer?.lineFragmentPadding ?? 0
            placeholder.draw(with: NSRect(x: origin.x + padding, y: origin.y, width: bounds.width - origin.x - padding * 2,
                                          height: bounds.height - origin.y),
                             options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }
}
