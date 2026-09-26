import AppKit
import Canvas
import CanvasUI
import Composition
import SwiftUI

@main
struct InfiniteCanvasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Infinite Canvas") {
            ContentView()
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

    /// Menu commands travel the responder chain, so they reach the canvas even while a shape's
    /// editing view is first responder.
    private func sendToCanvas(_ action: Selector) {
        NSApp.sendAction(action, to: nil, from: nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

struct ContentView: View {
    @State private var editor: CanvasEditor = ShippedPlugins.makeEditor()

    var body: some View {
        CanvasRepresentable(editor: editor)
            .frame(minWidth: 480, minHeight: 320)
            .toolbar {
                ToolbarItem(placement: .principal) { ToolPicker(editor: editor) }
            }
    }
}
