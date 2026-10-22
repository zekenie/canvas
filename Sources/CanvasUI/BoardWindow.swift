import AppKit
@_spi(Host) import Canvas

/// A board's window, which splits Edit › Undo and Redo between text and the board. While text has
/// the keyboard (a note being edited, a panel's field), they're the text's own, through the undo
/// manager the text uses: this window's (`textUndo`, which every text view that doesn't keep its
/// own sees, as a note's editor), or the text's own (a SwiftUI field's editor keeps one). Anywhere
/// else (the canvas, the table of contents' list, a checkbox in the panel), they run the commands that
/// answer them (the core's undo and redo, which ⌘Z and ⇧⌘Z run on the canvas), and the menu names the
/// step ("Undo Move").
///
/// Text's undo lasts while it has the keyboard: once the keyboard leaves it, what it could undo is
/// forgotten (a stale action could otherwise write through an editor that's gone, or into another
/// field), and the board's step for the typing is what's left to undo. And since the editor can't
/// see a click or a key in the panel, the window tells its history when one begins something new
/// (`seal()`), so a field's run of writes ends there. A click in a window of another kind (the color
/// panel a color well opens, whose picks write to the board through the panel's field) ends runs
/// too, in every board's window, but not one in a board's child window (a list of picks a text
/// shows beside itself, a pick being part of the typing). A card's step (`editor.showCard`) is not a
/// run: `seal()` leaves it, so a click or the keyboard moving between the card's fields doesn't end
/// it; it ends with the card, or with a commit from elsewhere.
@MainActor
public final class BoardWindow: NSWindow {
    /// The editor whose board this window shows.
    public weak var editor: CanvasEditor? { didSet { Self.watchOtherWindows() } }
    /// Escape where nothing takes it (the toolbar, the bare hosting view): the controller gives the keyboard back to the
    /// canvas; true if it did.
    var escapeToCanvas: (@MainActor () -> Bool)?
    /// Text's undo and redo, while text that keeps none of its own has the keyboard.
    public let textUndo = UndoManager()
    /// Localized menu titles for the board's steps ("Undo Move", or "Undo" for a step without a
    /// name); it never holds an action.
    private static let titles = UndoManager()

    public override var undoManager: UndoManager? { textUndo }

    /// Watches for clicks in windows that aren't boards' (the color panel), which no board's window
    /// sees: each begins something new, so it ends every board's run of panel writes. Once per app.
    /// Not one in a board's child window (a list text shows beside itself to pick from), whose
    /// pick is part of the typing.
    private static var otherWindowsClicks: Any?

    private static func watchOtherWindows() {
        guard otherWindowsClicks == nil else { return }
        otherWindowsClicks = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]) { event in
            MainActor.assumeIsolated {
                if !(event.window is BoardWindow), !(event.window?.parent is BoardWindow) {
                    for case let board as BoardWindow in NSApp.windows { board.editor?.undoHistory.seal() }
                }
            }
            return event
        }
    }

    /// The text that edits with the keyboard, where Undo is the text's own; nil anywhere else.
    private var textWithKeyboard: NSTextView? {
        guard let text = firstResponder as? NSTextView, text.isEditable else { return nil }
        return text
    }

    /// The undo manager of the text with the keyboard: its own, or this window's.
    private var textUndoInUse: UndoManager? { textWithKeyboard.map { $0.undoManager ?? textUndo } }

    /// What has the keyboard, as someone sees it: for a field, whose window's field editor has the
    /// keyboard, the field itself.
    private var keyboardOwner: AnyObject? {
        guard let text = textWithKeyboard, text.isFieldEditor else { return firstResponder }
        return (text.delegate as AnyObject?) ?? text
    }

    /// Edit › Undo. (`undo:` is NSWindow's, undeclared: this takes its place.)
    @objc(undo:) public func undo(_ sender: Any?) {
        if let text = textWithKeyboard { changeText(text) { $0.undo() } } else { editor?.perform(answering: .undo) }
    }

    /// Edit › Redo.
    @objc(redo:) public func redo(_ sender: Any?) {
        if let text = textWithKeyboard { changeText(text) { $0.redo() } } else { editor?.perform(answering: .redo) }
    }

    /// Undoes or redoes in `text`, then tells whoever listens that its text changed, as typing does:
    /// NSTextView's own undo changes its text without a word to its delegate (a note's editor, a
    /// field, whose SwiftUI binding would otherwise keep what was typed).
    private func changeText(_ text: NSTextView, _ change: (UndoManager) -> Void) {
        change(text.undoManager ?? textUndo)
        text.didChangeText()
    }

    public override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(undo(_:)):
            if let text = textUndoInUse {
                item.title = text.undoMenuItemTitle
                return text.canUndo
            }
            item.title = editor?.undoHistory.undoName.map(Self.titles.undoMenuTitle(forUndoActionName:)) ?? Self.titles.undoMenuItemTitle
            return editor?.canPerform(answering: .undo) == true
        case #selector(redo(_:)):
            if let text = textUndoInUse {
                item.title = text.redoMenuItemTitle
                return text.canRedo
            }
            item.title = editor?.undoHistory.redoName.map(Self.titles.redoMenuTitle(forUndoActionName:)) ?? Self.titles.redoMenuItemTitle
            return editor?.canPerform(answering: .redo) == true
        default:
            return super.validateMenuItem(item)
        }
    }

    /// Text that loses the keyboard forgets what it could undo; any move of the keyboard ends a run
    /// of panel writes. (A field's editor taking the keyboard from its field isn't a move.)
    @discardableResult
    public override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let old = keyboardOwner, oldText = textUndoInUse
        let made = super.makeFirstResponder(responder)
        if keyboardOwner !== old {
            if let oldText {
                oldText.removeAllActions()
                textUndo.removeAllActions()
            }
            editor?.undoHistory.seal()
        }
        return made
    }

    /// A click anywhere, or a key where neither text nor the canvas has the keyboard (a checkbox,
    /// the table of contents' list), begins something new: a run of panel writes ends there. (The
    /// canvas's own presses and keys are steps of their own anyway.)
    public override func sendEvent(_ event: NSEvent) {
        // Escape held with no modifier that changes a key (Caps Lock is no such modifier).
        if event.type == .keyDown, event.keyCode == 53, Modifiers(event.modifierFlags).isEmpty,
           textWithKeyboard == nil, escapeToCanvas?() == true { return }
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            editor?.undoHistory.seal()
        case .keyDown where textWithKeyboard == nil && !(firstResponder is CanvasView):
            editor?.undoHistory.seal()
        default:
            break
        }
        super.sendEvent(event)
    }
}
