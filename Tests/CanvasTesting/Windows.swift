import AppKit
import TestKit

// Driving views in an unshown window, which is enough for first responders, field editors and key
// events. SwiftUI applies changes, and the scheduler runs its actions, on the main run loop, so a
// test runs that loop: until the state it expects arrives (`spin(until:)`), or for a few turns
// (`settle()`) where there's nothing to see arrive, or the point is that nothing more happens.

extension NSWindow {
    /// Runs the main run loop, a turn at a time, until `done` holds; fails the test if it doesn't
    /// within `timeout` seconds. Always runs at least one turn.
    public func spin(until done: () -> Bool, timeout: TimeInterval = 2, file: StaticString = #fileID, line: UInt = #line) {
        let deadline = Date(timeIntervalSinceNow: timeout)
        repeat {
            guard Date() < deadline else {
                expect(false, "timed out after \(timeout) s", file: file, line: line)
                return
            }
            turn()
        } while !done()
    }

    /// A few turns of the main run loop: SwiftUI applies what's pending, and what that sets off (a
    /// focus change, an onChange, an action scheduled after zero) lands too.
    public func settle() {
        for _ in 0..<5 { turn() }
    }

    private func turn() {
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.002))
        contentView?.layoutSubtreeIfNeeded()
    }

    /// A key typed: `sendEvent` routes it to the first responder, as AppKit does.
    public func press(_ characters: String, code: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) {
        sendEvent(keyEvent(characters, code: code, modifiers: modifiers))
    }

    /// A key-down event for this window. `ignoringModifiers` is what the key types without them, when
    /// that differs (⌃H types "\u{8}", ignoring ⌃ "h").
    public func keyEvent(_ characters: String, ignoringModifiers: String? = nil, code: UInt16 = 0, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1, windowNumber: windowNumber, context: nil,
                         characters: characters, charactersIgnoringModifiers: ignoringModifiers ?? characters, isARepeat: false, keyCode: code)!
    }

    public func type(_ text: String) {
        for character in text { press(String(character)) }
    }

    public func pressReturn() { press("\r", code: 36) }
    public func pressEscape() { press("\u{1b}", code: 53) }
    public func pressDelete() { press("\u{7f}", code: 51) }

    /// Gives a field the keyboard, with its text selected, as a click does.
    public func focus(_ field: NSTextField) {
        makeFirstResponder(field)
        (firstResponder as? NSTextView)?.selectAll(nil)
        settle()
    }

    /// A mouse event at a point in the content view's top-left coordinates. Hand it to the view
    /// (`canvas.mouseDown(with:)`): `sendEvent` mouse-downs don't reach views in an unshown window.
    public func mouse(_ type: NSEvent.EventType, at point: CGPoint, clicks: Int = 1, modifiers: NSEvent.ModifierFlags = [],
                      time: TimeInterval) -> NSEvent {
        let height = contentView?.frame.height ?? frame.height
        return NSEvent.mouseEvent(with: type, location: CGPoint(x: point.x, y: height - point.y), modifierFlags: modifiers, timestamp: time,
                                  windowNumber: windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }
}

extension NSView {
    /// Every view under this one, depth first, in subview order.
    public var descendants: [NSView] { subviews.flatMap { [$0] + $0.descendants } }

    /// The views under this one of a class (controls are found by their public AppKit class).
    public func descendants<View: NSView>(_: View.Type) -> [View] { descendants.compactMap { $0 as? View } }
}
