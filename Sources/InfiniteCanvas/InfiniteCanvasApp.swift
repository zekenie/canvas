import AppKit
import SwiftUI

@main
struct InfiniteCanvasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Infinite Canvas") {
            CanvasRepresentable()
                .frame(minWidth: 480, minHeight: 320)
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(after: .toolbar) {
                Divider()
                Button("Zoom In") { sendToCanvas(#selector(CanvasView.zoomIn(_:))) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("Zoom Out") { sendToCanvas(#selector(CanvasView.zoomOut(_:))) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("Actual Size") { sendToCanvas(#selector(CanvasView.zoomToActualSize(_:))) }
                    .keyboardShortcut("0", modifiers: .command)
            }
        }
    }

    /// Menu commands travel the responder chain, so they reach the canvas even while a note's
    /// text editor is first responder.
    private func sendToCanvas(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // `swift run` launches a bare executable rather than an .app bundle, so opt in to
        // being a regular foreground app with a Dock icon.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct CanvasRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> CanvasView {
        CanvasView(frame: .zero)
    }

    func updateNSView(_ nsView: CanvasView, context: Context) {}
}
