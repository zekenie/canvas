import AppKit
import Canvas
import SwiftUI

/// The Settings window: one for the app (Infinite Canvas › Settings…, ⌘,, which the app's delegate
/// answers with `show()`), hosting `content`: for the app, the panes its plugins gave
/// (`init(registry:)`). Made afresh each time it opens: what a status said (a test that worked) was
/// about a moment that's past, a file a pane reads may have changed since, and what was typed and
/// left shouldn't wait in a hidden window. It opens where it was left.
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

    /// The app's Settings: the panes the registry's plugins gave (`registrar.settingsPane`), one
    /// under another in plugin order.
    public convenience init(registry: Registry, autosaveName: String? = "Settings") {
        self.init(autosaveName: autosaveName) { SettingsPanesView(panes: registry.settingsPanes) }
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
            let window = SecondaryWindow(contentViewController: hosting())
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

/// The Settings window's panes, one under another, each as its plugin made it: a pane says what it
/// is itself (a form's own label), so none is headed here. The first takes the keyboard as the
/// window opens (`settingsPaneTakesFocus`), and Tab goes on down from it.
struct SettingsPanesView: View {
    let panes: [SettingsPane]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(panes.indices, id: \.self) { panes[$0].view().environment(\.settingsPaneTakesFocus, $0 == 0) }
        }
    }
}
