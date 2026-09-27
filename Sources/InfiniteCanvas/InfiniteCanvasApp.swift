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
            InspectorCommands()     // View › Show/Hide Inspector
            ZoomCommands()
        }
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

struct CanvasFocusKey: FocusedValueKey {
    typealias Value = CanvasFocus
}

extension FocusedValues {
    /// The focused window's canvas.
    var canvasFocus: CanvasFocus? {
        get { self[CanvasFocusKey.self] }
        set { self[CanvasFocusKey.self] = newValue }
    }
}

/// Zoom goes straight to the focused window's canvas, so it works whatever has the keyboard: the
/// responder chain from a detail panel field never reaches the canvas.
struct ZoomCommands: Commands {
    @FocusedValue(\.canvasFocus) private var focus

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Zoom In") { focus?.canvas?.zoomIn(nil) }
                .keyboardShortcut("=", modifiers: .command)
                .disabled(focus == nil)
            Button("Zoom Out") { focus?.canvas?.zoomOut(nil) }
                .keyboardShortcut("-", modifiers: .command)
                .disabled(focus == nil)
            Button("Actual Size") { focus?.canvas?.zoomToActualSize(nil) }
                .keyboardShortcut("0", modifiers: .command)
                .disabled(focus == nil)
        }
    }
}

struct ContentView: View {
    @State private var editor: CanvasEditor = ShippedPlugins.makeEditor()
    @State private var canvasFocus = CanvasFocus()
    @SceneStorage("showsDetails") private var showsDetails = true

    var body: some View {
        CanvasRepresentable(editor: editor, focus: canvasFocus)
            .frame(minWidth: 480, minHeight: 320)
            .focusedSceneValue(\.canvasFocus, canvasFocus)
            .toolbar {
                ToolbarItem(placement: .principal) { ToolPicker(editor: editor) }
            }
            .inspector(isPresented: $showsDetails) {
                ShippedPlugins.detailPanel(editor: editor, onExit: canvasFocus.take)
                    .toolbar {
                        ToolbarItem {
                            Button { showsDetails.toggle() } label: { Label("Details", systemImage: "sidebar.trailing") }
                                .help("Show or hide details")
                        }
                    }
            }
    }
}
