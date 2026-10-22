import AppKit

// What VoiceOver reads of the two forms a card holds (`FieldFormView`, `DefinitionView`): the stops they walk, each an element
// with a role by its control, a label from its field's words, a value from its cell and a frame from where it is drawn, pressing
// as Return does. The form answers its children from its stops, and the stop with the keyboard as its focused element; where a
// cell has the caret that element is the cell editor, in the children too, so the focused element is always one of the children
// (an assistive app compares them by identity). A stop keeps its element from one query to the next, made again in place
// (`stopElement(reusing:)`), and the focused element is made for its stop alone, not for every stop. `focus(_:)` posts the
// change and names the editor.

/// One stop of a form, as an accessibility element.
final class CardStopElement: NSAccessibilityElement {
    /// What pressing it does: Return's. Set and used on the main thread, where AppKit asks.
    nonisolated(unsafe) var press: (@MainActor () -> Void)?

    override func accessibilityPerformPress() -> Bool {
        guard let press else { return false }
        MainActor.assumeIsolated { press() }
        return true
    }
}

extension NSView {
    /// A rect of this view on the screen.
    func screenRect(_ rect: CGRect) -> CGRect {
        guard let window else { return rect }
        return window.convertToScreen(convert(rect, to: nil))
    }

    /// An element with the parts every stop has.
    @MainActor
    func stopElement(reusing old: CardStopElement? = nil, role: NSAccessibility.Role, label: String, value: Any? = nil, rect: CGRect,
                     help: String? = nil, press: (@MainActor () -> Void)? = nil) -> CardStopElement {
        let element = old ?? CardStopElement()
        element.setAccessibilityParent(self)
        element.setAccessibilityRole(role)
        element.setAccessibilityLabel(label)
        element.setAccessibilityFrame(screenRect(rect))
        element.setAccessibilityValue(value)
        element.setAccessibilityHelp(help)
        element.press = press
        return element
    }
}
