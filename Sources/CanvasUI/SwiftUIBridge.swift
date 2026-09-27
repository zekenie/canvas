import Canvas
import SwiftUI

/// A window's canvas view, for chrome beside it: a panel hands the keyboard back with `take()`, and
/// menu commands reach the canvas through `canvas`, whatever has the keyboard.
@MainActor
public final class CanvasFocus {
    public internal(set) weak var canvas: CanvasView?
    public init() {}

    /// Makes the canvas its window's first responder.
    public func take() {
        if let canvas { canvas.window?.makeFirstResponder(canvas) }
    }
}

public struct CanvasRepresentable: NSViewRepresentable {
    let editor: CanvasEditor
    let focus: CanvasFocus?
    let showsMinimap: Bool

    public init(editor: CanvasEditor, focus: CanvasFocus? = nil, showsMinimap: Bool = false) {
        self.editor = editor
        self.focus = focus
        self.showsMinimap = showsMinimap
    }

    public func makeNSView(context: Context) -> CanvasView {
        let canvas = CanvasView(editor: editor)
        focus?.canvas = canvas
        canvas.showsMinimap = showsMinimap
        return canvas
    }

    public func updateNSView(_ canvas: CanvasView, context: Context) {
        canvas.showsMinimap = showsMinimap
    }
}

/// The toolbar, built from the registry. The editor is observable, so this follows tool switches
/// made on the canvas (shortcuts, finishing an arrow) with no callback. `help` is each tool's
/// tooltip: the host passes one that names the tool's key ("Note (N)"), which only the plugin that
/// keeps the keys knows; the label alone otherwise.
public struct ToolPicker: View {
    let editor: CanvasEditor
    let help: @MainActor (ToolDescriptor) -> String

    public init(editor: CanvasEditor, help: @escaping @MainActor (ToolDescriptor) -> String = { $0.label }) {
        self.editor = editor
        self.help = help
    }

    public var body: some View {
        Picker("Tool", selection: Binding(get: { editor.currentToolID }, set: { editor.setTool($0) })) {
            ForEach(editor.registry.tools) { tool in
                Image(systemName: tool.systemImage).help(help(tool)).tag(tool.id)
            }
        }
        .pickerStyle(.segmented)
    }
}
