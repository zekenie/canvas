import AppKit
import Canvas
import SwiftUI
import TextEditing

/// Jump To's palette, for the host to place over the canvas (`.overlay`): nothing while it's closed;
/// open, a clear scrim over the whole canvas, whose click closes the palette and goes no further, and
/// a capsule at the top middle with the field in it, `JumpToStyle.topOffset` below the part of the
/// canvas the host leaves clear, taken as it opened (`JumpToState.top`). Its list is the app's one
/// caret list (`CaretListWindow`), a child window under the capsule at the capsule's width. The field
/// takes the keyboard as the palette opens (and on every ⌘K while it's open, its text selected); ↑ ↓
/// ⌃P ⌃N and Page Up and Down move through the list, Return and Tab pick, Escape and ⌘. close. It
/// closes, too, once the field loses the keyboard to anything else (Find's field, the panel's) or its
/// window stops being key. `onExit` gives the keyboard back to the canvas, as the palette closes by
/// the person's doing (Escape, ⌘., a click outside, a pick).
public struct JumpToPalette: View {
    let editor: CanvasEditor
    let onExit: @MainActor () -> Void

    public init(editor: CanvasEditor, onExit: @escaping @MainActor () -> Void) {
        self.editor = editor
        self.onExit = onExit
    }

    public var body: some View {
        if let state = editor.jumpTo, state.isOpen {
            JumpToOpenPalette(state: state, onExit: onExit)
        }
    }
}

private struct JumpToOpenPalette: View {
    let state: JumpToState
    let onExit: @MainActor () -> Void

    var body: some View {
        ZStack(alignment: .top) {
            // The scrim: a click anywhere else closes the palette, and isn't the canvas's.
            Button {
                state.close()
                onExit()
            } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .focusable(false)
            .accessibilityHidden(true)
            JumpToField(state: state, focus: state.focusRequest, onExit: onExit)
                .padding(.horizontal, JumpToStyle.horizontalPadding)
                .frame(width: JumpToStyle.width, height: JumpToStyle.fieldHeight)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
                .shadow(color: .black.opacity(JumpToStyle.shadowOpacity), radius: JumpToStyle.shadowRadius, y: JumpToStyle.shadowY)
                .padding(.top, state.top)
        }
    }
}

/// The palette's field: a single line of `EditingTextView`, whose list is a `CaretListWindow` under
/// the capsule. It tells the state what's typed, and the state's rows are the list's.
private struct JumpToField: NSViewRepresentable {
    let state: JumpToState
    /// `state.focusRequest` as this was made: a change takes the keyboard, the text selected.
    let focus: Int
    let onExit: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(state: state, onExit: onExit) }

    func makeNSView(context: Context) -> JumpToTextView {
        let view = JumpToTextView()
        let coordinator = context.coordinator
        view.delegate = coordinator
        coordinator.view = view
        view.string = state.query
        view.onAttach = { [weak coordinator] in coordinator?.attachList() }
        view.onEscape = { [weak coordinator] in coordinator?.closeAndExit() }
        view.onLeave = { [weak coordinator] in coordinator?.state.close() }
        view.requestFocus(focus)
        return view
    }

    func updateNSView(_ view: JumpToTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.onExit = onExit
        // Closed and opened again before the view went: its list went with the close, and what was
        // typed is gone from the state, not the field.
        if view.string != state.query { view.string = state.query }
        if view.window != nil { coordinator.attachList() }
        view.requestFocus(focus)
    }

    static func dismantleNSView(_ view: JumpToTextView, coordinator: Coordinator) {
        coordinator.detachList()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let state: JumpToState
        var onExit: @MainActor () -> Void
        weak var view: JumpToTextView?

        init(state: JumpToState, onExit: @escaping @MainActor () -> Void) {
            self.state = state
            self.onExit = onExit
        }

        func textDidChange(_ notification: Notification) {
            guard let view else { return }
            state.setQuery(view.string)
        }

        /// The person closed it: it closes, and the canvas has the keyboard.
        func closeAndExit() {
            state.close()
            onExit()
        }

        /// Makes the list's window once the field is in its window: under the capsule, following it.
        func attachList() {
            guard let view, view.listWindow == nil else { return }
            let window = CaretListWindow(state.list, accessibilityLabel: JumpToStyle.accessibilityLabel, over: view,
                                         anchorRect: { [weak view] in view?.capsuleRect },
                                         pick: { [weak self] row in
                                             guard let self else { return }
                                             state.pick(row: row)
                                             onExit()
                                         },
                                         close: { [weak self] in self?.state.close() })
            view.listWindow = window
            state.list.onChange = { [weak window] in window?.listDidChange() }
            state.onClose = { [weak self] in self?.detachList() }
            window.listDidChange()
        }

        /// The palette closed: its list goes now, and nothing follows its changes (once: the view going
        /// afterwards finds it gone, and leaves what a palette opened since has set).
        func detachList() {
            guard let window = view?.listWindow else { return }
            view?.listWindow = nil
            state.list.onChange = nil
            state.onClose = nil
            window.dismiss()
        }
    }
}

/// The field: one line of the app's text view, in the capsule, its list the palette's. Return and Tab
/// pick (the list's keys, held while it's open) and are never text; Escape and ⌘. close.
final class JumpToTextView: EditingTextView {
    /// The list under the capsule, while the palette is open.
    var listWindow: CaretListWindow?
    /// The field is in its window: its list can be made.
    var onAttach: (@MainActor () -> Void)?
    /// Escape, or ⌘.: the person closed the palette.
    var onEscape: (@MainActor () -> Void)?
    private var appliedFocus = -1
    private var wantsFocus = false

    override var caretListWindow: CaretListWindow? { listWindow }

    // `init(frame:)` makes the text system and goes through `init(frame:textContainer:)`, which
    // AppKit asks of this class: it's the one that sets the field up.
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configure()
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }

    convenience init() {
        self.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configure() {
        font = JumpToStyle.fieldFont
        textColor = .labelColor
        placeholder = JumpToStyle.placeholder
        drawsBackground = false
        isRichText = false
        allowsUndo = true
        isHorizontallyResizable = false
        isVerticallyResizable = false
        autoresizingMask = [.width]
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0
        textContainer?.maximumNumberOfLines = 1
        textContainer?.lineBreakMode = .byClipping
        let line = JumpToStyle.fieldFont.ascender - JumpToStyle.fieldFont.descender + JumpToStyle.fieldFont.leading
        textContainerInset = NSSize(width: 0, height: max(0, ((JumpToStyle.fieldHeight - line) / 2).rounded(.down)))
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        CaretListSubstitutions.off.apply(to: self)
        setAccessibilityLabel(JumpToStyle.accessibilityLabel)
    }

    /// The capsule around the field, in screen coordinates: where the list goes under.
    var capsuleRect: CGRect? {
        guard let window else { return nil }
        let inWindow = convert(bounds, to: nil)
        return window.convertToScreen(inWindow).insetBy(dx: -JumpToStyle.horizontalPadding, dy: 0)
    }

    // MARK: The keyboard

    /// Takes the keyboard, its text selected, for a request not answered yet: as it's in a window.
    func requestFocus(_ request: Int) {
        guard request != appliedFocus else { return }
        appliedFocus = request
        wantsFocus = true
        takeFocus()
    }

    private func takeFocus() {
        guard wantsFocus, let window else { return }
        wantsFocus = false
        window.makeFirstResponder(self)
        selectAll(nil)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        onAttach?()
        takeFocus()
    }

    // MARK: One line, and the list's keys

    /// Escape closes the palette, and the canvas has the keyboard; the list's other keys are the
    /// text view's (`EditingTextView.doCommand`).
    override func doCommand(by selector: Selector) {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            onEscape?()
            return
        }
        super.doCommand(by: selector)
    }

    /// ⌘., sent up the responder chain as a command with no key.
    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    // The query is one line: Return and Tab with nothing to pick, and a line break, insert nothing.
    override func insertNewline(_ sender: Any?) {}
    override func insertTab(_ sender: Any?) {}
    override func insertBacktab(_ sender: Any?) {}
    override func insertLineBreak(_ sender: Any?) {}
    override func insertParagraphSeparator(_ sender: Any?) {}
    override func insertNewlineIgnoringFieldEditor(_ sender: Any?) {}
    override func insertTabIgnoringFieldEditor(_ sender: Any?) {}

    /// Text pasted in is one line: its line breaks and tabs are spaces.
    override func didChangeText() {
        if string.contains(where: { $0.isNewline || $0 == "\t" }) {
            let range = selectedRange()
            string = String(string.map { $0.isNewline || $0 == "\t" ? " " : $0 })
            setSelectedRange(range)
        }
        super.didChangeText()
    }
}
