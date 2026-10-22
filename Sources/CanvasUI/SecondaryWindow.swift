import AppKit

/// The window of the app's secondary windows (Settings, Keyboard Shortcuts): Escape, or ⌘., that
/// nothing inside took (`cancelOperation:` reaches the window last) closes it, as Close does.
final class SecondaryWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }
}
