import AppKit
import Canvas
import SwiftUI
import TextEditing

/// What the panel's own views (its text boxes, rows, code editors, status lines) need around them, for a plugin that draws some of
/// them outside a shape's panel, in a popover of its own (Constraints' funnel on a board): the panel's metrics and fonts, its
/// one uncommitted draft (so Escape lets go of words typed that haven't landed before it leaves), the editor its buttons run
/// commands on, and the panel's keys. The content is the caller's: it is as tall as it is, in a `ScrollView` if it needs one.
///
/// Escape (and ⌘.) lets go of a draft first, as the panel's does, and then calls `close`, which closes what the content is in
/// and gives the keyboard back to the canvas; a text view holding keys (a list it shows over its text) has the key first. Tab
/// walks the content's controls in reading order and goes round from the last to the first, ⇧Tab the other way: the ring is
/// closed on itself, as the panel's is, so the keyboard never leaves for another view. `focus` asks for the keyboard (a
/// change takes it to the first control, once the content is drawn). Taken out of the window while the keyboard is in it, the
/// keyboard goes to `reclaim`, the canvas.
public struct DetailHosted<Content: View>: View {
    let editor: CanvasEditor
    let focus: Int
    let close: @MainActor () -> Void
    let reclaim: @MainActor () -> Void
    let content: Content
    @State private var window = WindowBox()
    @State private var drafts = DraftTracker()

    public init(editor: CanvasEditor, focus: Int = 0, close: @escaping @MainActor () -> Void, reclaim: @escaping @MainActor () -> Void,
                @ViewBuilder content: () -> Content) {
        self.editor = editor
        self.focus = focus
        self.close = close
        self.reclaim = reclaim
        self.content = content()
    }

    public var body: some View {
        content
            .controlSize(.small)
            .font(DetailStyle.body)
            .labeledContentStyle(DetailRowStyle())
            .toggleStyle(DetailCheckboxStyle())
            .environment(\.detailDrafts, drafts)
            .environment(\.detailExit, close)
            .environment(\.detailReclaim, reclaimSoon)
            .environment(\.detailEditor, editor)
            .background(WindowReader(box: window, onHide: reclaimSoon))
            .onKeyPress(.escape, phases: [.down, .repeat]) { press in
                leave(withOption: press.modifiers.contains(.option)) ? .handled : .ignored
            }
            // ⌘., which the window sends up the responder chain as `cancelOperation:` with no key down, as it does the panel.
            .onExitCommand { _ = leave(withOption: false) }
            .onChange(of: focus, initial: true) { _, _ in focusFirst(retries: DetailStyle.focusRetries) }
            .onAppear { window.scheduler = editor.scheduler }
            .onDisappear(perform: reclaimSoon)
    }

    /// The keyboard to the first control, once the content is drawn and in its window (asked as the content appears, which is before
    /// either): tried a few times, a turn apart.
    private func focusFirst(retries: Int) {
        _ = editor.scheduler.schedule(after: DetailStyle.focusRetry) { [window, editor] in
            if window.window == nil, retries > 0 {
                // Not in its window yet.
                self.focusFirst(retries: retries - 1)
            } else {
                window.focusFirstControl(excluding: [], retries: retries, scheduler: editor.scheduler)
            }
        }
    }

    /// Escape or ⌘.: drops words being typed first, alone, and leaves the next time; unless a text view holding keys has the keyboard.
    /// Whether it did anything.
    private func leave(withOption: Bool) -> Bool {
        let text = window.window?.firstResponder as? EditingTextView
        if text?.holdsKeys == true || (withOption && text?.offersCompletions == true) { return false }
        if drafts.pending != nil {
            drafts.revert(in: window.window?.firstResponder as? NSTextView)
            return true
        }
        close()
        return true
    }

    /// After SwiftUI has removed views: if the keyboard fell to the window, the canvas has it.
    private func reclaimSoon() {
        let window = window, reclaim = reclaim
        _ = editor.scheduler.schedule(after: .zero) { [window] in
            guard let host = window.window else { return }
            if host.firstResponder === host { reclaim() }
        }
    }
}
