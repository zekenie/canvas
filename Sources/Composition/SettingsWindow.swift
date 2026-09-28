import AppKit
import SwiftUI

/// The Settings window: one for the app (Infinite Canvas › Settings…, ⌘,, which the app's delegate
/// answers with `show()`), hosting `content`, the app's `ShippedPlugins.settings()`. Made afresh
/// each time it opens: what a status said (a test that worked) was about a moment that's past, the
/// key's file may have changed since, and a key typed and left shouldn't wait in a hidden window.
/// It opens where it was left.
@MainActor
public final class SettingsWindow {
    private let content: @MainActor () -> AnyView
    private let autosaveName: String?
    private var window: NSWindow?

    /// `content` is made each time the window opens. AppKit keeps where the window was left under
    /// `autosaveName` (nil: nowhere, as in tests).
    public init<Content: View>(autosaveName: String? = "Settings", content: @escaping @MainActor () -> Content) {
        self.content = { AnyView(content()) }
        self.autosaveName = autosaveName
    }

    /// Brings the window forward, `prepare`d.
    public func show() {
        prepare().makeKeyAndOrderFront(nil)
    }

    /// The window as `show` brings it forward, not yet in front: made the first time; after, while
    /// it's closed, with its content made afresh; while it's open, as it is.
    @discardableResult
    public func prepare() -> NSWindow {
        guard let window else {
            let window = NSWindow(contentViewController: hosting())
            window.title = "Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            if let autosaveName { window.setFrameAutosaveName(autosaveName) }
            self.window = window
            return window
        }
        if !window.isVisible { window.contentViewController = hosting() }
        return window
    }

    /// The content, sized before it goes in: a controller's view of no size would shrink the window
    /// to none, keeping its top edge, and SwiftUI would then grow it back from its bottom edge, so
    /// each time it opened it would be higher, until it met the top of the screen.
    private func hosting() -> NSViewController {
        let controller = NSHostingController(rootView: content())
        controller.view.setFrameSize(controller.view.fittingSize)
        return controller
    }
}
