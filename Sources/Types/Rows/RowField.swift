import AppKit
import TextEditing

// The one-line editor of a row's value: an `EditingTextView` on TextKit 2, as every editor in the app is (so
// `placeSelection(at:)` and `caretFrame` work), made for a value: no wrapping, no autocorrect, no smart
// quotes or dashes, no replacement, no spelling marks, no mentions and no slash commands (`@` and `/` are
// letters here). Its keys are the rows' (`RowsView` decides what each does); the text view never holds a
// real line break, whatever is pasted: a value that holds one has, in its place, a space that carries the
// break it stands for.

/// What a key does in a row's field: the table of the rows' keys.
enum RowKey {
    /// Tab, ⇧Tab.
    case next, previous
    /// ↓ and ↑: the row after, the row before.
    case down, up
    /// Return: done (a row with more in it: its card). Escape: done.
    case commit, escape
    /// Space on a row that is not typed.
    case space
}

@MainActor
final class RowField: EditingTextView {
    /// The attribute of a space that stands for a line break: its value is the break it stands for.
    static let lineBreak = NSAttributedString.Key("RowField.lineBreak")

    /// A key that moves between rows or ends editing.
    var onKey: ((RowKey) -> Void)?
    /// The text changed by typing, pasting or an undo (not by `show`).
    var onChange: (() -> Void)?
    /// The field has the keyboard, or lost it.
    var onFocus: (() -> Void)?
    var onBlur: (() -> Void)?
    /// The list of notes a relation row's field finds in while it is typed in, and its window: the keys are the list's first.
    var picking: (picker: any NotePicking, window: CaretListWindow)?

    override var caretListWindow: CaretListWindow? { picking?.window }

    /// What every character of the text is drawn in: nothing typed or pasted ever takes another look.
    private let plain: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: TypesStyle.rowFontSize), .foregroundColor: TypesStyle.rowInk]
    private var isShowing = false

    init() {
        // `init(frame:)` calls `init(frame:textContainer:)` on the view, which sets it up.
        super.init(frame: .zero)
    }

    /// What NSTextView's `init(frame:)` calls on itself, with the text system it makes.
    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        setUp()
    }

    private func setUp() {
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
        textContainerInset = TypesStyle.fieldInset
        insertionPointColor = TypesStyle.rowInk
        // A value is typed as it is: nothing rewrites it, nothing is underlined.
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        CaretListSubstitutions.off.apply(to: self)
        commitsOnLeaving = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Nothing typed or pasted beside a stand-in takes its attribute.
    override var typingAttributes: [NSAttributedString.Key: Any] {
        get { plain }
        set {}
    }

    // MARK: The text

    /// Shows `value` as the field's text: a line break becomes the stand-in space that carries it.
    func show(_ value: String) {
        isShowing = true
        defer { isShowing = false }
        let range = selectedRange()
        textStorage?.setAttributedString(standIns(in: value))
        let length = textStorage?.length ?? 0
        setSelectedRange(NSRange(location: min(range.location, length), length: 0))
        if let manager = undoManager {
            if let storage = textStorage { manager.removeAllActions(withTarget: storage) }
            manager.removeAllActions(withTarget: self)
        }
    }

    /// What the field holds, each stand-in put back as the break it stands for.
    var value: String {
        guard let storage = textStorage else { return string }
        var result = ""
        storage.enumerateAttribute(Self.lineBreak, in: NSRange(location: 0, length: storage.length)) { found, range, _ in
            if let found = found as? String { result += found } else { result += (storage.string as NSString).substring(with: range) }
        }
        return result
    }

    private func standIn(for text: String) -> NSAttributedString {
        var attributes = plain
        attributes[Self.lineBreak] = text
        return NSAttributedString(string: " ", attributes: attributes)
    }

    /// `text` as the field holds it: every line break (`\n`, `\r\n`, `\r`, `\u{2028}`, `\u{2029}`) one stand-in.
    private func standIns(in text: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        var plainRun = ""
        func flush() {
            if !plainRun.isEmpty { result.append(NSAttributedString(string: plainRun, attributes: plain)) }
            plainRun = ""
        }
        for character in text {
            // A `Character` is one grapheme: "\r\n" is one.
            if character.isNewline {
                flush()
                result.append(standIn(for: String(character)))
            } else {
                plainRun.append(character)
            }
        }
        flush()
        return result
    }

    /// A paste or a drop brings real line breaks; each is replaced by a stand-in, the selection kept.
    private func replaceLineBreaks() {
        guard let storage = textStorage, storage.string.contains(where: \.isNewline) else { return }
        let selection = selectedRange()
        var shift = 0
        let text = storage.string
        var found: [(range: NSRange, text: String)] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .byComposedCharacterSequences) { character, range, _, _ in
            if let character, character.count == 1, character.first?.isNewline == true { found.append((NSRange(range, in: text), character)) }
        }
        for item in found.reversed() {
            // Real breaks only: a stand-in is a space.
            storage.replaceCharacters(in: item.range, with: standIn(for: item.text))
        }
        for item in found where item.range.location < selection.location { shift += item.range.length - 1 }
        setSelectedRange(NSRange(location: max(0, selection.location - shift), length: 0))
    }

    override func didChangeText() {
        replaceLineBreaks()
        super.didChangeText()
        if !isShowing { onChange?() }
    }

    // MARK: Keys

    /// The keys of the table: Tab and ⇧Tab, ↑ and ↓, Return and Escape are the rows'. Everything else is a text
    /// view's.
    override func doCommand(by selector: Selector) {
        // Picking a note for a relationship: the list's keys come first, as `NotePicking.perform` says them. Tab and ⇧Tab are never a pick:
        // the list closes with nothing stored, and the key goes on as the rows' (`EditingTextView` would hand it to the list).
        if let (picker, window) = picking {
            let (taken, action) = picker.perform(selector)
            if taken {
                switch action {
                case .pick: window.pickHighlighted()
                case .close: window.closeList()
                default: break
                }
                return
            }
            if action == .close {
                let onKey = onKey
                window.closeList()
                switch selector {
                case #selector(insertTab(_:)): onKey?(.next)
                case #selector(insertBacktab(_:)): onKey?(.previous)
                default: break
                }
                return
            }
        }
        switch selector {
        case #selector(insertTab(_:)): onKey?(.next)
        case #selector(insertBacktab(_:)): onKey?(.previous)
        case #selector(moveDown(_:)): onKey?(.down)
        case #selector(moveUp(_:)): onKey?(.up)
        case #selector(insertNewline(_:)), #selector(insertNewlineIgnoringFieldEditor(_:)), #selector(insertLineBreak(_:)): onKey?(.commit)
        case #selector(cancelOperation(_:)): onKey?(.escape)
        default: super.doCommand(by: selector)
        }
    }

    // MARK: The keyboard

    override func becomeFirstResponder() -> Bool {
        let became = super.becomeFirstResponder()
        if became { onFocus?() }
        return became
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onBlur?() }
        return resigned
    }
}
