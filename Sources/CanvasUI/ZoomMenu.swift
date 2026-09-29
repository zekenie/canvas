import AppKit
import Canvas
import SwiftUI

/// The toolbar's zoom menu: titled with the zoom in whole percent ("100%", where the camera is
/// headed: `editor.zoomPercentage`, so it redraws as the zoom changes, never as the camera pans),
/// with the View menu's zoom items. They go up the responder chain as the View menu's do, to the
/// board's window controller, so they run the same commands (the core's, and Selection's Zoom to
/// Selection) and are dimmed alike, as the menu opens. They have no keys: the View menu's are the
/// keys.
public struct ZoomMenu: View {
    let editor: CanvasEditor

    public init(editor: CanvasEditor) { self.editor = editor }

    public var body: some View {
        ZoomPopUp(title: Self.title(percent: editor.zoomPercentage))
            .fixedSize()
            .help("Zoom")
    }

    /// "100%".
    static func title(percent: Int) -> String { "\(percent)%" }

    /// Its items, in order, with what each sends (the View menu's actions).
    static let items: [(title: String, action: Selector)] = [
        ("Zoom In", #selector(BoardWindowController.zoomIn(_:))),
        ("Zoom Out", #selector(BoardWindowController.zoomOut(_:))),
        ("Actual Size", #selector(BoardWindowController.zoomToActualSize(_:))),
        ("Zoom to Fit", #selector(BoardWindowController.zoomToFit(_:))),
        ("Zoom to Selection", #selector(BoardWindowController.zoomToSelection(_:))),
    ]

    /// The pull-down, its first item the title it shows.
    static func makePopUp(title: String) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        button.bezelStyle = .toolbar
        button.addItem(withTitle: title)
        for (title, action) in items {
            button.menu?.addItem(NSMenuItem(title: title, action: action, keyEquivalent: ""))
        }
        button.setAccessibilityLabel("Zoom")
        return button
    }
}

struct ZoomPopUp: NSViewRepresentable {
    let title: String

    func makeNSView(context: Context) -> NSPopUpButton { ZoomMenu.makePopUp(title: title) }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        guard let first = button.item(at: 0), first.title != title else { return }
        first.title = title
        button.synchronizeTitleAndSelectedItem()
    }
}
